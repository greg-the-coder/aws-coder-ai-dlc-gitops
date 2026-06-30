# AWS Coder AI-DLC GitOps

AI-powered development platform on AWS: [Coder](https://coder.com) on Amazon EKS, with
**serverless Fargate workspaces** and **Coder Agents** backed by Amazon Bedrock.

![Architecture Diagram](images/AWSCoderSingleRegionv2-0.png)

## Overview

This repository deploys a complete AI-assisted development environment via a single
CloudFormation stack. Two capabilities are the focus of this platform:

- **Fargate workspaces** — developer workspaces run on AWS Fargate (serverless pods), with
  persistent home directories backed by Amazon EFS. No worker nodes to manage or scale for
  workspace compute.
- **Coder Agents** — the built-in agentic coding assistant, wired to Amazon Bedrock (native)
  and Bedrock Mantle (OpenAI-compatible) so agents run entirely on AWS-hosted models.

See [Deployment](#deployment) to run it in your own AWS account.

## Why this matters: AWS AI-DLC

This platform is purpose-built to operationalize the **AWS AI-Driven Development Life Cycle
(AI-DLC)** — AWS's methodology for adopting agentic AI across the software lifecycle while
keeping humans in control. AI-DLC structures work into a **three-phase, human-approved
workflow** — *Inception* (the what and why), *Construction* (the how), and *Review* (did it
work) — where AI agents plan, implement, and review, and engineers make the decisions at
every phase gate. Agents pause and ask when they need clarification, and requirements stay
traceable down to the code they produce.

The hard part of adopting AI-DLC is not the agents — it is giving them a place to *act*
safely. That is what this repository provides:

- **A governed execution surface.** Agentic “Construction” means agents run commands,
  install dependencies, and execute generated code. Doing that on
  [Firecracker microVM](https://firecracker-microvm.github.io/)-isolated
  [Fargate workspaces](#fargate-workspaces) confines each agent run to a disposable,
  single-tenant VM — the blast radius of an autonomous action is one sandbox.
- **Enterprise guardrails by construction.** Workspaces inherit scoped IAM roles, run inside
  your VPC, use models served through Amazon Bedrock, and are provisioned from version-
  controlled, reviewable templates. Access, networking, models, and tooling are all things
  the enterprise defines — not the agent.
- **Centralized, auditable AI access.** [Coder Agents](#coder-agents) route through
  admin-configured Bedrock providers and models, so model choice, usage, and budgets are
  governed centrally rather than per-developer.

### Fit for highly regulated enterprises — and everyone else

For **highly regulated industries** (financial services, healthcare, public sector), the
primary barrier to agentic AI is not capability but **control, isolation, and
auditability**. Running AI-DLC on this platform addresses those directly: VM-level isolation
per workspace (Firecracker), no shared kernels, data and inference kept within AWS accounts
and Regions you control, IAM/VPC boundaries around every agent, and human approval gates
built into the methodology. AWS's own [Responsible AI
Policy](https://aws.amazon.com/ai/responsible-ai/policy/) — review agent output and costs —
maps cleanly onto AI-DLC's human-in-the-loop phase gates.

The same properties let **any size enterprise** scale agentic development effectively:
start small with disposable sandboxes, keep humans deciding intent and reviewing output, and
grow agent autonomy as confidence in the guardrails grows — without standing up bespoke
isolation or governance infrastructure.

**Learn more about AI-DLC:**

- AWS DevOps Blog — [AI-Driven Development Life
  Cycle](https://aws.amazon.com/blogs/devops/ai-driven-development-life-cycle/) (methodology)
- `awslabs/aidlc-workflows` — [adaptive AI-DLC workflow rules for AI coding
  agents](https://github.com/awslabs/aidlc-workflows) (Kiro, Amazon Q, Claude Code, Cursor,
  Copilot, and more)
- `aws-samples/sample-collaborative-ai-dlc` — [collaborative AI-DLC
  platform](https://github.com/aws-samples/sample-collaborative-ai-dlc) (reference
  implementation)

## Fargate Workspaces

Workspaces are scheduled onto an EKS **Fargate profile** (`coder-workspaces`, selector
`namespace=coder-ws`) instead of EC2 worker nodes. Because Fargate does not support EBS
volumes, persistent storage uses **Amazon EFS** mounted `ReadWriteMany`.

### Firecracker microVM isolation — sandboxes for humans *and* agents

AWS Fargate runs every pod inside a dedicated
[**Firecracker microVM**](https://firecracker-microvm.github.io/). Each workspace therefore
gets hardware-virtualized, single-tenant isolation — its own kernel and a minimal,
purpose-built virtualization boundary — rather than sharing a kernel with neighboring
containers, while still booting in a fraction of a second.

That combination of **strong isolation + fast, ephemeral startup** is exactly what you want
for **cloud sandboxes used by both human developers and agentic AI**:

- **Blast-radius containment** — an autonomous agent running commands, installing packages,
  or executing generated code is confined to a single-use microVM, not a shared host.
- **Clean, reproducible environments** — workspaces are disposable; spin one up per
  developer, per task, or per agent run and throw it away.
- **Defense in depth** — VM-level isolation layers on top of Kubernetes namespaces, IAM
  scoping, and VPC network controls.

This makes the platform a safe execution surface for letting AI agents *build* — not just
suggest — inside guardrails the enterprise controls.

| Component | Purpose |
|-----------|---------|
| EKS Fargate profile `coder-workspaces` | Runs every workspace pod in the `coder-ws` namespace serverlessly |
| Dedicated Fargate subnets (2 AZs) | Private subnets for Fargate pod ENIs |
| EFS file system (encrypted, elastic throughput) | Persistent `/home/coder` per workspace, survives restarts |
| EFS mount targets + NFS security group | Reachable from Fargate pods over port 2049 within the VPC |
| `efs-static` StorageClass (`efs.csi.aws.com`) | Binds each workspace PVC to its EFS access point |
| `FargatePodExecutionRole` | Pulls images and runs pods under `AmazonEKSFargatePodExecutionRolePolicy` |

Workspace templates create an EFS access point + PV/PVC per workspace and mount it at
`/home/coder`. Tools installed outside the home directory live in the container image.

## Coder Agents

Coder Agents are configured during deployment through the Coder API (no console clicks
required). Two AI providers are provisioned:

| Provider | Type | Endpoint | Models |
|----------|------|----------|--------|
| `aws-bedrock-partner` | Bedrock (native, SigV4) | `bedrock-runtime.us-east-1` | Claude Opus 4.8 (default), Claude Haiku 4.5 (small/fast) |
| `openai-compat` | OpenAI-compatible (Bedrock Mantle) | `bedrock-mantle.us-east-1` | Mistral Large 3, Devstral 2 |

Notes:
- Anthropic models use global cross-region inference profile IDs and are served from
  **us-east-1**, independent of the stack's deployment region.
- The Bedrock Mantle (OpenAI-compatible) API key is generated automatically from an IAM
  service-specific credential and stored in Secrets Manager.
- Provider and model configuration is applied idempotently by the CodeBuild deployment
  script via `/api/v2/ai/providers` and `/api/experimental/chats/model-configs`.

## Workspace Templates

Templates live in [`templates/`](./templates) and are deployed via Terraform + the Coder
provider (see [GitOps Workflow](#gitops-workflow)). Each template's `description` and
`README.md` describe its capabilities so Coder Agents can pick the right environment.

| Template | Display Name | Best for |
|----------|--------------|----------|
| `awshp-k8s-challenge-agent` | Clash of Agents — Challenge Workspace | **Optimized for Coder Agents.** Pre-loaded Python agent frameworks (Strands, LangGraph, LangChain, LlamaIndex, Lyzr) + Bedrock. |
| `awshp-k8s-base-claudecode` | AWS Workshop — Kubernetes with Claude Code | Claude Code AI assistant with task automation. |
| `awshp-k8s-base-kirocli` | AWS Workshop — Kubernetes with Kiro CLI | Kiro CLI AI assistant for interactive development. |

All templates run on Fargate with EFS-backed persistent home directories.

## Prerequisites

- AWS account with permissions to create EKS, VPC, Aurora, CloudFront, EFS, IAM, and Secrets Manager resources
- AWS CLI configured
- Sufficient quotas for EKS, Aurora PostgreSQL, CloudFront, and VPC resources (NAT Gateways, EIPs)
- Amazon Bedrock model access enabled in **us-east-1** for the configured Claude and Mistral models

## Deployment

1. Open the AWS CloudFormation console and create a stack from
   [`infrastructure/coder_deployment.yaml`](./infrastructure/coder_deployment.yaml).
2. Set the required parameters:
   - `CoderAdminEmail`, `CoderAdminUser`, `CoderAdminPassword`, `CoderAdminName`
3. Optional parameters (defaults shown):
   - `EKSClusterName` (`coder-aws-cluster`), `KubernetesVersion` (`1.35`),
     `CoderVersion` (`2.34.4`), `CoderPremiumTrial` (`false`),
     `CoderGitOpsTemplateRepoURL`, `RetryFlag` (`False`)
4. Acknowledge IAM resource creation and create the stack (~30–45 minutes).

The stack provisions networking, Aurora PostgreSQL, the EKS cluster (Auto Mode + Fargate
profile), EFS storage, installs Coder via Helm, configures CloudFront, deploys templates,
and configures Coder Agents providers/models.

Monitor progress in the CloudFormation **Events** tab and the CodeBuild logs
(`/aws/codebuild/CodeBuild-<StackName>`).

### Access

When the stack completes, use these CloudFormation **Outputs**:

- `CoderURL` — CloudFront URL for the Coder dashboard
- `CoderAdminEmail` / `CoderAdminPassword` (also in Secrets Manager via
  `CoderAdminPasswordSecretArn`)
- `CoderSessionTokenSecretArn` — API token secret

Log in at `CoderURL`, then create a workspace from one of the templates.

## GitOps Workflow

Templates are versioned by Git SHA and applied with the Coder Terraform provider. The stack
runs [`templates/templates_gitops.sh`](./templates/templates_gitops.sh) automatically;
template metadata (name, display name, description, icon, image, EFS id) is defined in
[`templates/template_versions.tf`](./templates/template_versions.tf).

```bash
# Manual template update
cd templates/
export TF_VAR_coder_url="https://your-coder-url"
export TF_VAR_coder_token="your-session-token"
export TF_VAR_coder_gitsha="$(git log -1 --format=%H)"
terraform apply -auto-approve
```

## Architecture Summary

- **EKS** — Auto Mode (control plane + system workloads) with a dedicated **Fargate profile** for workspaces
- **Aurora PostgreSQL Serverless v2** — Coder database (encrypted, KMS)
- **CloudFront + Network Load Balancer** — secure global access to Coder
- **VPC** — public/private/Fargate subnets across 2 AZs, NAT gateways for egress
- **EFS** — persistent workspace home directories (Fargate-compatible)
- **Secrets Manager** — admin password, session token, Bedrock Mantle API key
- **IAM** — `coder-and-aws-workshop-user` workspace role (Bedrock, Bedrock Mantle, S3, Secrets Manager, EKS, EFS, etc.)

## Troubleshooting

| Symptom | Checks |
|---------|--------|
| Stack creation fails | CodeBuild logs `/aws/codebuild/CodeBuild-<StackName>`; service quotas; IAM permissions |
| Cannot reach `CoderURL` | CloudFront status is `Deployed`; NLB target health; `kubectl get pods -n coder` |
| Workspace won't start | Fargate profile is `ACTIVE`; `kubectl get sc` shows `efs-static`; EFS mount targets healthy; `kubectl get pvc -n coder-ws` |
| Coder Agent model errors | Bedrock model access in us-east-1; provider config via `/api/v2/ai/providers`; Bedrock Mantle secret populated |

## Cleanup

1. Delete all Coder workspaces from the UI.
2. Delete the CloudFormation stack.
3. Manually remove any retained resources (CloudFront distribution, logging S3 buckets, EKS
   cluster, Aurora cluster, EFS file system) if they were not auto-deleted.

## Resources

- [AWS AI-DLC (AI-Driven Development Life Cycle)](https://aws.amazon.com/blogs/devops/ai-driven-development-life-cycle/) and [awslabs/aidlc-workflows](https://github.com/awslabs/aidlc-workflows)
- [Firecracker microVM](https://firecracker-microvm.github.io/) (powers AWS Fargate isolation)
- [Coder Documentation](https://coder.com/docs)
- [Amazon EKS Fargate](https://docs.aws.amazon.com/eks/latest/userguide/fargate.html)
- [Amazon EFS CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html)
- [AWS Responsible AI Policy](https://aws.amazon.com/ai/responsible-ai/policy/)

## License

See [LICENSE](LICENSE).

## Contributing

Designed for AWS AI Builder Lab events. Follow standard GitOps practices and test changes in
a non-production environment first.

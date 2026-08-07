# Coder AWS Install Wizard

A GenAI-assisted CLI that guides customers through a **production-grade self-install** of [Coder](https://coder.com) into their own AWS account, using the [aws-coder-ai-dlc-gitops](https://github.com/greg-the-coder/aws-coder-ai-dlc-gitops) deployment.

It replaces the manual two-stack README process with:

1. **Pre-flight checks** — AWS credentials, Bedrock model access, service quotas (EKS, NAT Gateway, Aurora ACUs, EIP), ECR image dependency, and EKS cluster name conflicts.
2. **Cost estimate** — A per-team-size monthly breakdown before a single resource is created.
3. **Ordered deployment** — Deploys the image pipeline stack first (CodeBuild → ECR), waits for images, then deploys the core Coder stack — eliminating the most common `ImagePullBackOff` failure.
4. **Real-time progress** — CloudFormation events streamed to your terminal instead of "check the console".
5. **Post-install validation** — Confirms Coder API is reachable, admin token works, AI providers are wired to Bedrock, workspace templates deployed, Fargate profile is ACTIVE, and EFS is available.
6. **Install summary** — Writes `install-summary.json` with all endpoints, secret ARNs, and validation results.

---

## Prerequisites

- Python 3.10+
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configured (`aws configure` or `aws sso login`)
- IAM permissions sufficient to create EKS, VPC, Aurora, CloudFront, EFS, ECR, CodeBuild, IAM, Lambda, and Secrets Manager resources
- The `aws-coder-ai-dlc-gitops` repository cloned locally

---

## Installation

```bash
# From the repo root
pip install ./coder-install-wizard
# or for development
pip install -e ./coder-install-wizard
```

Or run directly without installing:

```bash
python -m coder_wizard
```

---

## Usage

### Interactive wizard (recommended)

```bash
coder-wizard
```

Asks a few questions, runs pre-flight, shows a cost estimate, and deploys.

### Sub-commands

```bash
# Pre-flight checks only (fast — no deploy)
coder-wizard preflight --region us-east-1 --cluster coder-aws-cluster

# Cost estimate for a 25-developer team
coder-wizard cost --developers 25 --region us-east-1

# Fully non-interactive deploy
coder-wizard deploy \
  --region us-east-1 \
  --cluster coder-aws-cluster \
  --admin-email ops@example.com \
  --admin-user admin \
  --admin-name "Platform Team" \
  --developers 20 \
  --yes

# Validate an existing deployment
coder-wizard validate \
  --coder-url  https://xxxx.cloudfront.net \
  --cluster    coder-aws-cluster \
  --efs-id     fs-0123456789abcdef0 \
  --stack-name coder-aws-cluster-coder
```

---

## Pre-flight Checks

| Check | What it verifies |
|---|---|
| AWS Credentials | `sts get-caller-identity` — valid credentials exist |
| AWS Region | Warns if deploying outside us-east-1 (Bedrock inference hardcoded there) |
| Bedrock Model Access | Checks Claude Opus 4, Claude Haiku 4.5, Mistral Large 3, Devstral 2 are accessible |
| Quota: EKS Clusters | ≥ 3 EKS clusters allowed |
| Quota: VPCs | ≥ 5 VPCs per region |
| Quota: NAT Gateways | ≥ 5 per AZ |
| Quota: Aurora ACUs | ≥ 40 Serverless v2 ACUs |
| EKS Cluster Name Conflict | No existing cluster with same name |
| ECR Workspace Images | All 3 `:latest` images exist (Step 1 complete) |

---

## Cost Estimate (10 developers, us-east-1, ~6h/day workspaces)

| Service | Est. $/month |
|---|---|
| Amazon EKS control plane | $72 |
| AWS Fargate workspaces | $219 |
| Aurora PostgreSQL Serverless v2 | $88 |
| NAT Gateway (2 AZs + data) | $101 |
| CloudFront | $5 |
| Amazon EFS | $6 |
| Amazon ECR | $1 |
| Amazon Bedrock (Claude Opus 4) | $1,350 |
| **Total** | **~$1,842/mo** |

> Bedrock costs are highly variable and scale with agent usage. Actual compute costs (Fargate, Aurora) scale down significantly outside business hours.

---

## Post-Install Validation

| Check | What it verifies |
|---|---|
| Coder API Reachable | `/api/v2/buildinfo` returns HTTP 200 |
| Admin Session Token | `/api/v2/users/me` returns the admin user |
| Coder AI Providers | At least one provider enabled (bedrock + openai-compat) |
| Workspace Templates | At least one active template deployed via GitOps |
| EKS Fargate Profile | `coder-workspaces` profile is ACTIVE |
| EFS File System | EFS is in `available` state |

---

## Output: install-summary.json

```json
{
  "installed_at": "2026-08-07T17:00:00+00:00",
  "region": "us-east-1",
  "eks_cluster_name": "coder-aws-cluster",
  "coder_url": "https://xxxx.cloudfront.net",
  "admin_password_secret_arn": "arn:aws:secretsmanager:...",
  "admin_session_token_secret_arn": "arn:aws:secretsmanager:...",
  "efs_file_system_id": "fs-0123456789",
  "validation_passed": true,
  "next_steps": [...]
}
```

---

## Architecture of the Wizard

```
coder_wizard/
├── __main__.py       ← CLI entry point, wizard UI, sub-command dispatch
├── preflight.py      ← Pre-flight check suite (credentials, quotas, Bedrock, ECR)
├── deploy.py         ← CloudFormation deploy orchestrator + CodeBuild waiter
├── validate.py       ← Post-install validation suite
├── cost_estimate.py  ← Static monthly cost estimator
└── summary.py        ← install-summary.json writer + human-readable summary
```

---

## Roadmap

- [ ] Bedrock cost usage query (actual token consumption post-install)
- [ ] `--dry-run` mode: generate parameter file without deploying
- [ ] Multi-region awareness (warn on specific model availability per region)
- [ ] Upgrade flow: detect running Coder version, show changelog, upgrade in-place
- [ ] Uninstall wizard with ordered resource cleanup

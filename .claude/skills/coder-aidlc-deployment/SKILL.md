---
name: coder-aidlc-deployment
description: Use this skill when reviewing, editing, deploying, debugging, or tearing down THIS AWS Coder AI-DLC GitOps deployment — i.e. any change to infrastructure/coder_deployment.yaml (the CloudFormation stack and its embedded CodeBuild buildspec), the image pipeline stack, infrastructure/helm/coder-values.yaml, the ai-providers/ coderd Terraform (AI Gateway providers, Coder Agents models, MCP servers), the templates/ Coder workspace templates, Amazon Bedrock / AI Gateway / session-logging wiring, IAM for the Bedrock API-key user, or infrastructure/scripts/teardown.sh. Also use it when a CodeBuild deploy or a `coder templates push` fails, or a CloudFormation stack delete fails.
license: Apache-2.0
---

# Coder AI-DLC deployment operations

A playbook for safely reviewing and updating this repo's automated Coder deployment. Read
[`AGENTS.md`](../../../AGENTS.md) first for the repo map, version pins, and the Golden Rules; this
skill adds task-scoped procedures and a known-error→fix table. **Always validate before deploying**
(30–45-minute feedback loop) and prefer pushing template changes to a live deployment so the
server-side `terraform plan` validates them.

## Where logic lives (mental model)

- **`infrastructure/coder_deployment.yaml`** is 90% of the system. Besides the CFN resources, its
  `BuildProject` embeds a `post_build.sh` (a YAML `|` literal block) that: creates the EKS cluster
  with `eksctl` (Auto Mode), installs Coder via Helm, creates the Bedrock API key + Marketplace
  agreement, applies `ai-providers/` and `templates/` Terraform, and wires CloudFront. Most bugs
  are in this buildspec. Extract and `bash -n` it after edits (command in `AGENTS.md`).
- **`ai-providers/`** and **`templates/`** are `coderd` Terraform, applied by the buildspec.
- The EKS cluster and its add-ons are **eksctl-managed** → they live in *separate* CFN stacks the
  core stack doesn't own (matters for teardown).

## Task playbooks

### A. Editing the AI Gateway / Bedrock providers (`ai-providers/`, or the buildspec's provider step)
- Two providers: `bedrock` (native, Pod Identity IAM / SigV4) and `openai-compat` (Bedrock native
  OpenAI endpoint `…/openai/v1`, **bearer-token** auth using the ABSK Bedrock API key).
- The `openai-compat` path authorizes as the `bak-<stack>` IAM user and needs, in
  `BedrockInvokeAccessPolicy`: `bedrock:CallWithBearerToken`, `aws-marketplace:ViewSubscriptions`,
  `aws-marketplace:Subscribe`.
- **OpenAI GPT models are AWS Marketplace models** — invocation 403s until an account-level
  agreement exists (true even for admins). The buildspec creates it via
  `list-foundation-model-agreement-offers` + `create-foundation-model-agreement` for each id in
  `BEDROCK_MARKETPLACE_MODELS`. **When you add an OpenAI model**, add it to that list AND add a
  `coderd_agents_model` in `ai_providers.tf`. Anthropic/xAI don't need an agreement.
- If bumping the `coderd` provider constraint, refresh `ai-providers/.terraform.lock.hcl` (Golden Rule #4).

### B. Editing workspace templates (`templates/*/main.tf`, `template_versions.tf`)
- **Route agents through the AI Gateway** for session logging: set agent-wide `ANTHROPIC_BASE_URL`
  / `OPENAI_BASE_URL` = `<access_url>/api/v2/ai-gateway/<provider-name>` (`bedrock`/`openai-compat`
  — the provider NAME), API key = `data.coder_workspace_owner.me.session_token`. Never
  `CLAUDE_CODE_USE_BEDROCK=1`.
- **Claude Code** uses module `coder/claude-code` `5.4.0`. No `dangerously_skip_permissions` /
  `report_tasks` / `subdomain` / web app. Permission bypass + no-`availableModels` handled in the
  agent `startup_script`; a `coder_script` pre-approves the rotating API key each start; a
  `coder_app` "claude-code" is the launcher (command app → **no `subdomain`**).
- **IDE modules (latest):** `code-server 1.6.0`, `vscode-web 1.6.2` (`accept_license = true`),
  `vscode-desktop 1.3.0`, `kiro 1.2.2`. HTTP IDEs (`code-server`, `vscode-web`) → `subdomain =
  false`. `vscode-desktop` opens the user's *local* VS Code (needs the Coder extension locally).
- `coderd_template.description` **≤ 127 chars** (Golden Rule #5). `local.cost = 0`.
- Validate by pushing to a live deployment: `coder templates push <name> -d templates/<dir>
  --variable namespace=coder-ws --variable workspace_image=<uri> --variable efs_file_system_id=<id>
  --name <ver> --activate --yes` (use a version-matched CLI).

### C. Editing the CloudFormation / CodeBuild deploy (`coder_deployment.yaml`)
- Keep every step **idempotent** (Golden Rule #11): `helm upgrade --install`; guard
  `create-fargate-profile` / `create-pod-identity-association` / `describe-cluster`; `kubectl apply`
  (or `create … --dry-run=client -o yaml | kubectl apply -f -`) not bare `create`; gate first-user
  + AI-provider setup on `GET /api/v2/users/first` == 200.
- IAM names ≤ 64 chars. `CoderLicenseKey` stays `NoEcho`.
- After editing, extract and `bash -n` the embedded `post_build.sh` (AGENTS.md command).

### D. Teardown (`infrastructure/scripts/teardown.sh`)
- Order matters: workspaces + Helm/**NLB** (wait until the NLB is gone) → `eksctl delete cluster`
  → **retained Aurora then EFS** → full Bedrock IAM user cleanup (all inline+managed policies,
  keys, service-specific creds) → SSM params → **empty stack S3 buckets** → core stack last.
- Long waits (`wait_rds`, `wait_stack_delete`) print a 15s heartbeat to survive CloudShell's
  inactivity timeout — keep that pattern for any new long wait.
- Always offer `--dry-run` first.

## Validation cheat-sheet
See `AGENTS.md` → "Validate BEFORE you deploy" for the exact CFN-YAML, HCL, and embedded-script
checks. Run them on every change.

## Known error → cause → fix

| Error (from CodeBuild / Terraform / CloudFormation) | Cause | Fix |
|---|---|---|
| `Invalid Attribute Value Length … description … at most 127, got: N` | `coderd_template.description` too long | Trim to ≤127 chars |
| `locked provider … coder/coderd X does not match configured version constraint >= 0.0.25` | Stale lock file | Update `.terraform.lock.hcl` (templates/ and ai-providers/) to a `>= 0.0.25` version |
| `bedrock:CallWithBearerToken … no identity-based policy allows` (401) | `bak-` user missing the bearer action | Add `bedrock:CallWithBearerToken` to `BedrockInvokeAccessPolicy` |
| `not authorized to perform the required AWS Marketplace actions` (403) on an OpenAI model | No account Marketplace agreement (and/or missing marketplace IAM) | Ensure the model id is in `BEDROCK_MARKETPLACE_MODELS` (buildspec creates the agreement) + user has `aws-marketplace:ViewSubscriptions/Subscribe` |
| `Model "…opus-4-6…" is restricted by your organization's settings. Using … instead` | `availableModels: []` in `~/.claude/settings.json` | Remove it (`del(.availableModels)`); never set an empty allow-list |
| `"command": conflicts with subdomain` | `subdomain` set on a `coder_app` that uses `command` | Remove `subdomain` from command/terminal apps |
| `userName … must have length less than or equal to 64` | IAM name too long | Shorten the static prefix |
| Stack `DELETE_FAILED`: `bucket … is not empty` | CFN can't delete a non-empty S3 bucket | Empty the bucket first (teardown does this) |
| Stack `DELETE_FAILED`: IAM user `must delete policies first` | Out-of-band inline/managed policy on the `bak-` user | Remove ALL user policies/creds before stack delete (teardown does this) |
| Stack delete stuck on VPC / ENIs | Orphaned NLB from the Coder Service | `helm uninstall coder` and wait for the NLB to be deleted before deleting the cluster/VPC |
| CloudShell disconnects mid-teardown | Silent multi-minute `aws … wait` | Use the heartbeat pollers (`wait_rds`, `wait_stack_delete`) |

## Scope guardrails
- This deployment is **Fargate-only** — do not add an EC2 Spot compute lane.
- Only **Codex** uses AWS Labs MCP servers; **Claude Code** and **Kiro CLI** use Fiddler/LangSmith/LlamaCloud.
- Keep the workshop's own repo URLs (`greg-the-coder/...`); don't copy upstream `coder/...` defaults.
- Work on a feature branch; never commit to `main` without explicit confirmation.

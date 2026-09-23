# AGENTS.md

Operational guide for AI coding agents (Coder Agents / Claude Code / Codex / Cursor) working
on this repository. This repo deploys **Coder v2.37.x with Coder Agents (GA)** on **Amazon EKS
(Auto Mode) + AWS Fargate**, driven almost entirely by a **CloudFormation stack whose CodeBuild
buildspec does the heavy lifting**. Small mistakes here fail 30–45-minute deploys, so read the
Golden Rules before changing anything.

> Deep, task-scoped procedures and the error→fix table live in the Agent Skill at
> [`.claude/skills/coder-aidlc-deployment/SKILL.md`](.claude/skills/coder-aidlc-deployment/SKILL.md).
> Coder Agents / Claude Code auto-discover it from this repo.

## Repository map

| Path | What it is | Notes |
|------|------------|-------|
| `infrastructure/coder_deployment.yaml` | **Core CloudFormation stack** (VPC, CloudFront, Aurora, EFS, KMS, IAM, secrets) **and the CodeBuild buildspec** that creates the EKS cluster (via `eksctl`), installs Coder via Helm, and applies AI providers + templates | The buildspec `post_build.sh` is embedded as a YAML literal block — most logic lives here |
| `infrastructure/codebuild_image_pipeline.yaml` | Builds the workspace container images to ECR | **Deploy this stack FIRST** |
| `infrastructure/helm/coder-values.yaml` | Coder Helm values (AI Gateway, experiments, HA, CSP) | `coder.example.com` placeholders are `sed`-patched to the CloudFront domain at deploy |
| `infrastructure/k8s/` | RBAC, gp3/EFS storageclasses, `coder-ws` service account | |
| `infrastructure/scripts/irsa-trust-policy-update.sh` | Adds the IRSA trust statement to the workshop role | |
| `infrastructure/scripts/teardown.sh` | **Comprehensive teardown** (dependency-ordered) | See Teardown section |
| `ai-providers/` | `coderd` **Terraform** for AI Gateway providers, Coder Agents models, and MCP servers | Applied by the buildspec on first init |
| `templates/` | Coder **workspace templates** (`coderd` Terraform, one dir per template) | Applied via `templates/templates_gitops.sh` |
| `images/` | Dockerfiles for the workspace images | |

## Platform versions / pins (keep in sync)

- **Coder:** `2.37.x` (`CoderVersion` default in `coder_deployment.yaml`; Coder Agents GA).
- **`coderd` Terraform provider:** `>= 0.0.25` (AI Gateway + `coderd_agents_*` resources). The
  lock files **must** pin a matching version — see Golden Rule #4.
- **Terraform:** `>= 1.11` (write-only args like `api_key_wo`); the ai-providers wrapper installs it.
- **Templates:** `coder/coder` provider `2.37.1`, `hashicorp/kubernetes` `2.37.1`, `random` `3.7.2`, `aws >= 5.0`.
- **Compute:** **Fargate-only** (namespace `coder-ws`, Fargate profile selector `namespace=coder-ws`). Do **not** add an EC2 Spot lane.
- **Models:** Opus 4.6 `global.anthropic.claude-opus-4-6-v1` (default), Haiku 4.5, `us.openai.gpt-5.6-sol`, `us.xai.grok-4.6`. Anthropic inference profiles live in **us-east-1**.

## Golden Rules (hard-won; violating these breaks deploys)

1. **Two-stack order:** deploy `codebuild_image_pipeline.yaml` **before** `coder_deployment.yaml`, same account/Region/`EKSClusterName`.
2. **Bedrock OpenAI-compat is a BEARER-token path, not SigV4.** The `bak-<stack>` IAM user needs `bedrock:CallWithBearerToken` **and** `aws-marketplace:ViewSubscriptions`/`Subscribe`. **OpenAI GPT models require a one-time account-level Bedrock Marketplace agreement** (`create-foundation-model-agreement`); the buildspec auto-creates it for every id in `BEDROCK_MARKETPLACE_MODELS`. Native Bedrock (Anthropic) uses Pod Identity (SigV4) and needs no agreement.
3. **IAM names ≤ 64 chars.** Keep static prefixes short (the Bedrock user is `bak-${AWS::StackName}`).
4. **`coderd` lock files must satisfy the version constraint.** If you bump `>= 0.0.25`, the `version` in `templates/.terraform.lock.hcl` and `ai-providers/.terraform.lock.hcl` must be `>= 0.0.25` too — a stale lock (e.g. `0.0.19`) fails `terraform init` (`does not match configured version constraint`).
5. **`coderd_template.description` ≤ 127 UTF-8 chars.** (The README/front-matter `description` has no limit — don't confuse them.)
6. **AI Gateway routing = provider NAME, not API type.** Set `ANTHROPIC_BASE_URL`/`OPENAI_BASE_URL` to `<access_url>/api/v2/ai-gateway/<provider-name>` where `<provider-name>` is the `coderd_ai_provider` name in `ai-providers/` (`bedrock` / `openai-compat`). Auth is the workspace owner's Coder session token. **Never set `CLAUDE_CODE_USE_BEDROCK=1`** — it bypasses the gateway (SigV4 direct) and produces **no AI Session logs**.
7. **Claude Code v5 (module `5.4.0`)** dropped `dangerously_skip_permissions` / `report_tasks` / `subdomain` / `order` / the web app. Set permission bypass in user-scope `~/.claude/settings.json`. **Do NOT set `availableModels: []`** — an empty array is an allow-list of *nothing*, so Claude Code reports the gateway model "restricted by your organization's settings" and falls back to a model the gateway can't serve. Pre-approve the (rotating) session-token API key in `~/.claude.json` `customApiKeyResponses.approved` on every start.
8. **No wildcard app subdomains in this deployment.** HTTP IDE apps (`code-server`, `vscode-web`) must set `subdomain = false`. A `coder_app` with `command` (terminal app, e.g. the Claude Code launcher) **must not** set `subdomain` at all — the provider rejects `subdomain` + `command`.
9. **`DeletionPolicy: Retain` on EFS + Aurora.** They survive `delete-stack` **and block it** (their networking is stack-owned). The teardown deletes them **before** the stack.
10. **`local.cost = 0`** in every template (feeds `coder_metadata.daily_cost`) so workspaces don't trip quota on initial deploy.
11. **The deploy is idempotent / self-healing.** First-run vs retry is detected from real state (`GET /api/v2/users/first`), not just `RetryFlag`. Keep new steps idempotent (`helm upgrade --install`, existence-guarded creates, `kubectl apply` over `create`). If you use `RetryFlag=True`, set it via a **stack UPDATE** (a console "Start build" reuses the old value).
12. **`CoderLicenseKey` is `NoEcho`** and gates HA (`replicaCount: 2`) + the MCP-servers API. Keep it `NoEcho`.

## Validate BEFORE you deploy (no CI catches these for you)

```bash
# CloudFormation YAML (tolerate !Ref/!Sub/!GetAtt intrinsic tags)
python3 - <<'PY'
import yaml
class L(yaml.SafeLoader): pass
L.add_multi_constructor('!', lambda l,s,n: l.construct_scalar(n) if isinstance(n,yaml.ScalarNode)
    else l.construct_sequence(n) if isinstance(n,yaml.SequenceNode) else l.construct_mapping(n))
yaml.load(open('infrastructure/coder_deployment.yaml'), Loader=L); print('CFN YAML OK')
PY

# Terraform (HCL) syntax for ai-providers and every template
python3 -c "import hcl2,glob; [hcl2.load(open(f)) for f in glob.glob('**/*.tf',recursive=True)]; print('HCL OK')"

# Shell scripts, including the buildspec's embedded post_build.sh
bash -n infrastructure/scripts/teardown.sh
python3 - <<'PY'   # extract + syntax-check the embedded post_build.sh
import yaml,re
class L(yaml.SafeLoader): pass
L.add_multi_constructor('!', lambda l,s,n: l.construct_scalar(n) if isinstance(n,yaml.ScalarNode) else (l.construct_sequence(n) if isinstance(n,yaml.SequenceNode) else l.construct_mapping(n)))
bs=yaml.load(open('infrastructure/coder_deployment.yaml'),Loader=L)['Resources']['BuildProject']['Properties']['Source']['BuildSpec']
m=re.search(r"cat > post_build\.sh << 'POST_EOF'\n(.*?)\n\s*POST_EOF",bs,re.S)
open('/tmp/pb.sh','w').write("\n".join(l[18:] if l.startswith(' '*18) else l for l in m.group(1).splitlines()))
PY
bash -n /tmp/pb.sh && echo "post_build.sh OK"
```
Requires `pip install --break-system-packages pyyaml python-hcl2` if not present.

## Applying changes to a running deployment

- **Templates:** `coder templates push <name> -d templates/<dir> --variable namespace=coder-ws --variable workspace_image=<ecr-uri> --variable efs_file_system_id=<fs-id> --name <ver> --activate --yes`. Use a **matching CLI version** (`curl -fsSL $CODER_URL/install.sh | sh`); the server-side `terraform plan` catches invalid args. Discover values from stack outputs/SSM.
- **AI providers:** re-run `ai-providers/ai_providers_gitops.sh <session-token>` (or the buildspec). Terraform state is **ephemeral in CodeBuild**, so this only runs on first init.
- A full re-deploy uses `RetryFlag` (see Golden Rule #11).

## Teardown (`infrastructure/scripts/teardown.sh`)

`delete-stack` alone fails. The script, in dependency order: deletes Coder workspaces + the
control-plane **NLB** (waits for it to disappear so ENIs don't block the VPC), `eksctl delete
cluster` (EKS is eksctl-managed in separate stacks), the **retained Aurora + EFS**, **all** the
Bedrock IAM user's policies/creds, SSM params, **empties the stack's S3 buckets** (CFN can't
delete a non-empty bucket), then the core stack last. Long AWS waits print a 15s heartbeat so
**AWS CloudShell doesn't disconnect** on inactivity. Run with `--dry-run` first;
`--image-stack <name>` also removes the image pipeline + ECR.

## Git workflow

- Work on a **feature branch** (this work lives on `feature/coder-agents-ga`). Never commit to `main`/protected branches without explicit confirmation.
- Validate (above), commit with a clear message explaining the *why* (especially the failure a change fixes), and push the feature branch.

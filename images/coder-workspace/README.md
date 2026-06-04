# Coder Workspace Image

Pre-built container image for Coder workspaces running on EKS Fargate.

Fargate enforces `allowPrivilegeEscalation: false`, so all system packages and tools must be pre-installed in the image (no `sudo` at runtime).

## Base Image

`codercom/enterprise-base:ubuntu`

## Pre-installed Tools

| Tool | Version | Purpose |
|------|---------|---------|
| Node.js | 20 LTS | CDK, MCP servers, npm packages |
| AWS CLI | v2 (latest) | AWS API access |
| AWS CDK | latest | Infrastructure as Code |
| uv / uvx | latest | Python package manager, MCP server runner |
| Kiro CLI | latest | Kiro AI agent |
| nctl | 4.10.7-rc.6 | Nirmata CLI |
| jq | system | JSON processing |
| git | system | Version control |
| curl, unzip, gnupg | system | Utility tools |

## Building

```bash
docker build -t coder-workspace:latest .
```

## Publishing to ECR Public

```bash
aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws/coder-aws
docker tag coder-workspace:latest public.ecr.aws/coder-aws/coder-workspace:latest
docker push public.ecr.aws/coder-aws/coder-workspace:latest
```

## Fargate Constraints

- Runs as uid 1000 (`coder` user)
- No `sudo` available at runtime
- `allowPrivilegeEscalation: false` enforced
- All packages must be baked into the image

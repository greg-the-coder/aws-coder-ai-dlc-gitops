---
display_name: AWS Workshop - Kubernetes with Kiro CLI
description: Fargate workspace with the Kiro CLI AI assistant, AWS CLI/CDK, Node.js, Nirmata CLI, and Amazon Bedrock access.
icon: ../../../site/static/icon/k8s.png
maintainer_github: coder
verified: true
tags: [kubernetes, fargate, ai, kiro, kiro-cli, bedrock, mcp]
---

# Kubernetes with Kiro CLI

A serverless Coder workspace running on **AWS Fargate** with the
[Kiro CLI](https://kiro.dev/docs) AI assistant. The home directory is persisted on
**Amazon EFS** so installed tools and work survive workspace restarts.

## Capabilities

### AI assistant
- **Kiro CLI** (`kiro-cli`, `kiro-cli-chat`) for interactive, command-line AI development
- **Kiro IDE** web app
- **MCP** (Model Context Protocol) support — pre-seeded `~/.kiro/settings/mcp.json`
- **Amazon Bedrock** access via the workspace IAM role

### Developer environment
- **code-server** (VS Code in the browser)
- One-click **Kiro CLI** authentication app (`kiro-auth`)
- Web terminal
- Node.js 20 LTS, AWS CLI v2, AWS CDK
- Nirmata CLI (`nctl`)

## Runtime & infrastructure
- **Compute:** AWS Fargate (namespace `coder-ws`), no EC2 worker nodes
- **Storage:** Amazon EFS access point mounted at `/home/coder` (`ReadWriteMany`, persistent)
- **Image:** [`images/coder-workspace-kiro-cli/Dockerfile`](../../images/coder-workspace-kiro-cli/Dockerfile)

## Parameters

| Parameter | Default | Range |
|-----------|---------|-------|
| CPU cores | 4 | 2–8 |
| Memory (GB) | 8 | 4–16 |

Storage is provisioned automatically via EFS; there is no disk-size parameter.

## Getting started
1. Create a workspace from this template.
2. Click the **Kiro CLI** (authenticate) app to log in.
3. Open code-server or Kiro and use `kiro-cli chat` in the terminal.

## Notes
- Tools installed outside `/home/coder` are part of the container image; rebuild the image to
  add system packages. Files under `/home/coder` persist across restarts.
- For Coder Agents, the [`awshp-k8s-challenge-agent`](../awshp-k8s-challenge-agent) template
  is the environment optimized for agentic use.

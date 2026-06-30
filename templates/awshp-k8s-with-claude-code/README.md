---
display_name: AWS Workshop - Kubernetes with Claude Code
description: Fargate workspace with the Claude Code AI assistant and task automation, AWS CLI/CDK, Node.js, and Amazon Bedrock access.
icon: ../../../site/static/icon/k8s.png
maintainer_github: coder
verified: true
tags: [kubernetes, fargate, ai, claude, claude-code, bedrock, task-automation]
---

# Kubernetes with Claude Code

A serverless Coder workspace running on **AWS Fargate** with the
[Claude Code](https://coder.com/docs/claude-code) AI assistant. The home directory is
persisted on **Amazon EFS** so work survives workspace restarts.

## Capabilities

### AI assistant
- **Claude Code** CLI (`@anthropic-ai/claude-code`) with **task automation** and task
  reporting back to Coder (`report_tasks = true`)
- **Amazon Bedrock** integration — defaults to Claude Opus 4.8
  (`global.anthropic.claude-opus-4-8`) via the workspace IAM role

### Developer environment
- **code-server** (VS Code in the browser) and **Kiro IDE** web app
- Web terminal
- Node.js 20 LTS, AWS CLI v2, AWS CDK
- Playwright (headless Chromium) for web access
- Python 3

## Runtime & infrastructure
- **Compute:** AWS Fargate (namespace `coder-ws`), no EC2 worker nodes
- **Storage:** Amazon EFS access point mounted at `/home/coder` (`ReadWriteMany`, persistent)
- **Image:** [`images/coder-workspace-claude-code/Dockerfile`](../../images/coder-workspace-claude-code/Dockerfile)

## Parameters

| Parameter | Default | Range |
|-----------|---------|-------|
| CPU cores | 4 | 2–8 |
| Memory (GB) | 8 | 4–16 |

Storage is provisioned automatically via EFS; there is no disk-size parameter.

## Notes
- Tools installed outside `/home/coder` are part of the container image; rebuild the image to
  add system packages. Files under `/home/coder` persist across restarts.
- For Coder Agents, the [`awshp-k8s-challenge-agent`](../awshp-k8s-challenge-agent) template
  is the environment optimized for agentic use.

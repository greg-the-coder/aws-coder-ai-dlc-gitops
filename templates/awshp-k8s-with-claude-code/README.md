---
display_name: AWS Workshop - Kubernetes with Claude Code
description: Fargate Claude Code workspace routed through the Coder AI Gateway (Claude Opus 4.6 on Amazon Bedrock) with AI Session logging, VS Code (browser + desktop), AWS CLI/CDK, Node.js, and MCP servers.
icon: ../../../site/static/icon/k8s.png
maintainer_github: coder
verified: true
tags: [kubernetes, fargate, ai, claude, claude-code, coder-ai-gateway, bedrock]
---

# Kubernetes with Claude Code

A serverless Coder workspace running on **AWS Fargate** with the
[Claude Code](https://coder.com/docs/claude-code) AI assistant, routed through the
**Coder AI Gateway**. The home directory is persisted on **Amazon EFS** so work survives
workspace restarts.

## Capabilities

### AI assistant
- **Claude Code** CLI (`@anthropic-ai/claude-code`, module `coder/claude-code` v5.4.0),
  launched from the **Claude Code** app tile (a `coder_app` launcher) or the web terminal.
- **Coder AI Gateway** routing — Claude Code and the notebook SDKs send every model request
  through the **Coder AI Gateway** (`ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` →
  `<access_url>/api/v2/ai-gateway/<provider>`), authenticated with the user's Coder session
  token. The gateway forwards to the admin-configured Amazon Bedrock provider (default
  **Claude Opus 4.6**, `global.anthropic.claude-opus-4-6-v1`) using the control plane's
  centrally-held credentials — no AWS keys in the workspace — so all usage is governed and
  observable by the **Coder AI Governance Add-On** (prompts, spend, and tool calls appear in
  Coder AI Session logs).
  > Requires Coder v2.32+ with the Coder AI Governance Add-On enabled on the deployment.
- **No prompts on start** — the workspace enables bypass-permissions mode at user scope and
  pre-approves the session-token API key, so Claude Code never shows the permission or
  "Detected a custom API key" prompts.
- **MCP** (Model Context Protocol) servers configured at user scope: **Fiddler GenAI**
  (observability) and **LangSmith** over remote HTTP, and **LlamaCloud** (LlamaIndex) over
  stdio via `uvx`. Each is enabled only when its API-key variable is supplied.

### Developer environment
- **code-server** (VS Code in the browser) and **VS Code Desktop** (opens the workspace in
  your local VS Code via the Coder Remote extension) — both pre-install the Jupyter extension
- Web terminal
- Node.js 20 LTS, AWS CLI v2, AWS CDK
- Playwright (headless Chromium) for web access
- Python 3 with a **Python (Agents)** Jupyter kernel; its Anthropic/OpenAI SDK calls also
  route through the Coder AI Gateway (via the agent-wide `ANTHROPIC_BASE_URL` /
  `OPENAI_BASE_URL`)

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
- **Bedrock SigV4 is not gateway-routable:** `boto3` `bedrock-runtime` and `langchain-aws`
  `ChatBedrock` still call Amazon Bedrock **directly** via the workspace IAM role. Use the
  Anthropic/OpenAI clients (which honor `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL`) to route
  through the Coder AI Gateway.
- **VS Code Desktop** opens the user's *local* VS Code, so testers need VS Code installed
  locally with the Coder extension; **code-server** is fully browser-based and needs nothing
  local.
- Tools installed outside `/home/coder` are part of the container image; rebuild the image to
  add system packages. Files under `/home/coder` persist across restarts.
- For building and deploying AI agents to AWS, the
  [`awshp-k8s-challenge-agent`](../awshp-k8s-challenge-agent) template ships the agent
  frameworks + AWS deploy tooling.

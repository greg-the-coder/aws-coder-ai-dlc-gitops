---
display_name: AWS Workshop - Kubernetes with OpenAI Codex
description: Fargate OpenAI Codex CLI workspace routed through the Coder AI Gateway (GPT-5.6 Sol on Amazon Bedrock), with AWS Labs MCP servers, AWS CLI/CDK, Node.js, and Amazon Bedrock access.
icon: ../../../site/static/icon/k8s.png
maintainer_github: coder
verified: true
tags: [kubernetes, fargate, ai, openai, codex, coder-ai-gateway, bedrock]
---

# Kubernetes with OpenAI Codex

A serverless Coder workspace running on **AWS Fargate** with the
[OpenAI Codex](https://github.com/openai/codex) CLI. The home directory is
persisted on **Amazon EFS** so work survives workspace restarts. This mirrors the
Claude Code template, swapping the assistant for Codex routed through the Coder AI
Gateway.

## Capabilities

### AI assistant
- **Codex** CLI (installed by the `coder-labs/codex` module), opened from the **Codex**
  app tile (a launcher `coder_app`) or the web terminal.
- **Coder AI Gateway** routing — Codex sends every model request through the
  **Coder AI Gateway** via the `openai-compat` provider
  (`OPENAI_BASE_URL = <access_url>/api/v2/ai-gateway/openai-compat/v1`), authenticated
  with the user's Coder session token (`OPENAI_API_KEY`). The gateway forwards to the
  admin-configured Amazon Bedrock provider (default **GPT-5.6 Sol**,
  `us.openai.gpt-5.6-sol`) using the control plane's centrally-held credentials — no AWS
  keys in the workspace — so all usage is governed and observable by the **Coder AI
  Governance Add-On** (prompts, spend, and tool calls appear in Coder AI Session logs).
  > Requires Coder v2.32+ with the Coder AI Governance Add-On enabled on the deployment.
- **MCP** (Model Context Protocol) — the same citizen-builder set of
  [AWS Labs MCP servers](https://github.com/awslabs/mcp) as the Claude Code template is
  configured for Codex (native `[mcp_servers.*]` TOML) and run on demand via `uvx`:
  **IaC** (CloudFormation + CDK), **pricing**, **Serverless**, and **CloudWatch** —
  covering the design → cost → build/deploy → operate lifecycle. Calls use the workspace
  IAM role (IRSA); Codex forwards the pod environment to the stdio MCP servers, so the
  `<cluster>-workshop-user` role/token are inherited automatically (no runtime credential
  injection needed).

### Codex configuration notes
The template bakes a `config.toml` (via the module's `base_config_toml`) tuned for the
Bedrock-backed gateway. Non-obvious settings and why they are required:

- `wire_api = "responses"` — Codex ≥ 0.153 dropped the `"chat"` wire API; the Bedrock
  OpenAI endpoint serves the **Responses API** for GPT-5.6, verified through the gateway.
- `web_search = "disabled"` — Codex attaches a hosted `web_search` tool by default, which
  Amazon Bedrock's OpenAI endpoint rejects ("web search is not supported for this
  request"); disabling it lets turns complete.
- `sandbox_mode = "danger-full-access"` — the workspace is an isolated Fargate microVM
  (already a sandbox) and lacks `bubblewrap`, which Codex's `workspace-write` OS sandbox
  requires; without this the shell/exec tool fails ("sandbox launcher lacks bwrap").
- `features.tool_search_always_defer_mcp_tools = false` — expose the AWS MCP tools
  directly to the model instead of hiding them behind a tool-search step (which the model
  otherwise does not invoke, reporting tools "unavailable").

> The path segment (`openai-compat`) is the **AI Gateway provider name** from
> `ai-providers/`, not the API type — the gateway routes `/api/v2/ai-gateway/<provider-name>/`.

### Notebooks & agent SDKs (Coder AI Gateway)
The agent kernel (`Python (Agents)`) inherits `OPENAI_BASE_URL` and `OPENAI_API_KEY`, so
OpenAI-protocol clients route through the gateway with no extra config:

```python
# OpenAI protocol -> gateway -> Bedrock (OpenAI-compatible) provider
from langchain_openai import ChatOpenAI
llm = ChatOpenAI(model="us.openai.gpt-5.6-sol")   # or "us.xai.grok-4.6"
```

> **Bedrock SigV4 is not gateway-routable.** The AI Gateway only exposes OpenAI- and
> Anthropic-compatible endpoints, so `boto3` `bedrock-runtime`, `langchain-aws`
> `ChatBedrock`, and `llama-index-llms-bedrock` still call Amazon Bedrock **directly**
> via the workspace IAM role. Use the OpenAI clients above to route through the gateway.

### Developer environment
- **VS Code Web** (official VS Code Server in the browser) and **VS Code Desktop**
  (opens the workspace in your local VS Code via the Coder Remote extension)
- Web terminal
- Node.js 20 LTS, AWS CLI v2, AWS CDK
- Python 3

## Runtime & infrastructure
- **Compute:** AWS Fargate (namespace `coder-ws`), no EC2 worker nodes
- **Storage:** Amazon EFS access point mounted at `/home/coder` (`ReadWriteMany`, persistent)
- **Image:** reuses the Claude Code workspace image
  ([`images/coder-workspace-claude-code/Dockerfile`](../../images/coder-workspace-claude-code/Dockerfile)),
  which already ships Node.js/npm/uv and the pre-warmed uv cache Codex + the MCP servers need.

## Parameters

| Parameter | Default | Range |
|-----------|---------|-------|
| CPU cores | 2 | 2–8 |
| Memory (GB) | 4 | 4–16 |

Storage is provisioned automatically via EFS; there is no disk-size parameter.

## Notes
- Tools installed outside `/home/coder` are part of the container image; rebuild the image to
  add system packages. Files under `/home/coder` persist across restarts.
- For building and deploying AI agents to AWS, the [`awshp-k8s-challenge-agent`](../awshp-k8s-challenge-agent)
  template ships the agent frameworks + AWS deploy tooling.

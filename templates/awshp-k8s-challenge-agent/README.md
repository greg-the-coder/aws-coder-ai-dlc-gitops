---
display_name: AWS Workshop - AI Agent Development
description: Build advanced AI agents and deploy them to AWS. Fargate workspace pre-loaded with agent frameworks (Strands, LangGraph, LangChain, LlamaIndex, Lyzr), AWS CDK/CLI, and Amazon Bedrock access.
icon: ../../../site/static/icon/k8s.png
maintainer_github: coder
verified: true
tags: [kubernetes, fargate, ai, agents, agent-development, bedrock, python, coder-agents]
optimized_for: coder-agents
---

# AI Agent Development on AWS

> **Optimized for Coder Agents.** This is also the recommended template for running
> [Coder Agents](https://coder.com/docs): the agent frameworks and Amazon Bedrock
> tooling are pre-installed, so an agent — or a human builder — can start building on
> the first turn without setting up the environment.

A serverless Coder workspace for **building advanced AI agents and deploying them to AWS**.
It runs on **AWS Fargate** with a persistent EFS-backed home directory and comes with a
curated set of agentic-AI frameworks, AWS SDKs/tooling, and Amazon Bedrock access baked into
the image — everything you need to go from prototype to a deployable agent.

## Why this template

- **Batteries-included agent stack** — the major Python agent frameworks, AWS SDKs, and
  Bedrock integrations are installed system-wide, so you can build and iterate immediately.
- **Deploy to AWS** — AWS CLI v2 and AWS CDK are preinstalled to package and ship your
  agents (e.g. to Lambda, ECS/Fargate, or Amazon Bedrock AgentCore) from the workspace.
- **Bedrock-ready** — `boto3`, `langchain-aws`, and the LlamaIndex Bedrock integrations are
  preconfigured to call Amazon Bedrock models via the workspace IAM role.
- **Multi-framework** — build with Strands, LangGraph/LangChain, LlamaIndex, or Lyzr, and
  compare approaches in a single environment.
- **Persistent workspace** — work survives restarts via an EFS `ReadWriteMany` home volume.

## Capabilities

### Agent & AI frameworks (Python)
- **Strands Agents** (`strands-agents`, `strands-agents-tools`)
- **LangGraph** + **LangChain** (`langchain`, `langchain-aws`, `langchain-community`)
- **LlamaIndex** (`llama-index`, Bedrock LLM + embeddings, file readers)
- **Lyzr** (`lyzr-automata`)
- **Amazon Bedrock** via `boto3` / `botocore` / `langchain-aws`

### Observability
- OpenTelemetry (`api`, `sdk`, OTLP exporter)
- Arize Phoenix (`arize-phoenix`)

### Document & web tooling
- Document parsing: `pypdf`, `python-docx`, `openpyxl`
- HTTP: `requests`, `httpx`, `pydantic`
- **Playwright** (headless Chromium) for web scraping / accessing workshop content

### Developer environment
- Python 3, Node.js 20 LTS, `uv` / `uvx`
- AWS CLI v2 and AWS CDK
- **code-server** (VS Code in the browser) and a web terminal
- Coder login module for one-step authentication

## Runtime & infrastructure

- **Compute:** AWS Fargate (namespace `coder-ws`), no EC2 worker nodes
- **Storage:** Amazon EFS access point mounted at `/home/coder` (`ReadWriteMany`, persistent)
- **Image:** built from [`images/coder-workspace-challenge/Dockerfile`](../../images/coder-workspace-challenge/Dockerfile)

## Parameters

| Parameter | Default | Range |
|-----------|---------|-------|
| CPU cores | 4 | 2–8 |
| Memory (GB) | 8 | 4–16 |

Storage is provisioned automatically via EFS; there is no disk-size parameter.

## Notes

- Tools installed outside `/home/coder` are part of the container image; rebuild the image to
  add system packages. Files under `/home/coder` persist across restarts.
- This template is intended as the primary environment for building AI agents in the workshop,
  and is also the recommended workspace when running Coder Agents against this deployment.

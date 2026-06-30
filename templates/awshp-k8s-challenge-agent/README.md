---
display_name: Clash of Agents - Challenge Workspace
description: Optimized for Coder Agents. Fargate workspace pre-loaded with Python agent frameworks (Strands, LangGraph, LangChain, LlamaIndex, Lyzr) and Amazon Bedrock access.
icon: ../../../site/static/icon/k8s.png
maintainer_github: coder
verified: true
tags: [kubernetes, fargate, coder-agents, ai, agents, bedrock, python]
optimized_for: coder-agents
---

# Clash of Agents — Challenge Workspace

> **Optimized for Coder Agents.** This is the recommended template for running
> [Coder Agents](https://coder.com/docs). It ships with the Python agent frameworks and
> Amazon Bedrock tooling that agents need pre-installed, so an agent can start building
> immediately without setting up its environment.

A serverless Coder workspace for the *Clash of Agents* workshop challenges. It runs on
**AWS Fargate** with a persistent EFS-backed home directory, and comes with a curated set of
agentic-AI libraries and AWS tooling baked into the image.

## Why this template for Coder Agents

- **Zero setup for agents** — the agent frameworks, AWS SDKs, and Bedrock integrations are
  already installed system-wide, so a Coder Agent can run code on first turn.
- **Bedrock-ready** — `boto3`, `langchain-aws`, and the LlamaIndex Bedrock integrations are
  preconfigured to call Amazon Bedrock models.
- **Lightweight, reproducible base** — minimal display apps (web terminal + code-server) keep
  the workspace fast to provision; everything an agent needs is in the image.
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
- This template is intended as the single environment Coder Agents use for the workshop.

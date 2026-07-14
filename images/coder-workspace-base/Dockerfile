FROM public.ecr.aws/docker/library/ubuntu:22.04

# ==========================================================================
# Shared base image for all Coder workspace images (claude-code, kiro-cli,
# challenge). Everything common lives here so the expensive layers -- notably
# the Playwright/Chromium install and the /opt/venvs/agents agent-framework
# venv -- are built ONCE instead of once per image. Derived images do
# `FROM ${BASE_IMAGE}` and add only their unique tooling.
# ==========================================================================

# Avoid interactive prompts during package install
ENV DEBIAN_FRONTEND=noninteractive

# Create coder user (uid 1000) to match Fargate security context
RUN useradd -m -s /bin/bash -u 1000 coder

# System packages (common to all workspace images)
RUN apt-get update && apt-get install -y \
    curl \
    unzip \
    gnupg \
    dirmngr \
    jq \
    git \
    ca-certificates \
    python3 \
    python3-pip \
    bash \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Node.js 20 LTS
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# AWS CLI v2
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

# AWS CDK
RUN npm install -g aws-cdk

# uv (Python package manager / uvx)
RUN curl -LsSf https://astral.sh/uv/install.sh | UV_UNMANAGED_INSTALL=/usr/local/bin sh

# Playwright headless browser for web scraping (used by agents to access workshop content)
RUN pip3 install playwright \
    && playwright install chromium --with-deps

# --- Pre-baked Python 3.12 virtualenv + Jupyter kernel for agent notebooks ---
# Baked at build time OUTSIDE /home/coder (which is overlaid by the EFS
# persistent volume at runtime) so workspaces start fast. Registers a
# system-wide Jupyter kernel "Python (Agents)" discoverable by code-server/Kiro.
#
# GPUs are never enabled on these workspaces, so install CPU-only PyTorch first
# from the PyTorch CPU index. This satisfies protopia's torch dependency and
# prevents the multi-GB NVIDIA CUDA wheels (torch's default deps) from being
# pulled in. --no-cache keeps the uv download cache out of the image layer.
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python
RUN uv venv --python 3.12 --seed /opt/venvs/agents \
    && UV_LINK_MODE=copy uv pip install --no-cache --python /opt/venvs/agents/bin/python \
        torch --index-url https://download.pytorch.org/whl/cpu \
    && UV_LINK_MODE=copy uv pip install --no-cache --python /opt/venvs/agents/bin/python \
        ipykernel \
        "boto3>=1.39.0" "botocore>=1.39.0" "pydantic>=2.0.0" \
        bedrock-agentcore bedrock-agentcore-starter-toolkit \
        langchain langchain-core langchain-aws langchain-anthropic langchain-community langgraph \
        "llama-index>=0.12.0" llama-index-core llama-index-llms-bedrock \
        llama-index-llms-bedrock-converse llama-index-embeddings-bedrock \
        llama-index-readers-file llama-cloud \
        strands-agents strands-agents-tools \
        hiddenlayer-sdk protopia \
    && /opt/venvs/agents/bin/python -m ipykernel install --prefix=/usr/local \
        --name agents --display-name "Python (Agents)" \
    && chown -R coder:coder /opt/venvs /opt/uv \
    && chmod -R a+rX /opt/venvs /opt/uv \
    && rm -rf /root/.cache/uv /root/.cache/pip

# Ensure coder user owns their home directory
RUN chown -R coder:coder /home/coder

# Make /usr/local/bin writable by coder user (Coder modules use sudo mv to install binaries there)
RUN chmod 777 /usr/local/bin

# Install a no-op sudo wrapper (Coder modules expect sudo to exist for `sudo mv`)
RUN printf '#!/bin/sh\nexec "$@"\n' > /usr/bin/sudo && chmod +x /usr/bin/sudo

USER coder
WORKDIR /home/coder

# Pre-configure npm global directory
RUN mkdir -p /home/coder/.npm-global \
    && npm config set prefix "/home/coder/.npm-global"

ENV PATH="/home/coder/.local/bin:/home/coder/bin:/home/coder/.npm-global/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

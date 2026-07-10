FROM public.ecr.aws/docker/library/ubuntu:22.04

# Avoid interactive prompts during package install
ENV DEBIAN_FRONTEND=noninteractive

# Create coder user (uid 1000) to match Fargate security context
RUN useradd -m -s /bin/bash -u 1000 coder

# System packages
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
    libasound2 \
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

# uv (Python package manager / uvx for MCP servers)
RUN curl -LsSf https://astral.sh/uv/install.sh | UV_UNMANAGED_INSTALL=/usr/local/bin sh

# Kiro CLI
RUN curl -fsSL https://cli.kiro.dev/install | bash \
    && cp /root/.local/bin/kiro-cli /usr/local/bin/kiro-cli \
    && cp /root/.local/bin/kiro-cli-chat /usr/local/bin/kiro-cli-chat \
    && chmod +x /usr/local/bin/kiro-cli /usr/local/bin/kiro-cli-chat

# Nirmata CLI (nctl)
ARG NCTL_VERSION=4.10.7-rc.6
RUN curl -LO "https://dl.nirmata.io/nctl/nctl_${NCTL_VERSION}/nctl_${NCTL_VERSION}_linux_amd64.zip" \
    && unzip -o "nctl_${NCTL_VERSION}_linux_amd64.zip" \
    && mv nctl /usr/local/bin/nctl \
    && chmod +x /usr/local/bin/nctl \
    && rm -f "nctl_${NCTL_VERSION}_linux_amd64.zip"*

# Playwright headless browser for web scraping (used by agents to access workshop content)
RUN pip3 install playwright \
    && playwright install chromium --with-deps

# --- Pre-baked Python 3.12 virtualenv + Jupyter kernel for agent notebooks ---
# Baked at build time OUTSIDE /home/coder (which is overlaid by the EFS
# persistent volume at runtime) so workspaces start fast. Registers a
# system-wide Jupyter kernel "Python (Agents)" discoverable by code-server/Kiro.
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python
RUN uv venv --python 3.12 --seed /opt/venvs/agents \
    && UV_LINK_MODE=copy uv pip install --python /opt/venvs/agents/bin/python \
        ipykernel \
        "boto3>=1.39.0" "botocore>=1.39.0" "pydantic>=2.0.0" \
        bedrock-agentcore bedrock-agentcore-starter-toolkit \
        langchain langchain-core langchain-aws langchain-anthropic langchain-community langgraph \
        "llama-index>=0.12.0" llama-index-core llama-index-llms-bedrock \
        llama-index-llms-bedrock-converse llama-index-embeddings-bedrock \
        llama-index-readers-file llama-cloud \
        strands-agents strands-agents-tools \
    && /opt/venvs/agents/bin/python -m ipykernel install --prefix=/usr/local \
        --name agents --display-name "Python (Agents)" \
    && chown -R coder:coder /opt/venvs /opt/uv \
    && chmod -R a+rX /opt/venvs /opt/uv

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

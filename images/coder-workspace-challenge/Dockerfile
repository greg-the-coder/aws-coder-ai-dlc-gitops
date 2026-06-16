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
    python3-venv \
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

# Python AI/ML libraries for all challenges
RUN pip3 install --no-cache-dir \
    boto3 \
    botocore \
    strands-agents \
    strands-agents-tools \
    langgraph \
    langchain \
    langchain-aws \
    langchain-community \
    llama-index \
    llama-index-llms-bedrock \
    llama-index-embeddings-bedrock \
    llama-index-readers-file \
    opentelemetry-api \
    opentelemetry-sdk \
    opentelemetry-exporter-otlp \
    arize-phoenix \
    lyzr-automata \
    pypdf \
    python-docx \
    openpyxl \
    requests \
    pydantic \
    httpx

# Ensure coder user owns their home directory
RUN chown -R coder:coder /home/coder

# Make /usr/local/bin writable by coder user (Coder modules use sudo mv to install binaries there)
RUN chmod 777 /usr/local/bin

# Install a no-op sudo wrapper (Coder modules expect sudo to exist)
RUN printf '#!/bin/sh\nexec "$@"\n' > /usr/bin/sudo && chmod +x /usr/bin/sudo

USER coder
WORKDIR /home/coder

# Pre-configure npm global directory
RUN mkdir -p /home/coder/.npm-global \
    && npm config set prefix "/home/coder/.npm-global"

ENV PATH="/home/coder/.local/bin:/home/coder/bin:/home/coder/.npm-global/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

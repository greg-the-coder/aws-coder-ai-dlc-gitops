FROM codercom/enterprise-base:ubuntu

USER root

# System packages (eliminates need for sudo apt at runtime)
RUN apt-get update && apt-get install -y \
    curl \
    unzip \
    gnupg \
    dirmngr \
    jq \
    git \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Node.js 20 LTS
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# AWS CLI
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

# AWS CDK (global)
RUN npm install -g aws-cdk

# uv (Python package manager / uvx for MCP servers)
RUN curl -LsSf https://astral.sh/uv/install.sh | UV_UNMANAGED_INSTALL=/usr/local/bin sh

# Kiro CLI
RUN curl -fsSL https://cli.kiro.dev/install | KIRO_INSTALL_DIR=/usr/local/bin bash

# Nirmata CLI (nctl)
ARG NCTL_VERSION=4.10.7-rc.6
RUN curl -LO "https://dl.nirmata.io/nctl/nctl_${NCTL_VERSION}/nctl_${NCTL_VERSION}_linux_amd64.zip" \
    && unzip -o "nctl_${NCTL_VERSION}_linux_amd64.zip" \
    && mv nctl /usr/local/bin/nctl \
    && chmod +x /usr/local/bin/nctl \
    && rm -f "nctl_${NCTL_VERSION}_linux_amd64.zip"*

# Ensure coder user owns their home directory
RUN chown -R coder:coder /home/coder

USER coder
WORKDIR /home/coder

# Pre-configure npm global directory for user-level installs at runtime
RUN mkdir -p /home/coder/.npm-global \
    && npm config set prefix "/home/coder/.npm-global"

ENV PATH="/home/coder/.local/bin:/home/coder/bin:/home/coder/.npm-global/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

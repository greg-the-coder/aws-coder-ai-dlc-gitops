# Built on top of the shared coder-workspace-base image (see the image
# pipeline). Only Kiro CLI-specific tooling is added here; all common layers
# (system packages, Node, AWS CLI/CDK, uv, Playwright, and the
# /opt/venvs/agents Jupyter kernel venv) come from the base image.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root

# Extra system package required by Kiro
RUN apt-get update && apt-get install -y libasound2 \
    && rm -rf /var/lib/apt/lists/*

# Kiro CLI
RUN curl -fsSL https://cli.kiro.dev/install | bash \
    && cp /root/.local/bin/kiro-cli /usr/local/bin/kiro-cli \
    && cp /root/.local/bin/kiro-cli-chat /usr/local/bin/kiro-cli-chat \
    && chmod +x /usr/local/bin/kiro-cli /usr/local/bin/kiro-cli-chat

USER coder

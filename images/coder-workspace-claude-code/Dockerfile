# Built on top of the shared coder-workspace-base image (see the image
# pipeline). Only Claude Code-specific tooling is added here; all common
# layers (system packages, Node, AWS CLI/CDK, uv, Playwright, and the
# /opt/venvs/agents Jupyter kernel venv) come from the base image.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Claude Code CLI (installed system-wide as root, before dropping to coder)
USER root
RUN npm install -g @anthropic-ai/claude-code
USER coder

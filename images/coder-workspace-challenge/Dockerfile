# Built on top of the shared coder-workspace-base image (see the image
# pipeline). Only challenge-specific tooling is added here; all common layers
# (system packages, Node, AWS CLI/CDK, uv, Playwright, and the
# /opt/venvs/agents Jupyter kernel venv) come from the base image.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root

# Python AI/ML libraries installed system-wide (Python 3.10) to back the
# runtime challenge agents that execute with the system interpreter. The
# 3.12 "Python (Agents)" notebook kernel is provided separately by the base
# image's /opt/venvs/agents venv.
RUN uv pip install --system --no-cache \
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

USER coder

#!/bin/bash
# Sync the Coder AI Gateway providers + Coder Agents models to the current Coder
# deployment via Terraform (coderd provider), replacing the direct /api/v2/ai/providers
# and /api/experimental/chats/model-configs curl calls.
#
# Usage:  ./ai_providers_gitops.sh <coder_session_token>
#
# Reads configuration from the environment (set by the CloudFormation buildspec):
#   CODER_AGENT_URL           - Coder deployment URL              (required)
#   BEDROCK_REGION            - AWS region for Bedrock            (default us-east-1)
#   BEDROCK_ENDPOINT          - native Bedrock runtime base URL
#   BEDROCK_OPENAI_ENDPOINT   - OpenAI-compatible base URL (bedrock-runtime /openai/v1)
#   BEDROCK_MODEL             - primary/default model id
#   BEDROCK_SMALL_FAST_MODEL  - small/fast model id
#   BEDROCK_OPENAI_KEY        - Amazon Bedrock API key (ABSK bearer)  (required)
#   MCP_KNOWLEDGE_SLUG        - AWS Knowledge MCP server slug     (default aws-knowledge)
#   MCP_KNOWLEDGE_URL         - AWS Knowledge MCP server endpoint (default knowledge-mcp.global.api.aws)
#   MCP_KNOWLEDGE_AVAIL       - availability policy               (default default_on)
#
set -euo pipefail

CODER_TOKEN="${1:-}"
if [ -z "$CODER_TOKEN" ]; then
  echo "ERROR: Coder session token required as argument 1." >&2
  exit 1
fi

# --- Ensure Terraform >= 1.11 (write-only arguments) --------------------------
need_tf() {
  command -v terraform >/dev/null 2>&1 || return 0
  ver=$(terraform version -json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || echo "0.0.0")
  major=$(echo "$ver" | cut -d. -f1); minor=$(echo "$ver" | cut -d. -f2)
  [ "$major" -gt 1 ] && return 1
  [ "$major" -eq 1 ] && [ "$minor" -ge 11 ] && return 1
  return 0
}
if need_tf; then
  echo "Installing Terraform >= 1.11 (required for write-only arguments)..."
  TF_VER="1.13.1"
  curl -sLo /tmp/tf.zip "https://releases.hashicorp.com/terraform/${TF_VER}/terraform_${TF_VER}_linux_amd64.zip"
  mkdir -p /tmp/tfbin && unzip -q -o /tmp/tf.zip -d /tmp/tfbin
  export PATH="/tmp/tfbin:$PATH"
fi
terraform version | head -1

# --- Map environment -> TF_VAR_* ---------------------------------------------
export TF_VAR_coder_url="${CODER_AGENT_URL}"
export TF_VAR_coder_token="${CODER_TOKEN}"
export TF_VAR_bedrock_region="${BEDROCK_REGION:-us-east-1}"
export TF_VAR_bedrock_endpoint="${BEDROCK_ENDPOINT:-https://bedrock-runtime.${BEDROCK_REGION:-us-east-1}.amazonaws.com}"
export TF_VAR_bedrock_openai_endpoint="${BEDROCK_OPENAI_ENDPOINT:-https://bedrock-runtime.${BEDROCK_REGION:-us-east-1}.amazonaws.com/openai/v1}"
export TF_VAR_bedrock_model="${BEDROCK_MODEL:-global.anthropic.claude-opus-4-6-v1}"
export TF_VAR_bedrock_small_fast_model="${BEDROCK_SMALL_FAST_MODEL:-global.anthropic.claude-haiku-4-5-20251001-v1:0}"
export TF_VAR_bedrock_openai_api_key="${BEDROCK_OPENAI_KEY:-}"

# Coder Agents MCP server (AWS Knowledge) — overridable, with sensible defaults.
export TF_VAR_mcp_knowledge_slug="${MCP_KNOWLEDGE_SLUG:-aws-knowledge}"
export TF_VAR_mcp_knowledge_url="${MCP_KNOWLEDGE_URL:-https://knowledge-mcp.global.api.aws}"
export TF_VAR_mcp_knowledge_availability="${MCP_KNOWLEDGE_AVAIL:-default_on}"

terraform init -input=false

MAX_ATTEMPTS=5
ATTEMPT=1
while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
  echo "Terraform attempt $ATTEMPT/$MAX_ATTEMPTS"
  if terraform apply -auto-approve; then
    echo "AI provider + model configuration applied successfully"
    exit 0
  fi

  if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
    WAIT_TIME=$((ATTEMPT * 30))
    echo "Terraform failed, waiting ${WAIT_TIME}s before retry..."
    sleep $WAIT_TIME
  fi

  ATTEMPT=$((ATTEMPT + 1))
done

echo "Terraform apply failed after $MAX_ATTEMPTS attempts"
exit 1

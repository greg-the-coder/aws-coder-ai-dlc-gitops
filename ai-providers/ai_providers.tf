###########################################################
# Coder AI Gateway — Providers & Agent Models (GitOps)
#
# Declarative replacement for the direct Coder API calls in the CloudFormation
# CodeBuild deploy script (curl to /api/v2/ai/providers,
# /api/experimental/chats/model-configs, and
# /api/v2/organizations/{org}/mcp-servers). Managed with the Coder `coderd`
# Terraform provider (>= 0.0.25 for Coder 2.37; the AI Gateway resources were
# introduced in 0.0.23), which provides first-class resources for the
# AI Gateway:
#
#   coderd_ai_provider          -> AI Gateway providers  (bedrock, openai-compat)
#   coderd_agents_model         -> Coder Agents chat models
#   coderd_agents_default_model -> the default agent model
#   coderd_agents_mcp_server    -> Coder Agents external MCP servers
#
# Requires Coder v2.37.0+ (Coder Agents GA) on the server side with the coderd
# provider >= 0.0.25, and Terraform >= 1.11 on the client (write-only
# arguments, e.g. api_key_wo / *_wo credentials).
#
# 2.37 / coderd 0.0.25 compatibility notes:
#   * The default-model resource was renamed
#     coderd_default_agents_model -> coderd_agents_default_model and now
#     requires organization_id (looked up via the coderd_organization data
#     source below).
#   * coderd_ai_provider and coderd_agents_model are otherwise unchanged for
#     this config (settings.bedrock.{region,model,small_fast_model}, api_key_wo,
#     model_config all still valid; new optional attrs are ignored here).
###########################################################

terraform {
  # Write-only arguments (api_key_wo, settings.bedrock.*_wo) require Terraform 1.11+.
  required_version = ">= 1.11.0"
  required_providers {
    coderd = {
      source  = "coder/coderd"
      version = ">= 0.0.25"
    }
  }
}

# --------------------------------------------------------------------------
# Variables (sourced from TF_VAR_* by ai_providers_gitops.sh)
# --------------------------------------------------------------------------

variable "coder_url" {
  type        = string
  description = "Coder deployment URL."
  default     = ""
}

variable "coder_token" {
  type        = string
  description = "Coder session token used to authenticate to the deployment."
  default     = ""
  sensitive   = true
}

variable "bedrock_region" {
  type        = string
  description = "AWS region serving the Bedrock models (Anthropic inference profiles live in us-east-1)."
  default     = "us-east-1"
}

variable "bedrock_endpoint" {
  type        = string
  description = "Base URL for the native Bedrock runtime provider."
  default     = "https://bedrock-runtime.us-east-1.amazonaws.com"
}

variable "bedrock_openai_endpoint" {
  type        = string
  description = "Base URL for the OpenAI-compatible provider: Bedrock runtime native OpenAI endpoint (/openai/v1)."
  default     = "https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1"
}

variable "bedrock_model" {
  type        = string
  description = "Primary (default) Bedrock model id."
  default     = "global.anthropic.claude-opus-4-6-v1"
}

variable "bedrock_small_fast_model" {
  type        = string
  description = "Small/fast Bedrock model id used for lightweight calls."
  default     = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "bedrock_openai_api_key" {
  type        = string
  description = "Amazon Bedrock API key (bearer, ABSK...) — a bedrock.amazonaws.com IAM service-specific credential from Secrets Manager, valid for the bedrock-runtime OpenAI-compatible endpoint (/openai/v1)."
  default     = ""
  sensitive   = true
}

variable "bedrock_openai_api_key_version" {
  type        = number
  description = "Bump to rotate the Bedrock API key (write-only argument version)."
  default     = 1
}

# --- Coder Agents MCP servers (AWS Knowledge) --------------------------------

variable "mcp_knowledge_slug" {
  type        = string
  description = "Organization-unique slug for the AWS Knowledge MCP server."
  default     = "aws-knowledge"
}

variable "mcp_knowledge_url" {
  type        = string
  description = "Endpoint for the AWS Knowledge MCP server (remote, streamable HTTP)."
  default     = "https://knowledge-mcp.global.api.aws"
}

variable "mcp_knowledge_availability" {
  type        = string
  description = "Availability policy for the AWS Knowledge MCP server: force_on | default_on | default_off."
  default     = "default_on"
}

# --------------------------------------------------------------------------
# Provider
# --------------------------------------------------------------------------

provider "coderd" {
  url   = var.coder_url
  token = var.coder_token
}

# The AI Gateway model resources are organization-scoped in coderd >= 0.0.25
# (Coder 2.37 / Agents GA). Look up the default org so we never hard-code an ID.
data "coderd_organization" "default" {
  is_default = true
}

# --------------------------------------------------------------------------
# AI Gateway providers
# --------------------------------------------------------------------------

# Native AWS Bedrock. Credentials come from the workspace/coder pod IAM role
# (EKS Pod Identity: the <cluster>-workshop-user role), so no static access
# keys are set here — only the model routing settings.
resource "coderd_ai_provider" "bedrock" {
  name         = "bedrock"
  type         = "bedrock"
  display_name = "AWS Bedrock"
  base_url     = var.bedrock_endpoint
  enabled      = true

  settings = {
    bedrock = {
      region           = var.bedrock_region
      model            = var.bedrock_model
      small_fast_model = var.bedrock_small_fast_model
      # protocol defaults to "invoke-model"; credentials via Pod Identity IAM role.
    }
  }
}

# OpenAI-compatible provider served by Amazon Bedrock's native OpenAI endpoint
# (https://bedrock-runtime.<region>.amazonaws.com/openai/v1), authenticated with
# an Amazon Bedrock API key (a bedrock.amazonaws.com IAM service-specific
# credential, passed as a write-only bearer key). The native /openai/v1 route
# serves the configured OpenAI (GPT-5.6 Sol) and xAI (Grok 4.6) models via Chat
# Completions; cross-region (CRIS) models are referenced by their us./global.
# inference-profile id (see the models below).
resource "coderd_ai_provider" "openai_compat" {
  name         = "openai-compat"
  type         = "openai"
  display_name = "OpenAI-compatible (AWS Bedrock)"
  base_url     = var.bedrock_openai_endpoint
  enabled      = true

  api_key_wo         = var.bedrock_openai_api_key
  api_key_wo_version = var.bedrock_openai_api_key_version
}

# --------------------------------------------------------------------------
# Coder Agents chat models
# --------------------------------------------------------------------------

resource "coderd_agents_model" "claude_opus" {
  ai_provider_id = coderd_ai_provider.bedrock.id
  model          = var.bedrock_model
  display_name   = "Claude Opus 4.6"
  enabled        = true
  context_limit  = 1000000
  model_config = jsonencode({
    max_output_tokens = 128000
    provider_options = {
      anthropic = {
        send_reasoning = true
      }
    }
  })
}

resource "coderd_agents_model" "claude_haiku" {
  ai_provider_id = coderd_ai_provider.bedrock.id
  model          = var.bedrock_small_fast_model
  display_name   = "Claude Haiku 4.5"
  enabled        = true
  context_limit  = 200000
  model_config = jsonencode({
    max_output_tokens = 64000
    provider_options = {
      anthropic = {
        send_reasoning = true
        thinking = {
          budget_tokens = 8192
        }
      }
    }
  })
}

# OpenAI-compatible models on the bedrock-runtime /openai/v1 provider. GPT-5.6
# Sol and Grok 4.6 are cross-region (CRIS) models, so they MUST be referenced by
# their us./global. inference-profile id. context_limit / max_output_tokens are
# conservative and tunable.
resource "coderd_agents_model" "gpt_5_6_sol" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "us.openai.gpt-5.6-sol"
  display_name   = "OpenAI GPT-5.6 Sol"
  enabled        = true
  context_limit  = 400000
  model_config = jsonencode({
    max_output_tokens = 128000
  })
}

# xAI Grok 4.6 (SpaceX AI). Reasoning model — reserve generous output headroom
# (small max_output_tokens gets consumed by reasoning and returns empty content).
resource "coderd_agents_model" "grok_4_6" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "us.xai.grok-4.6"
  display_name   = "xAI Grok 4.6"
  enabled        = true
  context_limit  = 256000
  model_config = jsonencode({
    max_output_tokens = 32000
  })
}

# Default agent model (was is_default:true on the Opus model config).
# coderd >= 0.0.25 renamed this resource (coderd_default_agents_model ->
# coderd_agents_default_model) and now requires organization_id.
resource "coderd_agents_default_model" "default" {
  model_id        = coderd_agents_model.claude_opus.id
  organization_id = data.coderd_organization.default.id
}

# --------------------------------------------------------------------------
# Coder Agents MCP servers
# --------------------------------------------------------------------------

# The AWS Knowledge MCP Server: a remote, fully-managed, AWS-hosted MCP server
# (no install, no credentials) exposing AWS docs, API references, What's New,
# Builder Center, and Well-Architected guidance -- ideal for Citizen
# Developers/Builders. Replaces the former ai_mcp_servers_gitops.sh direct
# admin-API call, now that coderd >= 0.0.25 provides a first-class resource
# (coderd_agents_mcp_server). Requires Coder v2.37.0+ with the AI Governance
# Add-On (the MCP-servers API).
# https://github.com/awslabs/mcp/tree/main/src/aws-knowledge-mcp-server
resource "coderd_agents_mcp_server" "aws_knowledge" {
  organization_id = data.coderd_organization.default.id
  display_name    = "AWS Knowledge"
  slug            = var.mcp_knowledge_slug
  url             = var.mcp_knowledge_url
  description     = "AWS-hosted MCP server: docs, API refs, What's New, Builder Center, and Well-Architected guidance."
  icon_url        = "/icon/aws.png"
  transport       = "streamable_http"
  auth_type       = "none"
  availability    = var.mcp_knowledge_availability
  enabled         = true
  model_intent    = true
}

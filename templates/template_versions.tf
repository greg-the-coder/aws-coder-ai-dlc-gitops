###########################################################
# Core Coder GitOps Provider, Resource & Variable definitions
###########################################################

terraform {
  required_providers {
    coderd = {
      source  = "coder/coderd"
      version = ">= 0.0.25"
    }
  }
}

// Variables sourced from TF_VAR_<environment variables>
variable "coder_url" {
  type        = string
  description = "Coder deployment login url"
  default     = ""
}
variable "coder_token" {
  type        = string
  description = "Coder session token used to authenticate to deployment"
  default     = ""
}
variable "coder_gitsha" {
  type        = string
  description = "Git SHA to use in version name"
  default = ""  
}
variable "workspace_image" {
  type        = string
  description = "ECR image URI for workspace pods"
  default     = ""
}

variable "claude_code_image" {
  type        = string
  description = "ECR image URI for Claude Code workspace"
  default     = ""
}

variable "kiro_cli_image" {
  type        = string
  description = "ECR image URI for Kiro CLI workspace"
  default     = ""
}

variable "challenge_image" {
  type        = string
  description = "ECR image URI for Challenge workspace"
  default     = ""
}

variable "codex_image" {
  type        = string
  description = "ECR image URI for Codex workspace (reuses the Claude Code workspace image, which already ships node/npm/uv)"
  default     = ""
}

variable "efs_file_system_id" {
  type        = string
  description = "EFS file system ID for persistent workspace storage"
  default     = ""
}

provider "coderd" {
    url   = "${var.coder_url}"
    token = "${var.coder_token}"
}

###########################################################
# Maintain Coder Template Resources in this Section
###########################################################

resource "coderd_template" "awshp-k8s-with-claude-code" {
  name        = "awshp-k8s-base-claudecode"
  display_name = "AWS Workshop - Kubernetes with Claude Code"
  description = "Fargate Claude Code workspace routed via the Coder AI Gateway, with AWS Labs MCP servers, AWS CLI/CDK, and Bedrock."
  icon = "/icon/k8s.png"
  versions = [{
    directory = "./awshp-k8s-with-claude-code"
    active    = true
    # Version name is optional
    name = var.coder_gitsha
    tf_vars = [{
      name  = "namespace"
      value = "coder-ws"
    },
    {
      name  = "workspace_image"
      value = var.claude_code_image
    },
    {
      name  = "efs_file_system_id"
      value = var.efs_file_system_id
    }]
  }]
}

resource "coderd_template" "awshp-k8s-with-kiro_cli" {
  name        = "awshp-k8s-base-kirocli"
  display_name = "AWS Workshop - Kubernetes with Kiro CLI"
  description = "Fargate Kiro CLI workspace with AWS Labs MCP servers, AWS CLI/CDK, Node.js, and Bedrock access."
  icon = "/icon/k8s.png"
  versions = [{
    directory = "./awshp-k8s-with-kiro-cli"
    active    = true
    # Version name is optional
    name = var.coder_gitsha
    tf_vars = [{
      name  = "namespace"
      value = "coder-ws"
    },
    {
      name  = "workspace_image"
      value = var.kiro_cli_image
    },
    {
      name  = "efs_file_system_id"
      value = var.efs_file_system_id
    }]
  }]
}

resource "coderd_template" "awshp-k8s-with-codex" {
  name        = "awshp-k8s-base-codex"
  display_name = "AWS Workshop - Kubernetes with OpenAI Codex"
  description = "Fargate OpenAI Codex CLI workspace via the Coder AI Gateway (GPT-5.6 Sol on Bedrock), with AWS Labs MCP servers and AWS CLI/CDK"
  icon = "/icon/k8s.png"
  versions = [{
    directory = "./awshp-k8s-with-codex"
    active    = true
    # Version name is optional
    name = var.coder_gitsha
    tf_vars = [{
      name  = "namespace"
      value = "coder-ws"
    },
    {
      name  = "workspace_image"
      value = var.codex_image
    },
    {
      name  = "efs_file_system_id"
      value = var.efs_file_system_id
    }]
  }]
}

###########################################################
# AI Agent Development Template
###########################################################

resource "coderd_template" "challenge-agent" {
  name        = "awshp-k8s-challenge-agent"
  display_name = "AWS Workshop - AI Agent Development"
  description = "Build and deploy AI agents to AWS on Fargate: Strands, LangGraph, LangChain, LlamaIndex, Lyzr + Bedrock and AWS CDK/CLI."
  icon = "/icon/k8s.png"
  versions = [{
    directory = "./awshp-k8s-challenge-agent"
    active    = true
    name = var.coder_gitsha
    tf_vars = [{
      name  = "namespace"
      value = "coder-ws"
    },
    {
      name  = "workspace_image"
      value = var.challenge_image
    },
    {
      name  = "efs_file_system_id"
      value = var.efs_file_system_id
    }]
  }]
}

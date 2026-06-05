###########################################################
# Core Coder GitOps Provider, Resource & Variable definitions
###########################################################

terraform {
  required_providers {
    coderd = {
      source = "coder/coderd"
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
  description = "Provision Kubernetes Deployments as Coder workspaces with Anthropic Claude Code."
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
  description = "Provision Kubernetes Deployments as Coder workspaces with Kiro CLI Agent."
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

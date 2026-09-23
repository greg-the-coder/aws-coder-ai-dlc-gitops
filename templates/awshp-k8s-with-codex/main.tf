terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.37.1"
    }
    coder = {
      source  = "coder/coder"
      version = ">= 2.13"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "namespace" {
  type        = string
  description = "The Kubernetes namespace to create workspaces in (must exist prior to creating workspaces)."
  default     = "coder-ws"
}

variable "workspace_image" {
  type        = string
  description = "Container image for workspace pods"
  default     = "codercom/enterprise-base:ubuntu"
}

variable "efs_file_system_id" {
  type        = string
  description = "EFS file system ID for persistent workspace storage"
  default     = ""
}

locals {
  home_dir = "/home/coder"
  cost     = 0 # keep daily_cost at 0 so workspaces don't consume quota on initial deployment

  # Deployment region for AWS API calls the MCP servers make via the workspace
  # IAM role. Derived from the ECR registry region embedded in workspace_image
  # (e.g. <acct>.dkr.ecr.us-east-2.amazonaws.com/...) so it always tracks the
  # deployment without a separate variable; falls back to us-east-1 for
  # non-ECR images (e.g. the codercom/enterprise-base default).
  aws_region = try(regex("\\.dkr\\.ecr\\.([a-z0-9-]+)\\.amazonaws\\.com", var.workspace_image)[0], "us-east-1")

  # Codex config.toml (written by the codex module). Routes Codex through the
  # Coder AI Gateway's `openai-compat` provider (-> Amazon Bedrock bedrock-runtime
  # /openai/v1) using the workspace owner's Coder session token as the API key
  # (set agent-wide as OPENAI_API_KEY), so every request is governed by the Coder
  # AI Governance Add-On. GPT-5.6 Sol is a cross-region (CRIS) model referenced by
  # its us. inference-profile id.
  #   * wire_api = "responses": Codex >= 0.153 dropped "chat"; the Bedrock OpenAI
  #     endpoint serves the Responses API for GPT-5.6, verified through the gateway.
  #   * web_search = "disabled": Codex attaches a hosted web_search tool by default,
  #     which Amazon Bedrock's OpenAI endpoint rejects ("web search is not supported
  #     for this request"); disabling it lets turns complete.
  #   * sandbox_mode = "danger-full-access": the workspace is an isolated Fargate
  #     microVM (already a sandbox) and lacks bubblewrap, which Codex's
  #     workspace-write OS sandbox requires; without this the shell/exec tool fails
  #     ("sandbox launcher lacks bwrap").
  #   * features.tool_search_always_defer_mcp_tools = false: expose the AWS MCP
  #     tools directly to the model instead of hiding them behind a tool-search
  #     step (which the model otherwise does not invoke, reporting tools
  #     "unavailable").
  codex_base_config = <<-TOML
    preferred_auth_method = "apikey"
    model_provider        = "openai-compat"
    model                 = "us.openai.gpt-5.6-sol"
    web_search            = "disabled"
    sandbox_mode          = "danger-full-access"

    [features]
    tool_search_always_defer_mcp_tools = false

    [model_providers.openai-compat]
    name     = "Coder AI Gateway (Bedrock)"
    base_url = "${trimsuffix(data.coder_workspace.me.access_url, "/")}/api/v2/ai-gateway/openai-compat/v1"
    env_key  = "OPENAI_API_KEY"
    wire_api = "responses"

    [projects."/home/coder"]
    trust_level = "trusted"
  TOML

  # AWS MCP servers for Codex (native TOML [mcp_servers.*], appended to
  # config.toml by the module). A citizen-builder toolkit of AWS Labs MCP servers
  # matching the Claude Code / Kiro templates (awslabs iac/pricing/serverless/
  # cloudwatch), run on demand via uvx from the pre-warmed on-image cache
  # (/opt/uv-cache). Calls use the workspace IRSA role (Codex forwards the pod env
  # to the stdio servers, so AWS_ROLE_ARN / web-identity token are inherited);
  # AWS_REGION pins the operation region (local.aws_region, derived from the ECR
  # image URI). KEEP VERSIONS IN SYNC with images/coder-workspace-base/Dockerfile.
  #
  # NOTE: the managed remote `aws-mcp` server (AWS's Agent Toolkit endpoint via
  # mcp-proxy-for-aws, which provided call_aws for arbitrary AWS APIs plus general
  # AWS documentation) was REMOVED across all templates: its remote endpoint
  # intermittently failed the MCP handshake with "-32602 Invalid request
  # parameters", disabling the server (Codex, an rmcp client, was hit hardest).
  # General AWS API access is available via the AWS CLI (v2) and boto3, which the
  # model drives directly from the shell.
  codex_mcp_toml = <<-TOML
    [mcp_servers.awslabs-aws-iac-mcp-server]
    command = "uvx"
    args = ["awslabs.aws-iac-mcp-server==1.0.25"]
    env = { FASTMCP_LOG_LEVEL = "ERROR", AWS_REGION = "${local.aws_region}", AWS_DEFAULT_REGION = "${local.aws_region}", AWS_STS_REGIONAL_ENDPOINTS = "regional", UV_CACHE_DIR = "/opt/uv-cache" }

    [mcp_servers.awslabs-aws-pricing-mcp-server]
    command = "uvx"
    args = ["awslabs.aws-pricing-mcp-server==1.1.0"]
    env = { FASTMCP_LOG_LEVEL = "ERROR", AWS_REGION = "${local.aws_region}", AWS_DEFAULT_REGION = "${local.aws_region}", AWS_STS_REGIONAL_ENDPOINTS = "regional", UV_CACHE_DIR = "/opt/uv-cache" }

    [mcp_servers.awslabs-aws-serverless-mcp-server]
    command = "uvx"
    args = ["awslabs.aws-serverless-mcp-server==0.2.0"]
    env = { FASTMCP_LOG_LEVEL = "ERROR", AWS_REGION = "${local.aws_region}", AWS_DEFAULT_REGION = "${local.aws_region}", AWS_STS_REGIONAL_ENDPOINTS = "regional", UV_CACHE_DIR = "/opt/uv-cache" }

    [mcp_servers.awslabs-cloudwatch-mcp-server]
    command = "uvx"
    args = ["awslabs.cloudwatch-mcp-server==0.2.0"]
    env = { FASTMCP_LOG_LEVEL = "ERROR", AWS_REGION = "${local.aws_region}", AWS_DEFAULT_REGION = "${local.aws_region}", AWS_STS_REGIONAL_ENDPOINTS = "regional", UV_CACHE_DIR = "/opt/uv-cache" }
  TOML
}

# Minimum vCPUs needed 
data "coder_parameter" "cpu" {
  name        = "CPU cores"
  type        = "number"
  description = "CPU cores for your individual workspace"
  icon        = "https://png.pngtree.com/png-clipart/20191122/original/pngtree-processor-icon-png-image_5165793.jpg"
  validation {
    min = 2
    max = 8
  }
  form_type = "input"
  mutable   = true
  default   = 2
  order     = 1
}

# Minimum GB memory needed 
data "coder_parameter" "memory" {
  name        = "Memory (__ GB)"
  type        = "number"
  description = "Memory (__ GB) for your individual workspace"
  icon        = "https://www.vhv.rs/dpng/d/33-338595_random-access-memory-logo-hd-png-download.png"
  validation {
    min = 4
    max = 16
  }
  form_type = "input"
  mutable   = true
  default   = 4
  order     = 2
}


data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "dev" {
  arch = "amd64"
  os   = "linux"

  display_apps {
    vscode          = false
    vscode_insiders = false
    web_terminal    = true
    ssh_helper      = false
  }

  # Live workspace resource utilization shown in the Coder dashboard,
  # using the agent's built-in `coder stat` command (pod/container-scoped).
  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "2_home_disk"
    script       = "coder stat disk --path $HOME"
    interval     = 60
    timeout      = 1
  }
  startup_script_behavior = "blocking"
  startup_script          = <<-EOT
    set -e
    mkdir -p $HOME/.local/bin
    # Make the coder CLI resolvable for module scripts (coder-utils `coder exp
    # sync`) and interactive shells.
    ln -sf /tmp/coder.*/coder "$HOME/.local/bin/coder" 2>/dev/null || true
    ln -sf /tmp/coder.*/coder "$CODER_SCRIPT_BIN_DIR/coder" 2>/dev/null || true
    EOT

}

module "coder-login" {
  source   = "registry.coder.com/coder/coder-login/coder"
  version  = "1.1.1"
  agent_id = coder_agent.dev.id
}

# Python 3.12 venv + Jupyter kernel for the workshop agent notebooks
# (LangGraph/LangChain, LlamaIndex, Strands, Bedrock AgentCore). The workshop
# images pre-bake this at /opt/venvs/agents with a system-wide "Python (Agents)"
# kernel, so this script is a fast no-op there. On a non pre-baked base image it
# falls back to provisioning into the EFS-persistent home (one-time).
resource "coder_script" "agent_python_kernel" {
  agent_id           = coder_agent.dev.id
  display_name       = "Python/Jupyter agent kernel"
  icon               = "/icon/python.svg"
  run_on_start       = true
  start_blocks_login = false
  script             = <<-EOT
    #!/bin/sh
    set -eu

    # Fast path: pre-baked in the workshop image (outside the EFS-mounted home).
    if [ -x /opt/venvs/agents/bin/python ]; then
      echo "Agent Python kernel pre-installed in image (/opt/venvs/agents)."
      exit 0
    fi

    # Fallback for non pre-baked base images: provision into the persistent home.
    VENV="$HOME/.venvs/agents"
    SENTINEL="$VENV/.provisioned"
    if [ -f "$SENTINEL" ]; then
      echo "Agent Python kernel already provisioned at $VENV"
      exit 0
    fi
    command -v uv >/dev/null 2>&1 || { echo "uv unavailable; skipping kernel setup."; exit 0; }

    export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
    export UV_LINK_MODE=copy
    mkdir -p "$HOME/.venvs"
    uv venv --python 3.12 --seed "$VENV"
    uv pip install --python "$VENV/bin/python" \
      ipykernel \
      "boto3>=1.39.0" "botocore>=1.39.0" "pydantic>=2.0.0" \
      bedrock-agentcore bedrock-agentcore-starter-toolkit \
      langchain langchain-core langchain-aws langchain-anthropic langchain-community langgraph \
      "llama-index>=0.12.0" llama-index-core llama-index-llms-bedrock \
      llama-index-llms-bedrock-converse llama-index-embeddings-bedrock \
      llama-index-readers-file llama-cloud \
      strands-agents strands-agents-tools
    "$VENV/bin/python" -m ipykernel install --user \
      --name agents --display-name "Python (Agents)"
    touch "$SENTINEL"
    echo "Provisioned Jupyter kernel 'Python (Agents)' -> $VENV"
    EOT
}

# Browser-based VS Code (official VS Code Server / "vscode-web"), replacing
# code-server. Served on a path (subdomain = false) since this workshop
# deployment does not use wildcard app subdomains; workspace trust disabled so
# the home folder opens without prompts.
module "vscode-web" {
  count          = data.coder_workspace.me.start_count
  source         = "registry.coder.com/coder/vscode-web/coder"
  version        = "1.6.2"
  agent_id       = coder_agent.dev.id
  folder         = local.home_dir
  accept_license = true
  subdomain      = false
  disable_trust  = true
  order          = 0
  extensions     = ["ms-toolsai.jupyter"]
}

# VS Code Desktop (Coder Remote) as an additional IDE option: a one-click button
# that opens the workspace in the user's local VS Code over SSH. Pre-installs the
# Jupyter extension on the workspace host.
module "vscode" {
  count      = data.coder_workspace.me.start_count
  source     = "registry.coder.com/coder/vscode-desktop/coder"
  version    = "1.3.0"
  agent_id   = coder_agent.dev.id
  folder     = local.home_dir
  order      = 1
  extensions = ["ms-toolsai.jupyter"]
}

module "codex" {
  source           = "registry.coder.com/coder-labs/codex/coder"
  version          = "5.3.2"
  agent_id         = coder_agent.dev.id
  workdir          = local.home_dir
  install_codex    = true
  base_config_toml = local.codex_base_config
  mcp              = local.codex_mcp_toml
}

# Gateway auth for Codex (and any OpenAI SDK): the workspace owner's Coder
# session token as OPENAI_API_KEY (referenced by config.toml env_key), so every
# request routes through the Coder AI Gateway and is governed centrally.
resource "coder_env" "openai_api_key" {
  agent_id = coder_agent.dev.id
  name     = "OPENAI_API_KEY"
  value    = data.coder_workspace_owner.me.session_token
}

resource "coder_env" "openai_base_url" {
  agent_id = coder_agent.dev.id
  name     = "OPENAI_BASE_URL"
  value    = "${trimsuffix(data.coder_workspace.me.access_url, "/")}/api/v2/ai-gateway/openai-compat/v1"
}

resource "coder_app" "codex" {
  agent_id     = coder_agent.dev.id
  slug         = "codex"
  display_name = "Codex"
  icon         = "${data.coder_workspace.me.access_url}/icon/openai.svg"
  share        = "owner"
  order        = 2
  open_in      = "slim-window"
  command      = <<-EOT
    cd "$HOME"
    codex
  EOT
}


resource "aws_efs_access_point" "home" {
  file_system_id = var.efs_file_system_id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/workspaces/${data.coder_workspace.me.id}"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }

  tags = {
    Name                     = "coder-${data.coder_workspace.me.name}-home"
    "com.coder.workspace.id" = data.coder_workspace.me.id
  }
}

resource "kubernetes_persistent_volume" "home" {
  metadata {
    name = "coder-${data.coder_workspace.me.id}-home"
  }
  spec {
    capacity = {
      storage = "50Gi"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "efs-static"
    volume_mode                      = "Filesystem"
    persistent_volume_source {
      csi {
        driver        = "efs.csi.aws.com"
        volume_handle = "${var.efs_file_system_id}::${aws_efs_access_point.home.id}"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-home"
    namespace = var.namespace
  }
  wait_until_bound = true
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = "efs-static"
    volume_name        = kubernetes_persistent_volume.home.metadata.0.name
    resources {
      requests = {
        storage = "50Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "dev" {
  count            = data.coder_workspace.me.start_count
  wait_for_rollout = false
  metadata {
    name      = "coder-${data.coder_workspace.me.id}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace"
      "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
      "app.kubernetes.io/part-of"  = "coder"
      "com.coder.resource"         = "true"
      "com.coder.workspace.id"     = data.coder_workspace.me.id
      "com.coder.workspace.name"   = data.coder_workspace.me.name
      "com.coder.user.id"          = data.coder_workspace_owner.me.id
      "com.coder.user.username"    = data.coder_workspace_owner.me.name
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "coder-workspace"
        "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
        "app.kubernetes.io/part-of"  = "coder"
        "com.coder.resource"         = "true"
        "com.coder.workspace.id"     = data.coder_workspace.me.id
        "com.coder.workspace.name"   = data.coder_workspace.me.name
        "com.coder.user.id"          = data.coder_workspace_owner.me.id
        "com.coder.user.username"    = data.coder_workspace_owner.me.name
      }
    }
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"     = "coder-workspace"
          "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
          "app.kubernetes.io/part-of"  = "coder"
          "com.coder.resource"         = "true"
          "com.coder.workspace.id"     = data.coder_workspace.me.id
          "com.coder.workspace.name"   = data.coder_workspace.me.name
          "com.coder.user.id"          = data.coder_workspace_owner.me.id
          "com.coder.user.username"    = data.coder_workspace_owner.me.name
        }
      }
      spec {
        security_context {
          run_as_user = 1000
          fs_group    = 1000
        }
        service_account_name = "coder-ws"

        container {
          name              = "dev"
          image             = var.workspace_image
          image_pull_policy = "Always"
          command           = ["sh", "-c", coder_agent.dev.init_script]
          security_context {
            run_as_user                = "1000"
            allow_privilege_escalation = false
          }
          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.dev.token
          }
          resources {
            requests = {
              "cpu"    = "${data.coder_parameter.cpu.value}"
              "memory" = "${data.coder_parameter.memory.value}Gi"
            }
            limits = {
              "cpu"    = "${data.coder_parameter.cpu.value}"
              "memory" = "${data.coder_parameter.memory.value}Gi"
            }
          }
          volume_mount {
            mount_path = "/home/coder"
            name       = "home"
            read_only  = false
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.home.metadata.0.name
            read_only  = false
          }
        }

      }
    }
  }
}

resource "coder_metadata" "pod_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = kubernetes_deployment.dev[0].id
  daily_cost  = local.cost
}

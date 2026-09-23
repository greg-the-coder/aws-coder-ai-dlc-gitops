terraform {
    required_providers {
        kubernetes = {
            source = "hashicorp/kubernetes"
            version = "2.37.1"
        }
        coder = {
            source  = "coder/coder"
            version = ">= 2.13"
        }
        random = {
            source = "hashicorp/random"
            version = "3.7.2"
        }
        aws = {
            source = "hashicorp/aws"
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

variable "anthropic_model" {
  type        = string
  description = "The AWS Inference profile ID of the base Anthropic model to use with Claude Code"
  default     = "global.anthropic.claude-opus-4-6-v1"
}

variable "mcp_api_key_fiddler" {
  type        = string
  description = "Fiddler AI API key (Bearer) for the Fiddler GenAI MCP server."
  sensitive   = true
  default     = ""
}

variable "fiddler_url" {
  type        = string
  description = "Fiddler instance base URL for the Fiddler GenAI MCP server (optional)."
  default     = "https://app.fiddler.ai"
}

variable "mcp_api_key_langsmith" {
  type        = string
  description = "LangSmith API key (sent as X-Api-Key) for the LangSmith remote MCP server."
  sensitive   = true
  default     = ""
}

variable "mcp_api_key_llamacloud" {
  type        = string
  description = "LlamaCloud API key for the LlamaCloud MCP server."
  sensitive   = true
  default     = ""
}

variable "llamacloud_project_name" {
  type        = string
  description = "Optional LlamaCloud project name for the LlamaCloud MCP server."
  default     = ""
}

variable "llamacloud_index" {
  type        = string
  description = "Optional LlamaCloud index ('name:description') exposed as a tool by the LlamaCloud MCP server."
  default     = ""
}

locals {
  home_dir = "/home/coder"
  bin_path = "/home/coder/.local/bin:/home/coder/bin:/home/coder/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  cost     = 2

  # MCP servers added to Claude Code at user scope: Fiddler GenAI (observability)
  # + LangSmith (LangChain) as remote HTTP, LlamaCloud (LlamaIndex) over stdio via
  # uvx. Security partners (HiddenLayer, Protopia) have no MCP server; their SDKs
  # are pre-baked in the image instead.
  mcp_servers = merge(
    {
      "fiddler-genai" = {
        type    = "http"
        url     = "${var.fiddler_url}/v1/mcp/genai/"
        headers = { Authorization = "Bearer ${var.mcp_api_key_fiddler}" }
      }
      "langsmith" = {
        type    = "http"
        url     = "https://api.smith.langchain.com/mcp"
        headers = { "X-Api-Key" = var.mcp_api_key_langsmith }
      }
      "llamacloud" = {
        command = "/usr/local/bin/uvx"
        args = concat(
          ["llamacloud-mcp@latest", "--api-key", var.mcp_api_key_llamacloud],
          var.llamacloud_project_name != "" ? ["--project-name", var.llamacloud_project_name] : [],
          var.llamacloud_index != "" ? ["--index", var.llamacloud_index] : [],
        )
      }
    }
  )
  mcp_json = jsonencode({ mcpServers = local.mcp_servers })
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
  default   = 4
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
  default   = 8
  order     = 2
}


data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# Route BOTH Claude Code and the notebook / agent-framework SDK LLM calls through
# the **Coder AI Gateway** so every model request is centrally governed and
# observable by the **Coder AI Governance Add-On** (spend, prompts, and tool calls
# surface in Coder AI Session logs). We set the standard SDK env vars agent-wide
# with the workspace owner's Coder session token, giving a single credential that
# Claude Code, the anthropic / langchain-anthropic SDKs, and the OpenAI SDKs all
# honor. The gateway forwards to the admin-configured Amazon Bedrock provider
# (see ai-providers/) using the control plane's centrally-held credentials.
#
# We deliberately do NOT set CLAUDE_CODE_USE_BEDROCK: that makes Claude Code call
# Bedrock directly over SigV4 (workspace IAM role), which bypasses the gateway and
# produces NO AI Session logs. Routing via ANTHROPIC_BASE_URL below is what enables
# session logging.
#
# IMPORTANT: the AI Gateway routes by PROVIDER NAME, not API type. The path segment
# `bedrock` / `openai-compat` is the coderd_ai_provider *name* from
# ai-providers/ai_providers.tf (routes are /api/v2/ai-gateway/<provider-name>/).
# Anthropic-format requests go to the bedrock provider; OpenAI-format to openai-compat.
#
# NOTE: requires Coder v2.32+ with the Coder AI Governance Add-On enabled.
# LIMITATION: the gateway exposes only OpenAI- and Anthropic-compatible endpoints
# (no Bedrock SigV4), so boto3 bedrock-runtime / langchain-aws ChatBedrock still
# call Bedrock directly via the workspace IAM role; use the Anthropic/OpenAI
# clients to route through the gateway.
resource "coder_env" "anthropic_base_url" {
  agent_id = coder_agent.dev.id
  name     = "ANTHROPIC_BASE_URL"
  value    = "${trimsuffix(data.coder_workspace.me.access_url, "/")}/api/v2/ai-gateway/bedrock"
}

resource "coder_env" "anthropic_api_key" {
  agent_id = coder_agent.dev.id
  name     = "ANTHROPIC_API_KEY"
  value    = data.coder_workspace_owner.me.session_token
}

resource "coder_env" "openai_base_url" {
  agent_id = coder_agent.dev.id
  name     = "OPENAI_BASE_URL"
  value    = "${trimsuffix(data.coder_workspace.me.access_url, "/")}/api/v2/ai-gateway/openai-compat/v1"
}

resource "coder_env" "openai_api_key" {
  agent_id = coder_agent.dev.id
  name     = "OPENAI_API_KEY"
  value    = data.coder_workspace_owner.me.session_token
}

resource "coder_env" "path" {
  agent_id = coder_agent.dev.id
  name     = "PATH"
  value    = local.bin_path
}

resource "coder_agent" "dev" {
    arch = "amd64"
    os = "linux"

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
    startup_script = <<-EOT
    set -e

    # Ensure the `coder` CLI is resolvable for login shells and coder_scripts.
    # This template pins a fixed agent PATH (coder_env.path), which drops the
    # agent's own coder bin dir, so symlink coder into $HOME/.local/bin (first
    # entry of local.bin_path) and $CODER_SCRIPT_BIN_DIR.
    mkdir -p /home/coder/.local/bin
    ln -sf /tmp/coder.*/coder /home/coder/.local/bin/coder 2>/dev/null || true
    ln -sf /tmp/coder.*/coder "$CODER_SCRIPT_BIN_DIR/coder" 2>/dev/null || true

    # claude-code v5 dropped the dangerously_skip_permissions input, so set bypass
    # mode at user scope instead (skips the dangerous-mode TOS prompt). We also LOCK
    # model selection to the gateway-configured default by setting availableModels
    # to an empty array: this deployment routes through the Coder AI Gateway (Bedrock
    # provider), which only serves the admin-configured models, so switching to any
    # other model id would make the gateway reject the request. Writes only
    # ~/.claude/settings.json (needs no coder CLI), safe to run concurrently with
    # the claude-code module install.
    mkdir -p "$HOME/.claude"
    SETTINGS="$HOME/.claude/settings.json"
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    tmp=$(mktemp) && jq '. + {"skipDangerousModePermissionPrompt": true, "availableModels": [], "permissions": ((.permissions // {}) + {"defaultMode": "bypassPermissions"})}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS" || true

    EOT

}

module "coder-login" {
    source   = "registry.coder.com/coder/coder-login/coder"
    version  = "1.1.0"
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

module "code-server" {
    source   = "registry.coder.com/coder/code-server/coder"
    version  = "1.3.1"
    agent_id       = coder_agent.dev.id
    folder         = local.home_dir
    subdomain = false
    order = 0
    extensions = ["ms-toolsai.jupyter"]
}

module "kiro" {
    source   = "registry.coder.com/coder/kiro/coder"
    version  = "1.1.0"
    agent_id = coder_agent.dev.id
    order = 1
}

# Auto-install the Jupyter extension for the Kiro IDE.
# Kiro connects as a desktop client and downloads its remote server on first
# connect, so we install into the (EFS-persistent) Kiro server extensions dir:
# immediately if the server is already present, otherwise via a one-time
# background poller. Dependencies resolve automatically from Open VSX.
resource "coder_script" "kiro_jupyter_extension" {
    agent_id           = coder_agent.dev.id
    display_name       = "Kiro: install Jupyter extension"
    icon               = "/icon/kiro.svg"
    run_on_start       = true
    start_blocks_login = false
    script             = <<-EOT
    #!/bin/sh
    set -eu
    EXT_ID="ms-toolsai.jupyter"
    KIRO_BIN="$HOME/.kiro-server/bin"
    SENTINEL="$HOME/.kiro-server/.jupyter-ext-installed"

    if [ -f "$SENTINEL" ]; then
      echo "Kiro: $EXT_ID already provisioned."
      exit 0
    fi

    install_ext() {
      SRV=$(find "$KIRO_BIN" -maxdepth 3 -type f -name kiro-server 2>/dev/null | head -1)
      [ -n "$SRV" ] || return 1
      "$SRV" --install-extension "$EXT_ID" && touch "$SENTINEL"
    }

    if install_ext; then
      echo "Kiro: installed $EXT_ID."
    else
      # Server not downloaded yet (first connect pending) - poll in background.
      (
        i=0
        while [ "$i" -lt 120 ]; do
          sleep 30
          if install_ext; then
            echo "Kiro: installed $EXT_ID after connect."
            break
          fi
          i=$((i + 1))
        done
      ) >/tmp/kiro-jupyter-install.log 2>&1 &
      echo "Kiro: will install $EXT_ID on first connect (background)."
    fi
    EOT
}

module "claude-code" {
    count               = data.coder_workspace.me.start_count
    source              = "registry.coder.com/coder/claude-code/coder"
    version             = "5.4.0"
    model               = var.anthropic_model
    agent_id            = coder_agent.dev.id
    workdir             = local.home_dir
    mcp                 = local.mcp_json
        
    pre_install_script = <<-EOF
    set -e

    # Create persistent bin directory
    mkdir -p $HOME/bin
    mkdir -p $HOME/.local/bin

    # Update PATH for current session
    export PATH="$HOME/.local/bin:$HOME/bin:$HOME/.npm-global/bin:$PATH"

    #Symlink Coder Agent
    ln -sf /tmp/coder.*/coder "$CODER_SCRIPT_BIN_DIR/coder"

    EOF

}


# Clickable Claude Code launcher. claude-code v5 no longer ships a web app, so
# provide a terminal launcher tile that opens an interactive Claude Code session.
# Authentication and model routing come from the agent-wide Coder AI Gateway env
# (ANTHROPIC_BASE_URL / ANTHROPIC_API_KEY / model), so the session is governed and
# logged by the Coder AI Governance Add-On like every other request.
resource "coder_app" "claude_code" {
  agent_id     = coder_agent.dev.id
  slug         = "claude-code"
  display_name = "Claude Code"
  icon         = "/icon/claude.svg"
  order        = 2
  open_in      = "slim-window"
  command      = <<-EOT
    cd "$HOME"
    claude --dangerously-skip-permissions
  EOT
}

# Pre-approve the current ANTHROPIC_API_KEY so Claude Code never shows its
# "Detected a custom API key ... Do you want to use this API key?" prompt. The
# key is the workspace owner's Coder session token (set agent-wide for AI Gateway
# routing), which ROTATES each start - so this runs on every start. Claude Code
# records the LAST 20 CHARACTERS of an approved key in
# customApiKeyResponses.approved in ~/.claude.json (EFS-persisted home), so we
# wait for the module install to settle that file, then add the current suffix.
resource "coder_script" "claude_api_key_approve" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.dev.id
  display_name = "Claude Code: pre-approve API key"
  icon         = "/icon/claude.svg"
  run_on_start = true
  script       = <<-EOT
    #!/usr/bin/env bash
    set -u
    CFG="$HOME/.claude.json"

    # Wait up to ~120s for the claude-code module install to settle ~/.claude.json.
    for _ in $(seq 1 60); do
      if [ -f "$CFG" ] && jq -e '.hasCompletedOnboarding == true' "$CFG" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    sleep 5
    [ -f "$CFG" ] || echo '{}' > "$CFG"

    KEY="$${ANTHROPIC_API_KEY:-}"
    if [ -n "$KEY" ]; then
      SUFFIX=$(printf %s "$KEY" | tail -c 20)
      tmp=$(mktemp)
      if jq --arg k "$SUFFIX" '.customApiKeyResponses = (.customApiKeyResponses // {"approved": [], "rejected": []}) | .customApiKeyResponses.approved = (((.customApiKeyResponses.approved // []) + [$k]) | unique) | .customApiKeyResponses.rejected = ((.customApiKeyResponses.rejected // []) - [$k])' "$CFG" > "$tmp" 2>/dev/null && mv "$tmp" "$CFG"; then
        echo "Pre-approved ANTHROPIC_API_KEY in $CFG (Claude Code will not prompt)."
      else
        rm -f "$tmp"; echo "Warning: could not pre-approve ANTHROPIC_API_KEY."
      fi
    fi
    exit 0
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
    Name = "coder-${data.coder_workspace.me.name}-home"
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
  count = data.coder_workspace.me.start_count
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
            mount_path = local.home_dir
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
    count = data.coder_workspace.me.start_count
    resource_id = kubernetes_deployment.dev[0].id
    daily_cost = local.cost
}

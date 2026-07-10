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

locals {
  home_dir = "/home/coder"
  bin_path = "/home/coder/.local/bin:/home/coder/bin:/home/coder/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  cost     = 2
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

    # Create persistent bin directory
    mkdir -p $HOME/bin
    mkdir -p $HOME/.local/bin

    # Update PATH for current session
    export PATH="$HOME/.local/bin:$HOME/bin:$HOME/.npm-global/bin:$PATH"

    #Symlink Coder Agent
    ln -sf /tmp/coder.*/coder "$CODER_SCRIPT_BIN_DIR/coder"

    EOT

}

module "coder-login" {
    source   = "registry.coder.com/coder/coder-login/coder"
    version  = "1.1.0"
    agent_id = coder_agent.dev.id
}

# Provision a persistent Python 3.12 virtual environment + Jupyter kernel for
# the workshop agent notebooks (LangGraph/LangChain, LlamaIndex, Strands,
# Bedrock AgentCore). The venv and kernelspec live on the EFS-persistent home,
# so this runs once and is reused across restarts. Selectable from Jupyter
# (code-server / Kiro) and by notebook-aware agents as "Python (Agents)".
resource "coder_script" "agent_python_kernel" {
    agent_id           = coder_agent.dev.id
    display_name       = "Python/Jupyter agent kernel"
    icon               = "/icon/python.svg"
    run_on_start       = true
    start_blocks_login = false
    script             = <<-EOT
    #!/bin/sh
    set -eu
    VENV="$HOME/.venvs/agents"
    SENTINEL="$VENV/.provisioned"

    if [ -f "$SENTINEL" ]; then
      echo "Agent Python kernel already provisioned at $VENV"
      exit 0
    fi

    export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
    export UV_LINK_MODE=copy   # EFS-mounted home: avoid hardlink fallback warnings
    mkdir -p "$HOME/.venvs"

    # uv (preinstalled) creates the venv without python3-venv and fetches a
    # managed CPython 3.12 to match the notebooks' kernel.
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

    # Register the kernel so Jupyter and notebook-aware agents can select it.
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

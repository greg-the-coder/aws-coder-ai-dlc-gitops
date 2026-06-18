# AI Agent Network Governance — Reference Architecture

> **Purpose:** Recommended architecture for enforcing network egress policies on Coder workspaces hosting AI agents, ensuring challenge/contest integrity and preventing unauthorized access to external resources.
>
> **Audience:** Product & Engineering teams focused on AI Governance  
> **Status:** Proposed  
> **Date:** 2026-06-17

---

## Executive Summary

When AI agents and humans share a workspace, network restrictions must be applied **uniformly at the workspace level** — not per-process. Differential access (relaxed for humans, strict for agents) provides no security when both share a filesystem, as any data fetched by the human is immediately available to the agent.

The recommended architecture uses **Cilium CNI on EKS EC2 node groups** with FQDN-based egress allowlists and optional TLS inspection for HTTP path-level filtering. This provides kernel-level enforcement that cannot be bypassed from within a pod.

---

## Table of Contents

1. [Threat Model](#threat-model)
2. [Design Principles](#design-principles)
3. [Architecture Overview](#architecture-overview)
4. [Namespace Strategy](#namespace-strategy)
5. [Network Policy Layers](#network-policy-layers)
6. [Implementation: Cilium on EKS](#implementation-cilium-on-eks)
7. [TLS Inspection for Path Filtering](#tls-inspection-for-path-filtering)
8. [What We Evaluated and Rejected](#what-we-evaluated-and-rejected)
9. [Security Model & Bypass Analysis](#security-model--bypass-analysis)
10. [Operational Considerations](#operational-considerations)
11. [Migration Path from Current Architecture](#migration-path-from-current-architecture)
12. [Cost Analysis](#cost-analysis)
13. [Decision Log](#decision-log)

---

## Threat Model

### What We're Protecting Against

| Threat | Description | Impact |
|--------|-------------|--------|
| **External AI assistance** | Participant uses ChatGPT, Claude API, or other LLM services to solve challenges | Contest integrity compromised |
| **Unauthorized code access** | Fetching solutions from non-allowed GitHub repos, StackOverflow, etc. | Unfair advantage |
| **Data exfiltration** | Sending challenge content to external services for processing | IP leakage, integrity loss |
| **Package installation** | Installing packages that contain pre-built solutions | Contest bypass |

### What We're NOT Protecting Against

| Non-Threat | Reason |
|------------|--------|
| Kernel exploits / container escape | Separate concern (runtime security) |
| Insider admin abuse | Operational trust boundary |
| Compromised AWS credentials | IAM policy scope, separate control |

### Critical Security Insight

> **Human + Agent in the same workspace = one security boundary.**
>
> If a human can access a resource, the agent effectively can too (via shared filesystem, environment variables, terminal history). Process-level discrimination is security theater for contest integrity.

---

## Design Principles

1. **Workspace-level enforcement** — Network policy applies to the entire pod, not individual processes
2. **Default-deny posture** — Only explicitly allowed domains are reachable
3. **Kernel-level enforcement** — Policies enforced by eBPF at the node; cannot be bypassed from within the pod
4. **Namespace isolation** — Different security postures for different workspace types
5. **Selective precision** — Use TLS inspection only where path-level filtering is needed; use lightweight FQDN filtering everywhere else
6. **Defense in depth** — Combine Cilium (pod-level) with DNS Firewall (VPC-level) as a backstop

---

## Architecture Overview

```
┌─ EKS Cluster ──────────────────────────────────────────────────────────────────┐
│                                                                                 │
│  ┌─ Auto Mode Nodes ──────────┐    ┌─ Managed Node Group (EC2) ─────────────┐ │
│  │  namespace: coder           │    │  Cilium Agent (DaemonSet)               │ │
│  │  namespace: kube-system     │    │  Envoy Proxy (L7 / TLS inspection)      │ │
│  │  (Coder control plane,     │    │                                          │ │
│  │   Cilium operator)          │    │  ┌─ coder-ws ──────────────────────┐   │ │
│  │                             │    │  │  Human-only workspaces           │   │ │
│  │                             │    │  │  Policy: UNRESTRICTED egress     │   │ │
│  │                             │    │  │  Use case: General development   │   │ │
│  │                             │    │  └──────────────────────────────────┘   │ │
│  │                             │    │                                          │ │
│  │                             │    │  ┌─ coder-ws-agents ───────────────┐   │ │
│  │                             │    │  │  Human + Agent workspaces        │   │ │
│  │                             │    │  │  Policy: FQDN ALLOWLIST          │   │ │
│  │                             │    │  │  + TLS inspection (GitHub paths) │   │ │
│  │                             │    │  │  Use case: AI challenges/contests│   │ │
│  │                             │    │  └──────────────────────────────────┘   │ │
│  └─────────────────────────────┘    └──────────────────────────────────────────┘ │
│                                                                                 │
│  ┌─ VPC-Level (Defense in Depth) ────────────────────────────────────────────┐ │
│  │  Route 53 DNS Firewall — blocks DNS for non-allowed domains (VPC-wide)    │ │
│  │  (Optional) AWS Network Firewall — TLS SNI enforcement at subnet level    │ │
│  └───────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Namespace Strategy

| Namespace | Who Uses It | Network Policy | Rationale |
|-----------|-------------|----------------|-----------|
| `coder` | Coder control plane | Unrestricted (system) | Needs full API access |
| `coder-ws` | Human developers (no agents) | Unrestricted | Full internet access for general work |
| `coder-ws-agents` | Humans + AI agents together | **Restricted allowlist** | Contest integrity — same rules for human and agent |

### Why Not Per-Process Restrictions?

| Approach | Bypassable? | How |
|----------|:-----------:|-----|
| Restrict agent process only | ✅ | Human fetches data, saves to shared filesystem; agent reads it |
| Restrict agent container (sidecar) | ✅ | Shared volume mount, environment variables, IPC |
| Restrict entire pod (Cilium) | ❌ | No shared path between restricted and unrestricted contexts |

**The only non-bypassable boundary is the pod/namespace level.** Both human and agent processes within the same workspace must operate under identical restrictions.

---

## Network Policy Layers

### Layer 1: Cilium FQDN Egress Allowlist (Primary — Pod Level)

Enforced by eBPF at the kernel level on workspace nodes. DNS-proxy-based domain matching with wildcard support.

**Allowed domains for `coder-ws-agents`:**

| Category | Domains | Method |
|----------|---------|--------|
| AWS Workshop | `catalog.us-east-1.prod.workshops.aws` | `toFQDNs matchName` |
| GitHub (aws-samples) | `github.com`, `api.github.com`, `raw.githubusercontent.com`, `codeload.github.com`, `objects.githubusercontent.com` | `toFQDNs matchName` + TLS inspection (path filter) |
| AWS APIs | `*.amazonaws.com`, `*.api.aws` | `toFQDNs matchPattern` |
| AWS Docs | `docs.aws.amazon.com`, `repost.aws`, `*.awsstatic.com` | `toFQDNs matchName/Pattern` |
| Coder Control Plane | `*.cloudfront.net` (or specific distribution) | `toFQDNs matchPattern` |
| Infrastructure | VPC CIDR (EFS NFS), IMDS, Pod Identity endpoints | `toCIDR` |

**Blocked (implicit deny):**
- All external AI APIs (OpenAI, Anthropic, Google AI, etc.)
- Package registries (PyPI, npm, crates.io)
- General internet (Google, StackOverflow, etc.)
- Non-aws-samples GitHub repositories (path-enforced via TLS inspection)

### Layer 2: Cilium TLS Inspection (Targeted — GitHub Only)

Applied selectively to GitHub domains where path-level filtering is required. Uses node-local Envoy to terminate TLS, inspect HTTP path, and re-encrypt.

**Path rules:**

| Domain | Allowed Paths | Denied |
|--------|---------------|--------|
| `github.com` | `/aws-samples/.*` | `/microsoft/.*`, `/torvalds/.*`, etc. |
| `api.github.com` | `/repos/aws-samples/.*` | `/repos/microsoft/.*`, etc. |
| `raw.githubusercontent.com` | `/aws-samples/.*` | Everything else |
| `codeload.github.com` | `/aws-samples/.*` | Everything else |

**Not TLS-inspected (lightweight FQDN only):**
- `*.amazonaws.com` — all paths allowed, no overhead
- `docs.aws.amazon.com` — all paths allowed
- `*.awsstatic.com` — all paths allowed

### Layer 3: Route 53 DNS Firewall (Backstop — VPC Level)

VPC-wide DNS-level enforcement. Prevents resolution of non-allowed domains even if Cilium is misconfigured or bypassed through direct IP connections.

```
Allowed: same domain list as Cilium
Blocked: * (NXDOMAIN response)
```

---

## Implementation: Cilium on EKS

### Prerequisites

- EKS cluster with EC2 managed node group (NOT Fargate)
- Node group with label `node-role=workspace` and taint `workspace-only=true:NoSchedule`
- AWS VPC CNI installed (Cilium runs in chaining mode alongside it)

### Installation

```bash
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set cni.chainingMode=aws-cni \
  --set cni.exclusive=false \
  --set enableIPv4Masquerade=false \
  --set tunnel=disabled \
  --set endpointRoutes.enabled=true \
  --set nodeinit.enabled=true \
  --set operator.replicas=2 \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set policyEnforcementMode=default \
  --set envoy.enabled=true
```

### Core Network Policy

```yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: agent-workspace-egress-allowlist
  namespace: coder-ws-agents
spec:
  endpointSelector: {}
  egress:
    # DNS (required for FQDN resolution)
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s:k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
          rules:
            dns:
              - matchPattern: "*"

    # Coder control plane (intra-cluster)
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: coder
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
            - port: "80"
              protocol: TCP

    # AWS Workshop Catalog
    - toFQDNs:
        - matchName: "catalog.us-east-1.prod.workshops.aws"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP

    # GitHub (with TLS inspection for path filtering)
    - toFQDNs:
        - matchName: "github.com"
        - matchName: "api.github.com"
        - matchName: "raw.githubusercontent.com"
        - matchName: "codeload.github.com"
        - matchName: "objects.githubusercontent.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
          terminatingTLS:
            secret:
              namespace: cilium-secrets
              name: github-egress-tls
          originatingTLS:
            secret:
              namespace: cilium-secrets
              name: public-root-cas
          rules:
            http:
              - host: "github.com"
                path: "/aws-samples/.*"
              - host: "api.github.com"
                path: "/repos/aws-samples/.*"
              - host: "raw.githubusercontent.com"
                path: "/aws-samples/.*"
              - host: "codeload.github.com"
                path: "/aws-samples/.*"
              - host: "objects.githubusercontent.com"
                path: "/github-production-release-asset/.*"

    # AWS APIs (all services, all paths — no TLS inspection needed)
    - toFQDNs:
        - matchPattern: "*.amazonaws.com"
        - matchPattern: "*.api.aws"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP

    # AWS Documentation
    - toFQDNs:
        - matchName: "docs.aws.amazon.com"
        - matchName: "repost.aws"
        - matchPattern: "*.awsstatic.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP

    # CloudFront (Coder access URL)
    - toFQDNs:
        - matchPattern: "*.cloudfront.net"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP

    # Infrastructure: EFS (NFS)
    - toCIDR:
        - "192.168.0.0/16"
      toPorts:
        - ports:
            - port: "2049"
              protocol: TCP

    # Infrastructure: IMDS + Pod Identity
    - toCIDR:
        - "169.254.169.254/32"
        - "169.254.170.23/32"
        - "169.254.170.2/32"
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
            - port: "443"
              protocol: TCP
```

---

## TLS Inspection for Path Filtering

### When to Use

| Scenario | TLS Inspection? | Reason |
|----------|:---:|--------|
| `github.com` restricted to `/aws-samples/*` | ✅ | Path is inside encrypted TLS payload |
| `*.amazonaws.com` (all paths allowed) | ❌ | No path restriction needed |
| `docs.aws.amazon.com` (all paths allowed) | ❌ | No path restriction needed |
| Blocking `pypi.org` entirely | ❌ | Domain-level deny at `toFQDNs` is sufficient |

### How It Works

```
Pod → HTTPS request to github.com/microsoft/vscode
       │
       ▼ (eBPF intercepts, redirects to node Envoy)
Node Envoy:
  1. Terminates TLS using internal CA certificate
  2. Inspects HTTP: GET /microsoft/vscode
  3. Checks against policy: path must match /aws-samples/.*
  4. DENIED → returns HTTP 403 to the pod
  5. (If allowed: re-encrypts and forwards to real github.com)
```

### Setup Requirements

1. Internal CA certificate + per-domain keys (stored as K8s secrets)
2. CA certificate injected into workspace container image (so `curl`, `git`, Python `requests` trust it)
3. Cilium Envoy enabled on workspace nodes

### Trade-offs

| Benefit | Cost |
|---------|------|
| Full HTTPS path filtering | 2-5ms latency per request on inspected domains |
| Matches original firewall spec exactly | Certificate management complexity |
| Transparent to applications (if CA is trusted) | Must regenerate certs before expiry |
| Works with git, curl, all HTTP clients | ~50-100MB additional memory per node (Envoy) |

---

## What We Evaluated and Rejected

| Solution | Why Rejected |
|----------|--------------|
| **Coder Agent Firewall (boundary)** | Cannot enforce on Fargate (no `CAP_NET_ADMIN`). On EC2 it works but requires per-pod capability escalation and is a Coder-specific tool with limited customer adoption. |
| **AWS Bedrock Guardrails** | Content safety filter, not network security. Cannot intercept tool calls or enforce URL allowlists. Wrong architectural layer. |
| **AWS Bedrock AgentCore** | Purpose-built agent runtime with 8hr max sessions. Not a workspace host. Network controls limited to VPC security groups (same as Fargate). |
| **Linkerd EgressNetwork** | Requires `CAP_NET_ADMIN` for traffic interception. SNI-only for HTTPS (no path filtering). Less mature egress features. |
| **Istio Sidecar** | Heavy operational overhead. Path filtering requires TLS origination with app cooperation. ~50MB per sidecar. |
| **Istio Ambient** | ztunnel DaemonSet works on EC2 but L7 egress via waypoints is immature. |
| **Calico Enterprise** | FQDN filtering is paid-only. No L7 path filtering on egress. |
| **AWS VPC CNI NetworkPolicy** | L3/L4 only (IP + port). No FQDN or L7 capability. |
| **Fargate + DNS Firewall** | Domain-level only (no path filtering). DNS Firewall is VPC-scoped (affects all workloads). Bypassable via hardcoded IPs. |
| **Per-process restrictions** | Bypassable via shared filesystem. Security theater when human and agent coexist. |

---

## Security Model & Bypass Analysis

### Enforcement Boundary

```
┌─────────────────────────────────────────────────┐
│  Pod (workspace)                                 │
│                                                  │
│  Human terminal ──┐                              │
│                   ├──── ALL egress traffic ────▶ eBPF (kernel)
│  Agent process ───┘                              │      │
│                                                  │      ▼
│  Cannot bypass:                                  │  Cilium policy
│  - No CAP_NET_ADMIN (can't modify eBPF)         │  evaluation
│  - No access to host network namespace          │      │
│  - DNS only to kube-dns (no alt resolvers)      │      ▼
│  - Unknown IPs implicitly denied                 │  Allow / Deny
└─────────────────────────────────────────────────┘
```

### Bypass Resistance

| Attack Vector | Mitigated? | How |
|---|:---:|---|
| Direct IP (bypass DNS) | ✅ | Implicit deny — only IPs learned from allowed DNS queries are permitted |
| Alternative DNS server | ✅ | Egress to port 53 only allowed to kube-dns |
| DNS-over-HTTPS (DoH) | ✅ | DoH servers (cloudflare-dns.com, etc.) not in allowlist |
| Modify /etc/resolv.conf | ✅ | Doesn't matter — eBPF blocks non-kube-dns port 53 egress |
| Tunneling (DNS/ICMP) | ✅ | DNS restricted to kube-dns; ICMP blocked (no rule allows it) |
| Shared CDN IP exploitation | ⚠️ | Low risk — Cilium tracks per-FQDN IP mappings |
| `unset HTTPS_PROXY` | N/A | Not proxy-based; eBPF is transparent and mandatory |
| Container escape | ❌ | Separate concern (runtime security, not network policy) |

### Residual Risks

1. **CDN IP overlap** — If an allowed domain (e.g., `*.cloudfront.net`) shares IPs with a blocked service, traffic to that IP may be allowed. Mitigate by narrowing CloudFront rule to specific distribution.
2. **Broad `*.amazonaws.com`** — Allows all AWS services. A participant could theoretically use an allowed AWS service in unintended ways (e.g., SageMaker endpoints). Mitigate with IAM if needed.
3. **GitHub release assets** — `objects.githubusercontent.com/github-production-release-asset/*` allows downloading any GitHub release asset, not just from aws-samples. Acceptable risk for contest scenarios.

---

## Operational Considerations

### Observability (Hubble)

Cilium includes Hubble for real-time flow visibility:

```bash
# See denied flows in agent workspace namespace
hubble observe --namespace coder-ws-agents --verdict DROPPED

# See allowed flows to GitHub
hubble observe --namespace coder-ws-agents --to-fqdn "github.com"

# Export to Prometheus/Grafana for dashboards
```

### Policy Updates

Network policy changes are applied via `kubectl apply` — no pod restart needed. Cilium picks up changes within seconds.

### Certificate Rotation (TLS Inspection)

| Component | Rotation Frequency | Automated? |
|---|---|---|
| Internal CA | Annually | Manual (or cert-manager) |
| Per-domain certs | 90 days | cert-manager recommended |
| Root CA in workspace image | On CA rotation | Rebuild image |

### Monitoring & Alerting

| Signal | Alert |
|--------|-------|
| Cilium agent pod unhealthy | P1 — policy enforcement may be degraded |
| High volume of DROPPED flows from single pod | Possible bypass attempt or misconfiguration |
| DNS proxy errors | Policy may not be applied correctly |
| TLS certificate expiry < 14 days | Rotate certificates |

---

## Migration Path from Current Architecture

### Phase 1: Infrastructure (Week 1-2)

1. Add EC2 managed node group to EKS cluster (alongside existing Auto Mode)
2. Configure node taints/labels for workspace scheduling
3. Install Cilium in chaining mode on workspace nodes
4. Add EFS mount targets in private subnets
5. Validate Cilium is healthy: `cilium status`

### Phase 2: Namespace & Policy (Week 2-3)

1. Create `coder-ws-agents` namespace
2. Apply `CiliumNetworkPolicy` (FQDN allowlist without TLS inspection initially)
3. Set up RBAC and Pod Identity for new namespace
4. Deploy test workspace → verify allowed endpoints respond, blocked endpoints fail

### Phase 3: TLS Inspection (Week 3-4)

1. Generate internal CA and per-domain certificates
2. Inject CA into workspace container image
3. Create Kubernetes TLS secrets
4. Enable `terminatingTLS` / `originatingTLS` on GitHub policy rules
5. Validate: `git clone github.com/aws-samples/repo` works; `git clone github.com/other/repo` returns 403

### Phase 4: Template Migration (Week 4-5)

1. Update challenge agent template: `namespace → coder-ws-agents`
2. Add tolerations and nodeSelector for workspace node group
3. Remove `agent-firewall` module from template
4. Create/update human-only template: `namespace → coder-ws`
5. Deploy and validate end-to-end

### Phase 5: DNS Firewall Backstop (Week 5-6)

1. Deploy Route 53 DNS Firewall rules (same domain list)
2. Associate with VPC
3. Validate: DNS resolution fails for non-allowed domains
4. Monitor for false positives from other VPC workloads

### Phase 6: Decommission Fargate (Week 6+)

1. Drain existing Fargate workspaces
2. Remove Fargate profile
3. Optionally remove Fargate subnets or repurpose
4. Remove `FargatePodExecutionRole`
5. Remove IRSA configuration (replaced by Pod Identity)

---

## Cost Analysis

| Component | Current (Fargate) | Proposed (EC2 + Cilium) |
|---|---|---|
| Workspace compute | ~$0.05/vCPU-hr + $0.005/GB-hr (per-pod) | m5.xlarge: ~$0.192/hr per node |
| Minimum (idle) | $0 (scales to zero) | ~$280/mo (2 nodes minimum) |
| At 20 concurrent workspaces | ~$800-1200/mo | ~$560-840/mo |
| At 50 concurrent workspaces | ~$2000-3000/mo | ~$1150-1500/mo |
| Network policy | Agent Firewall (broken, $0 value) | Cilium OSS (free) |
| DNS Firewall | N/A | ~$1/mo + $0.40/M queries |
| TLS certificates | N/A | cert-manager (free) or manual |
| Observability | None | Hubble (included with Cilium) |

**Net:** Higher minimum cost (no scale-to-zero), but better unit economics at scale due to bin-packing. Dramatically better security posture.

---

## Decision Log

| # | Decision | Rationale | Date |
|---|----------|-----------|------|
| 1 | Uniform workspace-level restrictions (not per-process) | Shared filesystem makes per-process discrimination bypassable | 2026-06-17 |
| 2 | Cilium over Linkerd/Istio/Calico | OSS, eBPF-native (no sidecar), strongest bypass resistance, FQDN + L7 + TLS inspection in one tool | 2026-06-17 |
| 3 | EC2 node groups over Fargate | Fargate blocks all enforcement mechanisms (no DaemonSets, no CAP_NET_ADMIN, no eBPF, no custom CNI) | 2026-06-17 |
| 4 | Two namespaces over one | Clean separation: unrestricted human-only vs restricted human+agent | 2026-06-17 |
| 5 | TLS inspection only for GitHub (not all traffic) | Minimizes performance overhead; AWS endpoints don't need path filtering | 2026-06-17 |
| 6 | DNS Firewall as backstop, not primary | Cilium is primary (namespace-scoped, path-capable); DNS Firewall is VPC-wide defense-in-depth | 2026-06-17 |
| 7 | Reject Bedrock Guardrails for this use case | Content filter, not network security. Cannot intercept tool execution. Wrong layer. | 2026-06-17 |
| 8 | Reject Bedrock AgentCore as workspace host | 8hr max session, no port exposure, no persistent compute. Purpose-built for agent sessions, not developer workspaces. | 2026-06-17 |
| 9 | Reject Coder Agent Firewall | Low customer adoption. Requires CAP_NET_ADMIN (same EC2 requirement as Cilium, but weaker enforcement — process-level vs kernel-level) | 2026-06-17 |

---

## Appendix A: Complete Allowlist Specification

```yaml
# Source of truth for network egress policy
# Applied to: coder-ws-agents namespace
egress_policy:
  default: deny
  
  allowlist:
    - category: "AWS Workshop"
      domains:
        - "catalog.us-east-1.prod.workshops.aws"
      path_filter: none
      tls_inspection: false

    - category: "GitHub (aws-samples)"
      domains:
        - "github.com"
        - "api.github.com"
        - "raw.githubusercontent.com"
        - "codeload.github.com"
      path_filter:
        github.com: "/aws-samples/.*"
        api.github.com: "/repos/aws-samples/.*"
        raw.githubusercontent.com: "/aws-samples/.*"
        codeload.github.com: "/aws-samples/.*"
      tls_inspection: true

    - category: "GitHub (release assets)"
      domains:
        - "objects.githubusercontent.com"
      path_filter:
        objects.githubusercontent.com: "/github-production-release-asset/.*"
      tls_inspection: true

    - category: "AWS APIs"
      domains:
        - "*.amazonaws.com"
        - "*.api.aws"
      path_filter: none
      tls_inspection: false

    - category: "AWS Documentation"
      domains:
        - "docs.aws.amazon.com"
        - "repost.aws"
        - "*.awsstatic.com"
      path_filter: none
      tls_inspection: false

    - category: "Coder Control Plane"
      domains:
        - "*.cloudfront.net"
      path_filter: none
      tls_inspection: false

    - category: "Infrastructure"
      cidr:
        - "192.168.0.0/16"   # VPC (EFS NFS port 2049)
        - "169.254.169.254/32"  # IMDS
        - "169.254.170.23/32"   # Pod Identity
        - "169.254.170.2/32"    # ECS credential endpoint
      path_filter: none
      tls_inspection: false
```

---

## Appendix B: Governance Compliance Mapping

| Governance Requirement | How This Architecture Addresses It |
|---|---|
| AI agents must not access unauthorized external resources | Default-deny egress + FQDN allowlist at kernel level |
| Contest participants cannot use external AI for answers | All AI API domains (OpenAI, Anthropic, Google, etc.) blocked |
| Access to approved resources only | Explicit allowlist with domain + path precision |
| Audit trail of network access | Hubble flow logs + CloudWatch VPC Flow Logs |
| Cannot be circumvented by participants | eBPF enforcement at node kernel; pod has no privilege to modify |
| Uniform enforcement regardless of access method | Pod-level policy; applies to human terminal and agent process equally |
| Doesn't interfere with legitimate AWS service use | `*.amazonaws.com` + `*.api.aws` wildcards allow all AWS APIs |
| Separates restricted from unrestricted workloads | Namespace isolation: `coder-ws` vs `coder-ws-agents` |

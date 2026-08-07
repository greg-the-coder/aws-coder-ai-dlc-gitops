"""
Pre-deploy cost estimation.

Uses static monthly estimates (as of 2025 us-east-1 pricing) to give customers
a rough cost preview before they commit to deploying. These are approximations —
direct users to the AWS Pricing Calculator for authoritative numbers.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List


@dataclass
class CostLineItem:
    service: str
    description: str
    monthly_usd: float
    notes: str = ""


@dataclass
class CostEstimate:
    items: List[CostLineItem] = field(default_factory=list)
    disclaimer: str = (
        "These are rough estimates based on typical usage patterns. "
        "Actual costs depend on workspace hours, data transfer, and Aurora ACU consumption. "
        "Use the AWS Pricing Calculator (https://calculator.aws) for authoritative estimates."
    )

    @property
    def total(self) -> float:
        return sum(i.monthly_usd for i in self.items)

    def format_table(self) -> str:
        lines = [
            f"{'Service':<30} {'Description':<45} {'Est. $/mo':>10}",
            "-" * 88,
        ]
        for item in self.items:
            lines.append(f"{item.service:<30} {item.description:<45} ${item.monthly_usd:>8.0f}")
        lines.append("-" * 88)
        lines.append(f"{'ESTIMATED TOTAL':<76} ${self.total:>8.0f}/mo")
        lines.append("")
        lines.append(f"Note: {self.disclaimer}")
        return "\n".join(lines)


def estimate(
    developer_count: int = 10,
    avg_workspace_hours_per_day: float = 6.0,
    region: str = "us-east-1",
) -> CostEstimate:
    """
    Build a monthly cost estimate based on team size and workspace usage.

    Parameters
    ----------
    developer_count              : number of concurrent developers
    avg_workspace_hours_per_day  : how many hours/day the average workspace runs
    region                       : AWS region (currently only affects disclaimer wording)
    """
    est = CostEstimate()

    # -----------------------------------------------------------------------
    # EKS Control Plane — $0.10/hr flat
    # -----------------------------------------------------------------------
    eks_control_plane = 0.10 * 24 * 30
    est.items.append(CostLineItem(
        service="Amazon EKS",
        description="Control plane (~$0.10/hr)",
        monthly_usd=round(eks_control_plane, 2),
    ))

    # -----------------------------------------------------------------------
    # Fargate workspace compute — 1 vCPU / 2 GB per workspace
    # Fargate pricing: ~$0.04048/vCPU-hr, ~$0.004445/GB-hr
    # -----------------------------------------------------------------------
    vcpu_per_workspace = 1.0
    gb_per_workspace = 2.0
    fargate_cpu_rate = 0.04048
    fargate_mem_rate = 0.004445
    workspace_hours_per_month = avg_workspace_hours_per_day * 30

    fargate_monthly = developer_count * workspace_hours_per_month * (
        vcpu_per_workspace * fargate_cpu_rate
        + gb_per_workspace * fargate_mem_rate
    )
    est.items.append(CostLineItem(
        service="AWS Fargate",
        description=f"{developer_count} devs × {avg_workspace_hours_per_day}h/day workspaces",
        monthly_usd=round(fargate_monthly, 2),
        notes="1 vCPU / 2 GB per workspace (Firecracker microVM)",
    ))

    # -----------------------------------------------------------------------
    # Aurora PostgreSQL Serverless v2
    # Minimum: 0.5 ACU, ~$0.12/ACU-hr — idle ~0.5 ACU, under load ~4 ACU
    # Estimate: ~2 ACU average
    # -----------------------------------------------------------------------
    aurora_acu_avg = 2.0
    aurora_acu_rate = 0.12
    aurora_storage_gb = 10
    aurora_storage_rate = 0.10  # $/GB-mo
    aurora_monthly = (aurora_acu_avg * aurora_acu_rate * 24 * 30) + (aurora_storage_gb * aurora_storage_rate)
    est.items.append(CostLineItem(
        service="Aurora PostgreSQL Serverless v2",
        description=f"~{aurora_acu_avg} ACU avg + {aurora_storage_gb} GB storage",
        monthly_usd=round(aurora_monthly, 2),
    ))

    # -----------------------------------------------------------------------
    # NAT Gateways — 2 (one per AZ), $0.045/hr each + data
    # -----------------------------------------------------------------------
    nat_hourly = 2 * 0.045 * 24 * 30
    nat_data_gb = developer_count * 5  # rough: 5 GB/dev/month outbound
    nat_data_cost = nat_data_gb * 0.045
    nat_monthly = nat_hourly + nat_data_cost
    est.items.append(CostLineItem(
        service="NAT Gateway",
        description=f"2 AZs ($0.045/hr) + ~{nat_data_gb} GB data",
        monthly_usd=round(nat_monthly, 2),
    ))

    # -----------------------------------------------------------------------
    # CloudFront — low cost for internal Coder access
    # -----------------------------------------------------------------------
    cf_monthly = 5.0  # nominal for internal traffic
    est.items.append(CostLineItem(
        service="CloudFront",
        description="HTTPS termination for Coder dashboard",
        monthly_usd=cf_monthly,
        notes="Actual cost depends on request volume; likely $1–15/mo",
    ))

    # -----------------------------------------------------------------------
    # EFS — persistent workspace home directories
    # ~2 GB per developer, elastic throughput
    # -----------------------------------------------------------------------
    efs_gb = developer_count * 2
    efs_rate = 0.30  # $/GB-mo (Standard)
    efs_monthly = efs_gb * efs_rate
    est.items.append(CostLineItem(
        service="Amazon EFS",
        description=f"~{efs_gb} GB (persistent /home/coder per workspace)",
        monthly_usd=round(efs_monthly, 2),
    ))

    # -----------------------------------------------------------------------
    # ECR — ~3 repos, ~1 GB images each
    # -----------------------------------------------------------------------
    ecr_monthly = 3 * 1 * 0.10  # $0.10/GB-mo after 50 GB free tier
    est.items.append(CostLineItem(
        service="Amazon ECR",
        description="3 workspace image repositories (~1 GB each)",
        monthly_usd=round(ecr_monthly, 2),
        notes="Often within free tier",
    ))

    # -----------------------------------------------------------------------
    # Bedrock inference — rough estimate
    # Claude Opus 4: $15/M input tokens, $75/M output tokens
    # ~50 agent interactions/dev/day, ~2K tokens each = 3M input tokens/mo (10 devs)
    # -----------------------------------------------------------------------
    bedrock_input_tokens_m = developer_count * 50 * 30 * 2000 / 1_000_000
    bedrock_input_cost = bedrock_input_tokens_m * 15
    bedrock_output_tokens_m = bedrock_input_tokens_m * 0.5
    bedrock_output_cost = bedrock_output_tokens_m * 75
    bedrock_monthly = bedrock_input_cost + bedrock_output_cost
    est.items.append(CostLineItem(
        service="Amazon Bedrock (Claude Opus 4)",
        description=f"~{bedrock_input_tokens_m:.1f}M input / {bedrock_output_tokens_m:.1f}M output tokens/mo",
        monthly_usd=round(bedrock_monthly, 2),
        notes="Highly variable; scales with agent usage",
    ))

    return est

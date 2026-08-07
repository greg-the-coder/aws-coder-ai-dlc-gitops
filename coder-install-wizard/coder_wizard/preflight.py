"""
Pre-flight checks for a production Coder install on AWS.
Each check returns a CheckResult with status (ok / warn / fail) and a message.
"""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass, field
from typing import Callable, List


# ---------------------------------------------------------------------------
# Result model
# ---------------------------------------------------------------------------

@dataclass
class CheckResult:
    name: str
    status: str          # "ok" | "warn" | "fail"
    message: str
    detail: str = ""
    fix: str = ""        # suggested remediation shown to the user


@dataclass
class PreflightReport:
    results: List[CheckResult] = field(default_factory=list)

    def add(self, r: CheckResult) -> None:
        self.results.append(r)

    @property
    def passed(self) -> bool:
        return all(r.status != "fail" for r in self.results)

    @property
    def warnings(self) -> List[CheckResult]:
        return [r for r in self.results if r.status == "warn"]

    @property
    def failures(self) -> List[CheckResult]:
        return [r for r in self.results if r.status == "fail"]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _aws(args: list[str]) -> tuple[int, str, str]:
    """Run an AWS CLI command and return (exit_code, stdout, stderr)."""
    result = subprocess.run(
        ["aws"] + args + ["--output", "json"],
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def _aws_json(args: list[str]) -> tuple[int, dict | list | None]:
    code, out, _ = _aws(args)
    if code != 0 or not out:
        return code, None
    try:
        return 0, json.loads(out)
    except json.JSONDecodeError:
        return 0, None


# ---------------------------------------------------------------------------
# Individual checks
# ---------------------------------------------------------------------------

def check_aws_credentials() -> CheckResult:
    """Verify that valid AWS credentials are configured."""
    code, out, err = _aws(["sts", "get-caller-identity"])
    if code != 0:
        return CheckResult(
            name="AWS Credentials",
            status="fail",
            message="No valid AWS credentials found.",
            detail=err,
            fix="Run `aws configure` or `aws sso login --profile <name>` then retry.",
        )
    data = json.loads(out)
    return CheckResult(
        name="AWS Credentials",
        status="ok",
        message=f"Authenticated as {data.get('Arn', 'unknown')}",
        detail=f"Account: {data.get('Account')}",
    )


def check_aws_region(region: str) -> CheckResult:
    """Warn if the target region is not us-east-1 (Bedrock inference profiles are hardcoded there)."""
    if region == "us-east-1":
        return CheckResult(
            name="AWS Region",
            status="ok",
            message=f"Region {region} — Bedrock cross-region inference fully supported.",
        )
    return CheckResult(
        name="AWS Region",
        status="warn",
        message=f"Region {region} detected. Coder Agents use Bedrock models served from us-east-1.",
        detail=(
            "The Anthropic inference profile IDs (global.anthropic.claude-*) in this deployment "
            "are routed via Bedrock cross-region inference from us-east-1. "
            "Agent features will work regardless of your deploy region, but Bedrock latency "
            "may be slightly higher than a direct us-east-1 deploy."
        ),
        fix="No action required. Alternatively, deploy in us-east-1 for lowest Bedrock latency.",
    )


def check_bedrock_model_access(region: str = "us-east-1") -> CheckResult:
    """Check that the required Bedrock foundation models are accessible."""
    required_models = [
        # (model_id_prefix_to_check, friendly_name)
        ("anthropic.claude-3-haiku",    "Claude Haiku (Bedrock)"),
        ("anthropic.claude-opus-4",     "Claude Opus 4 (Bedrock)"),
        ("mistral.mistral-large",       "Mistral Large (Bedrock Mantle)"),
        ("mistral.devstral",            "Devstral (Bedrock Mantle)"),
    ]

    code, data = _aws_json([
        "bedrock", "list-foundation-models",
        "--region", region,
        "--by-inference-type", "ON_DEMAND",
    ])

    if code != 0 or data is None:
        return CheckResult(
            name="Bedrock Model Access",
            status="warn",
            message="Could not list Bedrock foundation models (API call failed).",
            detail="This may mean Bedrock is not enabled in your account or the IAM caller lacks bedrock:ListFoundationModels.",
            fix=(
                "Go to AWS Console → Amazon Bedrock → Model access and enable:\n"
                "  • Claude Opus 4 / Claude Haiku 4.5 (Anthropic)\n"
                "  • Mistral Large 3 / Devstral 2 (Mistral AI)\n"
                "Ensure your IAM user/role has bedrock:InvokeModel permission."
            ),
        )

    available = {m["modelId"] for m in data.get("modelSummaries", [])}
    missing = [
        name
        for prefix, name in required_models
        if not any(mid.startswith(prefix) for mid in available)
    ]

    if missing:
        return CheckResult(
            name="Bedrock Model Access",
            status="warn",
            message=f"Some Bedrock models may not be enabled: {', '.join(missing)}",
            fix=(
                "Go to AWS Console → Amazon Bedrock → Model access and request access for the missing models.\n"
                "Access is usually granted within seconds for on-demand models."
            ),
        )

    return CheckResult(
        name="Bedrock Model Access",
        status="ok",
        message="All required Bedrock foundation models appear accessible.",
    )


def check_service_quota(service_code: str, quota_code: str, required: float, friendly_name: str) -> CheckResult:
    """Check a single Service Quotas limit."""
    code, data = _aws_json([
        "service-quotas", "get-service-quota",
        "--service-code", service_code,
        "--quota-code", quota_code,
    ])

    if code != 0 or data is None:
        return CheckResult(
            name=f"Quota: {friendly_name}",
            status="warn",
            message=f"Could not retrieve quota for {friendly_name}.",
            fix=f"Check manually: AWS Console → Service Quotas → {service_code} → {quota_code}",
        )

    limit = data.get("Quota", {}).get("Value", 0)
    if limit < required:
        return CheckResult(
            name=f"Quota: {friendly_name}",
            status="fail",
            message=f"Quota too low: {limit} available, {required} required.",
            fix=(
                f"Open AWS Console → Service Quotas → {service_code} and request an increase "
                f"for '{quota_code}' to at least {int(required)}."
            ),
        )

    return CheckResult(
        name=f"Quota: {friendly_name}",
        status="ok",
        message=f"Quota OK: {limit} available (need {required}).",
    )


def check_eks_quotas() -> List[CheckResult]:
    """Check EKS, VPC, and NAT Gateway quotas needed for the deployment."""
    return [
        check_service_quota("eks",     "L-1194D53C", 3,  "EKS Clusters"),
        check_service_quota("vpc",     "L-FE5A380F", 5,  "VPCs per Region"),
        check_service_quota("vpc",     "L-0263D0A3", 5,  "NAT Gateways per AZ"),
        check_service_quota("ec2",     "L-0263D0A3", 5,  "Elastic IP Addresses"),
    ]


def check_ecr_images(account_id: str, region: str, eks_cluster_name: str) -> CheckResult:
    """Verify that Step 1 (image pipeline) has already run and ECR images exist."""
    repos_expected = [
        f"{eks_cluster_name}/coder-workspace-claude-code",
        f"{eks_cluster_name}/coder-workspace-kiro-cli",
        f"{eks_cluster_name}/coder-workspace-challenge",
    ]

    missing: list[str] = []
    for repo in repos_expected:
        code, data = _aws_json([
            "ecr", "describe-images",
            "--repository-name", repo,
            "--region", region,
            "--image-ids", "imageTag=latest",
        ])
        if code != 0 or not data:
            missing.append(repo)

    if missing:
        return CheckResult(
            name="ECR Workspace Images",
            status="fail",
            message=f"Missing ECR images in {len(missing)} repositor{'y' if len(missing)==1 else 'ies'}.",
            detail="\n".join(f"  ✗ {r}" for r in missing),
            fix=(
                "Deploy the image pipeline stack first:\n"
                "  aws cloudformation create-stack \\\n"
                "    --stack-name coder-image-pipeline \\\n"
                f"    --template-url <S3_URL_OR_LOCAL_PATH>/codebuild_image_pipeline.yaml \\\n"
                f"    --parameters ParameterKey=EKSClusterName,ParameterValue={eks_cluster_name} \\\n"
                "    --capabilities CAPABILITY_IAM\n"
                "Then wait for the CodeBuild project to complete before rerunning this wizard."
            ),
        )

    return CheckResult(
        name="ECR Workspace Images",
        status="ok",
        message=f"All {len(repos_expected)} workspace images found in ECR with tag :latest.",
    )


def check_existing_eks_cluster(eks_cluster_name: str, region: str) -> CheckResult:
    """Detect an existing EKS cluster with the same name (would block a fresh deploy)."""
    code, data = _aws_json([
        "eks", "describe-cluster",
        "--name", eks_cluster_name,
        "--region", region,
    ])

    if code == 0 and data:
        status = data.get("cluster", {}).get("status", "UNKNOWN")
        return CheckResult(
            name="EKS Cluster Name Conflict",
            status="warn",
            message=f"An EKS cluster named '{eks_cluster_name}' already exists (status: {status}).",
            detail="A fresh deployment will fail if the cluster name is taken.",
            fix=(
                "Either:\n"
                "  • Choose a different EKSClusterName parameter, or\n"
                "  • Set RetryFlag=True if you are re-deploying Coder onto the existing cluster."
            ),
        )

    return CheckResult(
        name="EKS Cluster Name Conflict",
        status="ok",
        message=f"No existing EKS cluster named '{eks_cluster_name}' found. Safe to deploy.",
    )


def check_aurora_quota(region: str) -> CheckResult:
    """Check Aurora Serverless v2 ACU quota."""
    return check_service_quota(
        "rds", "L-7B6409FD", 40,
        "Aurora Serverless v2 ACUs (needed for Aurora PostgreSQL)"
    )


# ---------------------------------------------------------------------------
# Run all checks
# ---------------------------------------------------------------------------

def run_all(
    region: str,
    eks_cluster_name: str,
    skip_ecr: bool = False,
) -> PreflightReport:
    """Execute the full pre-flight suite and return a PreflightReport."""
    report = PreflightReport()

    # 1. Credentials
    creds = check_aws_credentials()
    report.add(creds)
    if creds.status == "fail":
        # No point running anything else without credentials
        return report

    # Extract account ID for ECR check
    _, identity_out, _ = _aws(["sts", "get-caller-identity"])
    account_id = json.loads(identity_out).get("Account", "")

    # 2. Region
    report.add(check_aws_region(region))

    # 3. Bedrock model access (always in us-east-1 per deployment hardcoding)
    report.add(check_bedrock_model_access(region="us-east-1"))

    # 4. Service quotas
    for quota_result in check_eks_quotas():
        report.add(quota_result)
    report.add(check_aurora_quota(region))

    # 5. EKS cluster name conflict
    report.add(check_existing_eks_cluster(eks_cluster_name, region))

    # 6. ECR images (Step 1 dependency)
    if not skip_ecr:
        report.add(check_ecr_images(account_id, region, eks_cluster_name))
    else:
        report.add(CheckResult(
            name="ECR Workspace Images",
            status="warn",
            message="ECR image check skipped (--skip-ecr flag set). Ensure Step 1 completed successfully.",
        ))

    return report

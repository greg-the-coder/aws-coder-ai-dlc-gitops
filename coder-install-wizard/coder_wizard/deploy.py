"""
Deploy orchestrator — launches both CloudFormation stacks in the correct order,
streams real-time events back to the caller, and waits for completion.
"""

from __future__ import annotations

import json
import subprocess
import time
from dataclasses import dataclass, field
from typing import Callable, Iterator, Optional


@dataclass
class StackEvent:
    timestamp: str
    logical_id: str
    resource_type: str
    status: str
    reason: str = ""


@dataclass
class DeployResult:
    stack_name: str
    success: bool
    outputs: dict = field(default_factory=dict)
    error: str = ""


def _aws(args: list[str]) -> tuple[int, str, str]:
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


def _cfn_stack_status(stack_name: str, region: str) -> Optional[str]:
    code, data = _aws_json([
        "cloudformation", "describe-stacks",
        "--stack-name", stack_name,
        "--region", region,
    ])
    if code != 0 or data is None:
        return None
    stacks = data.get("Stacks", [])
    return stacks[0].get("StackStatus") if stacks else None


def _cfn_stack_outputs(stack_name: str, region: str) -> dict:
    code, data = _aws_json([
        "cloudformation", "describe-stacks",
        "--stack-name", stack_name,
        "--region", region,
    ])
    if code != 0 or data is None:
        return {}
    stacks = data.get("Stacks", [])
    if not stacks:
        return {}
    return {
        o["OutputKey"]: o["OutputValue"]
        for o in stacks[0].get("Outputs", [])
    }


def _cfn_recent_events(stack_name: str, region: str, since_token: Optional[str]) -> tuple[list[StackEvent], Optional[str]]:
    """Return new events since the last seen NextToken."""
    args = [
        "cloudformation", "describe-stack-events",
        "--stack-name", stack_name,
        "--region", region,
    ]
    code, data = _aws_json(args)
    if code != 0 or data is None:
        return [], since_token

    events_raw = data.get("StackEvents", [])
    new_token = data.get("NextToken")

    seen_events: list[StackEvent] = []
    for e in events_raw:
        ts = e.get("Timestamp", "")
        if since_token and ts <= since_token:
            break
        seen_events.append(StackEvent(
            timestamp=ts,
            logical_id=e.get("LogicalResourceId", ""),
            resource_type=e.get("ResourceType", ""),
            status=e.get("ResourceStatus", ""),
            reason=e.get("ResourceStatusReason", ""),
        ))

    latest_ts = events_raw[0].get("Timestamp") if events_raw else since_token
    return list(reversed(seen_events)), latest_ts


TERMINAL_STATUSES = {
    "CREATE_COMPLETE", "CREATE_FAILED", "ROLLBACK_COMPLETE",
    "ROLLBACK_FAILED", "UPDATE_COMPLETE", "UPDATE_FAILED",
    "DELETE_COMPLETE", "DELETE_FAILED",
}

FAILURE_STATUSES = {
    "CREATE_FAILED", "ROLLBACK_COMPLETE", "ROLLBACK_FAILED",
    "UPDATE_FAILED", "DELETE_FAILED",
}


def deploy_stack(
    stack_name: str,
    template_path: str,
    parameters: dict,
    region: str,
    on_event: Callable[[StackEvent], None] | None = None,
    poll_interval: int = 15,
) -> DeployResult:
    """
    Deploy a CloudFormation stack and stream events until it reaches a terminal state.

    Parameters
    ----------
    stack_name      : CloudFormation stack name
    template_path   : local path to the YAML template
    parameters      : dict of {ParameterKey: ParameterValue}
    region          : AWS region
    on_event        : optional callback called for each new stack event
    poll_interval   : seconds between status polls
    """
    param_list = [
        f"ParameterKey={k},ParameterValue={v}"
        for k, v in parameters.items()
    ]

    create_args = [
        "cloudformation", "create-stack",
        "--stack-name", stack_name,
        "--template-body", f"file://{template_path}",
        "--capabilities", "CAPABILITY_IAM", "CAPABILITY_NAMED_IAM",
        "--region", region,
        "--parameters",
    ] + param_list

    code, _, err = _aws(create_args)
    if code != 0:
        return DeployResult(stack_name=stack_name, success=False, error=err)

    # Poll until terminal state
    last_ts: Optional[str] = None
    while True:
        status = _cfn_stack_status(stack_name, region)

        if on_event:
            new_events, last_ts = _cfn_recent_events(stack_name, region, last_ts)
            for evt in new_events:
                on_event(evt)

        if status in TERMINAL_STATUSES:
            success = status not in FAILURE_STATUSES
            outputs = _cfn_stack_outputs(stack_name, region) if success else {}
            error = "" if success else f"Stack ended in status: {status}"
            return DeployResult(
                stack_name=stack_name,
                success=success,
                outputs=outputs,
                error=error,
            )

        time.sleep(poll_interval)


def wait_for_codebuild(project_name: str, region: str, timeout: int = 3600) -> bool:
    """
    Poll a CodeBuild project until its latest build succeeds or fails.
    Returns True on success, False otherwise.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        code, data = _aws_json([
            "codebuild", "list-builds-for-project",
            "--project-name", project_name,
            "--region", region,
        ])
        if code != 0 or not data:
            time.sleep(30)
            continue

        build_ids = data.get("ids", [])
        if not build_ids:
            time.sleep(30)
            continue

        code2, build_data = _aws_json([
            "codebuild", "batch-get-builds",
            "--ids", build_ids[0],
            "--region", region,
        ])
        if code2 != 0 or not build_data:
            time.sleep(30)
            continue

        builds = build_data.get("builds", [])
        if not builds:
            time.sleep(30)
            continue

        build = builds[0]
        build_status = build.get("buildStatus", "")
        phase = build.get("currentPhase", "")

        if build_status == "SUCCEEDED":
            return True
        if build_status in {"FAILED", "FAULT", "STOPPED", "TIMED_OUT"}:
            return False

        time.sleep(30)

    return False  # timed out

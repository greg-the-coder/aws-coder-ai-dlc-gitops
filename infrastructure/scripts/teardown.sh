#!/usr/bin/env bash
###############################################################################
# teardown.sh - Comprehensive teardown for the AWS Coder AI-DLC workshop.
#
# Deletes, in dependency order, everything the workshop provisions:
#
#   1. Dynamically-created resources the CloudFormation stack does NOT own and
#      that will NOT be removed by `cloudformation delete-stack`:
#        * Coder workspaces (coder-ws namespace) + their EFS access points
#        * The Coder control-plane NLB (created by the LoadBalancer Service)
#        * The EKS cluster and all eksctl-managed CloudFormation stacks
#          (control plane, add-ons, Fargate profile, OIDC provider, Auto Mode
#          nodes, Pod Identity association)
#        * The Bedrock IAM user's inline/managed policies, access keys, and
#          service-specific credentials (bak-<stack>) - any of these left in
#          place blocks CloudFormation from deleting the CFN-managed IAM user
#        * SSM parameters under /eks/<cluster>/
#        * Objects in the stack's S3 buckets (CloudFront/NLB access logs) - CFN
#          cannot delete a non-empty bucket, so they are emptied before delete
#
#   2. Resources the core stack RETAINS on delete (DeletionPolicy: Retain) and
#      whose stack-owned networking would otherwise BLOCK stack deletion:
#        * EFS file system (+ access points + mount targets)
#        * Aurora PostgreSQL cluster + instance
#
#   3. The CloudFormation stacks themselves:
#        * the core Coder stack (VPC, CloudFront, NAT/EIP, KMS, IAM, secrets...)
#        * optionally the image-pipeline stack (+ emptying its ECR repos)
#
# The core stack is deleted LAST, after the EKS cluster, NLB, Aurora and EFS
# are gone, so the VPC / subnets / security groups / DB subnet group it owns can
# be removed cleanly.
#
# Usage:
#   ./teardown.sh --stack <core-stack-name> --region <aws-region> [options]
#
# Options:
#   --stack NAME         Core Coder CloudFormation stack name            (required)
#   --region REGION      AWS region (or set AWS_REGION / AWS_DEFAULT_REGION)
#   --image-stack NAME   Also empty its ECR repos and delete this image stack
#   --purge-secrets      Force-delete Secrets Manager secrets with no recovery window
#   --yes                Skip the interactive confirmation prompt
#   --dry-run            Show what would be deleted without deleting anything
#   -h, --help           Show this help
#
# Requires: aws, eksctl, kubectl, helm, jq
###############################################################################
set -o pipefail

# ----------------------------------------------------------------------------- helpers
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_blu=$'\033[36m'; c_off=$'\033[0m'
log()   { printf '%s[teardown]%s %s\n'  "$c_blu" "$c_off" "$*"; }
ok()    { printf '%s[ ok ]%s %s\n'      "$c_grn" "$c_off" "$*"; }
warn()  { printf '%s[warn]%s %s\n'      "$c_yel" "$c_off" "$*" >&2; }
err()   { printf '%s[fail]%s %s\n'      "$c_red" "$c_off" "$*" >&2; }
phase() { printf '\n%s========== %s ==========%s\n' "$c_blu" "$*" "$c_off"; }

DRY_RUN="false"
# run: execute (or echo, in dry-run) a simple command whose args have no shell
# metacharacters. For pipelines/loops, guard with: [ "$DRY_RUN" = true ] && ...
run() {
  if [ "$DRY_RUN" = "true" ]; then
    printf '  %s[dry-run]%s %s\n' "$c_yel" "$c_off" "$*"
  else
    printf '  + %s\n' "$*"
    "$@"
  fi
}

require_cmd() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { err "required command not found: $c"; missing=1; }
  done
  [ "$missing" -eq 0 ] || exit 1
}

# empty_bucket: remove all objects, versions, and delete markers from an S3 bucket
# so CloudFormation can delete it (CFN cannot delete a non-empty bucket - e.g. the
# CloudFront / NLB access-log buckets accumulate objects over the workshop's life).
empty_bucket() {
  local b="$1"
  aws s3api head-bucket --bucket "$b" >/dev/null 2>&1 || { log "bucket $b not found; skipping."; return 0; }
  if [ "$DRY_RUN" = "true" ]; then printf '  %s[dry-run]%s empty s3://%s\n' "$c_yel" "$c_off" "$b"; return 0; fi
  echo "  emptying s3://$b"
  aws s3 rm "s3://$b" --recursive >/dev/null 2>&1 || true
  # Remove any remaining object versions + delete markers (versioned buckets).
  while :; do
    local batch n
    batch=$(aws s3api list-object-versions --bucket "$b" --max-items 500 \
      --query '{Objects: [Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][]}' \
      --output json 2>/dev/null || echo '{"Objects":[]}')
    n=$(printf '%s' "$batch" | jq '.Objects | length' 2>/dev/null || echo 0)
    [ "${n:-0}" -eq 0 ] && break
    printf '%s' "$batch" | jq '{Objects: .Objects, Quiet: true}' > /tmp/td-empty.json
    aws s3api delete-objects --bucket "$b" --delete file:///tmp/td-empty.json >/dev/null 2>&1 || break
  done
}

# wait_rds: poll an RDS instance/cluster until it is gone, printing a status
# line every 15s. `aws rds wait ...` blocks SILENTLY for many minutes, which
# trips AWS CloudShell's inactivity timeout; the periodic output keeps the
# session alive. $1 = instance|cluster, $2 = identifier, $3 = optional max mins.
wait_rds() {
  local kind="$1" id="$2" max_min="${3:-45}" i=0 status
  local max_iter=$(( max_min * 4 ))
  while :; do
    if [ "$kind" = "instance" ]; then
      status=$(aws rds describe-db-instances --db-instance-identifier "$id" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null) || status=""
    else
      status=$(aws rds describe-db-clusters --db-cluster-identifier "$id" --query 'DBClusters[0].Status' --output text 2>/dev/null) || status=""
    fi
    case "$status" in
      ""|None) ok "RDS $kind '$id' deleted."; return 0;;
    esac
    i=$(( i + 1 ))
    printf '  ... waiting on RDS %s %s: status=%s (~%dm elapsed)\n' "$kind" "$id" "$status" "$(( i / 4 ))"
    if [ "$i" -ge "$max_iter" ]; then
      warn "RDS $kind '$id' still '$status' after ~${max_min}m; continuing (verify in the console)."
      return 1
    fi
    sleep 15
  done
}

# wait_stack_delete: poll a CloudFormation stack until it is gone, printing a
# status line every 15s (the core-stack delete - CloudFront disable+delete - can
# run 20-40 min; `aws cloudformation wait` blocks silently and trips CloudShell's
# inactivity timeout). Returns 0 when deleted, 1 on DELETE_FAILED/timeout.
wait_stack_delete() {
  local stack="$1" max_min="${2:-60}" i=0 status
  local max_iter=$(( max_min * 4 ))
  while :; do
    status=$(aws cloudformation describe-stacks --stack-name "$stack" --query 'Stacks[0].StackStatus' --output text 2>/dev/null) || status="GONE"
    case "$status" in
      GONE|""|DELETE_COMPLETE) return 0;;
      DELETE_FAILED)           return 1;;
    esac
    i=$(( i + 1 ))
    printf '  ... waiting on stack %s: status=%s (~%dm elapsed)\n' "$stack" "$status" "$(( i / 4 ))"
    if [ "$i" -ge "$max_iter" ]; then warn "Stack '$stack' still '$status' after ~${max_min}m; check the console."; return 1; fi
    sleep 15
  done
}

# ----------------------------------------------------------------------------- args
STACK_NAME=""; REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
IMAGE_STACK=""; PURGE_SECRETS="false"; ASSUME_YES="false"
usage() { sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --stack)        STACK_NAME="$2"; shift 2;;
    --region)       REGION="$2"; shift 2;;
    --image-stack)  IMAGE_STACK="$2"; shift 2;;
    --purge-secrets) PURGE_SECRETS="true"; shift;;
    --yes|-y)       ASSUME_YES="true"; shift;;
    --dry-run)      DRY_RUN="true"; shift;;
    -h|--help)      usage 0;;
    *) err "unknown argument: $1"; usage 1;;
  esac
done

[ -n "$STACK_NAME" ] || { err "--stack is required"; usage 1; }
[ -n "$REGION" ]     || { err "--region is required (or set AWS_REGION)"; usage 1; }
require_cmd aws jq eksctl kubectl helm
export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION" AWS_PAGER=""

# ----------------------------------------------------------------------------- discovery
phase "Discovering resources from stack '$STACK_NAME' ($REGION)"

if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  warn "Core stack '$STACK_NAME' not found. It may already be deleted."
  warn "Dynamic/retained resources (EKS, Aurora, EFS, ...) can still be cleaned if you"
  warn "pass the correct --stack name used at deploy time. Aborting to avoid guessing."
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
stack_json=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME")
get_param()  { echo "$stack_json" | jq -r --arg k "$1" '.Stacks[0].Parameters[]? | select(.ParameterKey==$k) | .ParameterValue'; }
get_output() { echo "$stack_json" | jq -r --arg k "$1" '.Stacks[0].Outputs[]?    | select(.OutputKey==$k)    | .OutputValue'; }

CLUSTER_NAME=$(get_param  EKSClusterName)
DB_NAME=$(get_param       DatabaseName)
EFS_ID=$(get_output       EfsFileSystemId)
BEDROCK_USER=$(get_output BedrockApiKeyUserName)
CF_DIST_ID=$(get_output   CloudFrontDistributionId)
ADMIN_SECRET_ARN=$(get_output   CoderAdminPasswordSecretArn)
SESSION_SECRET_ARN=$(get_output CoderSessionTokenSecretArn)
BEDROCK_SECRET_ARN=$(get_output BedrockOpenAIApiKeySecretArn)

: "${CLUSTER_NAME:?could not read EKSClusterName parameter from stack}"
AURORA_CLUSTER_ID="${CLUSTER_NAME}-aurora"
AURORA_INSTANCE_ID="${CLUSTER_NAME}-aurora-instance"
ECR_REPOS=(
  "${CLUSTER_NAME}/coder-workspace-claude-code"
  "${CLUSTER_NAME}/coder-workspace-kiro-cli"
  "${CLUSTER_NAME}/coder-workspace-challenge"
)

cat <<SUMMARY

  Account            : ${ACCOUNT_ID}
  Region             : ${REGION}
  Core stack         : ${STACK_NAME}
  Image stack        : ${IMAGE_STACK:-<not selected>}
  EKS cluster        : ${CLUSTER_NAME}
  Aurora cluster     : ${AURORA_CLUSTER_ID} (instance ${AURORA_INSTANCE_ID})
  EFS file system    : ${EFS_ID:-<none>}
  Bedrock IAM user   : ${BEDROCK_USER:-<none>}
  CloudFront dist    : ${CF_DIST_ID:-<none>}
  Purge secrets      : ${PURGE_SECRETS}
  Dry run            : ${DRY_RUN}

SUMMARY

if [ "$ASSUME_YES" != "true" ] && [ "$DRY_RUN" != "true" ]; then
  printf '%sThis will PERMANENTLY DELETE the resources above, including the Aurora database and EFS data.%s\n' "$c_red" "$c_off"
  read -r -p "Type the cluster name '${CLUSTER_NAME}' to confirm: " reply
  [ "$reply" = "$CLUSTER_NAME" ] || { err "Confirmation did not match. Aborting."; exit 1; }
fi

CLUSTER_EXISTS="false"
aws eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 && CLUSTER_EXISTS="true"

# ============================================================================= 1. k8s apps + NLB
phase "1/8  Kubernetes workloads (Coder workspaces, Helm release, control-plane NLB)"
if [ "$CLUSTER_EXISTS" = "true" ]; then
  if [ "$DRY_RUN" = "true" ]; then
    log "[dry-run] would: update kubeconfig; delete coder-ws workloads; helm uninstall coder; delete namespaces coder/coder-ws; wait for NLB deletion"
  else
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1 || warn "kubeconfig update failed"

    # Delete workspaces first so their pods/PVCs (and per-workspace EFS access
    # points via the CSI driver) are cleaned up before the cluster goes away.
    kubectl delete deployments,statefulsets,pods,pvc --all -n coder-ws --ignore-not-found --timeout=180s 2>/dev/null || warn "coder-ws workload cleanup incomplete"

    # Removing the Coder Helm release deletes the LoadBalancer Service, which
    # tells the in-cluster controller to delete the AWS NLB. This MUST finish
    # before we delete the cluster, or the NLB + its ENIs are orphaned and block
    # VPC (stack) deletion.
    helm uninstall coder -n coder --wait --timeout 5m 2>/dev/null || warn "helm uninstall coder skipped/failed (may already be gone)"

    kubectl delete namespace coder-ws --ignore-not-found --timeout=180s 2>/dev/null || warn "namespace coder-ws delete incomplete"
    kubectl delete namespace coder    --ignore-not-found --timeout=180s 2>/dev/null || warn "namespace coder delete incomplete"

    # Poll until the Coder control-plane NLB is actually deleted.
    log "Waiting for the Coder control-plane NLB to be removed..."
    for i in $(seq 1 30); do
      remaining=""
      for arn in $(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null); do
        [ -n "$arn" ] || continue
        tags=$(aws elbv2 describe-tags --resource-arns "$arn" --query 'TagDescriptions[0].Tags' --output json 2>/dev/null)
        if echo "$tags" | jq -e '.[]? | select(.Key=="kubernetes.io/service-name" and .Value=="coder/coder")' >/dev/null 2>&1 \
           || echo "$tags" | jq -e '.[]? | select(.Key=="Name" and .Value=="coder-cntrlpln-nlb")' >/dev/null 2>&1; then
          remaining="$remaining $arn"
        fi
      done
      [ -z "$remaining" ] && { ok "Coder NLB removed."; break; }
      if [ "$i" -eq 30 ]; then
        warn "NLB still present after timeout; force-deleting:$remaining"
        for arn in $remaining; do aws elbv2 delete-load-balancer --load-balancer-arn "$arn" 2>/dev/null || true; done
        sleep 30
      else
        sleep 10
      fi
    done
  fi
else
  log "EKS cluster '$CLUSTER_NAME' not found; skipping in-cluster cleanup."
fi

# ============================================================================= 2. EKS cluster
phase "2/8  EKS cluster + eksctl stacks (add-ons, Fargate profile, OIDC, Auto Mode nodes)"
if [ "$CLUSTER_EXISTS" = "true" ]; then
  # eksctl removes the cluster control plane, add-ons, Fargate profiles, the
  # OIDC provider, Pod Identity associations and all eksctl-created CloudFormation
  # stacks. The VPC was pre-created by the core stack (referenced by id), so
  # eksctl will NOT delete it.
  run eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --disable-nodegroup-eviction --wait \
    || warn "eksctl delete cluster reported errors; verify in the EKS/CloudFormation console."
else
  log "EKS cluster '$CLUSTER_NAME' not found; skipping."
fi

# ============================================================================= 3. Aurora (RETAINED)
phase "3/8  Aurora PostgreSQL (retained by the stack; must go before stack delete)"

# INSTANCE first - a cluster with member instances cannot be deleted. Probe the
# actual status (not just presence) so a re-run is clean: skip if already gone,
# don't re-issue delete if it's already 'deleting' (that errors with
# InvalidDBInstanceState), and surface any delete error instead of hiding it.
inst_status=$(aws rds describe-db-instances --db-instance-identifier "$AURORA_INSTANCE_ID" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "")
if [ -z "$inst_status" ] || [ "$inst_status" = "None" ]; then
  log "Aurora instance '$AURORA_INSTANCE_ID' not present; skipping."
elif [ "$DRY_RUN" = "true" ]; then
  printf '  %s[dry-run]%s delete-db-instance %s (status=%s)\n' "$c_yel" "$c_off" "$AURORA_INSTANCE_ID" "$inst_status"
else
  if [ "$inst_status" = "deleting" ]; then
    log "Aurora instance '$AURORA_INSTANCE_ID' already deleting; waiting."
  else
    run aws rds delete-db-instance --db-instance-identifier "$AURORA_INSTANCE_ID" --skip-final-snapshot --delete-automated-backups \
      || warn "delete-db-instance returned an error (status was '$inst_status'); waiting for the current state to resolve."
  fi
  wait_rds instance "$AURORA_INSTANCE_ID"
fi

# CLUSTER (only after the instance is fully gone, above).
clu_status=$(aws rds describe-db-clusters --db-cluster-identifier "$AURORA_CLUSTER_ID" --query 'DBClusters[0].Status' --output text 2>/dev/null || echo "")
if [ -z "$clu_status" ] || [ "$clu_status" = "None" ]; then
  log "Aurora cluster '$AURORA_CLUSTER_ID' not present; skipping."
elif [ "$DRY_RUN" = "true" ]; then
  printf '  %s[dry-run]%s delete-db-cluster %s (status=%s)\n' "$c_yel" "$c_off" "$AURORA_CLUSTER_ID" "$clu_status"
else
  if [ "$clu_status" = "deleting" ]; then
    log "Aurora cluster '$AURORA_CLUSTER_ID' already deleting; waiting."
  else
    run aws rds delete-db-cluster --db-cluster-identifier "$AURORA_CLUSTER_ID" --skip-final-snapshot \
      || warn "delete-db-cluster returned an error (status was '$clu_status'); waiting for the current state to resolve."
  fi
  wait_rds cluster "$AURORA_CLUSTER_ID"
  ok "Aurora deleted."
fi

# ============================================================================= 4. EFS (RETAINED)
phase "4/8  EFS file system (retained by the stack; access points + mount targets first)"
if [ -n "$EFS_ID" ] && aws efs describe-file-systems --file-system-id "$EFS_ID" >/dev/null 2>&1; then
  if [ "$DRY_RUN" = "true" ]; then
    log "[dry-run] would delete access points + mount targets, then file system $EFS_ID"
  else
    for ap in $(aws efs describe-access-points --file-system-id "$EFS_ID" --query 'AccessPoints[].AccessPointId' --output text 2>/dev/null); do
      [ -n "$ap" ] && { echo "  + delete access-point $ap"; aws efs delete-access-point --access-point-id "$ap" 2>/dev/null || true; }
    done
    for mt in $(aws efs describe-mount-targets --file-system-id "$EFS_ID" --query 'MountTargets[].MountTargetId' --output text 2>/dev/null); do
      [ -n "$mt" ] && { echo "  + delete mount-target $mt"; aws efs delete-mount-target --mount-target-id "$mt" 2>/dev/null || true; }
    done
    log "Waiting for mount targets to clear..."
    for i in $(seq 1 30); do
      n=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" --query 'length(MountTargets)' --output text 2>/dev/null || echo 0)
      [ "$n" = "0" ] && break
      sleep 10
    done
    aws efs delete-file-system --file-system-id "$EFS_ID" 2>/dev/null && ok "EFS file system deleted." || warn "EFS file system delete failed; retry after mount targets clear."
  fi
else
  log "EFS file system '${EFS_ID:-<none>}' not found; skipping."
fi

# ============================================================================= 5. Bedrock IAM user cleanup
phase "5/8  Bedrock IAM user policies + credentials (unblocks IAM user deletion)"
if [ -n "$BEDROCK_USER" ] && aws iam get-user --user-name "$BEDROCK_USER" >/dev/null 2>&1; then
  if [ "$DRY_RUN" = "true" ]; then
    log "[dry-run] would remove all inline/managed policies, access keys and service-specific credentials from $BEDROCK_USER"
  else
    # Inline policies (incl. any added out-of-band, e.g. BedrockBearerTokenAccess)
    # block CloudFormation from deleting the user ("must delete policies first").
    for pol in $(aws iam list-user-policies --user-name "$BEDROCK_USER" --query 'PolicyNames[]' --output text 2>/dev/null); do
      [ -n "$pol" ] && { echo "  + delete-user-policy $pol"; aws iam delete-user-policy --user-name "$BEDROCK_USER" --policy-name "$pol" 2>/dev/null || true; }
    done
    for arn in $(aws iam list-attached-user-policies --user-name "$BEDROCK_USER" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      [ -n "$arn" ] && { echo "  + detach-user-policy $arn"; aws iam detach-user-policy --user-name "$BEDROCK_USER" --policy-arn "$arn" 2>/dev/null || true; }
    done
    for ak in $(aws iam list-access-keys --user-name "$BEDROCK_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
      [ -n "$ak" ] && { echo "  + delete-access-key $ak"; aws iam delete-access-key --user-name "$BEDROCK_USER" --access-key-id "$ak" 2>/dev/null || true; }
    done
    for cid in $(aws iam list-service-specific-credentials --user-name "$BEDROCK_USER" --query 'ServiceSpecificCredentials[].ServiceSpecificCredentialId' --output text 2>/dev/null); do
      [ -n "$cid" ] && { echo "  + delete-service-specific-credential $cid"; aws iam delete-service-specific-credential --user-name "$BEDROCK_USER" --service-specific-credential-id "$cid" 2>/dev/null || true; }
    done
    ok "Bedrock IAM user policies + credentials cleared (CloudFormation can now delete the user)."
  fi
else
  log "Bedrock IAM user '${BEDROCK_USER:-<none>}' not found; skipping."
fi

# ============================================================================= 6. SSM parameters
phase "6/8  SSM parameters (/eks/${CLUSTER_NAME}/*)"
for p in "/eks/${CLUSTER_NAME}/cloudfront-url" "/eks/${CLUSTER_NAME}/cluster-name" "/eks/${CLUSTER_NAME}/region"; do
  if aws ssm get-parameter --name "$p" >/dev/null 2>&1; then
    run aws ssm delete-parameter --name "$p"
  else
    log "SSM parameter $p not found; skipping."
  fi
done

# ============================================================================= 7. Optional: image stack + ECR
phase "7/8  Image pipeline stack + ECR repositories (optional)"
if [ -n "$IMAGE_STACK" ]; then
  for repo in "${ECR_REPOS[@]}"; do
    if aws ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1; then
      run aws ecr delete-repository --repository-name "$repo" --force
    else
      log "ECR repo $repo not found; skipping."
    fi
  done
  if aws cloudformation describe-stacks --stack-name "$IMAGE_STACK" >/dev/null 2>&1; then
    run aws cloudformation delete-stack --stack-name "$IMAGE_STACK"
    [ "$DRY_RUN" = "true" ] || { log "Waiting for image stack deletion (status printed every 15s)..."; wait_stack_delete "$IMAGE_STACK" || warn "image stack delete did not complete cleanly"; }
  else
    log "Image stack '$IMAGE_STACK' not found; skipping."
  fi
else
  log "No --image-stack given; leaving ECR repositories and image pipeline stack in place."
fi

# ============================================================================= 8. Core stack
phase "8/8  Core CloudFormation stack '$STACK_NAME' (VPC, CloudFront, NAT/EIP, KMS, IAM, secrets)"

# Empty the stack's S3 buckets first (e.g. the CloudFront and NLB access-log
# buckets) - CloudFormation cannot delete a non-empty bucket, which otherwise
# fails the stack delete with "The bucket you tried to delete is not empty".
log "Emptying the stack's S3 buckets..."
for b in $(aws cloudformation describe-stack-resources --stack-name "$STACK_NAME" \
    --query "StackResources[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" --output text 2>/dev/null); do
  [ -n "$b" ] && [ "$b" != "None" ] && empty_bucket "$b"
done

log "CloudFront disable+delete makes this step slow (typically 20-40 minutes)."
run aws cloudformation delete-stack --stack-name "$STACK_NAME"
if [ "$DRY_RUN" != "true" ]; then
  log "Waiting for stack-delete-complete (status printed every 15s)..."
  if wait_stack_delete "$STACK_NAME"; then
    ok "Core stack deleted."
  else
    err "Core stack did not reach DELETE_COMPLETE. Check the CloudFormation console for the"
    err "resource that blocked deletion (commonly a leftover ENI/security group from the NLB"
    err "or EKS). Resolve it and re-run: aws cloudformation delete-stack --stack-name $STACK_NAME"
  fi
fi

# ----------------------------------------------------------------------------- optional secret purge
if [ "$PURGE_SECRETS" = "true" ]; then
  phase "Post: purge Secrets Manager secrets (no recovery window)"
  for arn in "$ADMIN_SECRET_ARN" "$SESSION_SECRET_ARN" "$BEDROCK_SECRET_ARN"; do
    [ -n "$arn" ] && [ "$arn" != "None" ] || continue
    run aws secretsmanager delete-secret --secret-id "$arn" --force-delete-without-recovery
  done
fi

# ----------------------------------------------------------------------------- best-effort log groups
phase "Post: CloudWatch log groups (best effort)"
for lg in "/aws/codebuild/CodeBuild-${STACK_NAME}" "/aws/eks/${CLUSTER_NAME}/cluster"; do
  if aws logs describe-log-groups --log-group-name-prefix "$lg" --query 'logGroups[0]' --output text 2>/dev/null | grep -q .; then
    run aws logs delete-log-group --log-group-name "$lg"
  fi
done

phase "Teardown complete"
cat <<DONE
Verify nothing lingers (a few resources may still be finalizing):
  aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${REGION}    # expect: does not exist
  aws eks describe-cluster --name ${CLUSTER_NAME} --region ${REGION}                  # expect: ResourceNotFound
  aws rds describe-db-clusters --db-cluster-identifier ${AURORA_CLUSTER_ID} --region ${REGION}
  aws efs describe-file-systems --file-system-id ${EFS_ID:-<none>} --region ${REGION}
  aws elbv2 describe-load-balancers --region ${REGION}    # no coder-cntrlpln-nlb

If the core stack failed to delete, it is almost always a leftover ENI/security
group left by the NLB or EKS. Delete it, then re-run delete-stack.
DONE

#!/bin/bash
# irsa-trust-policy-update.sh
# Updates the WorkshopCoderRole trust policy to allow IRSA from coder-ws namespace
#
# Usage: ./irsa-trust-policy-update.sh <cluster-name> <role-name> <namespace> <service-account>
#
set -e

CLUSTER_NAME="$1"
ROLE_NAME="$2"
NAMESPACE="$3"
SERVICE_ACCOUNT="$4"

if [ -z "$CLUSTER_NAME" ] || [ -z "$ROLE_NAME" ] || [ -z "$NAMESPACE" ] || [ -z "$SERVICE_ACCOUNT" ]; then
  echo "Usage: $0 <cluster-name> <role-name> <namespace> <service-account>"
  exit 1
fi

# Get the OIDC issuer URL from the cluster
OIDC_ISSUER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query "cluster.identity.oidc.issuer" --output text)
OIDC_PROVIDER=$(echo "$OIDC_ISSUER" | sed 's|https://||')

# Get the OIDC provider ARN
OIDC_PROVIDER_ARN=$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?ends_with(Arn, '${OIDC_PROVIDER}')].Arn" --output text)

if [ -z "$OIDC_PROVIDER_ARN" ]; then
  echo "ERROR: OIDC provider not found. IRSA will not work."
  exit 1
fi

echo "OIDC Provider ARN: $OIDC_PROVIDER_ARN"

# Get current trust policy
CURRENT_TRUST=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.AssumeRolePolicyDocument' --output json)

# Build the new trust policy statement
SUB_VALUE="system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT}"
AUD_KEY="${OIDC_PROVIDER}:aud"
SUB_KEY="${OIDC_PROVIDER}:sub"

NEW_TRUST=$(echo "$CURRENT_TRUST" | jq \
  --arg oidc_arn "$OIDC_PROVIDER_ARN" \
  --arg aud_key "$AUD_KEY" \
  --arg sub_key "$SUB_KEY" \
  --arg sub_value "$SUB_VALUE" \
  '.Statement += [{
    "Effect": "Allow",
    "Principal": { "Federated": $oidc_arn },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        ($aud_key): "sts.amazonaws.com",
        ($sub_key): $sub_value
      }
    }
  }]')

aws iam update-assume-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-document "$NEW_TRUST"

echo "Updated IAM role '$ROLE_NAME' trust policy for IRSA (${NAMESPACE}/${SERVICE_ACCOUNT})"

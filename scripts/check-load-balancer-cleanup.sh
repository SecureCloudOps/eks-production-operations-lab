#!/usr/bin/env bash
# Read-only gate. Delete Kubernetes entry points while the controller is healthy first.
set -euo pipefail
TF_BIN=${TERRAFORM:-terraform}
TF_DIR=${TERRAFORM_DIR:-terraform}
export AWS_PAGER=""
# Explicit overrides support documented partial-state recovery; never guess IDs.
VPC_ID=${VPC_ID:-$("$TF_BIN" -chdir="$TF_DIR" output -raw vpc_id)}
AWS_REGION=${AWS_REGION:-$("$TF_BIN" -chdir="$TF_DIR" output -raw aws_region)}
CLUSTER_NAME=${CLUSTER_NAME:-$("$TF_BIN" -chdir="$TF_DIR" output -raw cluster_name)}
[[ "$VPC_ID" =~ ^vpc-[0-9a-f]+$ ]] || { echo 'Missing/invalid VPC ID; inspect state and docs/teardown.md.' >&2; exit 1; }
: "${AWS_REGION:?}" "${CLUSTER_NAME:?}"
export AWS_REGION
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Confirm the VPC exists in this identity/region; a wrong target must not look empty.
aws ec2 describe-vpcs --region "$AWS_REGION" --vpc-ids "$VPC_ID" > "$work/vpc.json"
jq -e --arg vpc "$VPC_ID" '.Vpcs | length == 1 and .[0].VpcId == $vpc' "$work/vpc.json" >/dev/null
aws elbv2 describe-load-balancers --region "$AWS_REGION" > "$work/lbs.json"
aws elbv2 describe-target-groups --region "$AWS_REGION" > "$work/tgs.json"
aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER_NAME" > "$work/sgs.json"
aws ec2 describe-network-interfaces --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" 'Name=description,Values=ELB*' > "$work/enis.json"

# All ALBs/NLBs and target groups in this dedicated VPC must be gone, including
# untagged/partially created ones. AWS failures stop this script; they are not absence.
lbs=$(jq -er --arg vpc "$VPC_ID" '[.LoadBalancers[] | select(.VpcId == $vpc)] | length' "$work/lbs.json")
tgs=$(jq -er --arg vpc "$VPC_ID" '[.TargetGroups[] | select(.VpcId == $vpc)] | length' "$work/tgs.json")
sgs=$(jq -er '.SecurityGroups | length' "$work/sgs.json")
enis=$(jq -er '.NetworkInterfaces | length' "$work/enis.json")
if (( lbs + tgs + sgs + enis > 0 )); then
  printf 'STOP: load balancers=%s target groups=%s controller security groups=%s ELB ENIs=%s remain.\n' "$lbs" "$tgs" "$sgs" "$enis" >&2
  echo 'Keep controller, IAM and workers running. Complete docs/teardown.md steps 2–3, then retry.' >&2
  exit 1
fi
printf 'Load balancer cleanup gate passed for the configured lab VPC.\n'

# EKS management access

Private endpoint access is always enabled. `operator_public_access_cidrs = []`
(the default) disables public endpoint access. For an operator outside the VPC,
set an explicit allowlist in `terraform/terraform.tfvars`, for example:

```hcl
# Replace with the actual public egress IPv4 address of your operator/CI runner.
operator_public_access_cidrs = ["203.0.113.10/32"]
```

The example address is documentation-only. A nonempty list enables public access
only for those CIDRs; ranges broader than `/24`, IPv6, and malformed entries are rejected. Prefer `/32`
entries. Include the actual NAT/VPN/proxy egress address used by each Terraform,
Helm, or kubectl runner. Review and apply the Terraform change before expecting
the endpoint settings to take effect.

Run these steps in each new operator shell; profile and kubeconfig variables are
not persistent across sessions. If a working kubeconfig already exists, inspect
its contexts before assuming a file path or alias.

For private-only access, the runner needs VPC connectivity, working endpoint DNS,
and TCP 443 allowed by the cluster security group from its source. This change
adds a TCP 443 security group rule from `operator_cidr`, but does not provision
a VPN, bastion, routing, or DNS connectivity. Set that CIDR to the source seen
at the private API, preferably a runner /32.
Public CIDR rules do not grant access to the private endpoint. A runner resolving
the endpoint to private addresses still needs the private network/security group
path. See [AWS endpoint access documentation](https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html).

## Select the AWS identity before Terraform or Helm

Use AWS CLI v2 and a configured profile for the **same IAM role or user that
created the cluster through Terraform**. This configuration grants that principal
an EKS administrator access entry. For an assumed role, use the same underlying
IAM role; the session name can differ. Another profile/principal needs its own
authorized EKS access entry and policy; creating kubeconfig does not grant access.

Run from the repository root in the same shell used for Terraform and clients:

```sh
# Clear environment credentials that would override the selected profile.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
export AWS_PROFILE='your-terraform-operator-profile'
# For an IAM Identity Center (SSO) profile, authenticate first:
aws sso login --profile "$AWS_PROFILE"
# For a non-SSO profile, skip the login above.
aws sts get-caller-identity --profile "$AWS_PROFILE"
```

Verify the returned account and ARN against the intended cluster creator before
proceeding. Keep this profile selected for Terraform: the AWS provider and Helm's
`aws eks get-token` execution must use the same identity. Credentials must remain
valid throughout the operation. The identity also needs `eks:DescribeCluster`
for kubeconfig creation. See [AWS kubeconfig requirements](https://docs.aws.amazon.com/eks/latest/userguide/create-kubeconfig.html).

Terraform's Helm provider authenticates directly with `aws eks get-token`; it
does not read local kubeconfig. Its runner therefore needs the identity and
endpoint connectivity above **before** applying a configuration that manages
`helm_release.monitoring`. If refresh of an existing Helm release blocks an
endpoint change, run Terraform from an already permitted network path first;
editing the allowlist alone cannot repair connectivity before it is applied.

## Configure kubeconfig before standalone Helm or kubectl

After Terraform has successfully created/updated the cluster and saved outputs:

```sh
export AWS_REGION="$(terraform -chdir=terraform output -raw aws_region)"
EKS_CLUSTER_NAME="$(terraform -chdir=terraform output -raw cluster_name)"
export KUBECONFIG="$HOME/.kube/eks-operations-lab"
mkdir -p "$HOME/.kube"
aws sts get-caller-identity --profile "$AWS_PROFILE"
aws eks update-kubeconfig \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --name "$EKS_CLUSTER_NAME" \
  --kubeconfig "$KUBECONFIG" \
  --alias "$EKS_CLUSTER_NAME"
kubectl config current-context
kubectl auth can-i get nodes
kubectl get nodes
helm list --all-namespaces
```

If initial Terraform execution failed during Helm and outputs were not saved,
set `AWS_REGION` and `EKS_CLUSTER_NAME` manually to the exact `aws_region` and
`cluster_name` inputs, then run the remaining commands once the cluster is active
and its creator access entry is ready. Do not use a different role solely via
`update-kubeconfig --role-arn`: Terraform's Helm provider would still use its
original identity.

Public access exposes the API to the supplied ranges and still requires EKS
authentication/authorization. Broad ranges increase exposure, and changes to
operator egress addresses can interrupt access. Removing all entries restores
private-only access; establish a working private management path before doing so.

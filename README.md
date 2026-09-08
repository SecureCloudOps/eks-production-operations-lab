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
# EKS production operations lab

Terraform lives in `terraform/`. This disposable lab uses Terraform's default
**local state**; no remote backend is configured. Keep one operator and one
authoritative working directory per deployed environment.

## State and repository safety

- Preserve `terraform/terraform.tfstate` and `terraform/terraform.tfstate.backup`.
  If named workspaces were used, preserve `terraform/terraform.tfstate.d/` too
  and record the selected workspace. With a custom state path, preserve that
  path instead. A fresh clone does **not** recover deployed infrastructure.
- Before changes or teardown, and after **every successful, failed, or interrupted
  apply/destroy**, wait for Terraform to exit and copy the latest state, backups,
  and any `errored.tfstate` to access-restricted, encrypted storage outside this
  checkout. Keep dated versions and verify backups can be read. Preserve the exact
  configuration revision, input files, workspace, region and operator identity
  with the recovery record. Store credentials separately using your credential
  manager. Do not overwrite current state with an older backup to retry a failure.
- State and saved plans can contain secrets. `.gitignore` excludes them, real
  tfvars, credentials, caches and `.local/` raw artifacts. Use `*.tfplan` for saved
  plans or put arbitrary filenames under `.local/`. Commit only sanitized evidence
  to `evidence/`; inspect its contents before staging. Keep secrets out of tracked
  YAML and template files too. Never use `git clean -fdx` or delete the working
  directory while infrastructure remains; ignored state is still essential.
- Keep `terraform/.terraform.lock.hcl` in Git: it records provider selections and
  checksums, **not** live state. `terraform -chdir=terraform init` generates it when
  absent. Review and commit it; do not hand-write hashes or use `init -upgrade`
  during recovery. `.terraform/` is a disposable cache, but record the workspace
  before removing it. Provider constraints remain in `providers.tf`.
- `.gitignore` does not untrack previously committed files. In a Git checkout,
  inspect `git ls-files -ci --exclude-standard` and staged changes before pushing.
  If sensitive files are tracked, back them up securely before removing only their
  index entries with `git rm --cached -- <path>`. Rotate exposed credentials and
  arrange history cleanup if necessary; ignoring them does not erase history.

The [Terraform state documentation](https://developer.hashicorp.com/terraform/language/state)
and [dependency lock documentation](https://developer.hashicorp.com/terraform/language/files/dependency-lock)
describe these separate files. A remote backend is not needed for this single
operator workflow; shared operation would require a separate state design review.

## Teardown

Follow [the ordered teardown runbook](docs/teardown.md), including its partial
apply recovery section. `make down` only runs Terraform destroy; it does not
perform Kubernetes, load balancer, Helm prerequisite, or residual AWS cleanup.

## Plan without applying

See [Terraform plan readiness](terraform/PLAN_READINESS.md) for the completed
sample inputs, dependency verification, safe commands, validation results and
remaining account/region checks. No apply is part of that workflow.

## AWS-facing Labs 04 and 05

The Terraform-managed AWS Load Balancer Controller is enabled by default. Use
[the setup guide](docs/load-balancer-controller.md) to verify it (older local inputs may disable it). It supplies Pod Identity,
Helm installation and the `alb` IngressClass. Follow the load balancer cleanup
checks in [teardown](docs/teardown.md) before disabling it or destroying the VPC.

## Repository layout and safe validation

EKS configuration is in `terraform/eks.tf`; VPC, node groups, monitoring,
and optional lab resources remain in their existing Terraform files. The
canonical OOM fixture is `kubernetes/chaos/memory-leak.yaml`, and the HTTP
Ingress manifest is `kubernetes/ingress/http-demo-ingress.yaml`.

Each lab has a directory under `evidence/`: `cluster-upgrade`, `node-drain`,
`oom-triage`, `irsa-breach`, and `ingress-outage`. The lab directories contain capture templates referenced by the runbooks.
Populate them only with reviewed, sanitized observations from a real run.
The pre-lab baseline captures and their verification limits are recorded in
`evidence/baseline/` and `evidence/summary.md`.

`.github/workflows/validate.yml` checks Terraform formatting and validation,
parses YAML, validates Kubernetes schemas with kubeconform, and checks Bash
syntax. It initializes dependencies without a backend and does not run plans
or labs. Preserve `.terraform.lock.hcl` and `terraform.tfvars.sample` in Git;
the real `terraform.tfvars` remains ignored.

## Minimal infrastructure

See [the infrastructure review](docs/infrastructure-review.md) for lab requirements,
capacity decisions and apply/destroy constraints. New-cluster defaults are two AZs,
one NAT gateway, and four workers in three groups: system=1, apps=2, canary=1.
The system group supports controlled upgrades using two CoreDNS replicas, a PDB
and replacement-node surge; it does not provide unexpected-node-failure redundancy.
Prometheus/Grafana stay on the two 8-GiB apps nodes. Alert delivery is disabled.

Existing local tfvars override new defaults. Preserve existing AZs and
`system_node_count = 2` when adopting this configuration for a deployed baseline.
For an existing cluster using this root's customer-managed encryption key, set
`use_customer_managed_kms_key = true`; do not attempt to remove that encryption
association. Newly created clusters use EKS's default AWS-owned encryption.
Recreate saved plans after editing configuration; an old saved plan still contains
the old resource configuration. No apply or lab execution was performed by the review.

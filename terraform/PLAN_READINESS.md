# Safe Terraform plan preparation

Run from the repository root. No apply is part of this workflow. Avoid `make up`
and `make down`, which apply and destroy infrastructure respectively.

1. Select your intended AWS profile and privately verify its account and role.
   Keep AWS CLI v2 and the provider on the same identity (see the root README).
2. Copy `terraform/terraform.tfvars.sample` to `terraform/terraform.tfvars`.
   Replace the documentation-only operator CIDR with your VPN/VPC runner source.
   Confirm region, two or three account-available AZs, unique cluster name, Kubernetes
   version, non-overlapping /16 VPC CIDR, environment, and tags.
   Keep `enable_lab04 = false` and `operator_public_access_cidrs = []` for the
   private baseline. The sample is illustrative, not verified operator settings.
3. Verify the correct state/backend/workspace before planning. This root declares
   no remote backend. Do not plan an existing deployment against empty local state.
4. Run:

   ```sh
   terraform -chdir=terraform fmt -check -recursive
   terraform -chdir=terraform init -backend=false -input=false
   terraform -chdir=terraform validate
   terraform -chdir=terraform plan -input=false
   ```

   `init -backend=false` is for this local-backend preparation; initialize the
   actual backend normally if one is added. No binary plan is saved here. Treat
   any later plan/state/log artifacts as sensitive. Account-specific tfvars,
   state, and plan files are ignored; retain the provider lock file in source control.

## Current preparation notes (2026-09-07)

See [the infrastructure review](../docs/infrastructure-review.md). New defaults
use four nodes, two AZs, the load balancer controller, and AWS-owned encryption.
Local inputs are preserved: reconcile them with the sample before planning.
For a deployed legacy baseline, retain its AZs, `system_node_count = 2`, and
`use_customer_managed_kms_key = true` where applicable. Do not remove an existing
EKS customer-managed encryption association. Worker SSM-latest tracking is now
disabled; use explicit per-group release pins for reproducible upgrade stages.
Existing saved plans predate this review and must be regenerated.

## Historical dependency assumptions checked on 2026-09-06

- Terraform CLI 1.14.3 satisfies root `>= 1.6.0, < 2.0.0`.
- EKS module 21.22.0 was downloaded and inspected. It requires Terraform >= 1.5.7
  and AWS provider >= 6.42. The root pins remain unchanged.
- Init installed AWS 6.63.0 and Helm 3.3.0, plus transitive providers, with
  HashiCorp signatures. `.terraform.lock.hcl` records exact provider selections.
  Module dependencies are not locked by that file; EKS pins KMS module 4.0.0.
- Validation checks Helm 3's object-style `kubernetes` and `exec` configuration
  and the EKS input/output interface against installed dependencies.
- Kubernetes 1.35 remains the default, now configurable. AWS's
  [release calendar](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)
  lists standard support through March 27, 2027. Confirm target-region support
  before every deployment; old versions can incur extended-support charges.
- Monitoring retains kube-prometheus-stack 89.2.2. Its
  [upstream chart metadata](https://raw.githubusercontent.com/prometheus-community/helm-charts/kube-prometheus-stack-89.2.2/charts/kube-prometheus-stack/Chart.yaml)
  is available. Terraform validation does not prove OCI download access or runtime
  compatibility. EKS add-ons use AWS defaults selected for the cluster version
  (`most_recent = false`), not immutable add-on version pins. Bottlerocket images
  are also resolved regionally; verify add-ons and AMIs in the target region.

## Historical operational considerations (five-node configuration)

- STS authentication alone does not establish authorization to plan or deploy.
  Planning needs read/describe permissions for managed resources, EKS add-on
  versions and SSM AMI parameters. Provisioning would additionally need EC2/VPC,
  EKS, IAM role/policy/pass-role, KMS and CloudWatch permissions; Lab 04 adds S3
  and OIDC needs. SCPs, permission boundaries and quotas still apply.
- The cluster creator receives EKS administrator access. Review that principal
  and the KMS administration permissions in a complete plan. A plan cannot prove
  future write permissions, service-linked-role creation, or capacity availability.
- Private API access requires a working routed network path and endpoint DNS.
  The operator CIDR rule supplies only the security group portion. Refreshing
  existing Helm resources also needs connectivity and Kubernetes authorization.
  Combined cluster/Helm initial deployment remains a runtime bootstrap dependency.
- Baseline capacity is five on-demand nodes: three t3.small and two m6i.large,
  each with 34 GiB of EBS, plus an EKS control plane, one NAT Gateway/public IPv4,
  KMS and logs. These incur ongoing charges if later deployed; NAT traffic and
  cross-AZ traffic add usage charges. The single NAT is also an AZ failure point.
  Monitoring data uses ephemeral storage. No cost estimate or capacity guarantee
  is established by static validation.
- AZ names map differently by account; confirm all three standard AZs belong to
  the chosen region and offer the selected instance types. Check subnet/IP,
  instance/vCPU, EIP and NAT quotas and regional Bottlerocket/add-on availability.
- Lab 04 is disabled by default. Its intentional `s3:*` action is limited to the
  synthetic bucket and objects; it still permits destructive fixture/bucket
  administration. The least-privilege mode replaces that grant with public-prefix
  listing/read access. No account-wide bucket enumeration is granted.

## Historical validation results (before the infrastructure review)

Initialization and validation passed with a temporary cache at
`/private/tmp/eks-plan-preflight-20260906` because the workspace restricted module
Git metadata and sandboxed provider sockets. To reuse that cache, export
`TF_DATA_DIR=/private/tmp/eks-plan-preflight-20260906`; otherwise initialize normally
on a runner with registry/GitHub access. No provider/module pins were upgraded.

The first sample plan found six invalid-count errors: module-wide `depends_on`
deferred account/partition lookups needed by managed node group counts. The root
now uses a provisioner-free `terraform_data.cni_bootstrap` dependency for the CNI
role and node subnet inputs. This keeps route/association and IAM policy readiness
without deferring all module data sources. The module's before-compute add-ons
still use its built-in timed bootstrap window; a successful plan does not prove
runtime add-on readiness.

No infrastructure apply, destroy, import or state mutation was performed by this
preparation task.

Final checks: recursive fmt passed; init and validate passed. A read-only plan
using active credentials and `terraform.tfvars.sample` completed with exit code 2
(success with proposed changes): **79 creates, 0 updates, 0 replacements,
0 deletions, 0 imports**, plus 5 deferred data reads. No Lab 04 resource changes
were present. Creates include Terraform bookkeeping resources as well as AWS and
Helm resources. No binary plan or account-specific variable file was saved.
This is an example-input plan against empty local state, not a deployment-ready
plan for a verified operator network or an existing deployment.

Review-sensitive proposed creates include cluster-creator administrative access,
IAM roles/policies, KMS key/policy, network egress, the operator TCP 443 rule, and
billable compute/networking. Public EKS access is disabled in the sample. Regional
AZ/instance capacity, quotas, write permissions, actual operator connectivity and
OCI chart delivery remain unverified. The current folder has no Git metadata,
so no Git diff, commit, or tracked-file baseline was available.

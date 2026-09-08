# AWS Load Balancer Controller for Labs 04 and 05

The existing Terraform root installs chart **1.14.1**, controller
**v2.14.1**, in `kube-system` by default for Labs 01, 04 and 05.
The enable flag remains available; older local tfvars may still disable it. It uses the existing Helm provider, EKS Pod Identity
agent, private VPC subnets and untainted `workload=production-apps` nodes. Two
controller replicas prefer distinct nodes. No ALB/NLB is created until a lab
Service or Ingress requests one.

The chart creates `aws-load-balancer-controller` ServiceAccount, webhook/RBAC/CRDs,
and `alb` IngressClass (`ingress.k8s.aws/alb`). Lab 05 explicitly selects `alb`;
Lab 04 explicitly selects `service.k8s.aws/nlb`. Automatic Service mutation, Global Accelerator and Gateway API controllers are
disabled. The upstream chart bundles their dormant CRDs; no such workloads or
external controllers are installed. Region and VPC are supplied from Terraform, so the controller does not
need node IMDS discovery. The existing EKS module permits control-plane → node
TCP 9443 for the webhook. Pods need egress to EKS Auth via the Pod Identity agent
and regional AWS APIs via the existing NAT path.

## Identity and permissions

`aws_eks_pod_identity_association.load_balancer_controller` binds only this
cluster’s `kube-system/aws-load-balancer-controller` to its dedicated role.
Trust checks the cluster ARN, namespace and ServiceAccount session tags. No
static credentials, node-role ELB permissions or IRSA annotation are needed.
The separate Lab 04 IRSA exercise remains unchanged.

The policy in `terraform/iam/load-balancer-controller.json.tftpl` derives from the
[official v2.14.1 policy](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json),
with these restrictions for the HTTP-only labs:

- Remove Cognito, ACM/server certificates, WAF, Shield and listener certificate
  mutations. WAF/Shield integrations are disabled in the chart values.
- Scope resource ARNs to this account/region and use exact cluster ownership tags
  instead of testing only for tag presence. Register/deregister only owned targets.
- Create security groups only in this VPC; change ingress on the existing node
  security group or controller-owned security groups. The latter also carry the
  cluster ownership tag for deletion and tag updates.
- Preserve necessary global read/describe actions and ELB service-linked-role
  creation, restricted to `elasticloadbalancing.amazonaws.com`. Listener/rule
  permissions retain the upstream action model with regional/account ARN scopes;
  they are not permission to administer arbitrary AWS services.

Do not reuse this role for arbitrary ingress features (TLS/ACM, Cognito, WAF,
Shield, custom/shared target groups or security groups). Those need a separate
permission review. People allowed to create Ingresses/LoadBalancer Services can
request billable/exposed resources through the controller; limit Kubernetes RBAC
accordingly. Runtime IAM/SCP restrictions and resource reconciliation still need
verification in the target account.

## Enable before deploying the lab entry points

Follow README identity, state backup and API-connectivity requirements. Preserve
all existing input values and set this in the authoritative local tfvars:

```hcl
enable_load_balancer_controller = true
```

Check for an existing manual controller release or `alb` IngressClass first. Do
not install a second controller or overwrite another Helm owner. Resolve ownership
with a reviewed migration; do not uninstall a controller serving existing LBs.

```sh
helm list -n kube-system --all
kubectl get ingressclass
terraform -chdir=terraform init -input=false -lockfile=readonly
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
terraform -chdir=terraform plan -out=load-balancer-controller.tfplan
terraform -chdir=terraform show load-balancer-controller.tfplan
```

Only during a separately authorized deployment, apply that reviewed saved plan.
Expect a role, inline policy, Pod Identity association and Helm release; reject
unrelated infrastructure or Kubernetes-version changes. This preparation task
runs no apply. Readiness checks after installation are:

```sh
terraform -chdir=terraform output load_balancer_controller
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=5m
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller -o wide
kubectl -n kube-system get serviceaccount aws-load-balancer-controller -o yaml
kubectl get ingressclass alb -o yaml
kubectl get crd targetgroupbindings.elbv2.k8s.aws
kubectl -n kube-system logs deployment/aws-load-balancer-controller --since=5m
aws eks list-pod-identity-associations --cluster-name "$(terraform -chdir=terraform output -raw cluster_name)"
```

Confirm healthy replicas, `alb.spec.controller=ingress.k8s.aws/alb`, the correct
association, and no credential/webhook errors. Helm readiness alone does not prove
AWS write permissions: confirm reconciliation and target health when executing
Lab 04’s NLB Service or Lab 05’s ALB Ingress.

## Local validation without installation

```sh
CHECK_DIR=$(mktemp -d)
helm pull aws-load-balancer-controller --repo https://aws.github.io/eks-charts \
  --version 1.14.1 --untar --untardir "$CHECK_DIR" \
  --repository-config "$CHECK_DIR/repositories.yaml" --repository-cache "$CHECK_DIR/cache"
helm lint "$CHECK_DIR/aws-load-balancer-controller" \
  -f terraform/load-balancer-controller-values.yaml \
  --set clusterName=validation-only,region=us-east-1,vpcId=vpc-00000000000000000
helm template aws-load-balancer-controller "$CHECK_DIR/aws-load-balancer-controller" \
  --namespace kube-system --include-crds \
  -f terraform/load-balancer-controller-values.yaml \
  --set clusterName=validation-only,region=us-east-1,vpcId=vpc-00000000000000000 \
  > "$CHECK_DIR/rendered.yaml"
```

These dummy values are render-only. Inspect the Deployment arguments, Pod Identity
ServiceAccount, webhook, RBAC and IngressClass. Terraform/Helm validation does not
prove pod scheduling, image pull, endpoint connectivity, IAM propagation or AWS
reconciliation. Before a future chart upgrade, review matching controller IAM and
CRDs: Helm installs CRDs initially but does not upgrade/delete them automatically.
Atomic Helm rollback cannot undo CRD or controller-created AWS resource changes.

Local preparation validation (2026-09-07): Terraform formatting/validation and
Helm lint/template passed. Eleven rendered standard Kubernetes objects passed
strict Kubernetes 1.35 schema validation. Six upstream CRDs were rendered but
skipped by the schema validator because its catalog lacks the CRD schema; no
API-server/CRD admission test was run. A bounded local test of the teardown gate
passed for empty inventory and rejected each remaining LB/target-group/security-
group/ENI case and AWS errors using mocks. No AWS plan, installation or apply was run.

## Teardown

Follow [the full teardown](teardown.md) in order: delete the exact Lab 04 Service
and Lab 05 Ingress while the controller, workers and IAM remain available; wait
for their LBs, target groups, security groups and ENIs to disappear; run
`scripts/check-load-balancer-cleanup.sh`; only then destroy Terraform. `make down`
runs that read-only gate and stops if resources remain or AWS checks fail.
Direct Terraform destroy/flag-disable commands cannot discover Kubernetes-owned
AWS resources: the gate and runbook are mandatory prerequisites. Do not remove
finalizers, the controller, or its IAM to work around a stuck deletion.

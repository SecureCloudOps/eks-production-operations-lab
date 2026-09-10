# Full environment teardown

Run from the repository root. This procedure deletes the disposable environment.
For cleanup of just one exercise, use that lab's cleanup section instead.
Stop on a failed command and resolve it before advancing. An absent object is
safe to skip only after checking the correct environment; a permission error or
timeout is not proof of absence. These steps also apply after partial creation.

## 1. Preserve state and verify the target

Stop concurrent applies and deployment automation. Follow the [state backup
requirements](../README.md#state-and-repository-safety) before doing anything
destructive. Keep the same Terraform root, workspace, input values and AWS identity
used for creation, including `enable_lab04`, `enable_load_balancer_controller`, and any custom `-var-file` arguments.
Do not switch off lab flags or run a normal apply as part of full teardown.

```sh
terraform -chdir=terraform workspace show
terraform -chdir=terraform state list
kubectl config current-context
kubectl get nodes
kubectl get ingress,service -A
# Helm 4 includes all statuses by default; Helm 3 requires --all.
case "$(helm version --short)" in
  v3.*) helm list -A --all ;;
  v4.*) helm list -A ;;
  *) echo 'Review list flags for this Helm version before continuing.'; exit 1 ;;
esac
kubectl get pvc -A
kubectl get pv
```

Confirm the AWS profile/account privately (for example with `aws sts
get-caller-identity`), region, cluster name and Kubernetes context all refer to the
intended lab. Record VPC ID, cluster name, load balancer ARNs, target group ARNs,
security group IDs, volume IDs, NAT/EIP IDs and any Lab 04 bucket/trail in a private
inventory. Include manual resources absent from Terraform state. Record AWS
ownership tags such as `Project`, `Environment`, `elbv2.k8s.aws/cluster` and
`kubernetes.io/cluster/<cluster-name>`; tags alone are not an exhaustive inventory.

Maintain routing, TCP 443 security group access and IAM access to the **private
EKS endpoint** through Helm cleanup. Keep workers, CNI, DNS and AWS Load Balancer
Controller running until their cleanup work finishes. Uncordon only nodes cordoned
by Lab 02 if necessary to restore these controllers. Preserve wanted monitoring
data and sanitized evidence now; baseline monitoring uses ephemeral storage.

## 2. Remove Kubernetes lab entry points

Delete the known AWS-facing objects first, before their namespaces or controller:

```sh
kubectl -n default delete ingress lab01-http-demo --ignore-not-found --wait=true --timeout=10m
kubectl -n lab05 delete ingress web --ignore-not-found --wait=true --timeout=10m
kubectl -n lab04 delete service public-web --ignore-not-found --wait=true --timeout=10m
```

Inventory all namespaces and remove any other lab-owned Ingresses and
`LoadBalancer` Services by exact name, including those created by optional charts
or application manifests. Do not delete shared resources. Keep namespaces intact
until step 3 confirms AWS cleanup.

## 3. Wait for AWS cleanup, then remove remaining lab resources

Keep the lab namespaces intact while checking. Terraform does not own the
Lab 04 NLB or Lab 05 ALB.
Kubernetes deletion alone is insufficient evidence of AWS cleanup, as explained
in [AWS's EKS deletion guide](https://docs.aws.amazon.com/eks/latest/userguide/delete-cluster.html).

For each recorded ALB/NLB ARN, use `aws elbv2 wait load-balancers-deleted
--load-balancer-arns <recorded-arn> --region <region>`. Verify target groups and
controller-created security groups are also gone with ELBv2/EC2 describe calls.
Check Classic ELB too if any legacy controller was used. Shared target groups or
security groups require explicit ownership review instead of blanket deletion.

If deletion stalls, inspect Ingress/Service events, finalizers, controller logs,
IAM permissions, deletion protection, and AWS dependency errors. Restore the
controller's ability to reconcile. Do not force-delete namespaces or strip
finalizers to make Kubernetes look clean: that can orphan AWS resources. Wait
for associated ENIs to be released. Keep controller IAM roles until reconciliation
finishes.

Run the read-only cleanup gate before removing the controller or planning destroy:

```sh
bash scripts/check-load-balancer-cleanup.sh
```

It checks ALBs/NLBs and target groups in the recorded VPC, controller-tagged
security groups, and ELB ENIs. A nonzero result or AWS/API error blocks teardown;
wait for asynchronous deletion or restore reconciliation and retry. The gate also
requires that VPC to exist in the selected identity/region. If the VPC is already
gone after partial destruction, use the missing-cluster/partial-apply recovery
section below and verify the inventory manually before destroying residual state. If outputs
were never saved after a partial apply, inspect state/AWS first, then supply the
verified `VPC_ID`, `AWS_REGION`, and `CLUSTER_NAME` environment variables. Do not
invent values or use an empty-state plan to bypass this gate. Record the same
inventory for any manually created, untagged or legacy resources.

Then remove lab workloads and policies:

```sh
kubectl -n kube-system delete pod lab05-probe --ignore-not-found --wait=true --timeout=2m
kubectl delete namespace lab02 lab03 lab04 lab05 --ignore-not-found --wait=true --timeout=10m
```

Also remove resources actually deployed from `kubernetes/apps`, custom Lab 01
manifests and diagnostic sessions outside those namespaces. Those paths may be
empty or absent; do not assume a scaffold created resources. Namespace deletion
removes the known lab PDBs, policies, workloads and ServiceAccounts. Check any
added PVCs/PVs: retain/export wanted data, delete lab claims while storage
controllers still run, and track retained volumes/snapshots for step 6.

## 4. Remove manual Helm resources and prepare Terraform-owned Helm cleanup

Use the version-aware Helm inventory in step 1 to include failed and pending releases. Uninstall only
manually installed lab releases using their recorded name/namespace:

```sh
helm uninstall <release> --namespace <namespace> --wait --timeout 10m
```

Remove dependent custom resources before the operators that reconcile them.
If a controller was manually installed before this Terraform setup, uninstall
that manual release only after step 3 and all chart-created entry points have
finished cleanup. Do not uninstall the Terraform-owned controller manually. Keep any
storage controller until its volume cleanup finishes. Inspect retained CRDs,
custom resources, namespaces, PVCs and resources marked with Helm keep policies;
uninstall does not guarantee these are deleted. Delete only lab-owned remnants
with no remaining consumers while the Kubernetes API is still reachable.

**Leave `helm_release.monitoring` (`monitoring/kube-prometheus-stack`) and
`helm_release.load_balancer_controller[0]` (`kube-system/aws-load-balancer-controller`)
under Terraform ownership.** After AWS cleanup passes, full destroy removes these
releases before `module.eks`; controller IAM and Pod Identity also remain through
Helm removal. Keep the controller enabled until that destroy. Turning its flag off
earlier would strand reconciliation and is not a load balancer cleanup procedure. Do not routinely uninstall it with Helm or
remove it from state. Helm needs working endpoint access, credentials and nodes
for deletion hooks. If it fails, restore those prerequisites and retry from fresh
state. If a failed apply left a release that is genuinely absent from state,
inventory it and uninstall that orphan manually before step 5.

For Lab 04, inspect the fixture bucket for extra test objects. Terraform deletes
its two tracked objects, but the bucket has `force_destroy = false`. Remove only
confirmed unwanted, untracked test objects, including object versions/delete
markers if versioning was enabled; respect retention/Object Lock. Do not change
`force_destroy` to bypass this check. Handle the separate manual CloudTrail trail
and log bucket according to the evidence retention decision; record any retained
resources and continuing charges.

## 5. Review and execute Terraform destroy

With the original inputs loaded and a fresh state backup, run:

```sh
bash scripts/check-load-balancer-cleanup.sh
terraform -chdir=terraform plan -destroy -out=teardown.tfplan
terraform -chdir=terraform show teardown.tfplan
# Execute only after reviewing the saved plan; this command has no new prompt.
terraform -chdir=terraform apply teardown.tfplan
```

Append the same custom `-var-file` options used during creation to the **plan**
command, if applicable. Review locally because plans may expose sensitive data.
The plan must target only this environment. Expect controller and monitoring release removal
before EKS, then Terraform's dependency-ordered deletion of node groups, add-ons,
cluster and its IAM/KMS/logging resources, and VPC networking including NAT/EIP.
Let Terraform determine the detailed dependency order; do not delete EKS or its
network manually first. The [destroy planning mode](https://developer.hashicorp.com/terraform/cli/commands/plan#planning-modes)
supports this reviewable saved-plan workflow.

Alternatively, `terraform -chdir=terraform destroy` (or `make down` with default
inputs) creates an interactive destroy plan. `make down` runs the same read-only cleanup gate first; direct Terraform commands
do not run it automatically. Neither workflow executes the saved plan above. Use one workflow, not both. After failure or interruption, preserve the
updated state and make a **new** destroy plan; do not reuse a stale saved plan.
Do not run a normal apply between cleanup attempts, since it may recreate the
monitoring release or infrastructure already removed.

## 6. Verify residual AWS resources and archive the recovery record

Check `terraform -chdir=terraform state list`: no managed resources should remain.
An empty state is not proof that AWS is empty. Using the recorded IDs, correct
account/region, AWS console or service-specific list/describe APIs, check:

| Service | Expected cleanup / explicit retention record |
| --- | --- |
| EKS / EC2 / Auto Scaling | Cluster, node groups, instances, scaling groups and launch templates deleted |
| ELBv2 / Classic ELB | Lab load balancers, listeners and target groups deleted |
| EC2 networking | Lab ENIs, security groups, NAT gateways, EIPs, subnets, routes, internet gateway and VPC deleted/released |
| EBS | Lab volumes deleted; snapshots or retained PV backing volumes explicitly reviewed |
| IAM | Lab roles, inline/attached policies, instance profiles, Pod Identity associations and optional OIDC provider removed; shared identities preserved |
| S3 / CloudTrail | Fixture bucket gone; manual trail/data-event logging stopped or intentionally retained; log bucket and its contents accounted for |
| CloudWatch / KMS | Lab log groups removed or retained intentionally; optional customer-managed KMS keys pending scheduled deletion until their waiting period expires |
| Manual extras | Any lab DNS records, alarms, VPN/access infrastructure or other prerequisites outside this root accounted for |

Use service-specific inventories as well as tag searches; untagged and partially
created resources can be missed by tag filters. Tag results can also include terminated
instances, deleted NAT gateways or stale references. Resolve each match by its
recorded ID through the owning service API. Record confirmed terminal states or
explicit not-found responses; permission errors and timeouts remain unresolved. Check VPC dependencies before
manually deleting an orphan. Do not detach/delete requester-managed ENIs directly;
remove the owning service and wait. Review cost reporting later for residual
charges, allowing for billing delay. Pending deletion and retained resources
remain open follow-up items, not completed deletion.

Keep final state and dated backups encrypted until deletion/retention checks are
complete, then dispose of sensitive artifacts under your retention policy.
Remove obsolete local saved plans securely; preserve the Git-tracked provider
lock file. Store only a sanitized teardown summary in `evidence/`.

## Failed or partial apply / missing cluster recovery

- A failed apply can create billable resources and write useful state. Back up the
  **latest** state, backups and any recovery state before retrying. An unexpected
  empty state or zero-change destroy is a reason to inspect the original directory,
  workspace and backups, not evidence that creation did nothing.
- If EKS was never created, confirm that through AWS and state, skip unreachable
  Kubernetes/Helm steps only after checking whether their resources ever existed,
  then destroy recorded AWS resources. Do not finish an apply just to tear down.
- If EKS exists but is unreachable, repair runner routing/security group/IAM access
  to its private API and controller health. Do not remove state entries to bypass
  a transient provider or authentication error.
- If EKS was deleted outside Terraform, Kubernetes finalizers cannot clean up AWS.
  Inventory and remove confirmed orphan load balancers and dependencies through
  AWS, retaining evidence. If a stale Helm state entry blocks destroy, first verify
  the cluster/release is permanently gone. Back up state and obtain a separately
  reviewed state-reconciliation procedure for the exact address. Do not blindly
  use `state rm`, disable refresh, or edit JSON to make destroy pass.
- If state is lost, stop and restore the newest verified backup for this exact
  environment. If no usable backup exists, inventory AWS and decide ownership
  before a separately reviewed import/recovery or manual deletion. A fresh init
  cannot discover everything an earlier apply created. Include objects created
  just before an error that never made it into state.
- Preserve any state-write error's recovery file and follow Terraform's recovery
  instructions only after reconciling which snapshot is authoritative. Never
  overwrite a newer snapshot with a stale one or disable locking to get past a
  concurrent operation. Retry failed destroy from current state after fixing the
  reported dependency; reserve targeting/state mutation for reviewed recovery.

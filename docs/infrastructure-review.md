# Infrastructure review — 2026-09-07

Historical preparation review, retained for design rationale. Statements about
missing state or unexecuted operations describe this review date; see the later
[execution evidence](../evidence/README.md) for deployed observations and results.

Scope: all root Terraform files and the controller IAM template, Kubernetes
manifests, five lab guides, Makefile, scripts, and supporting documentation.
This is a configuration review, not an inventory of deployed AWS resources.
No local Terraform state file was found. Private inputs, the provider lockfile,
and the existing saved plan were preserved. No live AWS plan, apply, destroy,
or lab execution was performed.

## Required infrastructure

- One IPv4 VPC in two AZs, with one private and one public subnet per AZ,
  an internet gateway, and one shared NAT gateway/public IP.
- One EKS cluster with private endpoint enabled. An external operator needs
  either existing private routing/DNS or explicit, narrow public API access.
- Three independently versioned Bottlerocket managed node groups: two apps
  nodes, one system node, and one canary node for these controlled exercises.
- VPC CNI with native NetworkPolicy, CoreDNS, kube-proxy and Pod Identity agent.
- AWS Load Balancer Controller with its dedicated Pod Identity role.
- Prometheus, Grafana, Prometheus Operator, kube-state-metrics and node-exporter.
- CloudWatch control-plane logs; existing 30-day retention is retained.
- Only for Lab 04: OIDC/IRSA, a synthetic S3 bucket and two objects, and a
  dedicated regional CloudTrail trail delivering to a separate private log bucket.

Private nodes need outbound access to public image registries and AWS APIs.
Removing NAT would break those paths in this design. AWS-only VPC endpoints do
not supply Docker Hub/GHCR access; adding endpoint fleets or an image mirror is
outside this lab's needs. The shared NAT is a deliberate cost/availability
tradeoff. See [AWS private-cluster requirements](https://docs.aws.amazon.com/eks/latest/userguide/private-clusters.html).

## Existing configuration and confirmed findings

Before this review, the root described one VPC across three AZs, six subnets,
one NAT, one EKS cluster, three groups/five EC2 workers (system 2 x t3.small,
apps 2 x m6i.large, canary 1 x t3.small), a customer-managed KMS key, four EKS
add-ons, control-plane logging and monitoring including Alertmanager. The
controller and Lab 04 Terraform fixtures were disabled by default.

| Severity | Finding and evidence | Effect and resolution |
| --- | --- | --- |
| High, operational | `node_groups.tf` omitted `use_latest_ami_release_version`; installed EKS module 21.22.0 defaults it to true. | SSM release changes can roll unrelated groups and invalidate Lab 01's staged measurement. Explicitly disabled latest tracking; added optional per-group release pins. Mock checks verify all three groups retain this setting. |
| Medium | `variables.tf` allowed a node minor newer than its control plane. | AWS would reject the update; the lab order was only documented. Added a blocking precondition for equal or one-minor-behind workers. Mock checks accept control-plane-first and reject worker-first. |
| Medium | Public API CIDR validation accepted `/1` through `/32`. | An operator could expose the API to half the IPv4 space despite the narrow-access intent. It now requires `/24` or narrower, with `/32` recommended. Mock validation rejects `/1`. Authentication is still required. |
| Medium, prerequisite | The sample disabled the controller although Labs 01, 04 and 05 use its external routes. | Unmodified inputs would leave Services/Ingresses unreconciled. New defaults enable it. Existing local tfvars still override defaults and must be reviewed. |
| Low, cost | Three AZs and a second dedicated system worker were mandatory. | No AZ-failure exercise requires them. Two AZs and one system worker now suffice for controlled maintenance; the two-node system option and three-AZ support remain. |
| Low, cost | A customer-managed KMS key and Alertmanager were always enabled. | None of the labs exercises customer key management or alert delivery. New clusters use EKS AWS-owned encryption; Alertmanager is disabled. Existing customer-key clusters must retain the key option. |
| Low, teardown | The full teardown's explicit entry-point list omitted the Lab 01 Ingress. | A leftover ALB would block the VPC-wide cleanup gate. Added its exact deletion command while the controller remains alive. |

EKS 1.28+ supplies default envelope encryption for Kubernetes API data. The new
setting removes the need for a customer-managed key in a fresh lab, not encryption.
Existing encryption associations must not be removed through this change.
See [AWS encryption behavior](https://docs.aws.amazon.com/eks/latest/userguide/envelope-encryption.html).

## Node count and scheduling decisions

Four steady-state workers preserve all three Lab 01 rollout stages and Lab 03's
explicit canary selector/toleration. The canary earns its place as a bootstrap
upgrade gate and isolated OOM target. It is not a representative application
canary: the runbook correctly limits that claim. Removing it would leave the OOM
pod Pending and require rewriting two labs.

The two apps workers remain m6i.large (2 vCPU / 8 GiB each). They host the HTTP
replicas, monitoring, both controller replicas and the small lab workloads.
Their memory headroom accommodates pod rescheduling and Prometheus's 2-GiB limit;
reducing them to 2-GiB system-sized workers would risk an unrelated monitoring
failure. CPU/memory utilization has not been measured, so a smaller RAM baseline
or CPU-credit dependency is not justified by static evidence alone.

One t3.small system worker runs two CoreDNS replicas plus baseline DaemonSets.
The explicit CoreDNS PDB allows one unavailable replica, and DEFAULT managed
updates launch replacement workers before eviction. This can preserve DNS during
controlled maintenance; it does not preserve DNS through an unexpected failure
of the sole system node. Keep `system_node_count = 2` when that redundancy is
required. Do not use MINIMAL updates or force eviction. See
[CoreDNS replica/PDB behavior](https://docs.aws.amazon.com/eks/latest/userguide/managing-coredns.html).

Managed update surge is additional to steady state. Two AZs can require up to
four extra workers for the group being updated; three AZs can require six.
`max_size` is not an upgrade cost ceiling. Retain quota/subnet headroom and
one-group-at-a-time operation. See [AWS update phases](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-update-behavior.html).

## Lab dependencies and what remains intentionally conditional

| Lab | Required path and reviewed disposition |
| --- | --- |
| 01: upgrade | Cluster 1.35 -> 1.36, independent worker versions, canary/apps/system stages, two HTTP replicas and PDB, external ALB probe, monitoring. Latest AMI tracking is fixed. `addon_versions` supports explicit regional release choices before measurement. |
| 02: drain/PDB | Two untainted apps workers and spare pod capacity. The runbook deliberately drains only the selected fixture; it does not evacuate monitoring or prove full-node maintenance readiness. Retained. |
| 03: OOM | One tainted canary, bounded 128-MiB allocator, cAdvisor and kube-state-metrics. Selectors/tolerations and exporter coverage match. Retained. |
| 04: IRSA | Enable `enable_lab04`, annotate the ServiceAccount before starting pods, and create the dedicated trail/log bucket using section 2 of the runbook. The fixture IAM policy intentionally remains bucket-scoped `s3:*` until remediation. |
| 05: ingress/network | Controller, ALB, IP targets and VPC CNI NetworkPolicy in standard mode. The port mismatch and narrow policy are intentional faults. Keep the native enforcement preflight and healthy-port gate. |

There is no missing CloudTrail implementation: Lab 04 already creates and cleans
up a dedicated regional trail and log bucket with the AWS CLI. Moving ownership
to Terraform would duplicate/conflict with that workflow. The baseline therefore
has no trail; all five labs require following Lab 04's audit setup before object
requests. CloudTrail Event history is not a substitute for S3 data events.
See [AWS S3 event logging](https://docs.aws.amazon.com/AmazonS3/latest/userguide/cloudtrail-logging-s3-info.html).

CNI settings and Linux Bottlerocket workers support the intended NetworkPolicy
path. Actual regional add-on compatibility and kernel/agent enforcement must
still pass the existing lab preflight. Missing schema fields or a failed
allow/deny/allow check blocks Lab 05, not a reason to add another CNI. See
[AWS native policy setup](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy-configure.html).

Controller IAM remains scoped to account/region, cluster ownership tags and the
node/controller security groups, with service-linked-role creation restricted
to ELB. Read/describe wildcards are retained where needed. No missing action was
identified for the pinned chart's HTTP ALB/NLB paths. This static review does not
prove effective permissions under an account's SCPs or permission boundaries.
IRSA trust pins this cluster's issuer, audience and `lab04/public-web`; controller
and CNI credentials use separate Pod Identity roles. IMDSv2/hop limit 1 and
absence of CNI permissions on node roles remain intact. SSM access remains for
Bottlerocket node diagnostics; it adds no dedicated compute component.

## Apply/destroy constraints

- The sample private-only endpoint cannot be reached from an arbitrary laptop.
  Configure existing private connectivity or an actual public egress allowlist
  before applying Helm resources. Keep that path and the same EKS-authorized
  identity available through uninstall. A security-group rule creates no route.
  See [EKS endpoint access](https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html).
- EKS and Helm share one root. Resource dependencies put Helm after the cluster,
  workers and access setup, and before their destruction. They do not prove
  runtime bootstrap, IAM propagation, chart download or endpoint access.
- Never adopt new AZ, capacity or encryption defaults blindly on deployed state.
  Retain existing AZs, `system_node_count = 2`, and
  `use_customer_managed_kms_key = true` as applicable. ASG scale-down is not a
  PDB-protected managed upgrade. No live scale-down was performed here.
- The existing saved plan predates these changes. Generate and review a fresh
  plan; do not apply the old 79-addition artifact.
- Delete all controller-created ALB/NLB resources while the controller and IAM
  are running. `make down` runs the existing AWS inventory gate; direct Terraform
  destroy or disabling the controller flag bypasses it. Terraform dependencies
  cannot discover Kubernetes-owned load balancers.
- Lab 04's fixture bucket has `force_destroy = false`. Extra synthetic test
  objects must be removed deliberately. The manual trail/log bucket require
  their separate cleanup and evidence-retention steps.
- Single-replica Prometheus uses emptyDir; a worker replacement loses history.
  Lab 01's local continuous export preserves collected observations and records
  gaps. Lab 03 must export before monitoring restarts. No HA/durable monitoring
  or additional CSI/storage component is claimed or required by these runbooks.

## Expected footprint with new-cluster defaults

| Component | Expected quantity |
| --- | --- |
| VPC / AZs / subnets | 1 / 2 / 2 public + 2 private |
| Internet gateway / NAT gateway / NAT public IP | 1 / 1 / 1 |
| EKS clusters / managed groups | 1 / 3 |
| Steady EC2 workers | 4: system 1 x t3.small, canary 1 x t3.small, apps 2 x m6i.large |
| Worker storage | 8 encrypted gp3 volumes, 136 GiB total before upgrade surge |
| Baseline load balancers | 0; installing the controller creates none |
| Lab load balancers | Lab 01: 1 ALB; Lab 04: 1 NLB; Lab 05: 1 ALB. Run sequentially and clean up for at most 1 active; 3 if all routes are retained. |
| S3 / CloudTrail | Baseline 0 / 0; Lab 04 2 buckets total, 2 Terraform fixture objects, 1 dedicated regional trail plus its delivered logs |
| Workload identity | CNI and controller Pod Identity; one additional OIDC provider/IRSA role only with Lab 04 |
| Monitoring | 1 Prometheus, 1 Grafana, 1 operator, 1 kube-state-metrics, node-exporter on every worker; 0 Alertmanager |
| CloudWatch / customer KMS | 1 EKS control-plane log group / 0 new customer keys by default |

Current private tfvars were not changed; explicit legacy overrides take precedence
over the new defaults. These are expected configuration counts, not observed AWS
inventory or a fresh plan's resource-address count.

## Validation

- Terraform recursive format check and validate: passed with installed locked providers.
- Five offline, mock-only Terraform plan tests: passed (four-node layout,
  control-plane-first staging, newer-worker rejection, broad-CIDR rejection,
  and optional Lab 04/legacy capacity). EKS was overridden in these tests;
  they do not simulate EKS service behavior. No AWS plan or apply was run.
- Both existing Helm charts linted successfully; target 1.36 lint also passed.
- Repository YAML parsed; all 19 resources in seven manifests passed strict
  Kubernetes 1.35 schema validation, with none skipped.
- 71 rendered standard Kubernetes objects passed strict schema validation.
  39 monitoring custom resources rendered successfully but did not receive
  API-server/CRD admission validation. Rendered placement matches apps labels;
  node-exporter tolerates system/canary taints; Alertmanager is absent.
- Controller IAM template parsed using synthetic identifiers: 6,949 compact
  characters, below the role inline-policy size limit. No IAM simulator or
  live reconciliation test was performed.
- Shell syntax and all Makefile target dry-runs passed. No target was executed.
- No evidence file was populated. Provider/module pins and private inputs were
  preserved. No Git metadata exists here, so no tracked-file diff is available.

**INFRA READY** for a fresh reviewed plan, subject to the existing operator-input,
identity and state checks. This is static readiness, not a successful deployment
or completed lab. The largest safe saving remains deleting the disposable
cluster, NAT and lab load balancers between sessions after exporting evidence;
pausing pods alone does not stop those charges.

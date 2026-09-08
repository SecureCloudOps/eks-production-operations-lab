# Lab 01 remediation — controlled drain with ALB readiness gates

**Controlled-drain validation passed: 4,030 HTTP requests, zero observed failures.** This separate test followed the [original upgrade run](../summary.md), which recorded nine HTTP 502s. The original failed availability verdict remains unchanged.

## Scope and changes

Run `20260908T210043Z`, 8 September 2026, on Kubernetes 1.36. ALB target-health readiness-gate injection was enabled in the default namespace, and HTTP pods were recreated after the IP TargetGroupBinding existed. Both replicas had healthy target gates and were placed on separate apps nodes before the drain.

Apps capacity temporarily increased from two to three nodes, providing a spare destination. One apps node was drained through normal eviction with PDB enforcement; only DaemonSet pods remained. The HTTP replica moved to the spare node, its target became healthy, and the old target completed deregistration. A controller replica, Grafana and the Prometheus operator were also evicted. The Prometheus server was not on the drained node.

The preStop command remained `sleep 5; nginx -s quit`, with a 30-second termination grace period. This test did not isolate readiness gates from spare capacity, repeat the managed upgrade, or establish a universal shutdown timing requirement.

## Measurements

HTTP sample window: **2026-09-08T21:19:14Z → 2026-09-08T21:40:09Z**. One external client, no retries. These are observed request results, not a time-based uptime guarantee. Collector start times differ; phase labels changed while collection continued.

| Phase | Requests | Failures |
| --- | ---: | ---: |
| baseline | 743 | 0 |
| pre-drain | 1,504 | 0 |
| drain | 290 | 0 |
| recovery | 1,493 | 0 |

Prometheus: **880 records, 0 explicit gaps**, eight successful query series. Observer: **518 records including start/stop markers, 0 explicit gaps**. All three collector processes exited with code 0. Collection ended before capacity and route cleanup.

| Successful query | Samples |
| --- | ---: |
| `count(max by (node) (kube_node_info))` | 110 |
| `sum(max by (node) (kube_node_status_condition{condition="Ready",status="true"}))` | 110 |
| `sum(max by (node) (kube_node_status_capacity{resource="cpu",unit="core"}))` | 110 |
| `sum(max by (node) (kube_node_status_allocatable{resource="cpu",unit="core"}))` | 110 |
| `sum(max by (node) (kube_node_status_allocatable{resource="memory",unit="byte"}))` | 110 |
| `sum(max by (node) (kube_node_spec_unschedulable))` | 110 |
| `max(kube_deployment_spec_replicas{namespace="default",deployment="http-demo"})` | 110 |
| `max(kube_deployment_status_replicas_available{namespace="default",deployment="http-demo"})` | 110 |

Sampling can miss short transitions; absence of explicit gaps does not prove continuous visibility. This drain did not move the single Prometheus server, unlike the original upgrade.

## Cleanup and retained state

The drained instance was removed and apps capacity restored to min/desired/max **2/2/2**. Cleanup required reconciling EKS desired size after the Auto Scaling group had already decreased. Two sizing applies failed validation during preparation/cleanup (min 3 versus desired 2; max 2 versus EKS desired 3); corrected updates completed, and the saved final Terraform plan reports **No changes**.

At **2026-09-08T21:53:09Z**, four workers were Ready at 1.36, HTTP and controller rollouts succeeded, and the Prometheus StatefulSet rollout completed. Both HTTP pods had readiness gates 1/1; the HTTP PDB allowed one disruption. The temporary Ingress was deleted, and the AWS inventory contained zero load balancers matching its captured DNS name. Shared workloads and the namespace injection label remain provisioned.

## Evidence

- [HTTP requests](workload-health.txt): all original request rows and final counter.
- [Prometheus queries](prometheus-results.jsonl): all original query records.
- [Pod, PDB and target observations](observations.jsonl): every record retained, with selected response fields and consistent infrastructure aliases; full raw responses remain local.
- [Drain and timeline](drain.txt): eviction outcome and phase timestamps.
- [Final health and cleanup](cleanup.txt): selected AWS cleanup results, rollout output and collector exit codes.
- [Provenance](provenance.json): raw-source and published-file SHA-256 hashes, transformation description.

Node, IP, instance and target-binding aliases are scoped to this evidence package. Raw Terraform state/plans, account identifiers, unrelated AWS inventory and full object specifications are excluded.

**Result:** the remediated workload sustained the measured single-node drain with zero observed HTTP failures. Full EKS replacement, surge scale-down and controller-leader transitions still require separate validation before claiming the original failure mode is eliminated.

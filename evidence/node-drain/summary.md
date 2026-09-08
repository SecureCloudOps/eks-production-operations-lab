# Lab 02: Blocked node drain

Completed on 2026-09-08 in `us-east-1`, on EKS `eks-operations-lab` with
control plane 1.36 and four Ready workers running `v1.36.1-eks-a3a0722`.
The operator executed all cluster commands; the assistant reviewed local
manifests and captured evidence and guided each step.

The selected-pod drain was blocked by the intended PDB, timed out after one
minute, and returned exit code 1. Scaling the dedicated `lab02/drain-demo`
Deployment from one to two healthy replicas allowed eviction without changing
`minAvailable: 1`. The retry returned exit code 0. Cleanup restored node
scheduling and removed the dedicated namespace.

## Diagnosis and impact

The PDB selector `app=drain-demo` matched the sole Ready replica. Current healthy,
desired healthy, and total were all 1; allowed disruptions was 0. Evicting that
replica would violate the configured minimum. Repeated eviction errors explicitly
named the pod and disruption budget. The failed drain left `apps-node-a` cordoned
and the original pod Ready. The diagnosis capture contained no PDB events, so
the drain error and PDB status provide the direct blocker evidence.

Both attempts used `--pod-selector=app=drain-demo --ignore-daemonsets`, with
timeouts of 60 seconds and 180 seconds respectively. No eviction bypass was used.
The selector scope was checked before each attempt. The node was kept cordoned
during scaling, and the added replica became Ready on `apps-node-b`.

After eviction, both Lab 2 replicas were Ready on `apps-node-b` and none remained
on `apps-node-a`. The original node retained unselected workloads, including
HTTP demo, AWS Load Balancer Controller, and monitoring pods. Shared HTTP demo
was 2/2 at the recorded checks. No external HTTP traffic or continuous monitoring
measurement was collected for this lab; uninterrupted client availability is
not established. This was selected-pod eviction, not full-node evacuation or
proof that the node was safe to stop or replace.

## Recorded timeline (UTC)

| Capture start | Observation |
| --- | --- |
| 22:07:57 | Read-only preflight; four Ready schedulable nodes, two untainted apps nodes |
| 22:08:48 | Fixture Ready with one replica on apps-node-a |
| Not timestamped | Initial drain blocked by PDB; one-minute timeout, exit 1 |
| 22:12:10 | Diagnosis: one healthy pod, one required, zero allowed disruptions |
| 22:12:35 | Scale remediation capture begins; two Ready replicas and one allowed disruption observed |
| Not timestamped | Retry evicted original pod; exit 0 |
| 22:14:03 | Recovery capture begins; two Ready replicas on apps-node-b |
| 22:15:05 | Cleanup capture begins; uncordon and fixture deletion succeeded; four Ready schedulable nodes |

Timestamps mark capture starts, not exact completion times. Exact drain start
and end timestamps were not recorded.

## Evidence

- [Preflight](preflight.txt), [deployment](deploy.txt), and [baseline](baseline.txt)
- [Blocked drain](drain-blocked.txt) and [diagnosis](diagnosis.txt)
- [Scale remediation](scale-remediation.txt) and [successful retry](drain-retry.txt)
- [Original node workloads](node-pods-before.txt) and [recovery](recovery.txt)
- [Cleanup](cleanup.txt) and [capture hashes and sanitization](provenance.json)

Raw captures and resource YAML/JSON remain in the Git-ignored local run directory.
Published copies replace private addresses, node names, generated node-group
suffixes, and the local path with aliases. Aliases apply only within this lab.
The original drain errors, repetitions, exit codes, and observed states remain
in the sanitized captures. Lab 1 evidence is unchanged.

## Corrective action and reproducibility

The operator completed the availability-preserving scale remedy and cleanup.
For real maintenance, the workload owner should ensure enough healthy replicas
on eligible uncordoned capacity to satisfy the PDB during eviction. Scaling
requires scheduling capacity; a Pending replica would not have restored the budget.

The source fixture intentionally remains at one replica with `minAvailable: 1`
so a future run reproduces the blocked drain. The alternative remedy that relaxes
the PDB to accept downtime was not exercised. No Terraform plan was run during
Lab 2, and no inference of a fresh clean plan is made from the Lab 1 baseline.

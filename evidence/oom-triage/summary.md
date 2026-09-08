# Lab 03: OOMKilled triage

The operator reproduced a real `OOMKilled` termination with exit code `137`
on the canary node, captured pre/post-restart memory samples, contained the
allocator, and deleted the Lab 3 namespace. All four nodes were Ready at cleanup;
shared HTTP demo was 2/2 and all listed monitoring pods were Ready.

## Cause and observed impact

The fixture intentionally retains and touches 4 MiB every five seconds after
a 120-second warm-up. Its effective memory request was `32Mi`, limit `128Mi`
(134,217,728 bytes), and QoS was Burstable. It ran one container and one replica
on the tainted canary node. Baseline logs contain only the warm-up message and
baseline restart metrics are zero.

The original container started at **2026-09-08T22:49:32Z**, terminated with
`reason: OOMKilled`, `exitCode: 137` at **22:54:03Z**, and restarted at
**22:54:04Z** in the same pod. Previous logs were successfully captured and end
at 120 MiB of retained payload. The allocator's unbounded retention is confirmed
in the fixture; container-limit exhaustion is strongly supported by the ramp,
effective limit, OOM metadata, and lack of observed node-wide symptoms. Kernel
or cgroup OOM diagnostic records were not collected, so the exact kernel trigger
was not independently inspected.

The highest sampled working set for the original container was **121,491,456
bytes (115.86 MiB)**. The replacement container had samples between 3,706,880 and
4,440,064 bytes (3.54–4.23 MiB). These are distinct container-ID series. Query
evaluation can temporarily return an old series alongside a new one; they were
not summed. Working set differs from all memory charged to the cgroup, and the
sampled maximum is not the exact usage at termination.

Restart metrics rose from 0 to 1 and the last-termination OOM gauge was observed
at 1. The node MemoryPressure=true gauge was 0 in all returned evaluations.
Canary neighbors retained the same pod identities and zero restart counts in
the before/after snapshots. Monitoring pod identities and restart counts also
matched across the capture. This run provides no evidence of a noisy-neighbor
outage; absence of sampled pressure alone cannot exclude a brief host event.

## Timeline (UTC, 2026-09-08)

| Time | Recorded event |
| --- | --- |
| 22:41:21 | Preflight begins; canary Ready, schedulable, MemoryPressure=False |
| 22:49:28 | Experiment capture begins before deployment |
| 22:49:32 | Original allocator container starts its warm-up |
| 22:54:03 | Original container finishes with OOMKilled / 137 |
| 22:54:04 | Replacement container starts; restartCount=1 |
| 22:55:14 | Capture script finishes with metrics_gap_count=0 |
| 22:56:35 | Containment capture begins; scale to zero and pod deletion succeed |
| 22:58:09 | Recovery instant query evaluates desired replicas as 0 |
| 22:58:32 | Cleanup capture begins; namespace deletion and final health checks succeed |

Capture start timestamps are not exact operation completion timestamps.

## Evidence and telemetry

- [Preflight](preflight.txt), [scrape health](scrape-health.json), and [host/workload baseline](before-nodes.txt)
- [Status polling, OOM, logs, node checks, containment and cleanup](workload-health.txt)
- [OOM metadata](oom-summary.json) and [previous container logs](previous-logs.txt)
- [Memory, limit, restart, OOM, pressure and neighbor queries](prometheus-results.txt)
- [Projected placement and restart snapshots](placement-and-restarts.json)
- [Containment](containment.txt), [zero-replica query](recovery-metrics.json), and [final state](after-state.txt)
- [Source/output hashes and sanitization details](provenance.json)

Canary cAdvisor scrapes ran every 10 seconds; kube-state-metrics every 30 seconds.
The range queries used a 10-second evaluation step, which does not create extra
scrapes. All six exports returned nonempty successful results, and the five
core exports had no API warnings. The memory export contains 28 evaluations
for the original container and 7 for the replacement; repeat evaluations need
not represent unique scrapes. No missing response was treated as zero.

Recovery telemetry is an instant query confirming desired replicas zero, not a
range export of the scale-down transition. The first OOM was captured; continued
polling was not performed between export and containment, so a complete count
of all possible later terminations is not claimed. No external HTTP load or
continuous neighbor restart history was collected. Current healthy snapshots
do not prove uninterrupted client availability. A pre-existing local Prometheus
port-forward was reused; these cleanup captures do not establish its termination.

Raw snapshots, target inventories, and local capture scripts remain Git-ignored.
Publication aliases private nodes/addresses, host and instance identities,
generated group suffixes, and local paths. Pod UIDs and container IDs remain
for correlation. Lab 1 and Lab 2 evidence are unchanged.

## Containment and corrective action

Scaling to zero stopped the allocator; deleting the fixture removed the reserved
namespace. This is containment, not a fixed application release. The manifest
intentionally remains unchanged so another run can reproduce the failure.

For a real application, the workload owner should fix unbounded retention or
bound caches/batches and validate the change under representative load. Raising
the limit alone would only delay this fixture's next OOM. The platform owner
should retain termination metadata and memory history, and collect host/kernel
evidence when node-wide exhaustion is suspected. That alternative diagnosis
was not reproduced in this bounded exercise.

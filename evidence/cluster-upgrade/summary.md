# Lab 01 — EKS 1.35 → 1.36 under live HTTP traffic

**Upgrade completed; zero-failure availability objective failed.** The control plane and all three Bottlerocket managed node groups reached Kubernetes 1.36. Four Ready workers, healthy HTTP backends, DNS and monitoring were restored. Terraform's final plan reported no changes.

The external client recorded **26,611 requests and 9 HTTP 502 responses** (99.966179% observed request success). All failures occurred during the apps rollout. Recovery completed with no additional observed failures. The original failures have not been removed from the evidence.

## Run and measurement scope

- Run: `20260908T154548Z`, 8 September 2026, `us-east-1`.
- Operator: `operator-1` (publication alias assigned during evidence assembly; no operator alias was captured at run start).
- HTTP window: **2026-09-08T18:23:23Z → 2026-09-08T20:43:35Z**, 2h 20m 12s between first and last request-start timestamps.
- Client: operator Mac outside the cluster; uncached ALB `/healthz`; one outstanding request, 0.2-second sleep between attempts, no retries, five-second request deadline. Measured request success is not time-based uptime or a guarantee for every service/client.
- Terraform 1.14.3, workspace `default`; kubent 0.7.3. Full client-tool versions and an immutable source commit were not captured.
- Before measurement, an IP-access change exposed missing Helm state entries. The operator imported the existing releases and completed a separate recovery apply, then obtained a clean plan. That recovery was outside the HTTP measurement window.

## Evidence index

| File | Contents |
| --- | --- |
| [preflight.txt](preflight.txt) | Source/target, scanner output, readiness insights, installed add-ons/charts, workload/PDB checks, quota and subnet observations. |
| [before-nodes.txt](before-nodes.txt) | Baseline node → instance → actual launch AMI, group configuration and health. |
| [after-nodes.txt](after-nodes.txt) | Replacement instances and AMIs, final versions and group health. |
| [workload-health.txt](workload-health.txt) | Every HTTP request, observed pod UID/node transitions, PDB transitions, health checks and incident excerpts. |
| [prometheus-results.txt](prometheus-results.txt) | All 5,907 original JSON query records, including seven explicit gap records; JSONL format. |

## Upgrade stages

| Stage | Started UTC | Apply exited UTC | Result |
| --- | --- | --- | --- |
| Control plane | 18:38:01 | 18:47:04 | 1.35 → 1.36; workers retained at 1.35 |
| Canary | 18:55:21 | 19:10:30 | Canary replaced and validated at 1.36 |
| Apps | 19:16:48 | 19:34:29 | Apps replaced; nine HTTP 502s; monitoring gaps |
| System | 19:50:14 | 20:12:37 | System replaced; no observed HTTP failures in phase |
| Recovery | 20:17:34 | 20:43:35 collection stop | Healthy capacity restored; no observed HTTP failures |

All four apply exit codes were recorded as 0. Version stages were applied through reviewed saved Terraform plans. Add-ons remained pinned to CoreDNS `v1.13.2-eksbuild.21`, Pod Identity agent `v1.3.10-eksbuild.3`, kube-proxy `v1.35.3-eksbuild.21` and VPC CNI `v1.22.4-eksbuild.3`.

## HTTP observations

| Phase | Requests | Failures | Observed success |
| --- | ---: | ---: | ---: |
| preflight | 387 | 0 | 100.000000% |
| pre-upgrade | 2,400 | 0 | 100.000000% |
| control-plane | 3,269 | 0 | 100.000000% |
| canary | 4,054 | 0 | 100.000000% |
| apps | 6,293 | 9 | 99.856984% |
| system | 5,232 | 0 | 100.000000% |
| recovery | 4,976 | 0 | 100.000000% |

Failure request-start timestamps formed two bursts: **19:25:40–19:25:52** (four requests) and **19:33:16–19:33:32** (five requests), UTC. Every failed request returned HTTP 502 with curl exit 0 and about 3.2 seconds of latency. These ranges describe failed samples, not a measured continuous outage duration. Failed-response headers/bodies and historical ALB access logs were not collected, so the exact emitter and backend failure mode are not independently proven.

## Rescheduling and incident assessment

The two original HTTP pod UIDs were replaced. One replacement subsequently moved again from a temporary surge node during scale-down. The placement collector captured 1,397 pod snapshots and 1,397 PDB snapshots; the published file condenses these into observed changes, preserving UIDs and timestamps.

**Confirmed configuration gap:** HTTP pods had no ALB target-health readiness gates. The surviving replacement pod reported Kubernetes Ready at **19:33:14**, while controller logs show its target registered at **19:33:31**. Registration is not proof of ALB health. The old target was deregistered at **19:33:30**. These observations overlap the second failure burst.

**Working hypothesis, not a confirmed complete root cause:** pod termination, controller rescheduling and delayed ALB target reconciliation allowed traffic toward an unavailable backend during handoff. The configured preStop hook was `sleep 5; nginx -s quit`, with a 30-second termination grace period. Whether five seconds was sufficient has not been established. Missing readiness gates explain why Kubernetes Ready did not guarantee ALB readiness; they do not alone prove the cause of all nine 502s.

Both ALB targets were subsequently observed healthy, and the error count remained nine through recovery. No mid-run workload fix or retry erased the initial failures.

## Prometheus and capacity

| Phase | Observed registered-node range | Observed CPU capacity (cores) |
| --- | ---: | ---: |
| pre-upgrade | 4–4 | 8–8 |
| control-plane | 4–4 | 8–8 |
| canary | 4–8 | 8–16 |
| apps | 4–8 | 8–16 |
| system | 4–9 | 8–18 |
| recovery | 4–4 | 8–8 |

Peak sampled capacity was **9 registered nodes / 18 CPU cores** during system replacement, compared with a baseline and final capacity of **4 nodes / 8 cores**. Final allocatable CPU was **7.72 cores**; final allocatable memory was **17,898,278,912 bytes**. These are Kubernetes samples, not EC2 billing counts or a guaranteed simultaneous physical maximum.

All eight queries returned data before and after the upgrades. There were **seven explicit gap records**, all during apps: two empty transport responses, two HTTP-error query attempts and three empty result vectors. The longest interval between successive successful samples for any one query was **49 seconds**. A gap record is not an outage-duration measurement; the collector skips remaining queries in a cycle after a failure. The single Prometheus replica used emptyDir storage and moved during the rollout; local instant-query capture preserved earlier observations. Unsampled peaks and short workload changes remain possible. Exact peak capacity during gaps is inconclusive.

The available-replica metric returned 2 in successful samples, despite external 502s. Kubernetes readiness and sampled replica counts did not establish end-to-end availability.

## Node and AMI transition

All four original instances were replaced. The launch AMI changed from **`ami-0b2101516e0e6d4cc`** to **`ami-07ecc2f05e58aae70`**. Kubelet changed from `v1.35.5-eks-a3a0722` to `v1.36.1-eks-a3a0722`. Bottlerocket stayed at OS 1.64.0, with variant changing from `aws-k8s-1.35` to `aws-k8s-1.36`; the managed-group release string stayed `1.64.0-ad9d4847`.

Final groups: apps=2 × m6i.large, canary=1 × t3.small, system=1 × t3.small. All final group describe responses report 1.36 / ACTIVE and empty health issues. Detailed aliases, Availability Zones and launch times are preserved in the node files.

## Preflight and evidence limitations

- EKS reported both minors in standard support and five passing upgrade-readiness insights. No deprecated-API insight was returned.
- Kubent returned exit 0 with no findings, but displayed version-specific rules only through 1.32. This is not complete 1.36 API-removal coverage. The API-server snapshot observed deprecated core/v1 Endpoints usage without a removal release.
- Chart/controller inventories and AWS add-on compatibility insights were captured. A complete release-specific review of all rendered manifests, CRDs, webhooks and external clients for 1.36 was not recorded. Post-upgrade health is evidence of observed operation, not a substitute for that missing preflight certification.
- AWS add-on ACTIVE/health observations were saved before and after the control-plane upgrade. A separate final AWS add-on describe capture after all worker groups was not saved; final Kubernetes workload checks were saved.
- The baseline health observations preceded a network pause and Helm-state recovery. Fresh HTTP/Prometheus baseline measurements began after recovery. No contemporaneous signed GO statement was saved.
- Provider update IDs, AMI DescribeImages metadata, complete client-tool versions and external encrypted-backup verification were not captured in the published evidence. EC2 ImageId still directly records actual launch AMIs.
- The raw Prometheus gap records and HTTP failures are retained. Publication uses consistent node/instance/IP aliases and omits raw state, plans, credentials, account identifiers and full debug logs.

## Cleanup and final verdict

Terraform final plan: **No changes**, exit 0, captured before route cleanup. The three collectors were requested to stop at **20:43:35 UTC**; the timeline records completion at **20:43:38 UTC**, and the HTTP log has a final SUMMARY line. Only the placement exit code was explicitly shared; individual HTTP/metrics process exit codes were not saved.

The Lab 01 Ingress and its ALB were deleted at **20:47:14 UTC**, following the AWS deletion waiter. The HTTP application, monitoring, controller, cluster and node groups were retained. Infrastructure remains provisioned. Public HTTP measurement ended before route cleanup.

**Verdict: FAIL against the lab's zero-observed-failure criterion; infrastructure upgrade completed and recovered.** Monitoring coverage contains documented gaps. No statement of uninterrupted availability or fully certified compatibility is warranted.

## Follow-up work (not applied in this run)

Subsequent validation: [readiness-gate remediation and controlled drain](remediation-20260908T210043Z/summary.md) recorded 4,030 requests with zero observed failures. It used spare apps capacity on Kubernetes 1.36 and did not repeat the managed upgrade. The original verdict above remains unchanged.

1. Operator/platform owner: enable and verify ALB pod readiness-gate injection for eligible newly created HTTP pods; establish target-health readiness before considering replacements available. [Controller readiness gates](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.14/deploy/pod_readiness_gate/).
2. Operator/platform owner: test shutdown grace and target deregistration timing, including controller leader movement and temporary surge-node scale-down; select timings from measured behavior rather than assuming a fixed sleep guarantees zero loss.
3. Observability owner: preserve ALB access/error evidence and historical controller logs; provide durable or external Prometheus storage if uninterrupted historical coverage is required.
4. Operator: run a separate controlled validation with a fresh baseline and evidence directory after remediation. Preserve this failed run for comparison; do not downgrade the completed EKS control plane.

## Recorded timeline

```text
2026-09-08T16:17:44Z Paused before collectors and upgrades; operator changing networks.
2026-09-08T18:22:56Z Recovery complete; clean Terraform plan; external HTTP passed.
2026-09-08T18:25:24Z pre-upgrade
2026-09-08T18:38:01Z Control-plane upgrade started
2026-09-08T18:47:04Z Control-plane apply exited with code 0
2026-09-08T18:55:21Z Canary upgrade started
2026-09-08T19:10:30Z Canary apply exited with code 0
2026-09-08T19:16:48Z Apps upgrade started
2026-09-08T19:34:29Z Apps apply exited with code 0
2026-09-08T19:50:14Z System upgrade started
2026-09-08T20:12:37Z System apply exited with code 0
2026-09-08T20:17:34Z Final recovery window started
2026-09-08T20:43:35Z Collection stop requested
2026-09-08T20:43:38Z Collectors finished
2026-09-08T20:47:14Z Lab 1 Ingress and ALB deleted; shared workloads retained.
```

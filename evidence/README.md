# Execution evidence

These are observations from operator-executed EKS labs on September 8–9, 2026.
Start with each summary for the claim, supporting captures and measurement limits.
The successful recoveries do not erase the original failures.

| Exercise | Start with | Supporting records |
| --- | --- | --- |
| Initial baseline | [Baseline summary](summary.md) | [Readiness, workload and event captures](baseline/) |
| Cluster upgrade | [Upgrade summary](cluster-upgrade/summary.md) | [HTTP observations](cluster-upgrade/workload-health.txt), [Prometheus records](cluster-upgrade/prometheus-results.txt) |
| Upgrade follow-up | [Controlled-drain summary](cluster-upgrade/remediation-20260908T210043Z/summary.md) | [HTTP observations](cluster-upgrade/remediation-20260908T210043Z/workload-health.txt), [provenance](cluster-upgrade/remediation-20260908T210043Z/provenance.json) |
| Blocked drain | [Drain summary](node-drain/summary.md) | [Eviction failure](node-drain/drain-blocked.txt), [retry](node-drain/drain-retry.txt), [provenance](node-drain/provenance.json) |
| Container OOM | [OOM summary](oom-triage/summary.md) | [Termination metadata](oom-triage/oom-summary.json), [previous logs](oom-triage/previous-logs.txt), [provenance](oom-triage/provenance.json) |
| IRSA overprivilege | [IAM summary](irsa-breach/summary.md) | [Access checks](irsa-breach/access-checks.txt), [CloudTrail events](irsa-breach/cloudtrail-after.jsonl), [provenance](irsa-breach/provenance.json) |
| Ingress outage | [Ingress summary](ingress-outage/summary.md) | [Failure/recovery](ingress-outage/result.txt), [cleanup](ingress-outage/cleanup.txt), [final health](ingress-outage/final-health.json), [provenance](ingress-outage/provenance.json) |

## How to interpret the captures

- Aliases are scoped to their evidence package unless documented otherwise.
  Do not assume two similarly named nodes in different labs are the same resource.
- Source SHA-256 hashes support correlation with retained private captures;
  they are not signatures or independent verification of the original observer.
- Request success is measured over the recorded client window, not time-based
  uptime. Kubernetes readiness and sampled metrics do not prove client availability.
- An empty or failed metrics response is a gap, not zero usage or a healthy result.
- Capture-start timestamps may precede the operation they contain. See each
  summary before using them as exact incident event times.
- Historical preparation reports describe what was known at their stated dates.
  Later execution summaries provide the observed runtime results.

Raw state, plans, credentials, private configuration and full inventories belong
in ignored local storage and verified encrypted backups. Review every proposed
evidence change before staging; see [contribution guidance](../CONTRIBUTING.md).

The original Lab 01 zero-failure objective failed. Its separate controlled-drain
follow-up passed within a narrower scope. Both records are intentionally retained.

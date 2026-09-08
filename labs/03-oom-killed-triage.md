# Lab 03 — OOMKilled triage and noisy-neighbor diagnosis

## Objective

Run [memory-leak.yaml](../kubernetes/chaos/memory-leak.yaml), identify the container's
`128Mi` memory limit, and capture a real `OOMKilled` termination with exit code
`137`. Correlate that timestamp with memory growth and node pressure to distinguish
a container limit violation from shared-node exhaustion.

The manifest creates namespace `lab03` and a one-replica Deployment named
`memory-leak`. Python waits 120 seconds for evidence setup, then retains and touches
4 MiB every five seconds. Interpreter overhead also counts toward the limit, so
it should die before retaining 128 MiB of payload. The list keeps every chunk
reachable and the page writes commit memory, so garbage collection cannot flatten
the ramp. There is no liveness probe or timed process exit to imitate an OOM.
With normal scheduling, 32 allocations take roughly 4–5 minutes including warm-up;
the ten-minute observation window allows slack. Linux enforces the limit;
the container attempts to exceed it, rather than escaping it. Kubernetes restarts
the container, producing repeated growth/reset cycles and eventually restart
backoff. Exact timing varies. See the Kubernetes
[memory-limit exercise](https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/).

The pod is Burstable (`32Mi` request, `128Mi` limit), uses a non-root process with
no extra privileges, and targets this repository's tainted `workload=canary`
node group. Monitoring stays on the apps group. Keep one replica and the limit
in place; this exercise reproduces a container OOM and diagnoses noisy-neighbor
patterns without deliberately exhausting a whole node.

## 1. Prepare access and monitoring

Use a disposable lab cluster, Bash, kubectl, jq, and curl. Follow the
[repository access instructions](../README.md). The operator needs permission
to create/delete these lab resources, read nodes/pods/events/logs across namespaces,
and port-forward the Prometheus Service. This lab uses Prometheus and Kubernetes
status directly; neither `kubectl top` nor Metrics Server is required.

Run from the repository root in one Bash shell. Inspect the selected cluster
before applying anything. Start with no existing `lab03` experiment; reserve
that namespace for this fixture. `memory-leak.yaml` is the canonical entry point.

```bash
bash
set -euo pipefail
umask 077
kubectl config current-context
kubectl get nodes -l workload=canary -o wide
kubectl get nodes -l workload=canary -o json | jq -e '
  any(.items[]; .spec.unschedulable != true and
    any(.status.conditions[]; .type == "Ready" and .status == "True"))'
test -z "$(kubectl get namespace lab03 --ignore-not-found -o name)"
kubectl -n monitoring get pods
kubectl -n monitoring get svc
export EVIDENCE="$PWD/evidence/oom-triage"
export RAW="$PWD/.local/oom-triage/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$EVIDENCE" "$RAW"
chmod 700 "$RAW"
# Archive previous populated evidence locally before a rerun overwrites it.
for name in before-nodes workload-health prometheus-results; do
  if [ -s "$EVIDENCE/$name.txt" ]; then cp "$EVIDENCE/$name.txt" "$RAW/previous-$name.txt"; fi
done
PROM_SERVICE="$(kubectl -n monitoring get svc -o json | jq -er '
  [.items[] | select(.spec.clusterIP != "None") |
    select(any(.spec.ports[]; .port == 9090))] |
  if length == 1 then .[0].metadata.name else error("Inspect and select the actual Prometheus Service") end')"
export PROM_SERVICE
kubectl -n monitoring get svc "$PROM_SERVICE" -o yaml
kubectl -n monitoring port-forward "svc/$PROM_SERVICE" 19090:9090 \
  > "$RAW/port-forward.txt" 2>&1 &
PF_PID=$!
# Stop only this shell's port-forward on exit; preserve lab resources for evidence.
stop_forward() { kill "$PF_PID" 2>/dev/null || true; wait "$PF_PID" 2>/dev/null || true; }
trap stop_forward EXIT
trap 'exit 130' INT TERM
```

Choose the actual Prometheus Service with Service port 9090, and ensure local
port 19090 is free. Wait for the forwarding message in the log. In this shell:

```bash
for ((attempt=0; attempt<30; attempt++)); do
  if curl -fsS --max-time 2 http://127.0.0.1:19090/-/ready; then break; fi
  kill -0 "$PF_PID"
  sleep 2
done
curl -fsS --max-time 10 http://127.0.0.1:19090/-/ready
curl -fsS --max-time 10 http://127.0.0.1:19090/api/v1/targets > "$RAW/targets.json"
jq '.data.activeTargets[] | select((.scrapeUrl | contains("/metrics/cadvisor")) or
  ((.labels.job // "") | contains("kube-state-metrics"))) |
  {labels,scrapeUrl,health,lastError,scrapeInterval}' "$RAW/targets.json"
```

The current `kube-prometheus-stack` chart enables kubelet/cAdvisor and
kube-state-metrics; the repository values do not disable these or filter out
working-set, restart-count or last-termination-reason metrics. No exporter in
the Python container or ServiceMonitor for this allocator is needed. The
[kube-state-metrics pod metrics](https://github.com/kubernetes/kube-state-metrics/blob/main/docs/metrics/workload/pod-metrics.md)
define the restart counter and `kube_pod_container_status_last_terminated_reason`.
The latter is experimental: check the deployed exporter rather than treating an
absent series as zero. It normally appears only after a termination.

Require healthy kubelet/cAdvisor scrapes, including the intended canary node,
and kube-state-metrics. Record the actual scrape interval. Resolve missing
metrics, TLS/RBAC errors, or image/scheduling problems rather than interpreting
missing data as zero usage. Do not upgrade or restart monitoring during this
lab: its configured `emptyDir` storage loses history on pod replacement.

## 2. Deploy and capture `before-nodes.txt`

```bash
export START_EPOCH=$(date +%s)
date -u +%FT%TZ > "$RAW/start.txt"
kubectl apply -f kubernetes/chaos/memory-leak.yaml
# Equivalent deployment shortcut: make lab03-trigger
kubectl -n lab03 rollout status deployment/memory-leak --timeout=180s
export POD=$(kubectl -n lab03 get pods -l app=memory-leak -o jsonpath='{.items[0].metadata.name}')
export NODE=$(kubectl -n lab03 get pod "$POD" -o jsonpath='{.spec.nodeName}')
export POD_UID=$(kubectl -n lab03 get pod "$POD" -o jsonpath='{.metadata.uid}')
test -n "$POD" && test -n "$NODE" && test -n "$POD_UID"
{
  date -u +%FT%TZ
  kubectl config current-context
  printf 'pod=%s uid=%s node=%s\n' "$POD" "$POD_UID" "$NODE"
  kubectl get node "$NODE" -o json | jq '{name:.metadata.name,
    capacity:.status.capacity,allocatable:.status.allocatable,
    conditions:[.status.conditions[] | select(.type=="MemoryPressure" or .type=="Ready")],
    taints:.spec.taints}'
  kubectl describe node "$NODE"
  kubectl get pods -A --field-selector "spec.nodeName=$NODE" -o wide
  kubectl -n lab03 get pod "$POD" -o json | jq '{uid:.metadata.uid,
    qos:.status.qosClass,containers:[.spec.containers[] | {name,resources}],
    status:.status.containerStatuses}'
} > "$RAW/before-nodes.txt" 2>&1
cat "$RAW/before-nodes.txt"
kubectl -n lab03 logs "$POD" -c memory-leak --timestamps --tail=10
```

```bash
kubectl get node "$NODE" -o json | jq -e '
  .metadata.labels.workload == "canary" and
  any(.spec.taints[]; .key == "workload" and .value == "canary" and .effect == "NoSchedule")'
kubectl -n lab03 get pod "$POD" -o json | jq -e '
  .spec.nodeSelector.workload == "canary" and
  (.spec.containers | length == 1) and
  .spec.containers[0].resources.limits.memory == "128Mi" and
  all(.status.containerStatuses[]; .restartCount == 0)'
# Confirm discovery and initial memory/restart samples before the first OOM.
for query in \
  "container_memory_working_set_bytes{namespace=\"lab03\",pod=\"$POD\",container=\"memory-leak\"}" \
  "kube_pod_container_status_restarts_total{namespace=\"lab03\",pod=\"$POD\",container=\"memory-leak\"}"; do
  curl -fsS --max-time 10 --get http://127.0.0.1:19090/api/v1/query \
    --data-urlencode "query=$query" > "$RAW/baseline-query.json"
  printf '\nPromQL: %s\n' "$query" >> "$RAW/before-nodes.txt"
  cat "$RAW/baseline-query.json" >> "$RAW/before-nodes.txt"
  jq -e '.status == "success" and (.data.result | length > 0)' "$RAW/baseline-query.json"
done
```

Allow target discovery and one scrape before these queries, within the warm-up;
if empty, inspect targets and retry promptly. Do not proceed with absent baseline
metrics. Recheck the pod restart count if setup took longer than the warm-up.

Capture this promptly during the 120-second warm-up. If growth already began,
record that limitation; if it already restarted, this is not a clean baseline.
Preserve the attempt and repeat after cleanup. Confirm the effective pod spec
still says `128Mi` (134,217,728 bytes), with no injected sidecar or admission
mutation changing the experiment. `rollout status` only proves initial readiness;
there is no application health endpoint or readiness probe in this allocator.

In `describe node`, distinguish **Allocated resources** (summed requests/limits)
from live use. Scheduling is based on requests. A high sum of memory limits
suggests overcommit, not proof that memory is currently exhausted. Expect
`MemoryPressure=False` on a healthy node for this bounded experiment.

## 3. Capture the exact termination into `workload-health.txt`

Watch progress in another terminal with `kubectl -n lab03 get pods -w`; use
`kubectl -n lab03 logs <pod-name> -c memory-leak --timestamps -f` to follow
retained payload growth. In the original shell, poll for up to ten minutes and
save each status sample to the raw evidence file. Do not delete or restart
the pod before collecting termination metadata.

```bash
printf 'Observation started %s pod=%s uid=%s\n' "$(date -u +%FT%TZ)" "$POD" "$POD_UID" \
  > "$RAW/workload-health.txt"
found=0
for ((attempt=0; attempt<120; attempt++)); do
  kubectl -n lab03 get pod "$POD" -o json > "$RAW/pod-observed.json"
  test "$(jq -r .metadata.uid "$RAW/pod-observed.json")" = "$POD_UID"
  jq --arg utc "$(date -u +%FT%TZ)" '{observedAt:$utc,uid:.metadata.uid,
    phase:.status.phase,status:[.status.containerStatuses[]? |
      {name,restartCount,state,lastState}]}' "$RAW/pod-observed.json" \
    >> "$RAW/workload-health.txt"
  if jq -e '[.status.containerStatuses[]? | select(.name=="memory-leak") |
      .state.terminated, .lastState.terminated |
      select(.reason=="OOMKilled" and .exitCode==137)] | length > 0' \
      "$RAW/pod-observed.json" >/dev/null; then
    found=1
    cp "$RAW/pod-observed.json" "$RAW/pod-oom.json"
    break
  fi
  sleep 5
done
if [ "$found" -ne 1 ]; then
  printf 'INCONCLUSIVE: no OOMKilled/137 observed within ten minutes\n' \
    >> "$RAW/workload-health.txt"
  echo 'Stop here and inspect pod status/events; do not claim an OOM.' >&2
  exit 1
fi
jq '{pod:.metadata.name,uid:.metadata.uid,node:.spec.nodeName,qos:.status.qosClass,
  limits:[.spec.containers[] | {name,resources}],
  oom:[.status.containerStatuses[]? | select(.name=="memory-leak") |
    . as $c | [$c.state.terminated,$c.lastState.terminated][] |
    select(.reason=="OOMKilled" and .exitCode==137) |
    {container:$c.name,restartCount:$c.restartCount,reason,exitCode,signal,
     startedAt,finishedAt,containerID}]}' "$RAW/pod-oom.json" \
  >> "$RAW/workload-health.txt"
# The kill can be detected before Kubernetes has restarted the container.
for ((attempt=0; attempt<60; attempt++)); do
  kubectl -n lab03 get pod "$POD" -o json > "$RAW/pod-restarted.json"
  test "$(jq -r .metadata.uid "$RAW/pod-restarted.json")" = "$POD_UID"
  if jq -e 'any(.status.containerStatuses[]?;
    .name == "memory-leak" and .restartCount >= 1 and .lastState.terminated.reason == "OOMKilled")' \
    "$RAW/pod-restarted.json" >/dev/null; then break; fi
  sleep 2
done
logs_rc=0
kubectl -n lab03 logs "$POD" -c memory-leak --previous --timestamps \
  > "$RAW/previous-logs.txt" 2>&1 || logs_rc=$?
printf 'previous_logs_exit_code=%s\n' "$logs_rc" >> "$RAW/previous-logs.txt"
kubectl -n lab03 get events --field-selector "involvedObject.uid=$POD_UID" \
  --sort-by=.metadata.creationTimestamp > "$RAW/events.txt" 2>&1
{
  printf '\n--- Previous container logs ---\n'
  cat "$RAW/previous-logs.txt"
  if [ "$logs_rc" -ne 0 ]; then
    printf 'Previous logs unavailable; trying current/just-terminated container\n'
    kubectl -n lab03 logs "$POD" -c memory-leak --timestamps || true
  fi
  printf '\n--- Pod description and events ---\n'
  kubectl -n lab03 describe pod "$POD"
  kubectl -n lab03 get events --field-selector "involvedObject.uid=$POD_UID" \
    --sort-by=.metadata.creationTimestamp
  printf '\n--- Node and neighbors after termination ---\n'
  kubectl describe node "$NODE"
  kubectl get pods -A --field-selector "spec.nodeName=$NODE" -o wide
} >> "$RAW/workload-health.txt" 2>&1
```

Both `state.terminated` and `lastState.terminated` matter: termination can be
current, or already moved to last state after a restart. Preserve the pod UID,
container ID, reason, code, and start/finish times. Later restarts overwrite last
state and previous logs; the local snapshot preserves the observed event.
`137` alone means SIGKILL-style termination and is not unique to OOM. Require
`reason: OOMKilled` too, then investigate whether it was cgroup or node-level OOM.
`CrashLoopBackOff` is a restart-delay symptom, not the cause.

## 4. Export the memory spike into `prometheus-results.txt`

Allow at least two successful scrape intervals after the restart so the query
contains the memory reset, as well as the ramp before death. Then freeze the
end time and export range-query results immediately, before cleanup. If the
port-forward died, reconnect it and verify Prometheus still has this run's history.

```bash
# Read the actual intervals for canary cAdvisor and kube-state-metrics in targets.json.
# Use at least twice the larger interval; 120 seconds covers intervals up to 60s.
read -r -p 'Seconds to wait (at least two observed scrape intervals): ' SCRAPE_WAIT
[[ "$SCRAPE_WAIT" =~ ^[0-9]+$ ]] && test "$SCRAPE_WAIT" -gt 0
sleep "$SCRAPE_WAIT"
export END_EPOCH=$(date +%s)
printf 'UTC=%s start_epoch=%s end_epoch=%s pod=%s uid=%s node=%s\n' \
  "$(date -u +%FT%TZ)" "$START_EPOCH" "$END_EPOCH" "$POD" "$POD_UID" "$NODE" \
  > "$RAW/prometheus-results.txt"
export_range() {
  local query="$1" rc=0
  printf '\nPromQL: %s\n' "$query" >> "$RAW/prometheus-results.txt"
  curl -fsS --max-time 30 --get http://127.0.0.1:19090/api/v1/query_range \
    --data-urlencode "query=$query" \
    --data-urlencode "start=$START_EPOCH" --data-urlencode "end=$END_EPOCH" \
    --data-urlencode 'step=15s' > "$RAW/query.json" 2> "$RAW/query-error.txt" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'EXPORT FAILED curl_exit=%s\n' "$rc" >> "$RAW/prometheus-results.txt"
    cat "$RAW/query-error.txt" "$RAW/query.json" >> "$RAW/prometheus-results.txt"
    return 1
  fi
  cat "$RAW/query.json" >> "$RAW/prometheus-results.txt"
  printf '\n' >> "$RAW/prometheus-results.txt"
  if ! jq -e '.status=="success" and (.data.result | length>0)' "$RAW/query.json" >/dev/null; then
    printf 'METRICS GAP: API error or empty result; investigate scraping/labels\n' \
      >> "$RAW/prometheus-results.txt"
    return 1
  fi
}
export_range "container_memory_working_set_bytes{namespace=\"lab03\",pod=\"$POD\",container=\"memory-leak\"}"
export_range "kube_pod_container_resource_limits{namespace=\"lab03\",pod=\"$POD\",container=\"memory-leak\",resource=\"memory\",unit=\"byte\"}"
export_range "kube_pod_container_status_restarts_total{namespace=\"lab03\",pod=\"$POD\",container=\"memory-leak\"}"
export_range "kube_pod_container_status_last_terminated_reason{namespace=\"lab03\",pod=\"$POD\",uid=\"$POD_UID\",container=\"memory-leak\",reason=\"OOMKilled\"}"
# Require an observed OOM gauge value of 1, not just a nonempty response.
jq -e 'any(.data.result[]; any(.values[]; .[1] == "1"))' "$RAW/query.json"
export_range "kube_node_status_condition{node=\"$NODE\",condition=\"MemoryPressure\",status=\"true\"}"
```

The file now contains memory, configured limit, restart count, OOM reason and
node-pressure history, plus the exact expressions, observation window, original series
labels, and timestamp/value arrays. Preserve labels such as container `id`:
restarts may create a new series, so the “cliff” may be the end of one series and
the start of another. Do not sum old and new container instances into an apparent
larger leak. Expected pattern: rising working set toward the limit, termination
near that rise, lower use in the restarted container, and increasing restart count.
The memory limit should be 134,217,728 bytes; working set is not identical to
all memory charged to the cgroup. See the
[cAdvisor metric definitions](https://github.com/google/cadvisor/blob/master/docs/storage/prometheus.md).

A 15-second query step does not increase scrape resolution. The last pre-OOM
sample can be below 128 MiB, and a missing series is not a zero. Record scrape
intervals, warnings, missing samples, and any Prometheus restart. Use termination
metadata to prove the kill; do not invent a sampled peak. The
[Prometheus HTTP API](https://prometheus.io/docs/prometheus/latest/querying/api/)
returns range-query data suitable for this text audit trail.

## 5. Diagnose noisy neighbors without triggering a node-wide outage

Compare before/after node descriptions, pod inventory, timestamps, and metrics.
For each co-located pod, inspect effective requests/limits and recent restarts:

```bash
{
  date -u +%FT%TZ
  kubectl get pods -A --field-selector "spec.nodeName=$NODE" -o json | jq '.items[] |
    {namespace:.metadata.namespace,pod:.metadata.name,uid:.metadata.uid,
     qos:.status.qosClass,phase:.status.phase,reason:.status.reason,message:.status.message,
     containers:[.spec.containers[] | {name,resources}],
     status:.status.containerStatuses}'
  kubectl get events -A --field-selector "involvedObject.kind=Node,involvedObject.name=$NODE" \
    --sort-by=.metadata.creationTimestamp
} >> "$RAW/workload-health.txt" 2>&1
```

Optionally append a node-local ranking over the same time window. This joins
pod memory to kube-state-metrics placement, avoiding assumptions about a `node`
label on cAdvisor series. It assumes a single-cluster Prometheus; add cluster
selectors/matching labels for a shared monitoring backend.

```bash
export_range "topk(10, sum by (namespace,pod) (max by (namespace,pod,container) (container_memory_working_set_bytes{container!=\"\",container!=\"POD\"})) * on(namespace,pod) group_left(node) max by (namespace,pod,node) (kube_pod_info{node=\"$NODE\"}))"
```

| Pattern | Supporting evidence | Interpretation |
| --- | --- | --- |
| Only the leak container restarts near its limit; node healthy, neighbors stable | `OOMKilled`/137 plus ramp, node conditions, and neighbor status | Container limit exhaustion is the leading diagnosis. |
| Several workloads on one node degrade together; available memory falls and pressure/eviction events appear | Common node/timestamps, per-pod growth, requests/limits and node history | Investigate aggregate exhaustion and noisy neighbors. Largest consumer alone does not establish causation. |
| Pod is Failed with reason `Evicted` and a low-memory message | Pod status and kubelet events | Node-pressure eviction, distinct from an in-place container restart. |
| OOM occurs below the container limit alongside node-wide symptoms | Kernel/kubelet OOM records and host memory telemetry | Possible system-wide OOM; pod metadata alone cannot identify the exact kernel trigger. |

For a real node incident, inspect node-exporter available-memory history and
kubelet/kernel logs through the platform's approved node access path. Bottlerocket
does not provide a conventional SSH shell by default. Attribute growth to
co-located workloads, compare usage with requests, check priority/QoS and victim
timing, and separate the offender from the process killed. Evicted pods may
already have been replaced, so include retained events and earlier pod UIDs.
A current `MemoryPressure=False` snapshot cannot rule out an earlier rapid OOM;
kubelet observation can lag memory growth. Kubernetes documents these distinctions
in [node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/).

## 6. Stop the leak, verify, and clean up

After exporting evidence, stop the allocator:

```bash
kubectl -n lab03 scale deployment/memory-leak --replicas=0
kubectl -n lab03 wait --for=delete pod -l app=memory-leak --timeout=120s
{
  printf '\n--- Containment verification %s ---\n' "$(date -u +%FT%TZ)"
  kubectl -n lab03 get deployment memory-leak
  kubectl get node "$NODE" -o json | jq '.status.conditions[] | select(.type=="MemoryPressure")'
  kubectl get pods -A --field-selector "spec.nodeName=$NODE" -o wide
} >> "$RAW/workload-health.txt" 2>&1
# Verify containment in Prometheus while the Deployment still exists.
# Wait two observed scrape intervals; old container series may remain temporarily stale.
sleep "$SCRAPE_WAIT"
END_EPOCH=$(date +%s)
export_range 'kube_deployment_spec_replicas{namespace="lab03",deployment="memory-leak"}'
# Query the current value separately: require desired replicas zero.
curl -fsS --max-time 10 --get http://127.0.0.1:19090/api/v1/query \
  --data-urlencode 'query=kube_deployment_spec_replicas{namespace="lab03",deployment="memory-leak"}' \
  > "$RAW/recovery-metrics.json"
cat "$RAW/recovery-metrics.json" >> "$RAW/prometheus-results.txt"
jq -e '.status == "success" and (.data.result | length > 0) and
  all(.data.result[]; .value[1] == "0")' "$RAW/recovery-metrics.json"
kubectl delete -f kubernetes/chaos/memory-leak.yaml --ignore-not-found --wait=true --timeout=120s
{
  date -u +%FT%TZ
  kubectl get namespace lab03 --ignore-not-found -o name
  test -z "$(kubectl get namespace lab03 --ignore-not-found -o name)"
  kubectl wait --for=condition=Ready "node/$NODE" --timeout=120s
  kubectl get node "$NODE" -o wide
  kubectl get pods -A --field-selector "spec.nodeName=$NODE" -o wide
} > "$RAW/after-state.txt" 2>&1
cat "$RAW/after-state.txt" >> "$RAW/workload-health.txt"
stop_forward
```

Deletion removes namespace `lab03` and everything inside it; reserve that namespace
for this lab. After a failed/interrupted attempt, preserve the available status/logs first,
then run the following independent cleanup block. It is safe to repeat when the
namespace is already absent; do not repeat evidence collection against deleted
pods. If the namespace is stuck Terminating, inspect its remaining resources and
finalizers instead of force-removing them.

```bash
kubectl config current-context
kubectl delete -f kubernetes/chaos/memory-leak.yaml --ignore-not-found --wait=true --timeout=120s
test -z "$(kubectl get namespace lab03 --ignore-not-found -o name)"
```

The EXIT trap closes this run's port-forward, including on errors. In a new shell,
locate the original process before stopping it; do not kill an unverified stale PID.

For a real application, fix unbounded retention, bound caches/batches, or roll
back the leaking release. Raising the limit merely delays this allocator's next
OOM. Right-size requests/limits from observed workload needs and available node
capacity; validate a fixed release under representative load. Scaling to zero
here is containment, not proof of an application fix. Reapplying the manifest
intentionally starts the failure again.

Package raw captures only after the allocator has been contained and cleanup
verified. The existing three evidence files cover all stages:

| File | Capture |
| --- | --- |
| `before-nodes.txt` | Placement, effective limits, node/neighbors, initial memory/restart samples. |
| `workload-health.txt` | Status polling, exact OOM termination, previous logs, events, neighbor diagnosis, containment and after state. |
| `prometheus-results.txt` | Memory/limit, restarts, OOM reason, node pressure and recovery replica count. |

```bash
mkdir -p "$RAW/reviewed"
for name in before-nodes workload-health prometheus-results; do
  test -s "$RAW/$name.txt"
  cp "$RAW/$name.txt" "$RAW/reviewed/$name.txt"
done
# Stop here: review and sanitize the three copies in $RAW/reviewed in an editor.
# After review, publish them (the earlier block archives prior nonempty evidence).
for name in before-nodes workload-health prometheus-results; do
  cp "$RAW/reviewed/$name.txt" "$EVIDENCE/$name.txt"
done
```

For an incomplete attempt, retain available raw captures and document the missing
stages; do not fill gaps with expected values. Review all evidence before committing: redact private identifiers
consistently while retaining comparable node/pod aliases, times, limits, reason,
exit code, and query values. Raw pod snapshots live in ignored `.local/`.
In the final notes, record the observed impact, timeline, confirmed cause,
contributing factors, mitigation, recovery checks, detection gaps, and corrective
action owner. Label noisy-neighbor explanations as hypotheses unless supported.
A completed lab needs real OOMKilled/137 metadata, a host-node baseline, and usable
pre/post-termination memory samples. Missing telemetry makes the corresponding
claim inconclusive. No evidence files are prefilled with simulated results.

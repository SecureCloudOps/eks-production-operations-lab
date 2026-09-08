# Lab 02: Node Drain Failure

Reproduce a drain blocked by a PodDisruptionBudget (PDB), diagnose the
availability constraint, and resolve it in either of two ways.

Both attempts use `--pod-selector=app=drain-demo` to select only the lab fixture.
A full-node drain would also inspect monitoring pods on apps nodes; their
`emptyDir` volumes can stop drain before it reaches the intended PDB failure.
The [pod selector](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_drain/)
keeps those pods out of this experiment while preserving normal eviction/PDB
checks for `drain-demo`. Do not add `--force`, `--delete-emptydir-data`, or
`--disable-eviction`. This exercise proves successful **selected-pod eviction**,
not evacuation of the entire node; do not stop or replace the node afterward.

## Prerequisites

- Run commands from the repository root, in the same Bash shell, with `jq` installed.
- Use a disposable lab cluster with at least two Ready, schedulable worker nodes
  eligible for this Deployment and room for another pod. In the current
  architecture, use the two untainted apps nodes. The selected drain still
  cordons the whole node, preventing new ordinary pods from scheduling there;
  existing monitoring and other unselected pods remain running.
- Have `kubectl` access to create workloads and PDBs, evict pods, and cordon and
  uncordon nodes. Check the target before proceeding:

```sh
set -euo pipefail
umask 077
RUN_DIR="$PWD/.local/node-drain/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN_DIR"
kubectl config current-context
kubectl get nodes
```

After execution, review and sanitize copies of `drain-blocked.txt`,
`diagnosis.txt`, `drain-retry.txt`, and `recovery.txt` from `$RUN_DIR` into
`evidence/node-drain/`. Its empty files are capture placeholders, not results.

## 1. Deploy the failure scenario

The manifest creates a dedicated `lab02` namespace, a stateless nginx Deployment
with exactly one replica, and a matching PDB with `minAvailable: 1`.

```sh
kubectl apply -f kubernetes/chaos/node-drain-failure.yaml
# Equivalent shortcut: make lab02-trigger
kubectl -n lab02 rollout status deployment/drain-demo --timeout=120s
kubectl -n lab02 get pods -l app=drain-demo -o wide

NODE=$(kubectl -n lab02 get pods -l app=drain-demo -o jsonpath='{.items[0].spec.nodeName}')
test -n "$NODE" && printf 'Node for selected-pod eviction: %s\n' "$NODE"
printf '%s\n' "$NODE" > "$RUN_DIR/node.txt"
# Start with a schedulable node; cleanup will uncordon this same node.
kubectl get node "$NODE" -o json | jq -e '.spec.unschedulable != true'
# --pod-selector matches labels across namespaces, not just lab02.
kubectl get pods -A --field-selector "spec.nodeName=$NODE" \
  -l app=drain-demo -o json > "$RUN_DIR/selected-before.json"
jq -e '.items | length == 1 and all(.[]; .metadata.namespace == "lab02")' \
  "$RUN_DIR/selected-before.json"
kubectl get pods -A --field-selector "spec.nodeName=$NODE" -o wide \
  > "$RUN_DIR/node-pods-before.txt"
kubectl -n lab02 get pdb/drain-demo -o yaml > "$RUN_DIR/pdb-before.yaml"
```

Only proceed once the pod is Ready and `NODE` is populated. If rollout fails,
use `kubectl -n lab02 describe pods -l app=drain-demo` to resolve image, capacity,
or readiness problems first.

## 2. Attempt the selected-pod drain

```sh
drain_rc=0
kubectl drain "$NODE" --pod-selector=app=drain-demo --ignore-daemonsets --timeout=60s \
  > "$RUN_DIR/drain-blocked.txt" 2>&1 || drain_rc=$?
printf 'exit_code=%s\n' "$drain_rc" >> "$RUN_DIR/drain-blocked.txt"
cat "$RUN_DIR/drain-blocked.txt"
test "$drain_rc" -ne 0
```

Expect repeated eviction failures mentioning the pod's disruption budget, such
as `Cannot evict pod as it would violate the pod's disruption budget`, followed
by a timeout. Without a timeout the command can keep retrying indefinitely.
Unselected pods are left in place, including monitoring. `--ignore-daemonsets`
also leaves any selected DaemonSet pods alone. A nonzero exit alone is not proof:
require the output to identify `lab02/drain-demo` and its PDB as the blocker.

The node is cordoned before eviction starts. It remains unschedulable even when
the drain times out or you interrupt it. Keep it cordoned while applying a fix
so new replicas land on another node. If drain stops for a different reason,
such as another workload's local storage or unmanaged pods, inspect that error;
do not assume every drain failure is this PDB.

## 3. Diagnose the budget

```sh
{
  date -u +%FT%TZ
  kubectl -n lab02 get pdb
  kubectl -n lab02 describe pdb drain-demo
  kubectl -n lab02 get pods -l app=drain-demo -o wide
  kubectl get node "$NODE"
} > "$RUN_DIR/diagnosis.txt" 2>&1
cat "$RUN_DIR/diagnosis.txt"
```

After the PDB controller reconciles, expect a row like this (age varies):

```text
NAME         MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
drain-demo   1               N/A               0                     1m
```

`describe pdb` should report one current healthy pod, one desired healthy pod,
and one total pod. `ALLOWED DISRUPTIONS` is zero: evicting the only Ready pod
would leave zero available, violating `minAvailable: 1`. The selector matches
the Deployment's pod labels, so the budget applies to this pod.

Drain uses the eviction API, which respects PDBs. This is an availability
constraint, not a stuck application. A PDB does not create extra replicas, and
the Deployment does not start a replacement merely because an eviction was
denied. See the Kubernetes documentation on
[disruption budgets](https://kubernetes.io/docs/tasks/run-application/configure-pdb/)
and [node draining](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/).

## 4. Fix it: choose one option

### Option A: Scale the application to preserve availability

Leave `minAvailable: 1` in place and add another replica:

```sh
kubectl -n lab02 scale deployment/drain-demo --replicas=2
kubectl -n lab02 rollout status deployment/drain-demo --timeout=120s
kubectl -n lab02 get pods -l app=drain-demo -o wide
kubectl -n lab02 get pdb drain-demo
```

Verify both pods are Ready and the new pod is on another node. Once the PDB
reconciles, `ALLOWED DISRUPTIONS` becomes `1`. If the new pod stays Pending,
describe it and resolve capacity, taints, or scheduling constraints; scaling
alone cannot fix the budget until the additional pod is healthy.

### Option B: Correct the PDB if downtime is acceptable

For a workload that intentionally runs one replica and can tolerate a maintenance
outage, allow that replica to be unavailable. From the original failure state:

```sh
kubectl -n lab02 patch pdb drain-demo --type=merge -p '{"spec":{"minAvailable":0}}'
kubectl -n lab02 get pdb drain-demo
```

After reconciliation, `ALLOWED DISRUPTIONS` becomes `1`. Evicting the only pod
causes an outage until its replacement becomes Ready. Alternatively, define
`maxUnavailable: 1` and remove `minAvailable` entirely; a PDB cannot specify
both fields. Choose the budget according to the application's actual availability
requirement. `minAvailable: 1` is valid, but incompatible with evicting a sole
healthy replica while preserving availability.

## 5. Retry and verify recovery

After either fix:

```sh
# Record the chosen remediation and reconciled budget before retrying.
kubectl -n lab02 get deployment/drain-demo pdb/drain-demo -o yaml \
  > "$RUN_DIR/remediation.yaml"
kubectl -n lab02 get pdb/drain-demo -o json | jq -e '.status.disruptionsAllowed >= 1'
# Recheck the selector scope before each eviction attempt.
kubectl get pods -A --field-selector "spec.nodeName=$NODE" -l app=drain-demo -o json \
  | jq -e '.items | length > 0 and all(.[]; .metadata.namespace == "lab02")'
retry_rc=0
kubectl drain "$NODE" --pod-selector=app=drain-demo --ignore-daemonsets --timeout=180s \
  > "$RUN_DIR/drain-retry.txt" 2>&1 || retry_rc=$?
printf 'exit_code=%s\n' "$retry_rc" >> "$RUN_DIR/drain-retry.txt"
cat "$RUN_DIR/drain-retry.txt"
test "$retry_rc" -eq 0
{
  date -u +%FT%TZ
  kubectl -n lab02 rollout status deployment/drain-demo --timeout=180s
  kubectl -n lab02 get pods -l app=drain-demo -o wide
  kubectl -n lab02 get pods -l app=drain-demo --field-selector "spec.nodeName=$NODE" \
    -o json | jq -e '.items | length == 0'
  kubectl get node "$NODE"
  kubectl get pods -A --field-selector "spec.nodeName=$NODE" -o wide
} > "$RUN_DIR/recovery.txt" 2>&1
cat "$RUN_DIR/recovery.txt"
```

Expect selected-pod eviction to complete and the application pods to become
Ready on other nodes. The original node remains `SchedulingDisabled`, with
unselected workloads still present. Compare `node-pods-before.txt` with the
recovery capture to inspect monitoring placement. This is not a full-node drain
or evidence that the node is safe for maintenance. If it fails for a different
reason, inspect the named pod and selector scope; do not widen the drain or
bypass eviction checks to make the exercise pass.

The fixes above change live resources. For a lasting configuration change,
also update the Deployment replica count or PDB in the source manifest. This
repository's manifest intentionally retains the failure scenario; reapplying
it resets the replica count and budget.

## 6. Cleanup (also after an interrupted or failed attempt)

```sh
kubectl uncordon "$NODE"
kubectl get node "$NODE" -o yaml > "$RUN_DIR/node-after-cleanup.yaml"
kubectl delete -f kubernetes/chaos/node-drain-failure.yaml
```

Deletion removes the dedicated namespace and its contents. If you opened a new
shell, recover the original node name from this run’s `node.txt` before running
`uncordon`. To try the other fix, clean up and repeat from step 1 so the lab
starts with one replica and `minAvailable: 1` again.

The commands capture actual failure, diagnosis, remediation, successful eviction,
and restored scheduling under `$RUN_DIR`. Inspect and sanitize these files before
sharing; do not treat the expected behavior above as an observed result.

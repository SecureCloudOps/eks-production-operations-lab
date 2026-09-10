# Lab 05: Networking & Ingress Outage

Debug an ingress outage by separating a wrong backend port from a NetworkPolicy
drop. Start with the port failure alone, fix it, then introduce the policy. This
keeps one failure from masking the other. To reproduce both faults at once, apply
both manifests in order; remove the policy while diagnosing the port problem.

## Understand the path

With this lab's ALB `target-type: ip`, the data path is:

```text
Client -> ALB listener :80 -> application pod IP :8080 (wrong)
                              application listens on :3000

Ingress backend -> Service port -> Service targetPort -> registered pod target
       8080              8080               8080                 wrong port
```

The Ingress references a **Service port**, not a container port. A Service at
8080 forwarding to targetPort 3000 can be valid Kubernetes routing; the deliberate
bug here is `targetPort: 8080` too. `containerPort` is metadata and does not make
a process listen there. The Python process explicitly binds `0.0.0.0:3000`.

The AWS Load Balancer Controller normally runs in `kube-system` and reconciles
AWS resources. It is not a reverse proxy. In IP mode, the target group contains
application pod IPs, not controller pods. Allowing `kube-system` alone will not
allow ALB traffic. See the controller's
[traffic modes](https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/main/docs/how-it-works.md).

## 1. Prerequisites

- Use a disposable EKS lab cluster; the internet-facing ALB exposes HTTP and
  incurs charges. Run commands from the repository root in the same shell.
- Enable the Terraform-managed AWS Load Balancer Controller and its `alb`
  IngressClass via [the controller setup](../docs/load-balancer-controller.md).
  Public subnet discovery tags already exist; verify the controller is healthy.
- Have `kubectl` access and AWS read permissions for ELBv2 and EC2 diagnostics.
  Set the AWS CLI region to the cluster region and reach the private EKS API.
- The existing Terraform VPC CNI add-on now enables native NetworkPolicy in
  `standard` mode. Complete [the native enforcement preflight](../docs/lab05-network-policy.md)
  **before step 2**, including its allow → deny → allow test. Apply the reviewed
  CNI configuration before creating these lab pods; no second CNI is required.
- Use a fresh `lab05` namespace with no other policies. Existing ingress or probe
  egress restrictions, admission controls, or cluster-wide policies can change
  the results. The probe pods below use ordinary pod networking, not host networking.

```sh
kubectl config current-context
kubectl get ingressclass alb
kubectl -n kube-system get deployment aws-load-balancer-controller
kubectl -n kube-system get daemonset aws-node -o yaml
```

The linked preflight verifies the managed add-on, Linux kernel, `aws-node`
rollout, policy-agent flag, controller ConfigMap, PolicyEndpoint CRD, and actual
packet enforcement. Presence of the agent or acceptance of a NetworkPolicy alone
is not a pass. Keep its timestamped capture; step 6 then tests the lab-specific
policy after the deliberate Service-port failure has been fixed.

### Evidence and cleanup guard

After completing and cleaning up the linked preflight, start a dedicated Bash
shell and keep all remaining steps in it. The EXIT trap attempts cleanup on
success, command failure, or Ctrl-C; it preserves the original failure status.
It cannot handle SIGKILL or a lost machine. Keep the evidence directory and
rerun cleanup after restoring access if an API request fails. No other operator
should create resources with these lab names during the run.

During diagnosis, save the ALB ARN and every target group ARN, including any
group replaced by the port fix. Capture ownership tags and associated security
groups/ENIs before removing the Ingress. Distinguish the dedicated ALB security
group from the controller's shared backend group. The trap below intentionally
leaves the namespace for the final AWS verification and namespace cleanup.

```bash
bash
set -euo pipefail
umask 077
LAB05_RAW=$(mktemp -d "$PWD/.local/lab05-run.XXXXXX")
# The preflight creates .local. Refuse to adopt existing resources.
test -z "$(kubectl get namespace lab05 --ignore-not-found -o name)"
test -z "$(kubectl -n kube-system get pod lab05-probe --ignore-not-found -o name)"
lab05_cleanup() {
  local failed=0
  printf '%s cleanup started\n' "$(date -u +%FT%TZ)"
  kubectl -n lab05 delete ingress web --ignore-not-found --timeout=180s || failed=1
  kubectl -n lab05 delete networkpolicy web-same-namespace-only --ignore-not-found --timeout=60s || failed=1
  kubectl -n kube-system delete pod lab05-probe --ignore-not-found --timeout=60s || failed=1
  kubectl -n lab05 delete pod lab05-probe --ignore-not-found --timeout=60s || failed=1
  # Kubernetes deletion does not prove asynchronous AWS deletion completed.
  # Always retain the namespace until the AWS checks at the end of this lab pass.
  printf '%s entry-point cleanup exit=%s; namespace retained pending AWS deletion checks\n' "$(date -u +%FT%TZ)" "$failed"
  return "$failed"
}
lab05_exit() {
  local original=$? cleanup_rc=0
  trap - EXIT INT TERM
  lab05_cleanup >> "$LAB05_RAW/cleanup.txt" 2>&1 || cleanup_rc=$?
  if [ "$cleanup_rc" -ne 0 ]; then
    printf 'Cleanup incomplete: inspect %s/cleanup.txt and retry; keep the controller running.\n' "$LAB05_RAW" >&2
    if [ "$original" -eq 0 ]; then original=$cleanup_rc; fi
  fi
  exit "$original"
}
trap lab05_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
```

## 2. Reproduce the wrong-port failure

```sh
kubectl apply -f kubernetes/chaos/ingress-outage.yaml
kubectl -n lab05 rollout status deployment/web --timeout=180s
kubectl -n lab05 get ingress,service,pods -o wide
kubectl -n lab05 describe ingress web
```

Wait for an ALB hostname, then request the application:

A hostname can be assigned while the ALB is still provisioning. Confirm AWS
reports the ALB active and its hostname resolves before attributing an HTTP
failure to the backend. Curl exit `6` means DNS resolution failed; preserve that
capture and repeat after provisioning. It does not demonstrate the wrong-port
failure.

```sh
LAB05_HOST=$(kubectl -n lab05 get ingress web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
test -n "$LAB05_HOST"
LAB05_WRONG_PORT_RC=0
curl -i --max-time 75 "http://$LAB05_HOST/" > "$LAB05_RAW/wrong-port-http.txt" 2>&1 || LAB05_WRONG_PORT_RC=$?
printf '%s curl_exit=%s\n' "$(date -u +%FT%TZ)" "$LAB05_WRONG_PORT_RC" >> "$LAB05_RAW/wrong-port-http.txt"
cat "$LAB05_RAW/wrong-port-http.txt"
```

A connection reset/refusal from the wrong backend port can produce **502 Bad
Gateway**. A silently dropped connection is more likely to produce a timeout or
504. No registered targets can produce 503. Do not require one exact status to
diagnose the fault. If all registered targets are unhealthy, ALB can fail open
and still route to them. Health checks are evidence, not a guarantee that no
request reaches an unhealthy target. Consult AWS's
[ALB troubleshooting](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-troubleshooting.html)
and [target health behavior](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html).

## 3. Inspect AWS target group health

Find the controller-created TargetGroupBinding for the `web` Service:

```sh
kubectl -n lab05 get targetgroupbindings -o wide
LAB05_TG_ARN=$(kubectl -n lab05 get targetgroupbindings \
  -o jsonpath='{.items[?(@.spec.serviceRef.name=="web")].spec.targetGroupARN}')
aws elbv2 describe-target-groups --target-group-arns "$LAB05_TG_ARN" \
  --query 'TargetGroups[].{Type:TargetType,Port:Port,Protocol:Protocol,HealthPort:HealthCheckPort,HealthPath:HealthCheckPath}'
aws elbv2 describe-target-health --target-group-arn "$LAB05_TG_ARN" \
  --query 'TargetHealthDescriptions[].{IP:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}'
```

Only run AWS commands once exactly one matching ARN is populated. In the AWS
console, the equivalent is **EC2 -> Target Groups -> selected group -> Targets**.
Compare the registered IP and port against the pod IP and actual listener.

Expect port `8080` and unhealthy targets after health checks run. Record the full
description: `Target.FailedHealthChecks` suggests a connection or response
problem; `Target.Timeout` suggests a timeout; `Target.ResponseCodeMismatch`
indicates an HTTP response outside the matcher. None uniquely identifies a
NetworkPolicy. If there is no TargetGroupBinding or no target, investigate
reconciliation, selectors, readiness, and endpoints first.

## 4. Read controller logs and trace the Kubernetes port mapping

```sh
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller \
  --all-containers=true --prefix=true --since=20m --tail=300
kubectl -n lab05 get events --sort-by=.lastTimestamp
kubectl -n lab05 get ingress web -o yaml
kubectl -n lab05 get service web -o yaml
kubectl -n lab05 get endpointslices -l kubernetes.io/service-name=web -o yaml
kubectl -n lab05 logs deployment/web --tail=30
```

Look for reconciliation failures, missing Service ports, IAM denials, subnet
discovery errors, and target registration errors. Successful reconciliation does
not prove HTTP connectivity. Controller logs are not request logs or a packet
drop log. Use ALB access logs if already enabled to compare `elb_status_code`,
`target_status_code`, and the target address; a missing target response helps
separate load-balancer-generated errors from application-generated errors.

The EndpointSlice should show a Ready pod endpoint at `8080` even though its
readiness probe checks `3000`. Readiness proves that probe succeeded; it does
not validate the Service's targetPort.

Test the process locally inside the application container:

```sh
kubectl -n lab05 exec deployment/web -- python -c \
  'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:3000/", timeout=3).read().decode())'
```

Expect HTTP 200 content. Loopback bypasses the remote network path, so success
isolates the running application but does not clear policies or security groups.

## 5. Fix the port chain and establish a healthy baseline

Align Service port, targetPort, and Ingress backend to `3000`:

```sh
kubectl -n lab05 patch service web --type=json -p='[
  {"op":"replace","path":"/spec/ports/0/port","value":3000},
  {"op":"replace","path":"/spec/ports/0/targetPort","value":3000}
]'
kubectl -n lab05 patch ingress web --type=json -p='[
  {"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/port/number","value":3000}
]'
```

All three ports are aligned to avoid the native VPC CNI's documented Service-port
considerations during the next stage; see
[AWS network policy considerations](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy.html).
This is not a general Kubernetes requirement that Service and container ports
always match.

Wait for controller reconciliation and healthy targets, then run the healthy HTTP check below.
Re-read `LAB05_TG_ARN` using step 3 because changing the Service port can replace
the target group. Verify the new target port is `3000` and HTTP returns 200
before proceeding. If it does not, resolve security groups, subnet routing,
NACLs, or other policies before adding another failure.

```bash
test "$(curl -sS --connect-timeout 3 --max-time 10 -o "$LAB05_RAW/alb-before-body.txt" \
  -w '%{http_code}' "http://$LAB05_HOST/")" = 200
```

## 6. Introduce and isolate the NetworkPolicy drop

Define a capture helper, then create two temporary diagnostic pods. The remote
wrapper records curl's exit separately from `kubectl exec` errors. Each attempt
preserves timestamp, response body/status, stderr, and both exit codes. Only
curl timeout 28 is an expected policy-drop candidate; refusal (7), DNS errors,
exec failures, or HTTP errors are not accepted as proof of this policy.

```bash
lab05_probe() {
  local namespace=$1 label=$2 exec_rc=0
  local output="$LAB05_RAW/$label.txt"
  printf '%s namespace=%s target=%s:3000\n' "$(date -u +%FT%TZ)" "$namespace" "$LAB05_POD_IP" > "$output"
  kubectl -n "$namespace" exec lab05-probe -- sh -c '
    rc=0
    curl -sv --connect-timeout 3 --max-time 5 -w "\nLAB05_HTTP=%{http_code}\n" "$1" || rc=$?
    printf "\nLAB05_CURL_EXIT=%s\n" "$rc"
  ' sh "http://$LAB05_POD_IP:3000/" >> "$output" 2>&1 || exec_rc=$?
  printf 'kubectl_exit=%s\n' "$exec_rc" >> "$output"
  cat "$output"
  if [ "$exec_rc" -ne 0 ]; then return "$exec_rc"; fi
  LAB05_PROBE_RC=$(sed -n 's/^LAB05_CURL_EXIT=//p' "$output")
  LAB05_PROBE_HTTP=$(sed -n 's/^LAB05_HTTP=//p' "$output")
  [[ "$LAB05_PROBE_RC" =~ ^[0-9]+$ ]]
}
lab05_require_healthy() {
  test "$LAB05_PROBE_RC" = 0
  test "$LAB05_PROBE_HTTP" = 200
}
lab05_same_target() {
  test "$(kubectl -n lab05 get pods -l app=lab05-web -o jsonpath='{.items[0].metadata.uid}')" = "$LAB05_POD_UID"
  test "$(kubectl -n lab05 get pods -l app=lab05-web -o jsonpath='{.items[0].status.podIP}')" = "$LAB05_POD_IP"
}
```

Create two temporary diagnostic pods, one in each namespace:

```sh
kubectl -n lab05 run lab05-probe --image=curlimages/curl:8.12.1 \
  --labels=purpose=lab05-probe --restart=Never --command -- sleep 3600
kubectl -n kube-system run lab05-probe --image=curlimages/curl:8.12.1 \
  --labels=purpose=lab05-probe --restart=Never --command -- sleep 3600
kubectl -n lab05 wait --for=condition=Ready pod/lab05-probe --timeout=120s
kubectl -n kube-system wait --for=condition=Ready pod/lab05-probe --timeout=120s
LAB05_POD_IP=$(kubectl -n lab05 get pods -l app=lab05-web -o jsonpath='{.items[0].status.podIP}')
LAB05_POD_UID=$(kubectl -n lab05 get pods -l app=lab05-web -o jsonpath='{.items[0].metadata.uid}')
lab05_probe lab05 allowed-before
lab05_require_healthy
lab05_probe kube-system cross-before
lab05_require_healthy
```

Both requests should succeed before the policy. They use a literal pod IP to
exclude DNS and Service translation from the experiment. If a rollout changes
the pod identity or IP, stop and repeat the baseline in a fresh run. Now add the second manifest:

```sh
kubectl apply -f kubernetes/chaos/ingress-network-policy.yaml
kubectl -n lab05 describe networkpolicy web-same-namespace-only
kubectl -n lab05 get networkpolicy
kubectl -n kube-system get networkpolicy
kubectl get namespace lab05 kube-system --show-labels
```

Wait for policy reconciliation with at most 24 attempts, preserving each result.
A healthy same-namespace control, unchanged target, prior cross-namespace success,
and subsequent recovery after deleting only the policy are all required. A
timeout alone does not establish the cause.

```bash
kubectl -n lab05 get networkpolicy web-same-namespace-only -o yaml > "$LAB05_RAW/policy.yaml"
kubectl -n lab05 get service web -o yaml > "$LAB05_RAW/service-before-policy-check.yaml"
LAB05_DENIED=0
for attempt in $(seq 1 24); do
  lab05_same_target
  lab05_probe lab05 "allowed-during-$attempt"
  lab05_require_healthy
  lab05_probe kube-system "cross-during-$attempt"
  if [ "$LAB05_PROBE_RC" = 28 ] && [ "$LAB05_PROBE_HTTP" = 000 ] && \
      grep -q 'curl: (28)' "$LAB05_RAW/cross-during-$attempt.txt"; then
    LAB05_DENIED=1
    break
  fi
  # Only continued HTTP 200 is tolerated while policy reconciliation is pending.
  lab05_require_healthy
  sleep 5
done
test "$LAB05_DENIED" = 1
printf '%s expected timeout observed; attribution pending recovery\n' "$(date -u +%FT%TZ)" >> "$LAB05_RAW/result.txt"
```

Expected results:

| Request | Before policy | After policy |
| --- | --- | --- |
| App loopback, port 3000 | Success | Success |
| `lab05` probe -> pod:3000 | Success | Success |
| `kube-system` probe -> pod:3000 | Success | Timeout/drop |
| ALB -> pod:3000 | Healthy / HTTP 200 | Health checks fail; client errors/timeouts |

The policy selects only `app=lab05-web`, isolates ingress, and permits TCP 3000
only from the `lab05` namespace. It omits `kube-system` and also has no allowance
for ALB source addresses. Standard NetworkPolicies are additive allow rules:
another matching policy may allow a path this one omits. Node/host-network
traffic has special behavior, which is why the experiment uses normal pods.
See [Kubernetes NetworkPolicy semantics](https://kubernetes.io/docs/concepts/services-networking/network-policies/).

An ALB is not a Kubernetes namespace member. Its requests cannot match a
`namespaceSelector: kube-system` rule. The two failures above are distinct
consequences of the same overly narrow policy, not evidence that the controller
proxies ALB requests.

For a controlled A/B check, remove only this lab policy and repeat the probes:

```sh
kubectl delete -f kubernetes/chaos/ingress-network-policy.yaml --wait=true --timeout=120s
LAB05_RECOVERED=0
for attempt in $(seq 1 24); do
  lab05_same_target
  lab05_probe lab05 "allowed-after-$attempt"
  lab05_require_healthy
  lab05_probe kube-system "cross-after-$attempt"
  if [ "$LAB05_PROBE_RC" = 0 ] && [ "$LAB05_PROBE_HTTP" = 200 ]; then
    LAB05_RECOVERED=1
    break
  fi
  # Permit only the previous timeout while deletion propagates.
  test "$LAB05_PROBE_RC" = 28
  test "$LAB05_PROBE_HTTP" = 000
  sleep 5
done
test "$LAB05_RECOVERED" = 1
printf '%s PASS: same target allowed -> timeout -> allowed; same-namespace control healthy\n' \
  "$(date -u +%FT%TZ)" >> "$LAB05_RAW/result.txt"
```

If the blocked probe recovers while the application and port mapping stay fixed,
that strongly implicates the policy. Allow health-check convergence before
expecting ALB recovery. If traffic stays blocked, examine source egress policy,
security groups, NACLs, routing, and endpoint IPs. If it never blocks, verify
enforcement and additional allow policies instead of claiming a successful drop.

## 7. Distinguish a policy drop from AWS network filtering

Resolve the ALB and inspect its security groups and subnets:

```sh
LAB05_ALB_ARN=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?DNSName=='$LAB05_HOST'].LoadBalancerArn | [0]" --output text)
aws elbv2 describe-load-balancers --load-balancer-arns "$LAB05_ALB_ARN" \
  --query 'LoadBalancers[].{SecurityGroups:SecurityGroups,Subnets:AvailabilityZones[].SubnetId}'
aws ec2 describe-network-interfaces --filters "Name=addresses.private-ip-address,Values=$LAB05_POD_IP" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Groups:Groups,Subnet:SubnetId}'
```

Use the resulting group IDs with `aws ec2 describe-security-groups --group-ids
<ids>` and subnet IDs with `aws ec2 describe-network-acls --filters
Name=association.subnet-id,Values=<subnet-id>`. Verify ALB egress and target
ingress permit TCP 3000, and stateless NACLs permit requests and return traffic.
Inspect the actual pod/node ENI rules and any security groups for pods rather
than assuming the controller has managed every rule. Prefix delegation can make
the exact-address ENI lookup incomplete; inspect the hosting node's ENIs as needed.

VPC Flow Logs, if enabled, can help identify SG/NACL rejects. An `ACCEPT` record
does not rule out a later in-node CNI drop. For native VPC CNI, inspect the policy
agent on the node hosting the application; detailed deny events require its
network policy event logging to be enabled. This lab does not require event-log
export or extra IAM permissions. The preflight and step 6 provide packet-level
behavior checks; controller logs will not show each dropped data packet.

After execution and cleanup, review and sanitize copies of `wrong-port-http.txt`,
`result.txt`, and `cleanup.txt` from `$LAB05_RAW` into `evidence/ingress-outage/`.
The empty files are capture placeholders; leave missing observations empty.

## 8. Make the intended policy explicit and clean up

For this disposable lab, removing the faulty policy after correcting the port
mapping restores connectivity. A lasting restricted policy needs separate
allowances for the actual sources:

- Permit only the required diagnostic pods from `kube-system`, if this access is
  intended. Put a `namespaceSelector` for `kubernetes.io/metadata.name: kube-system`
  and a `podSelector` for `purpose: lab05-probe` in the **same** `from` item to
  require both labels. Limit the destination port to TCP 3000.
- Permit ALB traffic and health checks on TCP 3000 from the actual ALB subnet
  CIDRs using `ipBlock` rules, accounting for the source addresses observed by
  your CNI. Get those CIDRs from the ALB's subnet IDs rather than hardcoding
  individual ALB IPs. Maintain the target security-group allowance from the ALB's
  security group too. Namespace rules cannot substitute for this ALB path.

Verify each allowed source and an unrelated denied source before accepting a
replacement policy. Adding only a `kube-system` exception fixes that probe but
does not fix ALB access. Persist the corrected port mapping and intended policy
in your deployment source; the supplied files deliberately retain the faults.

Record the HTTP status, target health reason, registered port, relevant controller
logs, and before/after probe results under `$LAB05_RAW`. After ALB health-check
convergence, require HTTP recovery before ending the dedicated shell:

```bash
test "$(curl -sS --connect-timeout 3 --max-time 10 -o "$LAB05_RAW/alb-after-body.txt" \
  -w '%{http_code}' "http://$LAB05_HOST/")" = 200
# Runs the EXIT cleanup trap; any earlier unexpected failure also runs it.
exit
```

The trap writes `cleanup.txt` and attempts every independent entry-point/probe
cleanup operation, even if one fails. It always retains the namespace until AWS
deletion has been verified. Preserve the evidence, restore access,
and rerun the named deletions from `lab05_cleanup` if cleanup was incomplete.

After entry-point cleanup, use `aws elbv2 wait load-balancers-deleted` with the
recorded ALB ARN and explicit region. Verify each recorded target group and
dedicated security group is absent and the associated ENIs are released. Treat
only the corresponding resource-not-found response or a successful empty
inventory as absence; authorization errors and timeouts are failures. Keep the
controller and namespace running if any deletion remains unresolved. Do not
strip finalizers or manually delete shared AWS resources.

Only after these checks pass, remove the owned namespace:

```sh
kubectl delete namespace lab05 --wait=true --timeout=180s
kubectl get namespace lab05 --ignore-not-found -o name
```

The final query must succeed with empty output. Record this separately from the
trap's entry-point cleanup result; preserve shared workloads and infrastructure.

See [the sanitized execution evidence](../evidence/ingress-outage/summary.md)
for the observed wrong-port and policy failures, recoveries, and cleanup checks.

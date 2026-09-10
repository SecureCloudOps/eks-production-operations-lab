# Lab 01 — EKS 1.35 → 1.36 under live traffic

## Objective and version gate

Upgrade the control plane, then roll the Bottlerocket managed node groups while
an independent client measures HTTP availability. Produce real, timestamped
outputs for every evidence file; an empty file or an example result is not a pass.

This lab upgrades an existing Terraform-managed **1.35** cluster to **1.36**.
AWS supports this adjacent-version upgrade; confirm availability in your region
at execution time using the [EKS version lifecycle](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)
and [upgrade procedure](https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html).
Never downgrade a newer baseline or plan against missing state.

Terraform remains authoritative throughout. `cluster_version` controls only the
control plane; `node_group_versions` explicitly sets canary, apps, and system.
Defaults remain 1.35. For any existing deployment, first set these inputs to its
actual versions; adding the new input must not accidentally request a downgrade.
Workers must never be newer than the control plane; this lab permits only the
equal-version or one-minor-behind combinations below. Keep one operator, one
state/workspace, and one authoritative local
`terraform/terraform.tfvars`. Preserve all unrelated inputs and use no version
`-var` overrides, auto tfvars overrides, `-target`, or concurrent applies.

| Stage | Control plane | Canary | Apps | System | Gate before advancing |
| --- | --- | --- | --- | --- | --- |
| Preflight (§1–4) | 1.35 | 1.35 | 1.35 | 1.35 | Compatibility, healthy baseline, no unexplained drift |
| Control-plane upgrade (§5) | 1.36 | 1.35 | 1.35 | 1.35 | Reviewed saved plan; no worker rollout |
| Health validation (§5a) | 1.36 | 1.35 | 1.35 | 1.35 | API, add-ons, DNS, workloads and traffic healthy |
| Canary upgrade (§6) | 1.36 | 1.36 | 1.35 | 1.35 | Canary bootstrap and health pass |
| Apps upgrade (§6) | 1.36 | 1.36 | 1.36 | 1.35 | Application and traffic health pass |
| System upgrade (§6) | 1.36 | 1.36 | 1.36 | 1.36 | System and add-on health pass |
| Final validation (§7–8) | 1.36 | 1.36 | 1.36 | 1.36 | Healthy capacity, evidence, no unexplained Terraform drift |

The apply commands below are **operator execution steps for a later run**.
Preparing this lab does not require creating AWS resources or running apply.
`make lab01-trigger` only points to this runbook; do not use `make up` for stages.

## 1. Prepare the operator, workload, and evidence directory

Use Bash for all shell blocks, from the repository root. Install AWS CLI v2,
Terraform, kubectl compatible with both cluster versions, Helm, jq, curl,
Python 3, and [kubent](https://github.com/doitintl/kube-no-trouble#install).
Follow the [identity and endpoint instructions](../docs/access.md) first. Preserve
local Terraform state and inputs as described there before and after any apply.
The operator needs Kubernetes inspection permissions (including Helm release
Secrets for kubent), EKS describe/list/update permissions, and EC2
`DescribeInstances`/`DescribeImages` access, plus ELBv2 describe permissions
for route readiness and deletion verification.

Prerequisites before measuring:

- The existing [HTTP baseline](../kubernetes/apps/http-demo.yaml), deployed
  with `make deploy-apps` before starting this exercise. It is `default/http-demo`:
  two replicas, ClusterIP port 80 → 8080, `/healthz` returning `ok`, probes,
  resource requests/limits, graceful shutdown, hostname spreading and PDB
  `minAvailable: 1`. No replica or PDB changes are needed. Require two Ready pods
  on distinct `workload=production-apps` nodes (the apps group is untainted).
  Verify spare CPU, memory and pod IPs. PDBs govern voluntary eviction, not
  sudden node failures.
- Enable `enable_load_balancer_controller = true` in the authoritative tfvars
  and complete the [existing controller setup](../docs/load-balancer-controller.md)
  while the control plane and all groups remain at 1.35. Keep it enabled through
  upgrade and route cleanup. The optional ALB route below must be healthy before
  measurement; never combine controller installation with an upgrade apply.
- Healthy monitoring in namespace `monitoring`, including kube-state-metrics.
  Verify the installed chart, CRDs, admission webhooks, controllers, and workload
  images support BOTH 1.35 and 1.36. The current Terraform chart pin is not proof
  of compatibility with this upgrade.
- EC2 quotas, instance availability, and subnet IP space for surge nodes; EKS
  control-plane subnet space as required by its upgrade checks. No other
  upgrades, chaos experiments, or voluntary scaling changes during measurement.

Keep the load generator outside all node groups being replaced. Do not use
`kubectl port-forward` as the application URL: it selects a pod and depends on
the API connection, so its failure would not measure the real service path.
Choose an uncached endpoint that actually reaches a backend and normally returns
HTTP 200. The probe below measures short HTTP requests, not long-lived sessions
or maximum throughput.

```bash
bash
set -euo pipefail
export AWS_PAGER=""
export AWS_REGION="$(terraform -chdir=terraform output -raw aws_region)"
export EKS_CLUSTER_NAME="$(terraform -chdir=terraform output -raw cluster_name)"
export SOURCE_VERSION=1.35 TARGET_VERSION=1.36
export APP_NS=default APP_DEPLOYMENT=http-demo
export APP_SELECTOR=app=http-demo
read -r -p 'Operator alias: ' OPERATOR_ALIAS
export OPERATOR_ALIAS
: "${OPERATOR_ALIAS:?}"
export RUN_DIR="$PWD/.local/cluster-upgrade/$(date -u +%Y%m%dT%H%M%SZ)"
umask 077
mkdir -p "$RUN_DIR" evidence/cluster-upgrade
mark() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$RUN_DIR/timeline.txt"; }
printf '%s\n' preflight > "$RUN_DIR/phase"
chmod 700 "$RUN_DIR"
# Raw evidence stays here until reviewed and sanitized in section 8.
printf '%s\n' "$RUN_DIR" > .local/cluster-upgrade/latest-run
aws sts get-caller-identity > "$RUN_DIR/identity.json"
kubectl config current-context
aws eks describe-cluster --name "$EKS_CLUSTER_NAME" > "$RUN_DIR/cluster-before.json"
aws eks describe-cluster-versions > "$RUN_DIR/versions.json"
jq '.cluster | {name,version,status,upgradePolicy}' "$RUN_DIR/cluster-before.json"
jq '.clusterVersions[] | select(.clusterVersion=="1.35" or .clusterVersion=="1.36")' \
  "$RUN_DIR/versions.json"
test "$(jq -r .cluster.version "$RUN_DIR/cluster-before.json")" = "$SOURCE_VERSION"
test "$(jq -r .cluster.status "$RUN_DIR/cluster-before.json")" = ACTIVE
kubectl get --raw=/version
```

Stop on a mismatched context/version, unavailable upgrade target, or active
update. Check region-specific version eligibility and EKS upgrade insights;
require both source and target to have `versionStatus` of `STANDARD_SUPPORT` or
`EXTENDED_SUPPORT`; stop if either entry is absent or unsupported.
Inspect the identity locally, but do not commit account IDs or credentials.

In the authoritative local tfvars, explicitly set the baseline (preserve other inputs):

```hcl
cluster_version = "1.35"
node_group_versions = {
  canary = "1.35"
  apps   = "1.35"
  system = "1.35"
}
```

```bash
terraform -chdir=terraform init -input=false -lockfile=readonly
terraform -chdir=terraform fmt -check
terraform -chdir=terraform validate
terraform -chdir=terraform plan -input=false -out="$RUN_DIR/baseline.tfplan"
terraform -chdir=terraform show -no-color "$RUN_DIR/baseline.tfplan" > "$RUN_DIR/baseline-plan.txt"
```

Review the baseline plan locally. Require no unexplained changes and no creates,
destroys, replacements, or version changes. Resolve drift separately and repeat
preflight before collecting upgrade traffic. Verify no active EKS cluster,
node-group or add-on updates. Never apply a baseline plan that would create a
missing cluster; baseline provisioning is outside this upgrade run.

### Prepare the external HTTP route before measurement

Run from the same operator/probe machine outside the cluster. This opt-in
[Ingress](../kubernetes/ingress/http-demo-ingress.yaml) uses the existing `alb`
class, tagged public subnets and IP targets: ALB HTTP :80 → Service backend
`http-demo:80` → pods :8080. Only `/healthz` is routed. It exposes synthetic
health data over public HTTP and incurs ALB charges until removed. No custom
DNS, certificate, shared IngressGroup, or additional controller is required.
The annotations follow the [controller documentation](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.14/guide/ingress/annotations/).

During the later authorized execution, run this before any upgrade plan:

```bash
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=5m
kubectl get ingressclass alb -o json | jq -e '.spec.controller == "ingress.k8s.aws/alb"'
kubectl -n default rollout status deployment/http-demo --timeout=5m
kubectl apply -f kubernetes/ingress/http-demo-ingress.yaml
kubectl -n default wait --for=jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
  ingress/lab01-http-demo --timeout=10m
LAB01_HOST=$(kubectl -n default get ingress lab01-http-demo \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
export APP_URL="http://$LAB01_HOST/healthz"
kubectl -n default get ingress lab01-http-demo -o yaml > "$RUN_DIR/route.yaml"
aws elbv2 describe-load-balancers > "$RUN_DIR/load-balancers.json"
LAB01_ALB_ARN=$(jq -er --arg host "$LAB01_HOST" \
  '.LoadBalancers[] | select(.DNSName == $host) | .LoadBalancerArn' "$RUN_DIR/load-balancers.json")
printf '%s\n' "$LAB01_ALB_ARN" > "$RUN_DIR/route-alb-arn.txt"
aws elbv2 wait load-balancer-available --load-balancer-arns "$LAB01_ALB_ARN"
# DNS and target health may lag Ingress status. Retry only this setup check.
route_ready=false
for attempt in $(seq 1 60); do
  if code=$(curl -sS --connect-timeout 2 --max-time 5 -o "$RUN_DIR/route-body.txt" \
      -w '%{http_code}' "$APP_URL") && [ "$code" = 200 ] && \
      [ "$(cat "$RUN_DIR/route-body.txt")" = ok ]; then
    route_ready=true
    break
  fi
  sleep 5
done
[ "$route_ready" = true ]
printf '%s url=%s HTTP=200 body=ok\n' "$(date -u +%FT%TZ)" "$APP_URL" > "$RUN_DIR/route-ready.txt"
```

Stop if readiness times out; inspect Ingress events, controller logs and target
health. Keep this same route throughout the five-minute baseline, all upgrade
stages and final validation. Section 4 records every request without retries.

## 2. Populate `preflight.txt`

Capture both scanner streams and its exit status. `kubent --exit-error` makes
findings fail the check; a collector error is also a blocker. Its live scan uses
stored original manifests and may miss resources without those records. Review
rendered deployment manifests, Helm charts, external API clients, and release
notes too; API discovery alone does not prove that clients use compatible APIs.
See [kubent usage and limits](https://github.com/doitintl/kube-no-trouble#usage).
This lab chooses kubent; `kubectl mapbu` is not needed.

```bash
{
  date -u +%FT%TZ
  printf 'source=%s target=%s\n' "$SOURCE_VERSION" "$TARGET_VERSION"
  cat "$RUN_DIR/cluster-before.json" "$RUN_DIR/versions.json"
  terraform version
  terraform -chdir=terraform workspace show
  kubectl config current-context
  kubectl version -o yaml
  kubent --version
  scan_rc=0
  kubent --target-version "$TARGET_VERSION" --exit-error || scan_rc=$?
  printf 'kubent_exit_code=%s\n' "$scan_rc"
  test "$scan_rc" -eq 0
  kubectl get nodes -o wide
  kubectl get pods -A -o wide
  kubectl get pdb -A
  kubectl -n "$APP_NS" get deployment "$APP_DEPLOYMENT" -o yaml
  kubectl -n "$APP_NS" get service/http-demo configmap/http-demo pdb/http-demo -o yaml
  helm list -n monitoring
  aws eks list-insights --cluster-name "$EKS_CLUSTER_NAME" \
    --filter "categories=UPGRADE_READINESS,kubernetesVersions=$TARGET_VERSION"
} > "$RUN_DIR/preflight.txt" 2>&1
cat "$RUN_DIR/preflight.txt"
```

Run blocks individually and stop on failure. If the scanner fails, preserve the
failed file, fix its findings or permissions, then save a fresh dated attempt.
For each insight ID returned, append the detailed result:

```bash
aws eks list-insights --cluster-name "$EKS_CLUSTER_NAME" \
  --filter "categories=UPGRADE_READINESS,kubernetesVersions=$TARGET_VERSION" \
  > "$RUN_DIR/insights.json"
while IFS= read -r insight; do
  aws eks describe-insight --cluster-name "$EKS_CLUSTER_NAME" --id "$insight" \
    >> "$RUN_DIR/preflight.txt" 2>&1
done < <(jq -r '.insights[].id' "$RUN_DIR/insights.json")
```

No insights is not an automatic pass. Resolve errors, review warnings and stale
checks, and record the disposition. Inspect add-on compatibility for BOTH minors:

```bash
aws eks list-addons --cluster-name "$EKS_CLUSTER_NAME" > "$RUN_DIR/addons.json"
while IFS= read -r addon; do
  aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$addon" \
    >> "$RUN_DIR/preflight.txt"
  for version in "$SOURCE_VERSION" "$TARGET_VERSION"; do
    printf '\naddon=%s compatibility_target=%s\n' "$addon" "$version" \
      >> "$RUN_DIR/preflight.txt"
    aws eks describe-addon-versions --addon-name "$addon" --kubernetes-version "$version" \
      >> "$RUN_DIR/preflight.txt"
  done
 done < <(jq -r '.addons[]' "$RUN_DIR/addons.json")
```

Select explicit compatible releases for VPC CNI, CoreDNS, kube-proxy, Pod Identity
Agent, and any other installed add-ons. Put the four baseline release strings in
the `addon_versions` map in the authoritative tfvars; use the add-on names as keys. Record the choices and required order in
`preflight.txt`; apply any prerequisite add-on updates and validate health before
starting the control-plane update. The [add-on compatibility API](https://docs.aws.amazon.com/cli/latest/reference/eks/describe-addon-versions.html)
provides candidates, not an application compatibility test. Record a final
`GO` or `NO-GO` with reasons, UTC time, and operator alias.

Define these capture helpers once in the same Bash shell. Invocations record
actual output, including failures. The NGINX Alpine image supplies BusyBox
`nslookup` and `wget`; no diagnostic pod is created.

```bash
capture_addons() (
  set -euo pipefail
  date -u +%FT%TZ
  aws eks list-addons --cluster-name "$EKS_CLUSTER_NAME" > "$RUN_DIR/current-addons.json"
  while IFS= read -r addon; do
    aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$addon" \
      > "$RUN_DIR/current-addon.json"
    cat "$RUN_DIR/current-addon.json"
    jq -e '.addon | .status == "ACTIVE" and (.health.issues | length == 0)' \
      "$RUN_DIR/current-addon.json"
  done < <(jq -r '.addons[]' "$RUN_DIR/current-addons.json")
  helm list -n monitoring
)
capture_health() (
  set -euo pipefail
  phase="$1"
  date -u +%FT%TZ
  kubectl get --raw=/readyz
  kubectl -n default rollout status deployment/http-demo --timeout=5m
  kubectl -n default get deployment/http-demo -o json > "$RUN_DIR/$phase-deployment.json"
  cat "$RUN_DIR/$phase-deployment.json"
  jq -e '.spec.replicas == 2 and .status.availableReplicas == 2 and
    .status.observedGeneration == .metadata.generation' "$RUN_DIR/$phase-deployment.json"
  kubectl -n default get pods -l app=http-demo -o json > "$RUN_DIR/$phase-pods.json"
  jq -r '.items[] | [.metadata.name,.metadata.uid,.spec.nodeName,
    .metadata.creationTimestamp,.status.phase,
    ([.status.containerStatuses[]? | .ready] | tostring)] | @tsv' "$RUN_DIR/$phase-pods.json"
  kubectl -n default get pdb/http-demo -o json > "$RUN_DIR/$phase-pdb.json"
  cat "$RUN_DIR/$phase-pdb.json"
  jq -e '.spec.minAvailable == 1 and .status.currentHealthy == 2 and
    .status.disruptionsAllowed >= 1' "$RUN_DIR/$phase-pdb.json"
  kubectl -n default get endpointslices -l kubernetes.io/service-name=http-demo -o yaml
  kubectl -n default exec deployment/http-demo -- nslookup http-demo.default.svc.cluster.local
  kubectl -n default exec deployment/http-demo -- \
    wget -q -T 5 -O - http://http-demo.default.svc.cluster.local/healthz
  code=$(curl -sS --retry 0 --connect-timeout 2 --max-time 5 \
    -H 'Cache-Control: no-cache' -D "$RUN_DIR/$phase-http-headers.txt" \
    -o "$RUN_DIR/$phase-http-body.txt" -w '%{http_code}' "$APP_URL")
  printf '\nexternal_http=%s\n' "$code"
  cat "$RUN_DIR/$phase-http-headers.txt" "$RUN_DIR/$phase-http-body.txt"
  test "$code" = 200
  test "$(cat "$RUN_DIR/$phase-http-body.txt")" = ok
  kubectl -n kube-system rollout status deployment/coredns --timeout=5m
  kubectl get pods -A -o wide
  kubectl get pdb -A
)
capture_addons >> "$RUN_DIR/preflight.txt" 2>&1
capture_health before > "$RUN_DIR/before-health.txt" 2>&1
cat "$RUN_DIR/before-health.txt" >> "$RUN_DIR/preflight.txt"
jq -e '[.items[] | select(.metadata.deletionTimestamp == null) | .spec.nodeName] |
  length == 2 and (unique | length == 2)' "$RUN_DIR/before-pods.json"
```

The final assertion requires two distinct baseline nodes. Require a fresh
API/deprecation scan, reviewed insights, compatible installed add-on/chart
releases, and all health checks before measurement.

## 3. Populate `before-nodes.txt`: resolve nodes to actual EC2 AMIs

Do not infer the AMI from the kubelet version, OS name, or an SSM `latest`
parameter. Save each node's provider ID and resolve the EC2 instance's `ImageId`.
The EC2 value records the image actually used to launch it. Keep Bottlerocket
`osImage` too: an in-place OS update can change the running OS without changing
the launch AMI. Disable independent Bottlerocket update automation for this
controlled replacement exercise. See [EC2 instance descriptions](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instances.html).

Define this function in the operator shell; reuse it after the roll:

```bash
capture_nodes() (
  set -euo pipefail
  phase="$1"
  date -u +%FT%TZ
  aws eks describe-cluster --name "$EKS_CLUSTER_NAME" \
    --query 'cluster.{version:version,status:status}'
  kubectl get nodes -o json > "$RUN_DIR/$phase-nodes.json"
  jq -r '.items | sort_by(.metadata.name)[] |
    [.metadata.name, .metadata.labels["eks.amazonaws.com/nodegroup"],
     .spec.providerID, .status.nodeInfo.kubeletVersion, .status.nodeInfo.osImage,
     ([.status.conditions[] | select(.type=="Ready") | .status][0])] | @tsv' \
    "$RUN_DIR/$phase-nodes.json"
  while IFS= read -r instance_id; do
    test -n "$instance_id"
    aws ec2 describe-instances --instance-ids "$instance_id" \
      --query 'Reservations[].Instances[].{InstanceId:InstanceId,AMI:ImageId,State:State.Name,AZ:Placement.AvailabilityZone,LaunchTime:LaunchTime}'
    ami_id="$(aws ec2 describe-instances --instance-ids "$instance_id" \
      --query 'Reservations[0].Instances[0].ImageId' --output text)"
    test "$ami_id" != None
    aws ec2 describe-images --image-ids "$ami_id" \
      --query 'Images[].{AMI:ImageId,Name:Name,Created:CreationDate,Architecture:Architecture}'
  done < <(jq -r '.items[].spec.providerID | split("/")[-1]' \
    "$RUN_DIR/$phase-nodes.json" | sort -u)
  aws eks list-nodegroups --cluster-name "$EKS_CLUSTER_NAME" > "$RUN_DIR/$phase-groups.json"
  while IFS= read -r ng; do
    aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name "$ng" \
      --query 'nodegroup.{name:nodegroupName,version:version,release:releaseVersion,amiType:amiType,status:status,scaling:scalingConfig,update:updateConfig,health:health,launchTemplate:launchTemplate}'
  done < <(jq -r '.nodegroups[]' "$RUN_DIR/$phase-groups.json")
)
capture_nodes before > "$RUN_DIR/before-nodes.txt" 2>&1
cat "$RUN_DIR/before-nodes.txt"
```

Require all expected workers Ready, every group ACTIVE at 1.35, and
`BOTTLEROCKET_x86_64`. Preserve AMI IDs even if an old image is deregistered and
`describe-images` returns no metadata; explicitly annotate that limitation.
Expected minimal baseline: system=1, apps=2, canary=1. `system_node_count=2`
retains the former five-node layout. Record actual counts. The one-node system
group runs both CoreDNS replicas; require their enabled PDB with
`maxUnavailable: 1` and DEFAULT surge-before-drain updates. This supports
controlled maintenance, not DNS availability through an unexpected node failure.
Resolve the actual generated group names from this output; names need not equal
the logical Terraform keys.

## 4. Start live availability and Prometheus collection

In the operator shell, create and launch the two scripts below. They inherit the
AWS/kubeconfig environment and write locally even when cluster pods disappear.
Do not close the shell. Never overwrite an earlier run. Watch both output files
in another terminal and confirm at least five minutes of healthy baseline before
any update.

### HTTP probe → `workload-health.txt`

This sends up to roughly five requests/second, with one outstanding request,
no retries, and a five-second deadline. Every non-200 or curl
failure counts as an error; timeouts reduce achieved throughput. Increase load
with a separately documented load tool if testing throughput is part of your
experiment. Do not hide failures with retries or redirect following.

```bash
cat > "$RUN_DIR/probe.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
: "${APP_URL:?}" "${RUN_DIR:?}"
total=0; errors=0
printf '# started=%s interval_seconds=0.2 timeout_seconds=5 expected_http=200\n' "$(date -u +%FT%TZ)"
printf '# utc total errors http curl_exit latency_seconds phase outcome\n'
while [ ! -e "$RUN_DIR/stop" ]; do
  started=$(date -u +%FT%TZ)
  phase=$(cat "$RUN_DIR/phase")
  rc=0
  result=$(curl -sS --retry 0 --connect-timeout 2 --max-time 5 \
    -H 'Cache-Control: no-cache' -o /dev/null -w '%{http_code} %{time_total}' \
    "$APP_URL" 2>> "$RUN_DIR/curl-errors.txt") || rc=$?
  code=${result%% *}
  total=$((total + 1))
  outcome=success
  if [ "$rc" -ne 0 ] || [ "$code" != 200 ]; then
    errors=$((errors + 1)); outcome=failure
  fi
  printf '%s %s %s %s %s %s %s %s\n' "$started" "$total" "$errors" \
    "$code" "$rc" "${result#* }" "$phase" "$outcome"
  sleep 0.2
done
awk -v n="$total" -v e="$errors" 'BEGIN {
  if (n>0) printf "SUMMARY requests=%d errors=%d availability_pct=%.6f\n", n,e,100*(n-e)/n;
  else print "SUMMARY INVALID: no requests";
}'
printf '# ended=%s\n' "$(date -u +%FT%TZ)"
SH
bash "$RUN_DIR/probe.sh" > "$RUN_DIR/workload-health.txt" 2>&1 &
PROBE_PID=$!
```

Record the sanitized URL/path, client location, expected response, and any proxy
or caching behavior in the summary. If the generator dies or the laptop sleeps,
the unobserved interval is a gap, not evidence of availability.

### Continuous PromQL outputs → `prometheus-results.txt`

Discover the Prometheus Service (not Alertmanager or the operator), inspect its
ports, and export its actual name. Port 9090 below must be a Service port.

```bash
kubectl -n monitoring get svc
export PROM_SERVICE="$(kubectl -n monitoring get svc \
  -o json | jq -er '[.items[] | select(.spec.clusterIP != "None") |
    select(any(.spec.ports[]; .port == 9090))] |
    if length == 1 then .[0].metadata.name else error("Select the actual Prometheus Service from kubectl get svc") end')"
kubectl -n monitoring get svc "$PROM_SERVICE" -o yaml
```

The repository runs one Prometheus replica with `emptyDir`; replacing its apps
node loses historical data. Therefore save instant-query responses every ten
seconds throughout the experiment, rather than relying solely on a final range
query. The script reconnects the monitoring port-forward after failure and
records HTTP/API/empty-series errors. A reconnect or scrape gap remains a gap.
Port 19090 must be unused locally.

```bash
cat > "$RUN_DIR/metrics.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
: "${RUN_DIR:?}" "${PROM_SERVICE:?}"
pf=''
cleanup() { if [ -n "$pf" ]; then kill "$pf" 2>/dev/null || true; wait "$pf" 2>/dev/null || true; fi; }
trap cleanup EXIT
trap 'exit 130' INT TERM
queries=(
  'count(max by (node) (kube_node_info))'
  'sum(max by (node) (kube_node_status_condition{condition="Ready",status="true"}))'
  'sum(max by (node) (kube_node_status_capacity{resource="cpu",unit="core"}))'
  'sum(max by (node) (kube_node_status_allocatable{resource="cpu",unit="core"}))'
  'sum(max by (node) (kube_node_status_allocatable{resource="memory",unit="byte"}))'
  'sum(max by (node) (kube_node_spec_unschedulable))'
  'max(kube_deployment_spec_replicas{namespace="default",deployment="http-demo"})'
  'max(kube_deployment_status_replicas_available{namespace="default",deployment="http-demo"})'
)
while [ ! -e "$RUN_DIR/stop" ]; do
  if [ -z "$pf" ] || ! kill -0 "$pf" 2>/dev/null; then
    kubectl -n monitoring port-forward "svc/$PROM_SERVICE" 19090:9090 \
      >> "$RUN_DIR/prometheus-port-forward.txt" 2>&1 &
    pf=$!
    sleep 2
  fi
  for query in "${queries[@]}"; do
    stamp=$(date -u +%FT%TZ)
    phase=$(cat "$RUN_DIR/phase")
    rc=0
    response=$(curl -fsS --max-time 5 --get http://127.0.0.1:19090/api/v1/query \
      --data-urlencode "query=$query" --data-urlencode "time=$(date +%s)" \
      2>> "$RUN_DIR/prometheus-errors.txt") || rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$response" | \
      jq -e '.status=="success" and (.data.result | length > 0)' >/dev/null 2>&1; then
      jq -cn --arg phase "$phase" --arg utc "$stamp" --arg query "$query" --argjson response "$response" \
        '{phase:$phase,utc:$utc,query:$query,response:$response}'
    else
      jq -cn --arg phase "$phase" --arg utc "$stamp" --arg query "$query" --arg response "$response" \
        --argjson curl_exit "$rc" \
        '{phase:$phase,utc:$utc,query:$query,gap:true,curl_exit:$curl_exit,response:$response}'
      cleanup
      pf=''
      break
    fi
  done
  sleep 10
done
SH
bash "$RUN_DIR/metrics.sh" > "$RUN_DIR/prometheus-results.txt" 2>&1 &
METRICS_PID=$!
```

These expressions assume this Prometheus scrapes only this cluster. For a shared
backend, add its cluster selector to every metric. `max by (node)` avoids counting
duplicate scrape series. Registered nodes, Ready nodes, total CPU, allocatable
CPU/memory, and cordoned nodes describe different aspects of the surge; they do
not prove application availability. Metrics are defined by
[kube-state-metrics](https://github.com/kubernetes/kube-state-metrics/blob/main/docs/metrics/cluster/node-metrics.md);
JSON responses follow the [Prometheus query API](https://prometheus.io/docs/prometheus/latest/querying/api/).

Capture pod UID → node placement and PDB state during rescheduling. Polling
can miss short events; the final event capture supplements it. Never claim
unobserved transitions.

```bash
(
  while [ ! -e "$RUN_DIR/stop" ]; do
    date -u +%FT%TZ
    kubectl -n default get pods -l app=http-demo -o json || echo 'CAPTURE GAP'
    kubectl -n default get pdb/http-demo -o json || echo 'CAPTURE GAP'
    sleep 5
  done
) > "$RUN_DIR/rescheduling.txt" 2>&1 &
PLACEMENT_PID=$!
set_phase() {
  printf '%s\n' "$1" > "$RUN_DIR/phase.next"
  mv "$RUN_DIR/phase.next" "$RUN_DIR/phase"
  mark "$1"
}
set_phase pre-upgrade
sleep 300
kill -0 "$PROBE_PID" "$METRICS_PID" "$PLACEMENT_PID"
jq -c 'select(.phase == "pre-upgrade")' "$RUN_DIR/prometheus-results.txt" \
  > "$RUN_DIR/prometheus-before.jsonl"
test -s "$RUN_DIR/prometheus-before.jsonl"
cat "$RUN_DIR/prometheus-before.jsonl"
tail -5 "$RUN_DIR/workload-health.txt"
read -r -p 'Preflight GO or NO-GO and reasons: ' DECISION
printf '%s operator=%s %s\n' "$(date -u +%FT%TZ)" "$OPERATOR_ALIAS" "$DECISION" \
  >> "$RUN_DIR/preflight.txt"
[[ "$DECISION" == 'GO '* ]]
```

Inspect the full five-minute baseline for HTTP failures, scrape gaps and all eight
PromQL expressions, including available app replicas. File existence alone is
not a pass. Resolve failures and begin a fresh run; record actual reasons for GO.
Keep all three collectors running through final health validation.

## 5. Upgrade only the control plane

Keep both collectors running. Change **only** `cluster_version` to `"1.36"`
in the authoritative tfvars; leave all three `node_group_versions` at `"1.35"`.

```bash
terraform -chdir=terraform plan -input=false -out="$RUN_DIR/control-plane.tfplan"
terraform -chdir=terraform show -no-color "$RUN_DIR/control-plane.tfplan" > "$RUN_DIR/control-plane-plan.txt"
```

**Review gate:** inspect the entire saved plan before executing the next block.
Require an in-place cluster 1.35 → 1.36 update and **no managed node-group
update/replacement**, including AMI release or launch-template changes. Module
wait resources and data reads may change; they do not authorize worker changes.
This architecture selects add-on defaults for the cluster version, so the plan
may also update add-ons. Review those exact releases against preflight for both
minors and their required ordering. If a prerequisite must precede the control
plane, pin the appropriate release in the `addon_versions` tfvars map, plan and
complete that maintenance separately, then repeat preflight. Preserve CNI Pod
Identity and CoreDNS settings. Stop for unknown/unreviewable add-on releases,
unrelated infrastructure changes, creates, deletes, or AWS replacements.
Do not relax the worker gate to get an apply through; resolve the cause and
regenerate the plan. Never apply both version stages together.

Only after this gate, the operator executes the saved plan:

```bash
set_phase control-plane
terraform -chdir=terraform apply "$RUN_DIR/control-plane.tfplan" 2>&1 | tee "$RUN_DIR/control-plane-apply.txt"
# Back up state after Terraform exits, including on failure, per README.
aws eks describe-cluster --name "$EKS_CLUSTER_NAME" > "$RUN_DIR/cluster-after.json"
test "$(jq -r .cluster.version "$RUN_DIR/cluster-after.json")" = "$TARGET_VERSION"
test "$(jq -r .cluster.status "$RUN_DIR/cluster-after.json")" = ACTIVE
mark control-plane-success
```

Terraform waits for the EKS update. If it fails or is interrupted, stop: inspect
`aws eks list-updates` and `describe-update` for the cluster and affected add-ons,
preserve error details and state, and establish the actual AWS status before a
fresh plan. Never blindly retry the old saved plan.

## 5a. Health validation — mandatory stop before workers

```bash
{
  date -u +%FT%TZ
  kubectl get --raw=/readyz
  kubectl get --raw=/version
  capture_nodes control-plane
  kubectl wait --for=condition=Ready nodes --all --timeout=5m
  kubectl -n kube-system rollout status deployment/coredns --timeout=5m
  kubectl -n "$APP_NS" rollout status "deployment/$APP_DEPLOYMENT" --timeout=5m
  kubectl get pods -A -o wide
  kubectl get pdb -A
  helm list -A
  capture_addons
  capture_health control-plane
  # Control-plane-only stage must preserve worker identity and kubelet minor.
  jq -S '[.items[] | {id:.spec.providerID,version:.status.nodeInfo.kubeletVersion}] | sort_by(.id)' \
    "$RUN_DIR/before-nodes.json" > "$RUN_DIR/worker-before.json"
  jq -S '[.items[] | {id:.spec.providerID,version:.status.nodeInfo.kubeletVersion}] | sort_by(.id)' \
    "$RUN_DIR/control-plane-nodes.json" > "$RUN_DIR/worker-after-control-plane.json"
  diff -u "$RUN_DIR/worker-before.json" "$RUN_DIR/worker-after-control-plane.json"
} > "$RUN_DIR/control-plane-health.txt" 2>&1
cat "$RUN_DIR/control-plane-health.txt"
```

Require control plane 1.36 and **every group and kubelet still 1.35**, unchanged
worker instance/AMI IDs, all groups ACTIVE with no health issues, and all
installed add-ons ACTIVE with no health issues (`describe-addon` for each).
Check DNS resolution and Service networking from a running application pod,
admission webhooks, controllers, monitoring samples, and HTTP probe results.
The helper records app DNS/Service HTTP and external HTTP status/body. Inspect
configured admission webhooks and controller logs too; pod status is insufficient.
Observe at least five healthy minutes and record a timestamped `GO` with
operator alias in that file. Any failure or missing result is `NO-GO`: investigate
before modifying any node-group version. Do not advance automatically.

```bash
set_phase post-control-plane
sleep 300
kill -0 "$PROBE_PID" "$METRICS_PID" "$PLACEMENT_PID"
tail -5 "$RUN_DIR/workload-health.txt"
jq -c 'select(.phase == "post-control-plane")' "$RUN_DIR/prometheus-results.txt"
read -r -p 'Post-control-plane GO or NO-GO and reasons: ' DECISION
printf '%s operator=%s %s\n' "$(date -u +%FT%TZ)" "$OPERATOR_ALIAS" "$DECISION" \
  >> "$RUN_DIR/control-plane-health.txt"
[[ "$DECISION" == 'GO '* ]]
```

## 6. Roll Bottlerocket workers: canary, apps, system

The canary group checks node bootstrap first; it does not exercise application
compatibility unless you deploy a representative canary workload with its label
selector and taint toleration. Roll one group at a time with the default surge
strategy and `maxUnavailable=1`. Inspect the actual `updateConfig` in the before
snapshot; stop and correct it if different.

The default strategy launches replacements before draining old workers and may
surge by the larger of `maxUnavailable` or twice the number of group AZs. Across
two AZs this can be four additional nodes (six with the optional third AZ)
for one group, even with steady-state
`max_size=2`. This is an upper expectation, not a required observed peak. EKS
temporarily adjusts Auto Scaling group capacity. See the
[managed-node update phases](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-update-behavior.html).

Change only `node_group_versions.canary` to `"1.36"` in tfvars first.
Keep the control plane at 1.36 and apps/system at 1.35. Set `GROUP=canary` and
`NG` to its actual generated AWS name from the baseline capture. For later
iterations change apps, then system, retaining every previously upgraded value.
Never change all three values at once or use a loop to apply all stages.

```bash
GROUP=canary # On separate, reviewed iterations use apps, then system.
NG="$(terraform -chdir=terraform output -json node_groups |
  jq -er --arg group "$GROUP" '.[$group].id | split(":")[-1]')"
aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name "$NG" \
  > "$RUN_DIR/$GROUP-before.json"
terraform -chdir=terraform plan -input=false -out="$RUN_DIR/$GROUP.tfplan"
terraform -chdir=terraform show -no-color "$RUN_DIR/$GROUP.tfplan" > "$RUN_DIR/$GROUP-plan.txt"
```

Review the full saved plan: only the selected managed node group may roll, with
version 1.35 → 1.36 and its compatible Bottlerocket release/template changes.
Require the cluster and other groups unchanged; reject unrelated changes and
AWS resource creates/deletes/replacements (the managed update itself will
replace EC2 workers). Verify the resolved release is available
in this region. With this repository's EKS-selected AMI (no custom AMI ID), EKS
selects a compatible release; record the actual release and AMI after the roll.
The root disables SSM-latest AMI tracking. If `node_group_ami_release_versions`
contains a pin for this group, change only that pin to a target-compatible release
with its minor version; preserve the other groups' pins.
Do not enable force updates to bypass PDBs. Only after review, execute:

```bash
set_phase "nodegroup-$GROUP"
mark "nodegroup-start $NG"
terraform -chdir=terraform apply "$RUN_DIR/$GROUP.tfplan" 2>&1 | tee "$RUN_DIR/$GROUP-apply.txt"
# Back up state after Terraform exits, including on failure, per README.
aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name "$NG" \
  > "$RUN_DIR/nodegroup-$NG-after.json"
jq -e --arg version "$TARGET_VERSION" '
  .nodegroup | .version == $version and .status == "ACTIVE" and
  (.health.issues | length == 0)' "$RUN_DIR/nodegroup-$NG-after.json"
kubectl wait --for=condition=Ready node -l "eks.amazonaws.com/nodegroup=$NG" --timeout=10m
kubectl get nodes -l "eks.amazonaws.com/nodegroup=$NG" -o wide
kubectl -n "$APP_NS" rollout status "deployment/$APP_DEPLOYMENT" --timeout=5m
kubectl get pods -A -o wide
kubectl get pdb -A
capture_health "$GROUP" > "$RUN_DIR/$GROUP-health.txt" 2>&1
capture_addons >> "$RUN_DIR/$GROUP-health.txt" 2>&1
capture_nodes "$GROUP" > "$RUN_DIR/$GROUP-nodes.txt" 2>&1
kubectl -n default get events --sort-by=.metadata.creationTimestamp > "$RUN_DIR/$GROUP-events.txt"
cat "$RUN_DIR/$GROUP-health.txt"
mark "nodegroup-finished $NG"
read -r -p "$GROUP GO or NO-GO and reasons: " DECISION
printf '%s operator=%s %s\n' "$(date -u +%FT%TZ)" "$OPERATOR_ALIAS" "$DECISION" \
  >> "$RUN_DIR/$GROUP-health.txt"
[[ "$DECISION" == 'GO '* ]]
```

Check group version 1.36, ACTIVE status, empty health issues, Bottlerocket OS,
replacement instance IDs, successful DNS/network access, healthy monitoring,
and restored workload replicas. Inspect probe errors and Prometheus samples.
Record the canary validation, then repeat for **apps**, then **system**. Keep
collecting for at least five minutes after the final roll and stable capacity.

On `PodEvictionFailure`, examine PDB `disruptionsAllowed`, pending pods, events,
and termination handling. On `NodeCreationFailure`, examine subnet IPs, EC2
quotas/capacity, IAM, and node bootstrap. Do not bypass PDBs with `--force` to
manufacture a successful run. Record any traffic failure immediately and stop
initiating further updates; an in-flight managed update may continue. Investigate
and restore workload health before proceeding. Do not assume a control-plane
downgrade is available: consult current [rollback eligibility](https://docs.aws.amazon.com/eks/latest/userguide/rollback-cluster.html)
for this cluster/version. Do not attempt a Terraform version decrement as recovery.

## 7. Final validation and Terraform drift check

```bash
set_phase post-upgrade
capture_nodes after > "$RUN_DIR/after-nodes.txt" 2>&1
capture_addons >> "$RUN_DIR/after-nodes.txt" 2>&1
capture_health final > "$RUN_DIR/final-health.txt" 2>&1
sleep 300
kill -0 "$PROBE_PID" "$METRICS_PID" "$PLACEMENT_PID"
jq -c 'select(.phase == "post-upgrade")' "$RUN_DIR/prometheus-results.txt" \
  > "$RUN_DIR/prometheus-after.jsonl"
test -s "$RUN_DIR/prometheus-after.jsonl"
cat "$RUN_DIR/prometheus-after.jsonl"
# Capture actual before/after pod UID and node transitions, especially during apps roll.
{
  for phase in before apps final; do
    printf '\nphase=%s\n' "$phase"
    jq -r '.items[] | [.metadata.name,.metadata.uid,.spec.nodeName,
      .metadata.creationTimestamp] | @tsv' "$RUN_DIR/$phase-pods.json"
  done
} > "$RUN_DIR/pod-transitions.txt"
cat "$RUN_DIR/pod-transitions.txt"
kubectl -n "$APP_NS" get deployment "$APP_DEPLOYMENT" -o yaml > "$RUN_DIR/workload-after.yaml"
kubectl get events -A --sort-by=.metadata.creationTimestamp > "$RUN_DIR/events.txt"
mark observation-complete
touch "$RUN_DIR/stop"
wait "$PROBE_PID"
wait "$METRICS_PID"
wait "$PLACEMENT_PID"
cat "$RUN_DIR/workload-health.txt" | tail -5
diff -u "$RUN_DIR/before-nodes.txt" "$RUN_DIR/after-nodes.txt" || true
```

Compare **each node group**, not node names (replacements get new names): list
old instance IDs and AMI IDs → new instance IDs and AMI IDs, plus old/new
Bottlerocket OS strings, kubelet versions, and node-group `releaseVersion`.
All old instances should be absent from the final Kubernetes node list; confirm
termination and ASG membership in AWS, allowing for eventual consistency. Final
counts should return to the recorded baseline unless an explained scaling event
occurred. Mixed old/new AMIs or a successful control-plane update alone are not
completion evidence.

Keep the authoritative inputs at `cluster_version = "1.36"` and all three
`node_group_versions` at `"1.36"`. Verify the control plane and groups are ACTIVE
at 1.36, all kubelets are 1.36 and Ready, add-ons have no health issues, and DNS,
networking, admission, application replicas and monitoring pass the §5a checks.
The `capture_health final` call above records those health results in
`$RUN_DIR/final-health.txt`; review it before declaring completion.

```bash
terraform -chdir=terraform fmt -check
terraform -chdir=terraform validate
plan_rc=0
terraform -chdir=terraform plan -input=false -detailed-exitcode -out="$RUN_DIR/final.tfplan" \
  > "$RUN_DIR/final-plan.txt" 2>&1 || plan_rc=$?
printf 'terraform_plan_exit_code=%s\n' "$plan_rc" > "$RUN_DIR/final-plan-status.txt"
cat "$RUN_DIR/final-plan.txt" "$RUN_DIR/final-plan-status.txt"
test "$plan_rc" -eq 0
```

Require exit code 0 (no changes). Exit 1 is an error; exit 2 means drift/changes
and is not a pass. Inspect the plan locally, resolve the cause, and repeat final
validation. Do not apply a final reconciliation plan blindly. Terraform has
managed every upgrade stage; no CLI version updates need reconciliation.
Preserve state backups, input files and lockfile; never commit plans or state.

## 8. Interpret and publish the audit trail

For Prometheus, retain the raw query responses, UTC timestamps, and gap records.
Use this local summary to extract first, peak, and last values separately for
each recorded phase and expression without depending on Prometheus retaining the earlier samples:

```bash
python3 - "$RUN_DIR/prometheus-results.txt" > "$RUN_DIR/prometheus-summary.txt" <<'PY'
import json, sys
series = {}
gaps = 0
with open(sys.argv[1]) as source:
    for line in source:
        row = json.loads(line)
        if row.get('gap'):
            gaps += 1
            continue
        value = float(row['response']['data']['result'][0]['value'][1])
        series.setdefault((row['phase'], row['query']), []).append((row['utc'], value))
print('gap_records=', gaps)
for query, samples in series.items():
    peak = max(samples, key=lambda item: item[1])
    print(query)
    print('first=', samples[0], 'peak=', peak, 'last=', samples[-1],
          'peak_minus_first=', peak[1] - samples[0][1], 'samples=', len(samples))
if not series:
    raise SystemExit('INVALID: no successful Prometheus samples')
PY
```

The command writes `$RUN_DIR/prometheus-summary.txt`; the assembly below includes
it in `summary.md`. Correlate peaks with `timeline.txt` and the
actual managed-group/AZ configuration. Registered-node and capacity metrics are
sampled Kubernetes state, not exact EC2 billing counts. Scrape delays, stale
series, short-lived nodes, and Prometheus restarts can distort or miss peaks.
Inspect timestamps and gaps; report **inconclusive** if the upgrade interval
was not adequately covered. Missing data is never zero capacity or zero errors.

Review the six raw files below for sensitive values, then make sanitized copies
at their final paths. Preserve real timestamps, API findings, error counts,
versions, AMI IDs, and PromQL values. Replace account identifiers, private
hostnames/IPs, ARNs, and application URLs with consistent aliases as needed;
use the same node/instance aliases before and after so comparisons remain useful.
Do not commit tokens, kubeconfig, Helm Secrets, state, plans, or raw debug logs.

| Final file under `evidence/cluster-upgrade/` | Populate from this run | Required interpretation |
| --- | --- | --- |
| `preflight.txt` | `$RUN_DIR/preflight.txt` | Scanner version, target, stdout/stderr, exit code; findings and fixes; compatibility decisions; GO/NO-GO. |
| `before-nodes.txt` | `$RUN_DIR/before-nodes.txt` | Pre-update node → provider/instance → actual AMI mapping, OS/kubelet, group release/configuration. |
| `after-nodes.txt` | `$RUN_DIR/after-nodes.txt` | Same fields after all groups finish; exact per-group AMI and instance transition. |
| `workload-health.txt` | Assembled below | HTTP rows, health/PDB checks, pod UID/node rescheduling and events. |
| `prometheus-results.txt` | `$RUN_DIR/prometheus-results.txt` | Phase-tagged PromQL before/during/after upgrade, including failures. |
| `summary.md` | Assembled below | Cluster/version records, timeline, apply logs, Prometheus summary, final plan status, cleanup and operator verdict. |

In `summary.md`, record actual source/target versions, cluster alias, region,
operator alias, tool/configuration versions, sanitized phase timeline and update
IDs, AMI transitions, HTTP statistics, capacity deltas, monitoring gaps, Terraform
final-plan status, and a verdict:

- **Pass:** completed control plane and all worker groups at 1.36; healthy
  workloads and restored capacity; zero observed failed HTTP requests over a
  continuous baseline/upgrade/recovery window; usable capacity evidence.
- **Fail:** observed failed requests or failed upgrade/health checks. Include
  failure timestamps and diagnosis even if a later retry succeeds.
- **Inconclusive / not run:** missing baseline, incompatible versions,
  interrupted client, insufficient monitoring coverage, or missing evidence.

### Cleanup, final state and publishing

Default cleanup stops only the local collectors (the metrics script closes its
own port-forward). Keep the shared `http-demo` app, monitoring and cluster for
the other exercises. Never delete the `default` namespace. Keep Terraform inputs
at control plane 1.36 / all groups 1.36 and back up state per README. Record the
external route's disposition. Remove this lab's route after the final measurement
using the commands below; keep the controller running until AWS deletion finishes.
Infrastructure teardown is separate: [docs/teardown.md](../docs/teardown.md).
If aborting early, run `touch "$RUN_DIR/stop"` and wait for the three recorded
collector PIDs. This does not cancel an in-flight EKS update. Preserve failures;
do not execute later upgrades just to fill evidence files.

Remove only the optional Lab 01 Ingress, retaining the baseline Service,
Deployment and PDB. Reuse the recorded ARN if resuming cleanup in a fresh shell
with `RUN_DIR` and `AWS_REGION` restored. The delete and AWS waiter can be rerun.
Do not strip finalizers or delete the controller to bypass a cleanup failure.

```bash
LAB01_ALB_ARN=$(cat "$RUN_DIR/route-alb-arn.txt")
kubectl delete -f kubernetes/ingress/http-demo-ingress.yaml --ignore-not-found --timeout=10m
aws elbv2 wait load-balancers-deleted --load-balancer-arns "$LAB01_ALB_ARN"
printf '%s Lab01 Ingress and ALB deleted\n' "$(date -u +%FT%TZ)" > "$RUN_DIR/route-cleanup.txt"
```

Before Terraform teardown, follow the existing teardown guide and run
`bash scripts/check-load-balancer-cleanup.sh` to check for remaining load
balancers, target groups and associated network resources. That VPC-wide guard
can also report resources belonging to other exercises; do not delete them as
part of this Lab 01 cleanup.

After collectors exit, assemble copies for review. Never edit the raw HTTP log
while its writer is active.

```bash
{
  date -u +%FT%TZ
  aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --query 'cluster.{version:version,status:status}'
  kubectl -n default get deployment/http-demo service/http-demo pdb/http-demo
  helm list -n monitoring
  printf 'Local collectors stopped; shared app and monitoring retained.\n'
} > "$RUN_DIR/cleanup.txt" 2>&1
read -r -p 'Actual external route disposition and any cleanup performed: ' CLEANUP_NOTE
printf '%s\n' "$CLEANUP_NOTE" >> "$RUN_DIR/cleanup.txt"
mkdir -p "$RUN_DIR/publish"
cp "$RUN_DIR/preflight.txt" "$RUN_DIR/before-nodes.txt" "$RUN_DIR/after-nodes.txt" \
  "$RUN_DIR/prometheus-results.txt" "$RUN_DIR/publish/"
cp "$RUN_DIR/workload-health.txt" "$RUN_DIR/publish/workload-health.txt"
for name in before-health control-plane-health canary-health apps-health system-health final-health rescheduling pod-transitions events; do
  test -s "$RUN_DIR/$name.txt"
  printf '\n# %s\n' "$name" >> "$RUN_DIR/publish/workload-health.txt"
  sed 's/^/# /' "$RUN_DIR/$name.txt" >> "$RUN_DIR/publish/workload-health.txt"
done
python3 - "$RUN_DIR" <<'PY'
from pathlib import Path
import sys
r = Path(sys.argv[1])
files = ['cluster-before.json', 'cluster-after.json', 'timeline.txt',
         'control-plane-apply.txt', 'canary-apply.txt', 'apps-apply.txt',
         'system-apply.txt', 'prometheus-summary.txt', 'final-plan-status.txt', 'cleanup.txt']
with (r / 'publish/summary.md').open('w') as out:
    out.write('# Lab 01 execution evidence\n\n')
    for name in files:
        out.write(f'## {name}\n\n```text\n{(r / name).read_text()}\n```\n\n')
    rows = [line for line in (r / 'workload-health.txt').read_text().splitlines()
            if line.startswith('SUMMARY ')]
    out.write('## Observed HTTP summary\n\n' + '\n'.join(rows) + '\n')
PY
read -r -p 'Verdict (Pass/Fail/Inconclusive) and evidence-based reasons, including gaps: ' VERDICT
printf '\n## Operator assessment\n\n%s — %s: %s\n' \
  "$(date -u +%FT%TZ)" "$OPERATOR_ALIAS" "$VERDICT" >> "$RUN_DIR/publish/summary.md"
```

Review and sanitize **every file in `$RUN_DIR/publish/`** before copying to the
repository. Add actual image/route and probe location, per-group AMI/instance
transitions, compatibility decisions and monitoring coverage limitations to the
summary. The generator only packages recorded data; it never decides Pass.
Preserve consistent aliases and valid Prometheus JSON. Never erase failures or
replace missing samples with zeroes. For an interrupted run, assemble only the
available captures and explicitly list missing files/phases instead of using the
success-path assembly above.

After review, populate the existing six files with the commands below. They
refuse to overwrite a prior nonempty evidence set; archive that set first.

```bash
files=(preflight.txt before-nodes.txt after-nodes.txt workload-health.txt prometheus-results.txt summary.md)
for file in "${files[@]}"; do
  test -s "$RUN_DIR/publish/$file"
  test ! -s "evidence/cluster-upgrade/$file"
done
for file in "${files[@]}"; do
  cp "$RUN_DIR/publish/$file" "evidence/cluster-upgrade/$file"
done
```

Say “zero failures observed across N requests,” not “zero traffic can ever be
dropped.” This probe samples one service path, not every client or long-lived
connection. Keep historical failed attempts.

### Recorded readiness-gate follow-up

The [separate remediation evidence](../evidence/cluster-upgrade/remediation-20260908T210043Z/summary.md)
documents a controlled drain after the original run's HTTP failures. The namespace
opt-in is defined in
[`lab01-readiness-gate-namespace.yaml`](../kubernetes/ingress/lab01-readiness-gate-namespace.yaml).
Create the matching IP TargetGroupBinding before recreating HTTP pods, then verify
the injected target-health gates are True. Existing pods are not retroactively
mutated. Never delete the shared namespace as cleanup for this manifest.

The follow-up used an extra apps node and the
[`lab01-remediation-observe.py`](../scripts/lab01-remediation-observe.py) collector
alongside HTTP and Prometheus sampling. It validates one controlled drain, not
the complete managed-node upgrade sequence. Preserve both runs when reporting results.

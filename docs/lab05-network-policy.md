# Lab 05 native VPC CNI NetworkPolicy preflight

The Terraform `vpc-cni` managed add-on enables `enableNetworkPolicy = "true"`
and `env.NETWORK_POLICY_ENFORCING_MODE = "standard"`. Its existing Pod Identity,
CNI role, subnet dependencies and version-selection architecture remain intact.
No Calico, Cilium, replacement CNI or extra IAM policy is needed.

Standard mode initially allows traffic while policies converge, then enforces
policies on selected pods. Strict mode would require startup allow policies for
other workloads, including DNS; it is not necessary for this exercise. Inventory
existing NetworkPolicies before enabling enforcement, because previously inert
policies may begin restricting their selected workloads.

The existing Bottlerocket EC2 workers and IPv4 cluster can support native policies.
Verify the **actual** kernel and selected add-on release; configuration alone is
not runtime proof. AWS documents Linux kernel >= 5.10, required agent ports
8162 (metrics) / 8163 (health), and add-on configuration in
[the native setup guide](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy-configure.html).
Use an EKS-compatible current CNI release (AWS’s current guide recommends 1.21+
for its current policy capabilities). The root still selects the regional EKS
default with `most_recent = false`; do not blindly change versions or overwrite
other add-on settings. This lab uses standard namespace-scoped NetworkPolicy,
not admin/cluster policies. Run the preflight on new lab pods after the CNI rollout.

## Apply configuration in a separate maintenance step

Keep `enable_load_balancer_controller = true` in local tfvars and complete
[controller setup](load-balancer-controller.md). Preserve all other inputs.
The existing Lab 05 Ingress uses `ingressClassName: alb`, the chart creates
`alb` with controller `ingress.k8s.aws/alb`, and both select pod IP targets.
The AWS controller reconciles ALBs; VPC CNI enforces policy on pod traffic.

```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
terraform -chdir=terraform plan -out=lab05-cni.tfplan
terraform -chdir=terraform show lab05-cni.tfplan
```

Review the CNI configuration update and any explicitly enabled controller setup.
Stop for unrelated changes or Kubernetes version/node rollouts. The operator
applies the saved plan only during authorized execution, before Lab 05 starts.
Do not edit the managed DaemonSet or install VPC CNI again through Helm: that
would compete with the EKS add-on. This repository preparation performs no apply.

## Check installed components and settings

Use Bash, AWS CLI v2, kubectl, jq and the same operator identity/cluster as
Terraform. Save raw outputs locally; sanitize before sharing. All commands below
are for later execution, not claims of observed results.

```bash
set -euo pipefail
umask 077
export AWS_PAGER=""
export AWS_REGION="$(terraform -chdir=terraform output -raw aws_region)"
CLUSTER=$(terraform -chdir=terraform output -raw cluster_name)
RAW="$PWD/.local/lab05-network-policy/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RAW"
kubectl config current-context
kubectl get networkpolicy -A > "$RAW/existing-policies.txt"
aws eks describe-cluster --name "$CLUSTER" > "$RAW/cluster.json"
aws eks describe-addon --cluster-name "$CLUSTER" --addon-name vpc-cni > "$RAW/cni.json"
CNI_VERSION=$(jq -er '.addon.addonVersion' "$RAW/cni.json")
aws eks describe-addon-configuration --addon-name vpc-cni --addon-version "$CNI_VERSION" \
  > "$RAW/cni-schema.json"
jq -r '.configurationSchema' "$RAW/cni-schema.json" > "$RAW/cni-schema-decoded.json"
jq -e '.addon | .status == "ACTIVE" and (.health.issues | length == 0) and
  ((.configurationValues | fromjson) |
    .enableNetworkPolicy == "true" and .env.NETWORK_POLICY_ENFORCING_MODE == "standard")' "$RAW/cni.json"
kubectl -n kube-system rollout status daemonset/aws-node --timeout=5m
kubectl -n kube-system get daemonset/aws-node -o json > "$RAW/aws-node.json"
jq -e '.spec.template.spec.containers |
  any(.[]; any(.args[]?; . == "--enable-network-policy=true")) and
  any(.[]; .name == "aws-node" and
    any(.env[]; .name == "NETWORK_POLICY_ENFORCING_MODE" and .value == "standard"))' "$RAW/aws-node.json"
kubectl -n kube-system get configmap/amazon-vpc-cni -o json > "$RAW/cni-configmap.json"
jq -e '.data["enable-network-policy-controller"] == "true"' "$RAW/cni-configmap.json"
kubectl get crd policyendpoints.networking.k8s.aws -o yaml > "$RAW/policyendpoint-crd.yaml"
kubectl -n kube-system get pods -l k8s-app=aws-node -o wide > "$RAW/cni-pods.txt"
POLICY_AGENT=$(jq -er '[.spec.template.spec.containers[] |
  select(any(.args[]?; . == "--enable-network-policy=true")) | .name] |
  if length == 1 then .[0] else error("Expected exactly one enabled policy-agent container") end' "$RAW/aws-node.json")
kubectl -n kube-system logs -l k8s-app=aws-node -c "$POLICY_AGENT" \
  --prefix=true --since=10m --tail=100 > "$RAW/agent-logs.txt" 2>&1
kubectl get nodes -l workload=production-apps -o json > "$RAW/apps-nodes.json"
jq -r '.items[] | [.metadata.name,.status.nodeInfo.osImage,.status.nodeInfo.kernelVersion,
  ([.status.conditions[] | select(.type == "Ready") | .status][0])] | @tsv' "$RAW/apps-nodes.json"
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=5m
kubectl get ingressclass/alb -o json > "$RAW/ingressclass.json"
jq -e '.spec.controller == "ingress.k8s.aws/alb"' "$RAW/ingressclass.json"
```

Confirm all eligible apps nodes are Ready with kernels >= 5.10 and a healthy
policy-agent container on each. The container name varies by add-on version
(for example, `aws-eks-nodeagent`); select it by the enabled NetworkPolicy flag
rather than a hardcoded name. Inspect the captured schema for these settings,
Pod Identity association in the add-on description, and agent logs for eBPF,
policy-controller or port-conflict errors. Do not modify PolicyEndpoint resources:
they are generated by the EKS policy controller. If a setting/component is absent,
resolve the installed add-on/schema/version discrepancy before proceeding.

## Prove enforcement before the intentional ingress failure

This temporary check creates one HTTP Deployment and two client Deployments,
with no Ingress, LoadBalancer Service or AWS resources. It adapts a **copy** of
the existing policy to a dedicated check namespace; the scenario file is unchanged.
Clients use ordinary pod networking, a literal target IP and fresh curl processes.
The target is a Deployment pod, matching the lab workload model.

```bash
CHECK_NS=lab05-netpol-check
CHECK_CLIENT=lab05-netpol-check-client
test -z "$(kubectl get namespace "$CHECK_NS" --ignore-not-found -o name)"
test -z "$(kubectl -n kube-system get deployment "$CHECK_CLIENT" --ignore-not-found -o name)"
kubectl create namespace "$CHECK_NS"
# Reuse only the web Deployment (its healthy :3000 listener/probe), not the faulty Service/Ingress.
kubectl create --dry-run=client -f kubernetes/chaos/ingress-outage.yaml -o json |
  jq -s --arg ns "$CHECK_NS" '[.[] | if .kind == "List" then .items[] else . end][] |
    select(.kind == "Deployment") | .metadata.namespace = $ns |
    .spec.template.spec.nodeSelector = {workload:"production-apps"}' |
  kubectl apply -f -
for ns in "$CHECK_NS" kube-system; do
  kubectl -n "$ns" create deployment "$CHECK_CLIENT" --image=curlimages/curl:8.12.1 \
    --dry-run=client -o json -- sleep 3600 |
    jq '.spec.template.spec.nodeSelector = {workload:"production-apps"} |
      .spec.template.spec.automountServiceAccountToken = false |
      .spec.template.spec.containers[0].resources = {
        requests:{cpu:"10m",memory:"16Mi"},limits:{cpu:"100m",memory:"64Mi"}}' |
    kubectl apply -f -
  kubectl -n "$ns" rollout status "deployment/$CHECK_CLIENT" --timeout=180s
done
kubectl -n "$CHECK_NS" rollout status deployment/web --timeout=180s
CHECK_IP=$(kubectl -n "$CHECK_NS" get pods -l app=lab05-web -o jsonpath='{.items[0].status.podIP}')
: "${CHECK_IP:?}"
np_probe() {
  kubectl -n "$1" exec "deployment/$CHECK_CLIENT" -- \
    curl -fsS --retry 0 --connect-timeout 2 --max-time 4 "http://$CHECK_IP:3000/"
}
np_probe "$CHECK_NS" > "$RAW/allowed-before.txt" 2>&1
np_probe kube-system > "$RAW/cross-namespace-before.txt" 2>&1
# Change only the copy's namespace and same-namespace allowance.
kubectl create --dry-run=client -f kubernetes/chaos/ingress-network-policy.yaml -o json |
  jq --arg ns "$CHECK_NS" '.metadata.namespace = $ns |
    .spec.ingress[0].from[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"] = $ns' \
  > "$RAW/check-policy.json"
kubectl apply -f "$RAW/check-policy.json"
kubectl -n "$CHECK_NS" get policyendpoints.networking.k8s.aws -o yaml > "$RAW/policyendpoints.yaml"
blocked=0
for ((attempt=0; attempt<30; attempt++)); do
  rc=0
  np_probe kube-system > "$RAW/denied-latest.txt" 2>&1 || rc=$?
  printf '%s attempt=%s curl_or_exec_exit=%s\n' "$(date -u +%FT%TZ)" "$attempt" "$rc" \
    >> "$RAW/enforcement.txt"
  cat "$RAW/denied-latest.txt" >> "$RAW/enforcement.txt"
  if [ "$rc" -eq 28 ]; then blocked=1; break; fi
  # Before reconciliation a connection may still succeed; other errors are inconclusive.
  test "$rc" -eq 0
  sleep 2
done
test "$blocked" -eq 1
np_probe "$CHECK_NS" > "$RAW/allowed-during-deny.txt" 2>&1
kubectl delete -f "$RAW/check-policy.json" --wait=true --timeout=120s
recovered=0
for ((attempt=0; attempt<30; attempt++)); do
  if np_probe kube-system > "$RAW/recovered.txt" 2>&1; then recovered=1; break; fi
  sleep 2
done
test "$recovered" -eq 1
printf '%s allow/deny/allow check completed\n' "$(date -u +%FT%TZ)" >> "$RAW/enforcement.txt"
```

Require initial success from both clients, a curl timeout (28) from `kube-system`
while the same-namespace client still succeeds, then restored success after
policy deletion. API/exec errors, DNS errors or HTTP errors do not prove a drop.
If the target pod is replaced, record its new IP and repeat the test from the
initial allow stage. Standard-mode convergence can allow early requests; do not
claim enforcement before a blocked fresh connection is observed. Inspect other
policies if traffic never blocks or fails to recover.

Clean up the check resources, including after an error/interruption:

```bash
kubectl -n kube-system delete deployment lab05-netpol-check-client --ignore-not-found --wait=true --timeout=120s
kubectl delete namespace lab05-netpol-check --ignore-not-found --wait=true --timeout=120s
```

The guarded names belong only to this preflight; never delete unrelated pods or
namespaces to make it pass. Keep the native CNI settings enabled. Proceed to
[Lab 05 step 2](../labs/05-ingress-outage.md#2-reproduce-the-wrong-port-failure)
only after this check passes. Step 5 aligns Service/target ports to 3000 before
step 6 applies the original same-namespace-only policy. The ALB is not a namespace
member, so its traffic remains intentionally omitted by that policy.

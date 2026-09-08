# Baseline Evidence Summary

These saved captures describe the pre-lab starting state. They are a point-in-time
record, not a live health check performed when this Git commit was created.

## Baseline snapshot

- Capture date: not recorded in the source captures (ages are relative).
- AWS account: not recorded in the source captures.
- Region: `us-east-1`, inferred from the load balancer hostname in `baseline/ingress.txt`.
- Kubernetes node version: `v1.35.5-eks-a3a0722`; control-plane version is not independently captured.
- Nodes: 4/4 Ready in `baseline/nodes.txt`; node-group labels are not captured.
- HTTP demo: 2/2 replicas ready and available in `baseline/workload.txt`.
- Pods: all listed pods Running with all containers ready and zero restarts in `baseline/pods.txt`.
- AWS Load Balancer Controller: both listed pods ready.
- Prometheus and Grafana: listed pods ready; query and dashboard functionality are not independently captured.
- Ingress: ALB hostname assigned in `baseline/ingress.txt`; external HTTP success is not independently captured.
- Historical warnings: four `InvalidDiskCapacity` node events and one Grafana readiness probe failure appear in `baseline/events.txt`. The node and pod snapshots show Ready status; the captures do not establish whether warnings recurred afterward.
- Baseline result: healthy node and pod readiness in the saved snapshots, with the verification limits above.

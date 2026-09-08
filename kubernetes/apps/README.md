# HTTP workload

`http-demo.yaml` supplies one two-replica NGINX Deployment, its configuration,
a ClusterIP Service, and a PDB in `default`. Both `/` and `/healthz` return HTTP
200. The health endpoint returns `ok` and disables caching.

The pods select `workload=production-apps`, matching the untainted Terraform apps
node group. Hostname spreading places one replica on each of its two healthy
nodes. With fewer eligible nodes, both replicas can share the surviving node;
spreading does not guarantee availability during a node outage. The PDB retains
one available replica during voluntary eviction. Deployment rollouts retain both
available replicas and allow one surge pod. Requests are 50m CPU / 32Mi memory;
limits are 250m CPU / 64Mi memory per pod.

NGINX runs unprivileged with a read-only root filesystem and writable temporary
storage, following the [image's filesystem conventions](https://github.com/nginx/docker-nginx-unprivileged).
Shutdown allows five seconds for endpoint propagation before NGINX quits gracefully.
ConfigMap edits require a Deployment restart to reload NGINX configuration.

When deployment is authorized, run `make deploy-apps` from the repository root.
The existing target already discovers this manifest. Then use:

```sh
kubectl -n default rollout status deployment/http-demo
kubectl -n default get pods -l app=http-demo -o wide
kubectl -n default get service/http-demo poddisruptionbudget/http-demo
```

For Lab 01, use `APP_NS=default` and `APP_DEPLOYMENT=http-demo`, two replicas,
and PDB `minAvailable: 1`, exactly as supplied. No replica or PDB edits are needed.

The internal URL is `http://http-demo.default.svc.cluster.local/healthz`.
For independent upgrade measurements, [Lab 01](../../labs/01-cluster-upgrade.md)
provides setup, HTTP evidence capture, and cleanup for the optional
[ALB Ingress](../ingress/http-demo-ingress.yaml). It uses the existing AWS Load
Balancer Controller and routes public HTTP `/healthz` to this Service's port 80,
then directly to pod targets on port 8080. No DNS record or certificate is needed.
The route incurs ALB charges while present and exposes only the synthetic health
endpoint. Apply it separately: `make deploy-apps` does not create it.
Do not use port-forwarding for upgrade availability evidence. Other chaos
exercises retain their isolated fixtures.

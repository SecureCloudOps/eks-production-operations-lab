# Lab 05 execution — 2026-09-09

Both deliberately introduced ingress failures were diagnosed and reversed.
The operator executed cloud/Kubernetes changes; the assistant reviewed local
captures and prepared commands. Shared infrastructure remains deployed.

| Stage | Port | External result | Target health | Diagnostic control |
| --- | --- | --- | --- | --- |
| Wrong Service targetPort | 8080 | HTTP 502 | Unhealthy, Target.FailedHealthChecks | Loopback 3000 HTTP 200; 8080 connection refused |
| Port mapping corrected | 3000 | HTTP 200 | Healthy | Application pod UID/IP unchanged |
| Same-namespace-only policy | 3000 | HTTP 504 | Unhealthy, Target.Timeout | Same namespace HTTP 200; cross namespace curl 28 / HTTP 000 |
| Only policy removed | 3000 | HTTP 200 | Healthy | Both probes HTTP 200; same pod and port mapping |

The first external attempt returned curl exit 6 while the ALB was provisioning.
That DNS failure was retained separately and excluded from backend-fault evidence.
The later ALB response headers timestamp the 502 at 17:43:14 UTC and the 504 at
17:49:21 UTC. Other capture ordering is recorded by the source stages below;
local file modification times are not presented as exact incident event times.

## Findings and remediation

The Ingress referenced Service port 8080, and that Service forwarded to pod
port 8080. The Python listener was on 3000. The registered target IP matched the
application pod. Aligning Service port, targetPort and Ingress backend to 3000
restored healthy targets and HTTP 200 without replacing the pod.

The subsequent policy allowed TCP 3000 only from the lab namespace. With the
port mapping fixed, the ordinary-network kube-system probe timed out while the
same-namespace probe remained healthy. Removing only that policy restored both
probe and ALB connectivity. This controlled reversal supports policy attribution;
a target-health reason alone would not establish it. The ALB is not a Kubernetes
namespace member, and the controller does not proxy its application requests.

Before the ingress exercise, native VPC CNI enforcement also passed an isolated
allow → timeout → allow test against an unchanged Deployment pod. CNI was
v1.22.4-eksbuild.3, ACTIVE with zero reported issues, standard enforcement,
four Ready DaemonSet pods, and an enabled policy controller. Apps-node kernels
were 6.18.38. The installed agent container was aws-eks-nodeagent.

## Cleanup and final state

The Ingress was removed first. While the namespace remained, AWS checks verified
absence of the ALB, both recorded target groups (including the replaced group),
one dedicated ALB security group, and three recorded ALB ENIs. Resource-not-found
responses were distinguished from API errors. The shared backend security group
was identified separately and was not manually deleted. Only then were the lab05
namespace and dedicated kube-system probe deleted. The separate preflight
namespace and client Deployment had already been removed.

Final verification at approximately 18:00 UTC: four Ready nodes, apps capacity
min/max/desired 2/2/2, system 1/1/1, canary 1/1/1; control plane 1.36 and nodes
v1.36.1-eks-a3a0722. Shared HTTP demo and controller remained 2/2. Prometheus
was Ready with 25/25 targets up, monitoring containers Ready with zero restarts,
and default namespace ALB readiness-gate injection remained enabled.
The final normal Terraform plan exited 0 with no resource actions, output actions,
or drift. The earlier office endpoint update was reconciled using a reviewed
refresh-only apply between verified encrypted pre/post state backups. Private
endpoint access and both operator /32 allowlist entries remained enabled.

## Repository fixes and limits

- Detect the policy-agent container by its enabled policy flag instead of a fixed name.
- Retain the lab namespace until AWS deletion checks pass, including the replaced target group.
- Explain ALB provisioning/DNS failures before interpreting backend HTTP failures.
- Keep intentional fixture faults for repeatable lab execution; remediation was live and disposable.

A local kubeconfig/context assumption was corrected in the private execution
scripts. Prometheus's API Service-proxy request timed out; localhost port-forward
verified readiness, targets and alerts instead. The Service-proxy timeout's cause
was not established. The policy-agent stdout capture was empty; no packet event
logs or Flow Logs were used to claim enforcement. Packet tests and their reversal
provide the enforcement evidence. The captured controller log window contained
no error-level entries, which does not prove absence of all controller errors.

PrometheusNotConnectedToAlertmanagers remained firing with Alertmanager explicitly
disabled by repository configuration; Watchdog was also firing. Alert delivery
and dashboard rendering were not validated. No restrictive replacement policy was
deployed. No commit or push was performed as part of this execution.

Raw outputs, full plans/state, private configuration, identities, network addresses,
and backup passwords are excluded. See provenance.json for selected capture hashes.

# Full environment teardown — September 10, 2026

The operator removed the disposable AWS lab after completing Labs 01–05.
Terraform reported **79 managed resources destroyed**, with no additions or
updates. Independent checks passed for the recorded lab resources and regional
project/cluster tag searches. The final local state was empty, and a fresh
**destroy-mode** plan returned exit 0 with no actions or drift.

See [verification results](verification.json) and [capture provenance](provenance.json).
Historical lab evidence remains unchanged.

## Order and ownership

1. Captured the original state, identity, Kubernetes inventory and AWS resource
   IDs. Four workers were Ready; monitoring and the controller were healthy.
   No Ingresses, LoadBalancer Services, PVCs or PVs remained. The AWS load-balancer
   cleanup gate passed, including controller security groups and ELB interfaces;
   the separate Classic ELB check was empty.
2. Created and reopened an encrypted pre-teardown backup outside the checkout,
   verifying captured file hashes.
3. Removed the four manually deployed HTTP demo objects and waited for their
   pods to disappear. Kept workers, monitoring and the controller healthy.
4. Reviewed the saved destroy plan against all 79 managed addresses and IDs in
   state. Applied that exact plan with the original private inputs. Terraform
   owned the removal of both Helm releases and the dependent AWS infrastructure.
5. After Terraform exited successfully, created, reopened and hash-verified
   an encrypted backup of the latest state, configuration and execution record.
6. Independently verified AWS cleanup and generated the final empty destroy-mode
   plan. Verification did not change Terraform state.

## Independent verification

All **41 checks passed**, with zero unresolved checks and zero API errors:

- EKS cluster absent; recorded Auto Scaling groups and launch templates absent;
  four tagged former workers confirmed terminated by exact-ID EC2 queries.
- VPC, subnets, route tables, interfaces, security groups, network ACLs, VPC
  endpoints and internet gateway absent. NAT gateway recorded as `deleted`;
  its Elastic IP allocation was absent.
- ALB/NLB, Classic ELB and target-group searches for the recorded VPC empty.
- All eight recorded worker EBS volumes absent; no owned snapshots found for
  those volumes and no volumes found under the checked project/cluster tags.
- Six teardown IAM roles plus the earlier Lab 04 role absent; three recorded
  instance profiles, the Lab 04 OIDC provider and the lab log group absent.
- Earlier Lab 04 fixture/audit buckets and the manual CloudTrail trail absent.
- Project/cluster tag matches resolved through their owning service APIs.

The initial tag search flagged two project matches and four cluster matches.
Exact-ID checks identified one deleted NAT gateway, one absent EKS Pod Identity
association and four terminated instances. These were terminal or stale records,
not additional resources requiring deletion. The original flagged capture is
retained alongside the successful follow-up.

## Execution fixes and limits

The inventory initially used the Helm 3 `--all` flag with Helm 4. The runbook now
selects the appropriate command for each major version. Demo deletion succeeded,
but its first verification tried to parse empty `--ignore-not-found` output as
JSON. A follow-up list-based check confirmed all four objects and their pods absent.
Neither verification failure required another infrastructure deletion.

This verifies the recorded lab and the stated searches, not every resource in the
AWS account. Billing settlement and unrelated/manual resources outside that scope
were not audited. No ongoing lab resources were identified by these checks.
A later billing review can check for delayed charges.

The unchanged Terraform configuration remains reproducible. A normal plan against
empty state would propose rebuilding the environment; it is not the appropriate
zero-change teardown check. Preserve encrypted recovery records and private raw
captures according to the operator's retention policy.

# Lab 04: IRSA overprivilege and least-privilege remediation

Completed across 2026-09-08 and 2026-09-09 UTC on `eks-operations-lab`,
`us-east-1`. The operator demonstrated access to a synthetic private S3 object,
replaced the excessive policy, and verified that the same pod and role session
retained legitimate public access while private access and writes were denied.
CloudTrail captured both the successful private read and the denied requests.
Cleanup removed the lab resources; the final Terraform plan reported **No changes**.

## Scope and confirmed configuration flaw

The intentionally flawed role granted `s3:*` on one generated fixture bucket
and its objects. The application's intended access was listing and reading only
`public/`. This permitted reading `private/customer-demo.txt`, whose entire
content was synthetic: `SYNTHETIC ONLY: customer=demo, record=123.`
The flaw was fixture-bucket overprivilege, not account-wide S3 access.

IRSA trust required the cluster's OIDC provider, audience `sts.amazonaws.com`,
and subject `system:serviceaccount:lab04:public-web`. Effective role trust,
policy documents, pod identity metadata, and STS caller results were captured.
The shared controller continued using its separate baseline identity.

The public NLB returned HTTP 200 and the expected greeting. No application
exploit was performed. The operator used the AWS CLI sidecar as a controlled
stand-in for code execution with the workload identity. Copying the synthetic
bytes into the operator's workspace demonstrates transfer through `kubectl exec`;
it does not establish an attacker-controlled external exfiltration path.

## Access results

| Operation | Broad policy | Least-privilege policy |
| --- | --- | --- |
| Read `public/hello.txt` | Succeeded | Succeeded |
| List `public/` | Not separately tested | Succeeded |
| List `private/` | Succeeded | AccessDenied, CLI exit 254 |
| Read `private/customer-demo.txt` | Succeeded | AccessDenied, CLI exit 254 |
| Write `public/should-be-denied.txt` | Not tested | AccessDenied, CLI exit 254 |

The replacement policy allows only `s3:ListBucket` with a `public/` prefix
condition, and `s3:GetObject` on `public/*`. It replaces the broad grant rather
than adding another Allow. Terraform updated the existing inline policy only.
Pod UID and assumed-role ARN matched before and after remediation. New CLI
invocations were used; this does not prove reuse of an identical temporary
credential set or revocation of previously issued sessions.

## Timeline and audit evidence

| UTC timestamp | Recorded event |
| --- | --- |
| 2026-09-08 23:18:14 | Setup apply finishes: 8 added, 0 changed, 0 destroyed |
| 2026-09-08 23:22:23 | Dedicated trail configuration verified |
| 2026-09-08 23:28:15 | CloudTrail: successful public GetObject |
| 2026-09-08 23:33:17 | Public-read event delivery confirmed |
| 2026-09-09 01:05:30 | CloudTrail: successful private GetObject |
| 2026-09-09 01:10:29 | Private-read event delivery reported by the operator |
| 2026-09-09 01:41:30 | Remediation apply finishes: 0 added, 1 changed, 0 destroyed |
| 2026-09-09 01:46:19 | CloudTrail: successful public GetObject after remediation |
| 2026-09-09 01:46:23 | CloudTrail: denied private listing, recorded as ListObjects |
| 2026-09-09 01:46:27 | CloudTrail: denied private GetObject |
| 2026-09-09 01:46:31 | CloudTrail: denied PutObject |
| 2026-09-09 01:51:31 | Denied-read event delivery confirmed |
| 2026-09-09 02:20:55 | Service deletion and NLB deletion waiter passed |
| 2026-09-09 02:24:45 | Namespace cleanup recorded |
| 2026-09-09 02:28:20 | Cleanup apply finishes: 0 added, 0 changed, 8 destroyed |
| 2026-09-09 02:32:46 | Dedicated trail stopped and deleted |
| 2026-09-09 02:36:00 | Encrypted audit archive verified outside the checkout |
| 2026-09-09 02:43:16 | Dedicated audit bucket absence confirmed |
| 2026-09-09 02:44:36 | Final health capture begins after clean Terraform plan |

Times come from event metadata and local captures, except the explicitly
operator-reported private-event delivery time. Capture timestamps are not exact
completion times for every command within a block. Delivery took approximately
five minutes for the required reads; no additional read was issued by the poller.

The published before set contains 7 correlated events; the after set contains
12 and includes the earlier events. Deduplicate by `eventID` when combining them.
STS AssumeRoleWithWebIdentity records and S3 session identity support correlation;
session names are caller-selected and are not independent proof of pod origin.
Kubernetes audit logs, web access logs, and packet/network evidence were not
collected. CloudTrail establishes API activity, not the subsequent byte transfer.

## Cleanup and retention

The NLB, its recorded target groups, both recorded security groups, and its
identified ENIs were absent in the post-cleanup inventories. The namespace was
removed. Dependency checks found no other role trusting the optional OIDC
provider and no remaining IRSA-annotated ServiceAccount before Terraform removed
the fixture objects, bucket configuration, role/policy, and OIDC provider.

The dedicated trail was removed after the required evidence arrived. The audit
bucket contained 173 archived objects: 171 files and 2 zero-byte folder markers.
The encrypted disk image outside this checkout contains 292 files, including
the audit files and supporting investigation records. Reopening it and checking
SHA-256 hashes succeeded. Compressed JSON readability and object sizes were
checked; the CloudTrail digest signature chain was not independently validated.
The original encrypted archive remains on the operator's Mac; no off-device
backup is established by these captures.

After comparison with the archived inventory, the exact 173 keys were submitted
for deletion. A subsequent listing confirmed zero objects, bucket deletion
succeeded, and HeadBucket returned 404. The final Terraform plan exit code was 0
with No changes. All four nodes were Ready; HTTP demo and controller were 2/2,
and all listed monitoring pods were Ready. These are point-in-time health checks,
not a continuous availability measurement.

## Fixes and execution issues

- The operator encountered `Permission denied: '/root/.aws'` in the CLI sidecar.
  `HOME=/tmp` allowed STS identity verification. The manifest now supplies that
  home directory, and a fresh pod verified the role without a command-line HOME
  override. Capability restrictions were retained. The initial error was shared
  in the conversation; a standalone raw error capture was not retained.
- The archive verifier initially treated zero-byte S3 folder markers as ordinary
  files. The 171 file sizes matched; the verifier was corrected to preserve and
  check the two marker inventory entries separately before encryption.
- Empty CLI output interrupted versioning and quiet-delete verification. Explicit
  JSON queries and a fresh bucket listing resolved the checks. No empty response
  was accepted as proof of cleanup. The guide now makes the versioning query
  explicit and explains folder markers.
- A repeated Service-delete attempt found it absent after the earlier successful
  cleanup. Recorded NLB identity and fresh AWS inventories established absence;
  no Service was recreated and no finalizers were removed.

For a real incident, the workload owner should remove unused AWS access or scope
it to required actions/resources; the platform owner should maintain audit data
events and identity correlation. If credentials are compromised, containment and
session revocation require separate handling. This lab tested policy restriction,
not credential theft or session revocation. The source fixture intentionally
retains the opt-in broad-policy scenario for future runs.

## Evidence index

- [Preflight](preflight.txt), [identity and trust](identity-and-trust.json), [before/after policies](policies.json)
- [Access checks](access-checks.txt), [audit configuration](audit-config.json)
- [CloudTrail before](cloudtrail-before.jsonl), [CloudTrail after](cloudtrail-after.jsonl), [local timeline](timeline.txt)
- [Terraform results](terraform-results.json), [cleanup record](cleanup.txt), [cleanup verification](cleanup-verification.json), [final health](final-health.txt)
- [Source/output hashes and sanitization](provenance.json)

Publication aliases account, role, bucket, trail, OIDC and network identifiers
while retaining event/request IDs, pod UIDs, session names, timestamps, policy
scope and observed results. ARN aliases are publication placeholders, not usable
AWS identifiers. Raw captures, state, plans, local inputs and encrypted-backup
paths remain outside Git. Labs 1–3 evidence is unchanged.

# Lab 04: IRSA Security Breach

Trace how a compromised public-facing workload can abuse an overprivileged AWS
identity, then replace the policy and verify that access is restricted.

## What this lab creates

- `terraform/lab04_irsa.tf`: an opt-in role whose **intentional High-severity
  flaw** is `Action = "s3:*"` scoped to the generated fixture bucket ARN and
  that bucket’s object ARNs (`<bucket-arn>/*`), plus a private, encrypted
  bucket containing two synthetic text objects. `enable_lab04` defaults to false.
- `kubernetes/chaos/irsa-security-breach.yaml`: the `lab04/public-web`
  ServiceAccount, a one-replica Deployment, and an internet-facing NLB Service.
  The HTTP container returns a greeting. An AWS CLI sidecar provides controlled
  simulation tooling with the same ServiceAccount identity.

Use a disposable lab environment and only the synthetic fixtures. The policy
permits unnecessary administration of this one bucket and access outside the
application’s intended `public/` prefix. It does **not** grant account-wide S3
access, `ListAllMyBuckets`, or access to the separate CloudTrail log bucket. The NLB exposes HTTP port 80 and incurs charges.
The manifest contains no application exploit or credential-export endpoint.

## 1. Prerequisites and Terraform setup

Run from the repository root. Use Bash in one shell. You need Terraform, AWS CLI v2, `kubectl`, `jq`,
Python 3 and curl;
operator permissions for this infrastructure and CloudTrail; connectivity to the
private EKS API; and pod egress to regional STS and S3. Confirm your AWS profile,
region, and Kubernetes context target the disposable lab environment. The
operator must already be authorized to create/configure/delete a dedicated trail
and log bucket, retrieve logs, and operate the fixture; this guide grants no
additional permissions to the workload or operator. CloudTrail data events and
the NLB incur charges. All commands below are execution instructions, not observed
results.

```bash
bash
set -euo pipefail
umask 077
export AWS_PAGER=""
AWS_REGION=$(terraform -chdir=terraform output -raw aws_region)
export AWS_REGION
RUN_ID="$(date -u +%Y%m%d%H%M%S)-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:8])')"
RAW="$PWD/.local/irsa-breach/$RUN_ID"
mkdir -p "$RAW"
RUN_START=$(date -u +%FT%TZ)
kubectl config current-context
aws sts get-caller-identity > "$RAW/operator-identity.json"
# Reserve lab04 for this fixture; clean up a previous experiment before restarting.
test -z "$(kubectl get namespace lab04 --ignore-not-found -o name)"
```

The baseline uses EKS Pod Identity. Lab 04 additionally enables the module's IAM
OIDC provider for IRSA; it leaves the baseline add-on associations intact. Do not
create a Pod Identity association for this lab ServiceAccount.

Enable the Terraform-managed AWS Load Balancer Controller using
[the controller setup](../docs/load-balancer-controller.md) before deploying
the Service. It has a separate Pod Identity role; Lab 04’s application still uses
IRSA. The public subnet discovery tags already exist. This Service explicitly selects `service.k8s.aws/nlb` with
internet-facing, IP targets; see the controller's
[Service annotations](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/service/annotations/).

In your local Terraform variable file, preserving existing settings, set:

```hcl
enable_lab04           = true
lab04_least_privilege  = false
```

```sh
terraform -chdir=terraform init
terraform -chdir=terraform fmt -check
terraform -chdir=terraform validate
terraform -chdir=terraform plan -out=lab04.tfplan
```

Review the complete plan before applying. On an existing baseline, expect the
OIDC provider, lab role/policy, fixture bucket/settings, and objects to be added.
An undeployed baseline also plans the cluster and monitoring infrastructure.
Investigate unrelated replacements or deletions. Apply only the reviewed plan:

```sh
terraform -chdir=terraform apply lab04.tfplan
LAB04_ROLE_ARN=$(terraform -chdir=terraform output -raw lab04_role_arn)
LAB04_BUCKET=$(terraform -chdir=terraform output -raw lab04_bucket_name)
LAB04_ROLE_NAME=${LAB04_ROLE_ARN##*/}
LAB04_ACCOUNT=$(jq -r .Account "$RAW/operator-identity.json")
LAB04_PARTITION=$(printf '%s' "$LAB04_ROLE_ARN" | cut -d: -f2)
aws iam get-role --role-name "$LAB04_ROLE_NAME" > "$RAW/role-trust-before.json"
aws iam get-role-policy --role-name "$LAB04_ROLE_NAME" --policy-name lab04-s3-access \
  > "$RAW/policy-before.json"
jq -e --arg bucket "arn:$LAB04_PARTITION:s3:::$LAB04_BUCKET" '
  .PolicyDocument.Statement | length == 1 and
  .[0].Action == "s3:*" and
  (.[0].Resource | sort) == ([$bucket,($bucket + "/*")] | sort)' "$RAW/policy-before.json"
```

The role trust policy requires both `aud = sts.amazonaws.com` and
`sub = system:serviceaccount:lab04:public-web` from this cluster's OIDC provider.
The ServiceAccount annotation associates that role with pods; IRSA injects a
projected token and SDK environment settings on pod creation. AWS STS exchanges
the token through `AssumeRoleWithWebIdentity` for temporary credentials. See
[AWS's IRSA setup](https://docs.aws.amazon.com/eks/latest/userguide/associate-service-account-role.html).

## 2. Enable the audit trail before making object requests

Create a **new dedicated regional trail and separate log bucket** with your
operator identity. The fixture is in this region and the helper uses regional
STS. Basic event selectors retain management events (including STS) and capture
both read/write S3 object data events only under the fixture bucket ARN prefix.
Never run `put-event-selectors` against an existing organization/shared trail.
CloudTrail Event history / `lookup-events` do not provide S3 object data events;
this trail must be logging before the requests. See
[AWS S3 data-event logging](https://docs.aws.amazon.com/AmazonS3/latest/userguide/cloudtrail-logging-s3-info.html).

```bash
LAB04_TRAIL="eks-lab04-$RUN_ID"
LAB04_LOG_BUCKET="eks-lab04-audit-$RUN_ID"
LAB04_LOG_PREFIX=lab04
LAB04_TRAIL_ARN="arn:$LAB04_PARTITION:cloudtrail:$AWS_REGION:$LAB04_ACCOUNT:trail/$LAB04_TRAIL"
# Save resource names BEFORE creation for partial-setup cleanup. No credentials are saved.
declare -p AWS_REGION RUN_ID RUN_START RAW LAB04_ROLE_ARN LAB04_ROLE_NAME LAB04_BUCKET \
  LAB04_ACCOUNT LAB04_PARTITION LAB04_TRAIL LAB04_TRAIL_ARN LAB04_LOG_BUCKET LAB04_LOG_PREFIX \
  > "$RAW/resources.env"
if [ "$AWS_REGION" = us-east-1 ]; then
  aws s3api create-bucket --bucket "$LAB04_LOG_BUCKET" --region "$AWS_REGION"
else
  aws s3api create-bucket --bucket "$LAB04_LOG_BUCKET" --region "$AWS_REGION" \
    --create-bucket-configuration "LocationConstraint=$AWS_REGION"
fi
aws s3api put-public-access-block --bucket "$LAB04_LOG_BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-ownership-controls --bucket "$LAB04_LOG_BUCKET" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
aws s3api put-bucket-encryption --bucket "$LAB04_LOG_BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
jq -n --arg bucket "arn:$LAB04_PARTITION:s3:::$LAB04_LOG_BUCKET" \
  --arg trail "$LAB04_TRAIL_ARN" --arg prefix "$LAB04_LOG_PREFIX/AWSLogs/$LAB04_ACCOUNT/*" '
  {Version:"2012-10-17",Statement:[
    {Sid:"TrailAclCheck",Effect:"Allow",Principal:{Service:"cloudtrail.amazonaws.com"},
     Action:"s3:GetBucketAcl",Resource:$bucket,
     Condition:{StringEquals:{"aws:SourceArn":$trail}}},
    {Sid:"TrailDelivery",Effect:"Allow",Principal:{Service:"cloudtrail.amazonaws.com"},
     Action:"s3:PutObject",Resource:($bucket+"/"+$prefix),
     Condition:{StringEquals:{"aws:SourceArn":$trail,"s3:x-amz-acl":"bucket-owner-full-control"}}}
  ]}' > "$RAW/log-bucket-policy.json"
aws s3api put-bucket-policy --bucket "$LAB04_LOG_BUCKET" --policy "file://$RAW/log-bucket-policy.json"
aws cloudtrail create-trail --name "$LAB04_TRAIL" --s3-bucket-name "$LAB04_LOG_BUCKET" \
  --s3-key-prefix "$LAB04_LOG_PREFIX" --no-is-multi-region-trail \
  --no-include-global-service-events --enable-log-file-validation > "$RAW/trail-created.json"
jq -n --arg prefix "arn:$LAB04_PARTITION:s3:::$LAB04_BUCKET/" '
  [{ReadWriteType:"All",IncludeManagementEvents:true,
    DataResources:[{Type:"AWS::S3::Object",Values:[$prefix]}]}]' > "$RAW/event-selectors.json"
aws cloudtrail put-event-selectors --trail-name "$LAB04_TRAIL" \
  --event-selectors "file://$RAW/event-selectors.json" > "$RAW/selectors-applied.json"
aws cloudtrail start-logging --name "$LAB04_TRAIL"
aws cloudtrail get-trail-status --name "$LAB04_TRAIL" > "$RAW/trail-status.json"
aws cloudtrail get-event-selectors --trail-name "$LAB04_TRAIL" > "$RAW/selectors-observed.json"
jq -e '.IsLogging == true' "$RAW/trail-status.json"
jq -e --arg prefix "arn:$LAB04_PARTITION:s3:::$LAB04_BUCKET/" '
  .EventSelectors | length == 1 and .[0].ReadWriteType == "All" and
  .[0].IncludeManagementEvents == true and
  .[0].DataResources == [{Type:"AWS::S3::Object",Values:[$prefix]}]' "$RAW/selectors-observed.json"
```

The log bucket policy follows [AWS’s CloudTrail delivery policy](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-s3-bucket-policy-for-cloudtrail.html),
allowing only the service’s ACL check and delivery under this trail’s account
prefix, with an exact `aws:SourceArn`. No workload grant is added. The existing
fixture-scoped role cannot administer or read this separate bucket. Logs remain
private and SSE-S3 encrypted. This disposable log bucket starts unversioned;
do not enable versioning/Object Lock unless you also adapt retention/cleanup.

Define this repeatable download/correlation helper now. It uses this newly
created trail’s known path, handles runs crossing UTC midnight, deduplicates
records, and prints no token/credential values. No matching events produces an
empty output, never a fabricated result.

```bash
collect_cloudtrail() {
  mkdir -p "$RAW/cloudtrail" || return $?
  aws s3 cp "s3://$LAB04_LOG_BUCKET/$LAB04_LOG_PREFIX/AWSLogs/$LAB04_ACCOUNT/CloudTrail/$AWS_REGION/" \
    "$RAW/cloudtrail/" --recursive --exclude '*' --include '*.json.gz' > "$RAW/log-download.txt" || return $?
  python3 - "$RAW" "$LAB04_ROLE_ARN" "$LAB04_BUCKET" "$RUN_START" <<'PY'
import gzip, json, sys
from pathlib import Path
raw, role, bucket, start = sys.argv[1:]
seen = set()
with (Path(raw) / 'cloudtrail-correlated.jsonl').open('w') as out:
    for path in sorted((Path(raw) / 'cloudtrail').rglob('*.json.gz')):
        with gzip.open(path, 'rt') as source:
            for event in json.load(source).get('Records', []):
                if event.get('eventTime', '') < start or event.get('eventID') in seen:
                    continue
                identity = event.get('userIdentity', {})
                issuer = identity.get('sessionContext', {}).get('sessionIssuer', {}).get('arn')
                req = event.get('requestParameters') or {}
                s3 = (event.get('eventSource') == 's3.amazonaws.com' and
                      issuer == role and req.get('bucketName') == bucket)
                sts = (event.get('eventName') == 'AssumeRoleWithWebIdentity' and
                       req.get('roleArn') == role)
                if not (s3 or sts):
                    continue
                seen.add(event.get('eventID'))
                row = {k: event.get(k) for k in ['eventTime','eventSource','eventName',
                       'eventID','requestID','awsRegion','sourceIPAddress','userAgent',
                       'errorCode','errorMessage']}
                row.update(role=issuer or req.get('roleArn'), session=identity.get('arn'),
                           roleSessionName=req.get('roleSessionName'),
                           bucket=req.get('bucketName'), key=req.get('key'))
                out.write(json.dumps(row) + '\n')
PY
}

# Invoke directly (not through a pipeline); a nonzero return stops set -e.
# jq must return one boolean: only exit 1 (false) means delivery is pending.
wait_cloudtrail() {
  local label=$1
  shift
  local deadline=$((SECONDS + 900)) rc remaining
  while :; do
    if collect_cloudtrail; then
      :
    else
      rc=$?
      printf '%s FAILURE %s: collection failed (exit %s)\n' "$(date -u +%FT%TZ)" "$label" "$rc" >&2
      return "$rc"
    fi
    if jq -e -s "$@" "$RAW/cloudtrail-correlated.jsonl" > /dev/null; then
      printf '%s FOUND %s: matching event captured\n' "$(date -u +%FT%TZ)" "$label"
      return 0
    else
      rc=$?
      if [ "$rc" -ne 1 ]; then
        printf '%s FAILURE %s: evidence query failed (exit %s)\n' "$(date -u +%FT%TZ)" "$label" "$rc" >&2
        return "$rc"
      fi
    fi
    remaining=$((deadline - SECONDS))
    if [ "$remaining" -le 0 ]; then
      printf '%s TIMEOUT %s: no matching event within 900s; evidence incomplete\n' "$(date -u +%FT%TZ)" "$label" >&2
      return 124
    fi
    printf '%s WAITING %s: no matching event yet (%ss remaining)\n' "$(date -u +%FT%TZ)" "$label" "$remaining"
    if [ "$remaining" -gt 15 ]; then remaining=15; fi
    sleep "$remaining" || return $?
  done
}
```

After the ServiceAccount steps, verify actual delivery with a benign public-object
read before the private-object exercise. `IsLogging=true` alone is insufficient.
The poller waits up to 15 minutes, checking every 15 seconds (plus collection
request time). `WAITING` tolerates only a valid query returning false; `FOUND`
requires the matching event. `TIMEOUT` returns 124 with evidence incomplete.
Download, decoding, and query errors print `FAILURE` and return nonzero immediately,
preserving the documented `set -e` stop. Do not wrap calls in `|| true` or disable
`set -e`. On timeout/error, inspect trail status for `LatestDeliveryError` and
resolve the cause before resuming with the same run context and polling again.
Do not repeatedly generate private reads or claim evidence until it is captured.

## 3. Associate the ServiceAccount and expose the demo

Create and annotate the ServiceAccount **before** creating the Deployment:

```sh
kubectl create namespace lab04 --dry-run=client -o yaml | kubectl apply -f -
kubectl -n lab04 create serviceaccount public-web --dry-run=client -o yaml | kubectl apply -f -
kubectl -n lab04 annotate serviceaccount public-web \
  eks.amazonaws.com/role-arn="$LAB04_ROLE_ARN" \
  eks.amazonaws.com/sts-regional-endpoints=true --overwrite
kubectl apply -f kubernetes/chaos/irsa-security-breach.yaml
# After the annotation setup, make lab04-trigger is equivalent to the apply above.
kubectl -n lab04 rollout status deployment/public-web --timeout=180s
kubectl -n lab04 get service public-web
kubectl -n lab04 get serviceaccount public-web -o json > "$RAW/serviceaccount.json"
jq -e --arg role "$LAB04_ROLE_ARN" '
  .metadata.annotations["eks.amazonaws.com/role-arn"] == $role and
  .metadata.annotations["eks.amazonaws.com/sts-regional-endpoints"] == "true"' "$RAW/serviceaccount.json"
```

The manifest leaves the role annotation unset so your local ARN is supplied by
the setup step. If you applied it before annotation, restart the Deployment and
wait for rollout so the IRSA webhook processes fresh pods:
`kubectl -n lab04 rollout restart deployment/public-web`, then rerun rollout
status and capture the new pod name below. The annotation is added imperatively;
the source manifest does not manage/remove that key. Verify it after every apply.
Do not annotate the AWS Load Balancer Controller ServiceAccount with this role.

Once the Service has an external hostname:

```sh
LAB04_HOST=$(kubectl -n lab04 get service public-web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
test -n "$LAB04_HOST" && curl --fail "http://$LAB04_HOST/"
POD=$(kubectl -n lab04 get pods -l app=lab04-public-web -o jsonpath='{.items[0].metadata.name}')
aws_pod() {
  kubectl -n lab04 exec "$POD" -c aws-tools -- env AWS_ROLE_SESSION_NAME="$POD" aws "$@"
}
kubectl -n lab04 get pod "$POD" -o json | jq '{name:.metadata.name,uid:.metadata.uid,
  node:.spec.nodeName,serviceAccount:.spec.serviceAccountName,
  containers:[.spec.containers[] | {name,irsaEnv:[.env[]? |
    select(.name == "AWS_ROLE_ARN" or .name == "AWS_WEB_IDENTITY_TOKEN_FILE" or .name == "AWS_REGION")]}]}' \
  > "$RAW/pod-identity-metadata.json"
jq -e --arg role "$LAB04_ROLE_ARN" '
  .serviceAccount == "public-web" and all(.containers[];
    any(.irsaEnv[]; .name == "AWS_ROLE_ARN" and .value == $role) and
    any(.irsaEnv[]; .name == "AWS_WEB_IDENTITY_TOKEN_FILE" and (.value | length > 0)))' \
  "$RAW/pod-identity-metadata.json"
aws_pod sts get-caller-identity > "$RAW/assumed-identity.json"
jq -e --arg expected "arn:$LAB04_PARTITION:sts::$LAB04_ACCOUNT:assumed-role/$LAB04_ROLE_NAME/$POD" \
  '.Arn == $expected' "$RAW/assumed-identity.json"
cat "$RAW/assumed-identity.json"
# A known-good read verifies IRSA, legitimate access, and actual trail delivery.
aws_pod s3api get-object --bucket "$LAB04_BUCKET" --key public/hello.txt /tmp/hello.txt \
  > "$RAW/public-before.json"
wait_cloudtrail public-read --arg session "$(jq -r .Arn "$RAW/assumed-identity.json")" '
  any(.[]; .eventName == "GetObject" and .key == "public/hello.txt" and
    .session == $session and .errorCode == null)'
```

Verify the caller is an assumed session of the Terraform lab role, not the node
role. The CLI sidecar disables EC2 metadata fallback. If the Service remains
Pending, inspect `kubectl -n lab04 describe service public-web` and controller
events/logs. IRSA failures need checking of the annotation, trust conditions,
OIDC provider, new-pod injection, and STS connectivity.

## 4. Understand and simulate the attack path

Public reachability is an entry point, not proof of compromise. Assume an attacker
has obtained code execution in the web container through a separate application
vulnerability. Code running there can use its projected IRSA token to request
the same role credentials. Root access or node credentials are unnecessary.
The CLI sidecar is a convenient operator-controlled stand-in for that execution;
access to the greeting endpoint does not itself grant `kubectl exec` access.

The excessive policy lets that role list the fixture bucket and read its objects
beyond the application’s intended `public/` prefix. After a successful `GetObject`, an
attacker could send the bytes through an outbound connection or a compromised
HTTP response. It also permits writes, deletion, and policy changes within that fixture bucket. SCPs,
permissions boundaries, explicit denies, and cross-account resource policies
still apply; `s3:*` does not grant KMS decryption or unrestricted cross-account
access. The synthetic fixtures use SSE-S3 to avoid a separate KMS dependency.

“Unauthorized” here means outside the application’s intended permissions;
the flawed IAM policy currently authorizes it. Do not test access against any
other bucket. Use only the generated synthetic bucket:

```sh
PRIVATE_START=$(date -u +%FT%TZ)
printf '%s private-read-start pod=%s\n' "$PRIVATE_START" "$POD" >> "$RAW/timeline.txt"
aws_pod s3api list-objects-v2 --bucket "$LAB04_BUCKET" --prefix private/ > "$RAW/private-list-before.json"
aws_pod s3api get-object --bucket "$LAB04_BUCKET" \
  --key private/customer-demo.txt /tmp/customer-demo.txt > "$RAW/private-get-before.json"
kubectl -n lab04 exec "$POD" -c aws-tools -- cat /tmp/customer-demo.txt > "$RAW/synthetic-copy.txt"
printf '%s private-read-complete\n' "$(date -u +%FT%TZ)" >> "$RAW/timeline.txt"
```

The final command demonstrates the synthetic bytes leaving the pod into your
local lab workspace. It uses the operator's Kubernetes channel, not an actual
attacker-controlled external destination. Keep the UTC time and pod name for
correlation. Do not print or copy projected tokens or temporary credentials.

## 5. Trace the API calls in CloudTrail

Poll the dedicated trail with the bounded helper in section 2. Continue only
after `FOUND`; timeout/failure stops execution with incomplete evidence. Do not
use `lookup-events` for S3 data events.

```bash
wait_cloudtrail private-read --arg session "$(jq -r .Arn "$RAW/assumed-identity.json")" --arg start "$PRIVATE_START" '
  any(.[]; .eventName == "GetObject" and .key == "private/customer-demo.txt" and
    .session == $session and .eventTime >= $start and .errorCode == null)'
cat "$RAW/cloudtrail-correlated.jsonl"
cp "$RAW/cloudtrail-correlated.jsonl" "$RAW/cloudtrail-before.jsonl"
```

Find the successful `GetObject` for `private/customer-demo.txt` near your recorded
time. Inspect `eventTime`, `eventName`, bucket/key, the role's session issuer ARN,
session ARN, source IP, user agent, and any error. The session name should match
the pod name supplied by the helper. Source IP can be the cluster NAT's public
IP rather than the pod IP. See the
[CloudTrail event fields](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-event-reference-record-contents.html).

Also inspect STS `AssumeRoleWithWebIdentity` management events around that time,
matching `requestParameters.roleArn` and the role session name. Event history can
help find these management events in the STS region; the helper uses regional
STS. Correlate with EKS audit logs for `pods/exec`, the pod's UID/node, and web
access logs. Session names are caller-selected clues, not proof of pod identity.

CloudTrail records the S3 read, not the later transfer through HTTP or `kubectl
exec`. A successful read demonstrates access, but does not alone prove onward
exfiltration. Preserve the relevant logs and use Kubernetes/network/application
evidence to establish that next step. Missing data events are an evidence gap,
not proof that no read occurred.

## 6. Replace the broad policy with least privilege

Assume the application's legitimate requirement is listing and reading only
`public/` in the fixture bucket. If a real static greeting service needs no S3
access, remove its S3 role entirely. For the prefix-read example, the remediation
already exists in `terraform/lab04_irsa.tf`. Set:

```hcl
enable_lab04          = true
lab04_least_privilege = true
```

The replacement policy grants exactly:

| Action | Resource | Restriction |
| --- | --- | --- |
| `s3:ListBucket` | The fixture bucket ARN | `s3:prefix` matches `public/` or `public/*` |
| `s3:GetObject` | The fixture bucket ARN plus `/public/*` | Only those object keys |

Bucket listing uses a bucket ARN; object reads use object ARNs. Do not grant
`ListAllMyBuckets`, writes, deletion, or bucket administration for this use case.
See AWS's [prefix-scoped policy examples](https://docs.aws.amazon.com/AmazonS3/latest/userguide/example-policies-s3.html).
If SSE-KMS is required, separately scope needed KMS access to the specific key
and appropriate key policy; do not add `kms:*`.

```sh
terraform -chdir=terraform plan -out=lab04-remediation.tfplan
# Review: the lab inline policy should be replaced in place with the narrow policy.
terraform -chdir=terraform apply lab04-remediation.tfplan
aws iam get-role-policy --role-name "$LAB04_ROLE_NAME" --policy-name lab04-s3-access \
  > "$RAW/policy-after.json"
printf '%s remediation-applied\n' "$(date -u +%FT%TZ)" >> "$RAW/timeline.txt"
```

Replace the broad Allow; adding a narrow policy alongside it leaves broad access
intact. Inspect other attached policies and resource policies for additional grants.
Keep the exact ServiceAccount trust conditions. After IAM propagation, verify:

```sh
POST_FIX_START=$(date -u +%FT%TZ)
aws_pod sts get-caller-identity > "$RAW/assumed-identity-after.json"
jq -e --arg expected "$(jq -r .Arn "$RAW/assumed-identity.json")" \
  '.Arn == $expected' "$RAW/assumed-identity-after.json"
# Expected: allowed; failure here is not a successful remediation test.
aws_pod s3api list-objects-v2 --bucket "$LAB04_BUCKET" --prefix public/ > "$RAW/public-list-after.json"
aws_pod s3api get-object --bucket "$LAB04_BUCKET" --key public/hello.txt /tmp/hello.txt \
  > "$RAW/public-get-after.json"
expect_denied() {
  local name="$1" rc=0
  shift
  aws_pod "$@" > "$RAW/$name.txt" 2>&1 || rc=$?
  printf '\nexit_code=%s\n' "$rc" >> "$RAW/$name.txt"
  cat "$RAW/$name.txt"
  test "$rc" -ne 0
  # Network/credential errors must not masquerade as denied authorization.
  grep -q 'AccessDenied' "$RAW/$name.txt"
}
expect_denied private-list-after s3api list-objects-v2 --bucket "$LAB04_BUCKET" --prefix private/
expect_denied private-get-after s3api get-object --bucket "$LAB04_BUCKET" \
  --key private/customer-demo.txt /tmp/denied.txt
expect_denied write-after s3api put-object --bucket "$LAB04_BUCKET" \
  --key public/should-be-denied.txt --body /tmp/hello.txt
printf '%s post-fix-checks-complete\n' "$(date -u +%FT%TZ)" >> "$RAW/timeline.txt"
# Require the denied GetObject evidence before proceeding to cleanup.
wait_cloudtrail denied-read --arg start "$POST_FIX_START" \
  --arg session "$(jq -r .Arn "$RAW/assumed-identity-after.json")" '
  any(.[]; .session == $session and .eventName == "GetObject" and .key == "private/customer-demo.txt" and
    .eventTime >= $start and (.errorCode // "" | contains("AccessDenied")))'
cp "$RAW/cloudtrail-correlated.jsonl" "$RAW/cloudtrail-after.jsonl"
```

A successful forbidden operation means remediation is incomplete; inspect the
effective grants and allow for IAM propagation. If the write unexpectedly
succeeds, remove that synthetic object with your operator identity during cleanup.
Confirm the denied reads in the data-event logs. In a real active incident,
contain the workload and revoke compromised role sessions as well as correcting
permissions; deleting a pod alone does not invalidate issued STS credentials.

## 7. Evidence and cleanup

Keep actual outputs under `$RAW`; none are prefilled. Before cleanup, collect
remaining trail deliveries and preserve the original compressed logs. Review and
sanitize copies before sharing. Use these files as the evidence checklist:

| Evidence | Files |
| --- | --- |
| Effective bucket-scoped flaw and trust | `policy-before.json`, `role-trust-before.json` |
| Assumed role and pod linkage | `serviceaccount.json`, `pod-identity-metadata.json`, `assumed-identity.json` |
| Synthetic access outside intended prefix | `private-list-before.json`, `private-get-before.json`, `synthetic-copy.txt`, `timeline.txt` |
| Audit configuration and correlation | `trail-status.json`, `selectors-observed.json`, `cloudtrail-before.jsonl`, original `cloudtrail/` logs |
| Remediation and legitimate access | `policy-after.json`, `assumed-identity-after.json`, `public-list-after.json`, `public-get-after.json` |
| Denied forbidden requests | `private-list-after.txt`, `private-get-after.txt`, `write-after.txt`, `cloudtrail-after.jsonl` |
| Cleanup record | `resources.env`, `cleanup.txt`, reviewed Terraform cleanup plan |

`evidence/irsa-breach/cleanup.txt` is an empty capture placeholder. After
execution, review and sanitize a copy of `$RAW/cleanup.txt` there; keep the
remaining checklist artifacts under `$RAW` until reviewed for sharing.

Write an operator summary with UTC times, actual role/session and pod aliases,
read event/request IDs, remediation, denied results and any gaps. Do not report
an authorization fix merely because a pod stopped working. The same identity
must still perform legitimate reads while forbidden operations return AccessDenied.

### Remove the NLB before its namespace

Capture the exact NLB ARN before deleting its Service. Do not delete the whole
manifest first: it includes the namespace and the controller needs to reconcile
Service finalizers. Keep the shared controller and its Pod Identity enabled.

```bash
LAB04_HOST=$(kubectl -n lab04 get service public-web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
: "${LAB04_HOST:?Resolve pending/partial Service creation before cleanup}"
aws elbv2 describe-load-balancers > "$RAW/load-balancers-before-cleanup.json"
LAB04_NLB_ARN=$(jq -er --arg host "$LAB04_HOST" '
  [.LoadBalancers[] | select(.DNSName == $host)] |
  if length == 1 then .[0].LoadBalancerArn else error("Resolve actual NLB ownership") end' \
  "$RAW/load-balancers-before-cleanup.json")
declare -p LAB04_NLB_ARN >> "$RAW/resources.env"
aws elbv2 describe-target-groups --load-balancer-arn "$LAB04_NLB_ARN" > "$RAW/target-groups-before-cleanup.json"
kubectl -n lab04 delete service public-web --ignore-not-found --wait=true --timeout=10m
aws elbv2 wait load-balancers-deleted --load-balancer-arns "$LAB04_NLB_ARN"
# Inspect recorded target groups and controller security groups/ENIs too; see docs/teardown.md.
kubectl delete -f kubernetes/chaos/irsa-security-breach.yaml --ignore-not-found --wait=true --timeout=10m
printf '%s Kubernetes fixture deleted; NLB deletion waiter passed\n' "$(date -u +%FT%TZ)" >> "$RAW/cleanup.txt"
```

For partial setup or reruns, recover recorded names from your own protected
`resources.env` (inspect it before sourcing). If the Service never obtained a
hostname, inventory controller-tagged resources and events instead of assuming
nothing was created. If already removed, reuse the recorded ARN for the waiter;
a permission error is not proof of absence. Follow [teardown](../docs/teardown.md)
for orphan target groups/security groups/ENIs; never strip finalizers blindly.

### Remove the Terraform fixture, retaining the shared baseline

With the operator identity, remove only the optional synthetic object if a
post-fix write unexpectedly succeeded:

```bash
aws s3api delete-object --bucket "$LAB04_BUCKET" --key public/should-be-denied.txt
aws s3api list-objects-v2 --bucket "$LAB04_BUCKET" > "$RAW/fixture-objects-before-cleanup.json"
```

Confirm only the two Terraform-managed fixtures remain; remove any other
operator-created test objects by exact key after ownership review. Set
`enable_lab04 = false`, preserving the controller flag and other settings. First
confirm no other IRSA workloads depend on this lab’s optional OIDC provider.
Review/apply only the Lab 04 removal plan; Terraform deletes the two tracked
objects and the fixture bucket (`force_destroy = false`), role/policy and OIDC
provider. Do not destroy the baseline cluster to clean up this experiment.

```bash
terraform -chdir=terraform plan -out=lab04-cleanup.tfplan
terraform -chdir=terraform show lab04-cleanup.tfplan
# After reviewing that only Lab 04 resources are removed:
terraform -chdir=terraform apply lab04-cleanup.tfplan
printf '%s Terraform fixture cleanup completed\n' "$(date -u +%FT%TZ)" >> "$RAW/cleanup.txt"
```

### Remove the dedicated audit resources

Wait for the needed success and denied events before stopping logging. Archive
raw logs and digest files to access-restricted storage outside this checkout,
then remove the dedicated trail and its unversioned destination bucket. These
names were created for this run; never substitute shared/organization resources.

```bash
aws cloudtrail stop-logging --name "$LAB04_TRAIL"
aws cloudtrail delete-trail --name "$LAB04_TRAIL"
# Includes digest files as well as regional event logs.
aws s3 cp "s3://$LAB04_LOG_BUCKET/" "$RAW/audit-archive/" --recursive
# Stop here until the archive is copied to protected storage and verified readable.
# This lab did not enable versioning; refuse this cleanup if that has changed.
aws s3api get-bucket-versioning --bucket "$LAB04_LOG_BUCKET" > "$RAW/log-bucket-versioning.json"
jq -e '.Status == null' "$RAW/log-bucket-versioning.json"
aws s3 rm "s3://$LAB04_LOG_BUCKET/" --recursive
aws s3api delete-bucket --bucket "$LAB04_LOG_BUCKET"
printf '%s Dedicated trail and log bucket removed\n' "$(date -u +%FT%TZ)" >> "$RAW/cleanup.txt"
```

If delivery races with bucket emptying, repeat the listing/removal for this exact
bucket after the trail is deleted. For partial cleanup, skip an already deleted
trail/bucket only after confirming absence in the correct account/region; do not
hide AccessDenied or other errors. Do not force-remove Object Lock or retention.
Verify no dedicated trail, log bucket, NLB or Terraform Lab 04 resources remain;
record any intentionally retained audit archive separately.

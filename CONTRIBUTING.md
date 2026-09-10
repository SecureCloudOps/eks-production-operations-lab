# Contributing and reproducing results

Keep changes small enough to review against the lab's operational purpose.
Before editing, identify whether the file is infrastructure, a deliberately faulty
fixture, a runbook or historical evidence. A fault in a training fixture is not
automatically a bug to remove.

## Local validation

Install the tools listed in the [README](README.md#validate-without-deployment),
initialize Terraform without upgrading dependencies, then run:

```bash
make validate
make validate-schemas
git diff --check
```

These checks do not deploy or require live AWS reads. An infrastructure change
also needs an operator-reviewed plan against the correct state and private inputs.
Do not mix module/provider upgrades with incident recovery. Do not run an apply,
destroy, lab trigger or live probe merely to validate a documentation change.

## Runbook changes

- State the expected baseline, target namespace/resource and ownership boundary.
- Distinguish observed outcomes from hypotheses and expected outcomes.
- Record command failures; do not treat permission errors as resource absence.
- Keep restoration and cleanup instructions usable after a partial failure.
- Keep controllers, workers and IAM available until their AWS cleanup finishes.
- Verify AWS load-balancer deletion before removing its namespace.
- Treat each new shell as a new session: explicitly select profile, region,
  kubeconfig/context and capture directory before live operations.

## Evidence changes

Preserve original private captures before sanitizing. Publish selected observations
or sanitized copies with the execution date, scope, limitations and provenance.
Keep failed requests, counterexamples and missing measurements visible. Never
fill a placeholder with an expected result that was not observed.

Do not commit AWS account IDs, credentials, state, saved plans, real tfvars,
operator addresses, resource endpoints or full private inventories. Documentation
example CIDRs and Terraform network definitions are distinct from captured live
addresses. A `.gitignore` rule does not remove an already committed file or its
history. Before the first push, review every reachable commit as well as HEAD.

Do not rewrite published history or remove evidence to improve a result. Any
necessary privacy rewrite needs a verified backup, a reviewed replacement and
coordination with anyone who has fetched the old commits.

## Pull request notes

Describe the concrete problem, resulting behavior, checks actually run and any
remaining execution limits. Link the relevant lab or evidence summary. Keep raw
outputs and private infrastructure identifiers out of descriptions and issues.

The repository uses the [MIT License](LICENSE). Preserve applicable upstream
licenses and attribution when adapting third-party material; see
[third-party notices](THIRD_PARTY_NOTICES.md).

## Publication and CI safeguards

`make test` exercises the cleanup gate with mocked AWS responses, including its
integration with `make down`; it never invokes real cloud mutations. `make validate`
includes these tests. The gate rejects missing/null response collections as well
as AWS failures and remaining resources.

Before publication, run `python3 scripts/check-publication.py --history HEAD`
and `gitleaks git . --log-opts=HEAD --config=.gitleaks.toml --redact` using
Gitleaks 8.30.0. The publication guard checks captured hostnames and private artifact
paths; it complements secret detection and manual review, rather than proving
that every possible identifying value is absent. The two Gitleaks exceptions
require both the exact reviewed source hash and the Lab 04 provenance path.

CI checks full reachable history. Actions use commit SHAs; kubeconform and
Gitleaks archives are checked against committed release SHA-256 values before
execution. When updating a tool, review the upstream release and checksum, update
both together, and validate before merging. Do not disable integrity checks to
resolve a download failure. Runtime image tags and Helm/module releases still
need their separate compatibility and vulnerability reviews.

# Third-party notices

## AWS Load Balancer Controller IAM policy

[terraform/iam/load-balancer-controller.json.tftpl](terraform/iam/load-balancer-controller.json.tftpl)
is adapted from the Kubernetes SIGs AWS Load Balancer Controller
[v2.14.1 IAM policy](https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/v2.14.1/docs/install/iam_policy.json).
The upstream project licenses this material under Apache License 2.0; its
[license text is included here](LICENSES/aws-load-balancer-controller-Apache-2.0.txt).

This repository changes the policy to scope applicable resources to the lab's
account, region, VPC and ownership tags, and removes permissions for unused
features. The [controller guide](docs/load-balancer-controller.md) describes the
modifications. The repository's own license does not replace the applicable
upstream terms for this adapted material.

## Downloaded dependencies

Terraform modules/providers, Helm charts, container images and validation tools
are referenced or downloaded rather than vendored into this repository. Their
respective licenses remain applicable. Sources and selected versions are recorded
in Terraform declarations, the provider lockfile, manifests and the CI workflow.
Local dependency caches are Git-ignored.

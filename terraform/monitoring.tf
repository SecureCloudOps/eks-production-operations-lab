# Run Terraform with AWS CLI v2 installed, using the same IAM identity as the
# AWS provider. The runner must reach the EKS API on TCP 443 through either the
# private endpoint and cluster security group, or the public operator CIDR
# allowlist. See README.md. No local kubeconfig or short-lived token stored in state.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region", var.aws_region,
        "--output", "json",
      ]
    }
  }
}

resource "helm_release" "monitoring" {
  name             = "kube-prometheus-stack"
  repository       = "oci://ghcr.io/prometheus-community/charts"
  chart            = "kube-prometheus-stack"
  version          = "89.2.2"
  namespace        = "monitoring"
  create_namespace = true

  values = [file("${path.module}/prometheus-values.yaml")]

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  wait_for_jobs   = true
  timeout         = 900
  skip_crds       = false

  # Includes managed node groups, CoreDNS, CNI, and the creator's access entry.
  # On destroy, Terraform removes the release before removing the cluster.
  depends_on = [module.eks]

  # Helm waits for chart workloads/jobs, but does not guarantee that every
  # operator-created Prometheus pod or scrape target is healthy.
  # Review upstream CRD upgrade instructions before changing the chart pin:
  # atomic rollback does not roll back CRDs or recover monitoring data.
}

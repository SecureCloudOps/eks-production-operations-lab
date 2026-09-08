data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# A separate role for kube-system/aws-node keeps networking permissions off nodes.
resource "aws_iam_role" "vpc_cni" {
  name_prefix = "eks-vpc-cni-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = {
          "aws:RequestTag/eks-cluster-arn"            = "arn:${data.aws_partition.current.partition}:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
          "aws:RequestTag/kubernetes-namespace"       = "kube-system"
          "aws:RequestTag/kubernetes-service-account" = "aws-node"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Gate the CNI add-on and node subnets, not the whole module: module-wide
# depends_on defers account/partition data needed by node-group count expressions.
# terraform_data records a dependency only; it runs no provisioner or AWS action.
resource "terraform_data" "cni_bootstrap" {
  input = {
    role_arn   = aws_iam_role.vpc_cni.arn
    subnet_ids = [for az in var.availability_zones : aws_subnet.private[az].id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.vpc_cni,
    aws_route.private_nat,
    aws_route.public_internet,
    aws_route_table_association.private,
    aws_route_table_association.public,
  ]

  lifecycle {
    precondition {
      condition = alltrue([
        for version in values(var.node_group_versions) :
        try(contains([0, 1], tonumber(split(".", var.cluster_version)[1]) - tonumber(split(".", version)[1])), false)
      ])
      error_message = "Lab workers must match the control plane or be one minor behind it. Advance the control plane first, then one node group at a time."
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.22.0"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version
  ip_family          = "ipv4"

  vpc_id     = aws_vpc.this.id
  subnet_ids = [for az in var.availability_zones : aws_subnet.private[az].id]

  # Public management access requires an explicit operator allowlist.
  endpoint_private_access      = true
  endpoint_public_access       = length(var.operator_public_access_cidrs) > 0
  endpoint_public_access_cidrs = var.operator_public_access_cidrs
  authentication_mode          = "API"

  security_group_additional_rules = {
    operator_https = {
      description = "Private EKS API access from the operator network"
      type        = "ingress"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_blocks = [var.operator_cidr]
    }
  }

  # Grants the Terraform caller an explicit, removable administrator access entry.
  enable_cluster_creator_admin_permissions = true

  # Creates the EKS service role and attaches AmazonEKSClusterPolicy.
  create_iam_role = true
  enable_irsa     = var.enable_lab04 # Baseline add-ons still use EKS Pod Identity.

  enabled_log_types                      = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cloudwatch_log_group_retention_in_days = 30
  # EKS >=1.28 already encrypts API data with an AWS-owned key.
  # Preserve the opt-in for clusters that already use this root's CMK.
  create_kms_key          = var.use_customer_managed_kms_key
  enable_kms_key_rotation = true
  encryption_config       = var.use_customer_managed_kms_key ? { resources = ["secrets"] } : null

  addons = {
    # Host-networked agents bootstrap without CoreDNS or CNI pod networking.
    eks-pod-identity-agent = {
      addon_version  = lookup(var.addon_versions, "eks-pod-identity-agent", null)
      before_compute = true
      most_recent    = false
    }
    vpc-cni = {
      addon_version  = lookup(var.addon_versions, "vpc-cni", null)
      before_compute = true
      most_recent    = false
      # Native enforcement for Lab 05; standard mode preserves startup connectivity.
      # Keep the existing Pod Identity association and all CNI IAM/bootstrap wiring.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
        env = {
          NETWORK_POLICY_ENFORCING_MODE = "standard"
        }
      })
      pod_identity_association = [{
        role_arn        = terraform_data.cni_bootstrap.output.role_arn
        service_account = "aws-node"
      }]
    }
    kube-proxy = {
      addon_version = lookup(var.addon_versions, "kube-proxy", null)
      most_recent   = false
    }
    coredns = {
      addon_version = lookup(var.addon_versions, "coredns", null)
      most_recent   = false
      configuration_values = jsonencode({
        replicaCount        = 2
        podDisruptionBudget = { enabled = true, maxUnavailable = 1 }
        nodeSelector        = { workload = "system" }
        # Preserve standard tolerations when adding the custom system taint.
        tolerations = [
          { key = "CriticalAddonsOnly", operator = "Exists" },
          { key = "node-role.kubernetes.io/control-plane", operator = "Exists", effect = "NoSchedule" },
          { key = "critical-addons", operator = "Equal", value = "true", effect = "NoSchedule" }
        ]
      })
    }
  }

  eks_managed_node_groups = local.eks_managed_node_groups

}

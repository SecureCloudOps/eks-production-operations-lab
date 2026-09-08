variable "enable_load_balancer_controller" {
  description = "Install the ALB/NLB controller required by Labs 04 and 05. Remove its AWS load balancers before disabling or destroying it; see docs/teardown.md."
  type        = bool
  default     = true
  nullable    = false
}

resource "aws_iam_role" "load_balancer_controller" {
  count       = var.enable_load_balancer_controller ? 1 : 0
  name_prefix = "eks-lbc-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = {
          "aws:RequestTag/eks-cluster-arn"            = module.eks.cluster_arn
          "aws:RequestTag/kubernetes-namespace"       = "kube-system"
          "aws:RequestTag/kubernetes-service-account" = "aws-load-balancer-controller"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "load_balancer_controller" {
  count = var.enable_load_balancer_controller ? 1 : 0
  name  = "lab-alb-nlb-controller"
  role  = aws_iam_role.load_balancer_controller[0].id
  policy = templatefile("${path.module}/iam/load-balancer-controller.json.tftpl", {
    partition               = data.aws_partition.current.partition
    region                  = var.aws_region
    account_id              = data.aws_caller_identity.current.account_id
    cluster_name            = var.cluster_name
    vpc_arn                 = aws_vpc.this.arn
    node_security_group_arn = "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:security-group/${module.eks.node_security_group_id}"
  })
}

resource "aws_eks_pod_identity_association" "load_balancer_controller" {
  count           = var.enable_load_balancer_controller ? 1 : 0
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.load_balancer_controller[0].arn
  # Session tags are required by the narrow role trust above.
  disable_session_tags = false
}

resource "helm_release" "load_balancer_controller" {
  count      = var.enable_load_balancer_controller ? 1 : 0
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.14.1" # Controller v2.14.1; IAM policy derives from this release.

  values = [
    file("${path.module}/load-balancer-controller-values.yaml"),
    yamlencode({
      clusterName = module.eks.cluster_name
      region      = var.aws_region
      vpcId       = aws_vpc.this.id
    })
  ]

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600
  skip_crds       = false

  # Workers, CNI, Pod Identity agent, IAM and association must precede the pods.
  # Reverse destroy ordering keeps these available through Helm uninstall.
  # Kubernetes-owned load balancers require the separate teardown gate FIRST.
  depends_on = [
    module.eks,
    aws_iam_role_policy.load_balancer_controller,
    aws_eks_pod_identity_association.load_balancer_controller,
  ]
}

output "load_balancer_controller" {
  description = "Controller setup for Labs 04/05; null until enabled. No load balancer is created by this release alone."
  value = var.enable_load_balancer_controller ? {
    release         = helm_release.load_balancer_controller[0].name
    namespace       = "kube-system"
    service_account = "aws-load-balancer-controller"
    ingress_class   = "alb"
    service_class   = "service.k8s.aws/nlb"
    chart_version   = "1.14.1"
  } : null
}

output "cluster_name" {
  description = "EKS cluster name for aws eks update-kubeconfig."
  value       = module.eks.cluster_name
}

output "aws_region" {
  description = "AWS region for aws eks update-kubeconfig."
  value       = var.aws_region
}

output "cluster_endpoint" {
  description = "EKS API endpoint; private-only with the sample settings."
  value       = module.eks.cluster_endpoint
}

output "node_groups" {
  description = "Managed node group IDs, status, and backing Auto Scaling groups, keyed by logical group."
  value = {
    for key, group in module.eks.eks_managed_node_groups : key => {
      id                      = group.node_group_id
      status                  = group.node_group_status
      autoscaling_group_names = group.node_group_autoscaling_group_names
    }
  }
}

output "kubeconfig_command" {
  description = "Run with the same AWS profile/identity used by Terraform. Does not execute or write kubeconfig."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  description = "Lab VPC ID for load balancer diagnostics and the pre-destroy cleanup gate."
  value       = aws_vpc.this.id
}

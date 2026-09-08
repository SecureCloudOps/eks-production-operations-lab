locals {
  bottlerocket_defaults = {
    # Preserve egress/IAM readiness without deferring the EKS module's data reads.
    subnet_ids      = terraform_data.cni_bootstrap.output.subnet_ids
    ami_type        = "BOTTLEROCKET_x86_64"
    capacity_type   = "ON_DEMAND"
    create_iam_role = true

    # A changing SSM "latest" value must not roll every group during Lab 01.
    # EKS chooses the initial release; explicit pins are available per group.
    use_latest_ami_release_version = false
    force_update_version           = false

    # The module attaches AmazonEKSWorkerNodePolicy and ECR read permissions.
    # CNI permissions belong to the Pod Identity role defined in eks.tf.
    iam_role_attach_cni_policy = false
    iam_role_additional_policies = {
      # Enables Session Manager through Bottlerocket's built-in control container.
      AmazonSSMManagedInstanceCore = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }

    # Bottlerocket has separate OS and container-data EBS volumes.
    block_device_mappings = {
      root = {
        device_name = "/dev/xvda"
        ebs = {
          volume_size           = 4
          volume_type           = "gp3"
          encrypted             = true
          delete_on_termination = true
        }
      }
      data = {
        device_name = "/dev/xvdb"
        ebs = {
          volume_size           = 30
          volume_type           = "gp3"
          encrypted             = true
          delete_on_termination = true
        }
      }
    }

    metadata_options = {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 1
    }

    update_config = { max_unavailable = 1, update_strategy = "DEFAULT" }
  }

  eks_managed_node_groups = {
    system = merge(local.bottlerocket_defaults, {
      kubernetes_version  = var.node_group_versions["system"]
      ami_release_version = lookup(var.node_group_ami_release_versions, "system", null)
      name                = "system"
      instance_types      = ["t3.small"]
      min_size            = var.system_node_count
      max_size            = var.system_node_count
      desired_size        = var.system_node_count
      labels              = { workload = "system" }
      taints = {
        critical_addons = {
          key    = "critical-addons"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
      # One node fits two CoreDNS replicas and the baseline DaemonSets.
      # Controlled upgrades require DEFAULT surge and the CoreDNS PDB.
    })

    apps = merge(local.bottlerocket_defaults, {
      kubernetes_version  = var.node_group_versions["apps"]
      ami_release_version = lookup(var.node_group_ami_release_versions, "apps", null)
      name                = "apps"
      instance_types      = ["m6i.large"]
      min_size            = 2
      max_size            = 2
      desired_size        = 2
      labels              = { workload = "production-apps" }
    })

    canary = merge(local.bottlerocket_defaults, {
      kubernetes_version  = var.node_group_versions["canary"]
      ami_release_version = lookup(var.node_group_ami_release_versions, "canary", null)
      name                = "canary"
      instance_types      = ["t3.small"]
      min_size            = 1
      max_size            = 1
      desired_size        = 1
      labels              = { workload = "canary" }
      # Labels alone do not reserve nodes. Canary pods must both select this
      # label and tolerate workload=canary:NoSchedule to opt into this group.
      taints = {
        canary = {
          key    = "workload"
          value  = "canary"
          effect = "NO_SCHEDULE"
        }
      }
    })
  }
}

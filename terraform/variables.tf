variable "aws_region" {
  description = "AWS region containing the selected availability zones."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the future EKS cluster; must match its subnet discovery tags."
  type        = string
  default     = "eks-operations-lab"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$", var.cluster_name))
    error_message = "Use an EKS cluster name of 1–100 letters, digits, underscores or hyphens, starting with a letter or digit."
  }
}

variable "operator_public_access_cidrs" {
  description = "Operator public egress IPv4 CIDRs allowed to reach the EKS API. Empty keeps the endpoint private-only; prefer individual /32 addresses."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for cidr in var.operator_public_access_cidrs :
      can(cidrnetmask(cidr)) && can(regex("/(2[4-9]|3[0-2])$", cidr))
    ])
    error_message = "Use narrowly restricted IPv4 CIDRs with prefixes /24 through /32; prefer operator /32 addresses."
  }
}

variable "environment" {
  description = "Environment tag applied to all resources."
  type        = string
  default     = "lab"
}

variable "vpc_cidr" {
  description = "IPv4 /16 VPC CIDR; subnet CIDRs are derived automatically without overlap."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && can(regex("/16$", var.vpc_cidr))
    error_message = "Provide a valid IPv4 /16 CIDR."
  }
}

variable "availability_zones" {
  description = "Two or three distinct AZs in aws_region. Keep ordering stable; the first hosts the NAT Gateway."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = contains([2, 3], length(var.availability_zones)) && length(distinct(var.availability_zones)) == length(var.availability_zones)
    error_message = "Specify two or three distinct availability zones."
  }
}

variable "tags" {
  description = "Additional tags for all AWS resources."
  type        = map(string)
  default     = {}
}

variable "cluster_version" {
  description = "EKS control-plane Kubernetes minor version. Node groups are configured separately; follow Lab 01 stage gates."
  type        = string
  default     = "1.35"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.cluster_version))
    error_message = "Use an EKS minor version such as 1.35."
  }

  validation {
    condition     = try(tonumber(split(".", var.cluster_version)[1]) >= 28, false)
    error_message = "This lab requires EKS 1.28 or newer, including its default envelope encryption. Use a currently supported minor."
  }
}

variable "system_node_count" {
  description = "One system node is sufficient for controlled lab upgrades with surge and a CoreDNS PDB. Use two to retain DNS across an unexpected node failure."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = contains([1, 2], var.system_node_count)
    error_message = "Use one or two system nodes."
  }
}

variable "use_customer_managed_kms_key" {
  description = "Retain true for an existing cluster created with this root's KMS key. New labs use EKS default AWS-owned encryption; never disable this on an existing CMK-encrypted cluster."
  type        = bool
  default     = false
  nullable    = false
}

variable "node_group_ami_release_versions" {
  description = "Optional EKS Bottlerocket release pins keyed by canary/apps/system. Omit for EKS selection at creation or minor upgrade; never track SSM latest during staged upgrades."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition = alltrue([
      for group, release in var.node_group_ami_release_versions :
      contains(["canary", "apps", "system"], group) && try(length(trimspace(release)) > 0, false)
    ])
    error_message = "Supply nonempty EKS release versions only for canary, apps, or system."
  }
}

variable "addon_versions" {
  description = "Optional regional EKS add-on release pins. Select releases compatible with both Lab 01 minors before measuring an upgrade; omitted entries use the EKS default."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition = alltrue([
      for addon, version in var.addon_versions :
      contains(["vpc-cni", "coredns", "kube-proxy", "eks-pod-identity-agent"], addon) &&
      can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", version))
    ])
    error_message = "Use EKS build versions for vpc-cni, coredns, kube-proxy, or eks-pod-identity-agent only."
  }
}

variable "operator_cidr" {
  description = "IPv4 source CIDR seen by the private EKS API from a routed VPN or VPC runner; prefer /32. Does not create connectivity."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.operator_cidr)) && try(tonumber(split("/", var.operator_cidr)[1]) >= 16, false)
    error_message = "Provide a valid IPv4 operator CIDR with prefix /16 or narrower; prefer a single-host /32."
  }
}

variable "node_group_versions" {
  description = "Explicit Kubernetes minor per managed node group. Keep workers at the source version during the Lab 01 control-plane stage, then advance one group at a time."
  type        = map(string)
  default = {
    canary = "1.35"
    apps   = "1.35"
    system = "1.35"
  }
  nullable = false

  validation {
    condition     = toset(keys(var.node_group_versions)) == toset(["canary", "apps", "system"])
    error_message = "Specify exactly canary, apps, and system node-group versions."
  }

  validation {
    condition     = alltrue([for version in values(var.node_group_versions) : can(regex("^1\\.[0-9]{2}$", version))])
    error_message = "Each node-group version must be an EKS minor such as 1.35."
  }
}

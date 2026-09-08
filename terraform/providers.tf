terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.63.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(var.tags, {
      Project     = var.cluster_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    })
  }
}

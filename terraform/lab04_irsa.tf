# Intentionally vulnerable training configuration. Never enable in production.
variable "enable_lab04" {
  description = "Opt into Lab 04: OIDC provider, S3 fixture bucket, and an IRSA role."
  type        = bool
  default     = false
}

variable "lab04_least_privilege" {
  description = "Replace the intentional s3:* policy with read-only access to public/ fixtures."
  type        = bool
  default     = false
}

resource "aws_s3_bucket" "lab04" {
  count         = var.enable_lab04 ? 1 : 0
  bucket_prefix = "eks-lab04-fixtures-"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "lab04" {
  count                   = var.enable_lab04 ? 1 : 0
  bucket                  = aws_s3_bucket.lab04[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lab04" {
  count  = var.enable_lab04 ? 1 : 0
  bucket = aws_s3_bucket.lab04[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "lab04" {
  for_each = var.enable_lab04 ? {
    "public/hello.txt"          = "Synthetic public application content.\n"
    "private/customer-demo.txt" = "SYNTHETIC ONLY: customer=demo, record=123.\n"
  } : {}

  bucket                 = aws_s3_bucket.lab04[0].id
  key                    = each.key
  content                = each.value
  server_side_encryption = "AES256"
}

resource "aws_iam_role" "lab04" {
  count       = var.enable_lab04 ? 1 : 0
  name_prefix = "eks-lab04-irsa-"

  # Trust stays narrow: only this cluster's lab04/public-web ServiceAccount.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = module.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:lab04:public-web"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "lab04_s3" {
  count = var.enable_lab04 ? 1 : 0
  name  = "lab04-s3-access"
  role  = aws_iam_role.lab04[0].id

  # Replace the policy; adding a narrow Allow alongside s3:* would not fix it.
  policy = var.lab04_least_privilege ? jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListApplicationPrefix"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.lab04[0].arn
        Condition = {
          StringLike = { "s3:prefix" = ["public/", "public/*"] }
        }
      },
      {
        Sid      = "ReadApplicationObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.lab04[0].arn}/public/*"
      }
    ]
    }) : jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "IntentionalLabMisconfiguration"
      Effect = "Allow"
      Action = "s3:*"
      # Retain the training flaw within synthetic fixtures only.
      Resource = [aws_s3_bucket.lab04[0].arn, "${aws_s3_bucket.lab04[0].arn}/*"]
    }]
  })
}

output "lab04_role_arn" {
  description = "Role ARN to annotate on lab04/public-web."
  value       = try(aws_iam_role.lab04[0].arn, null)
  sensitive   = true
}

output "lab04_bucket_name" {
  description = "Bucket containing synthetic fixtures only."
  value       = try(aws_s3_bucket.lab04[0].id, null)
}

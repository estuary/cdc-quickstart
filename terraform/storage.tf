# --------------------------------------------------------------------------
# S3 bucket for Estuary's collection-data storage mapping.
#
# Estuary's data plane writes collection data (the durable, replayable copy of
# every captured document) to this bucket under a `collection-data/` prefix.
# The bucket policy grants Estuary's data-plane IAM users exactly the actions
# the docs require:
#   s3:GetObject, s3:PutObject, s3:DeleteObject, s3:ListBucket, s3:GetBucketPolicy
# Resources are wired to the bucket Terraform creates (not a hardcoded name),
# so the ARNs are always correct.
#
# After `apply`, point your Estuary storage mapping at the bucket name from the
# `storage_bucket_name` output (Dashboard -> Admin -> Storage Mappings).
# --------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  storage_bucket_name = (
    var.storage_bucket_name != "" ? var.storage_bucket_name :
    "${var.db_identifier}-collections-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
  )
}

resource "aws_s3_bucket" "storage" {
  count  = var.create_storage_bucket ? 1 : 0
  bucket = local.storage_bucket_name

  # force_destroy so `terraform destroy` removes the bucket even though Estuary
  # has written objects into it — keeps teardown clean (no orphaned bucket).
  force_destroy = true

  tags = {
    Project = "estuary-cdc-demo"
  }
}

# ACLs disabled; the bucket owner owns all objects (current AWS best practice).
resource "aws_s3_bucket_ownership_controls" "storage" {
  count  = var.create_storage_bucket ? 1 : 0
  bucket = aws_s3_bucket.storage[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Keep the bucket private to the public internet. The cross-account grant to
# Estuary's named IAM users below is NOT "public", so Block Public Access does
# not interfere with it.
resource "aws_s3_bucket_public_access_block" "storage" {
  count  = var.create_storage_bucket ? 1 : 0
  bucket = aws_s3_bucket.storage[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "storage" {
  count  = var.create_storage_bucket ? 1 : 0
  bucket = aws_s3_bucket.storage[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = var.estuary_data_plane_principals
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketPolicy",
        ]
        Resource = [
          aws_s3_bucket.storage[0].arn,
          "${aws_s3_bucket.storage[0].arn}/*",
        ]
      },
    ]
  })

  # Ensure ACL/ownership and public-access settings are in place first.
  depends_on = [
    aws_s3_bucket_ownership_controls.storage,
    aws_s3_bucket_public_access_block.storage,
  ]
}

output "address" {
  description = "RDS endpoint hostname (no port)."
  value       = aws_db_instance.this.address
}

output "endpoint" {
  description = "RDS endpoint as host:port."
  value       = aws_db_instance.this.endpoint
}

output "port" {
  description = "Postgres port."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Initial database name."
  value       = aws_db_instance.this.db_name
}

output "username" {
  description = "Master username."
  value       = aws_db_instance.this.username
}

output "password" {
  description = "Master password (generated)."
  value       = random_password.master.result
  sensitive   = true
}

output "storage_bucket_name" {
  description = "S3 bucket for Estuary's collection-data storage mapping (empty if not created)."
  value       = var.create_storage_bucket ? aws_s3_bucket.storage[0].bucket : ""
}

output "storage_bucket_arn" {
  description = "ARN of the Estuary storage bucket (empty if not created)."
  value       = var.create_storage_bucket ? aws_s3_bucket.storage[0].arn : ""
}

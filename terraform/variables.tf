variable "allowed_cidr" {
  description = <<-EOT
    Your operator IP(s) in CIDR notation for psql/admin access. Added ON TOP OF
    estuary_cidrs — it never replaces the Estuary data-plane IPs. Accepts a
    single value or a comma-separated list, e.g.
      1.2.3.4/32
      1.2.3.4/32,5.6.7.8/32
    Set via TF_VAR_allowed_cidr. May be left empty to allow only Estuary (but
    then you can't reach Postgres from your own machine).
  EOT
  type        = string
  default     = ""

  validation {
    condition = alltrue([
      for c in [for x in split(",", var.allowed_cidr) : trimspace(x) if trimspace(x) != ""] :
      can(cidrhost(c, 0))
    ])
    error_message = "Each allowed_cidr entry must be a valid CIDR, e.g. 1.2.3.4/32 (comma-separate multiples)."
  }
}

variable "estuary_cidrs" {
  description = <<-EOT
    Estuary Flow data-plane egress IPs that must reach Postgres for the CDC
    capture to connect. These are separate from your own IP. The default covers
    all of Estuary's public data planes; trim to just your tenant's data plane
    (shown under Admin -> "Allowlist IP addresses" in the dashboard;
    https://docs.estuary.dev/reference/allow-ip-addresses/) for a tighter rule.
    Override from the shell with, e.g.:
      export TF_VAR_estuary_cidrs='["35.226.75.135/32"]'
  EOT
  type        = list(string)
  # Egress IPs of the DATA PLANE your capture runs in — independent of the AWS
  # region your RDS lives in. The default below covers ALL of Estuary's PUBLIC
  # data planes, so whichever one your tenant uses is allowlisted. Source:
  # https://docs.estuary.dev/reference/allow-ip-addresses/ (confirm against
  # Admin -> "Allowlist IP addresses" in your dashboard). Trim to just your
  # data plane's IPs if you prefer a tighter allowlist.
  default = [
    # AWS us-east-1 c1
    "107.20.68.5/32",
    "98.89.112.85/32",
    # GCP us-central1 c2
    "35.226.75.135/32",
    # AWS us-west-2 c1
    "34.213.10.188/32",
    "52.34.175.198/32",
    # AWS eu-west-1 c1
    "18.200.127.124/32",
    "34.247.94.19/32",
    # AWS ap-southeast-2 c1
    "15.134.198.216/32",
    "3.24.170.247/32",
  ]

  validation {
    condition     = alltrue([for c in var.estuary_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry in estuary_cidrs must be a valid CIDR, e.g. 35.226.75.135/32."
  }
}

variable "db_identifier" {
  description = "RDS instance identifier."
  type        = string
  default     = "estuary-cdc-demo"
}

variable "db_name" {
  description = "Initial database name created on the instance."
  type        = string
  default     = "demo"
}

variable "master_username" {
  description = "Master (admin) username for the Postgres instance."
  type        = string
  default     = "flowdemo"
}

variable "instance_class" {
  description = "RDS instance class. db.t3.micro is free-tier eligible."
  type        = string
  default     = "db.t3.micro"
}

variable "engine_version" {
  description = "Postgres major version. Must match the parameter group family below."
  type        = string
  default     = "15"
}

variable "parameter_group_family" {
  description = "RDS parameter group family. Must match engine_version (e.g. postgres15)."
  type        = string
  default     = "postgres15"
}

variable "allocated_storage" {
  description = "Allocated storage in GB. 20 GB is the free-tier limit."
  type        = number
  default     = 20
}

# ---------------------------------------------------------------------------
# Estuary collection-data storage bucket (S3 storage mapping)
# ---------------------------------------------------------------------------
variable "create_storage_bucket" {
  description = "Whether to create the S3 bucket + policy for Estuary's storage mapping."
  type        = bool
  default     = true
}

variable "storage_bucket_name" {
  description = <<-EOT
    Name of the S3 bucket Estuary writes collection data to. Must be globally
    unique. Leave empty to auto-generate as
    <db_identifier>-collections-<account_id>-<region>.
  EOT
  type        = string
  default     = ""
}

variable "estuary_data_plane_principals" {
  description = <<-EOT
    Estuary data-plane IAM user ARNs granted access to the storage bucket. These
    are shown in the storage-mapping dialog in your Estuary dashboard (they are
    Estuary's public data-plane IAM users). Replace if your dialog shows others.
  EOT
  type        = list(string)
  default = [
    "arn:aws:iam::770785070253:user/data-planes/data-plane-hsfgjfu7id8daor4",
    "arn:aws:iam::770785070253:user/data-planes/data-plane-6urqu22rnp0ulooe",
  ]
}

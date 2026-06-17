# --------------------------------------------------------------------------
# Networking: use the account's default VPC and its subnets so the demo needs
# no extra network plumbing. The default VPC already has an internet gateway,
# which is required for a publicly accessible RDS instance.
# --------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  # Operator IP(s): split the comma-separated string and drop empty entries.
  operator_cidrs = [
    for c in [for x in split(",", var.allowed_cidr) : trimspace(x)] : c if c != ""
  ]
  # Postgres ingress = operator IP(s) PLUS the Estuary data-plane IPs. Pasting
  # your IP into allowed_cidr is additive; it never removes the Estuary IPs.
  ingress_cidrs = concat(local.operator_cidrs, var.estuary_cidrs)
}

# Random master password so no secret is ever committed. Exposed only as a
# (sensitive) Terraform output, consumed by start.sh.
resource "random_password" "master" {
  length  = 24
  special = false # keep it URL/connection-string safe
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.db_identifier}-subnets"
  subnet_ids = data.aws_subnets.default.ids

  tags = {
    Project = "estuary-cdc-demo"
  }
}

# Security group: allow inbound Postgres ONLY from the operator CIDR plus the
# Estuary data-plane egress IPs (so the CDC capture can connect).
resource "aws_security_group" "rds" {
  name        = "${var.db_identifier}-sg"
  description = "Allow Postgres access from the operator CIDR and Estuary data-plane IPs"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Postgres from operator + Estuary data-plane CIDRs"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = local.ingress_cidrs
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = "estuary-cdc-demo"
  }
}

# Parameter group enabling logical replication. rds.logical_replication = 1
# sets wal_level = logical, which Postgres CDC requires. It is a static
# parameter, so it is applied at boot — the instance comes up replication-ready.
resource "aws_db_parameter_group" "this" {
  name        = "${var.db_identifier}-pg"
  family      = var.parameter_group_family
  description = "Enable logical replication for Estuary CDC"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "aws_db_instance" "this" {
  identifier     = var.db_identifier
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp2"

  db_name  = var.db_name
  username = var.master_username
  password = random_password.master.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.this.name

  publicly_accessible = true
  multi_az            = false

  # Demo hygiene: no backups, no final snapshot, instant teardown.
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  tags = {
    Project = "estuary-cdc-demo"
  }
}

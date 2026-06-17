terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  # State is intentionally local (no remote backend) so the demo is fully
  # self-contained and `terraform destroy` leaves nothing behind.
}

provider "aws" {
  # Region is read from the AWS_REGION environment variable (set in .env).
}

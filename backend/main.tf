################################################################################
# Bootstrap - S3 Backend Resources
#
# Run this FIRST to create the S3 bucket and DynamoDB lock table.
# Then configure the backend block in the root main.tf and run:
#   terraform init -migrate-state
################################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "web"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

################################################################################
# S3 Bucket for Terraform State
################################################################################

resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project_name}-${var.environment}-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-tfstate"
    Purpose     = "Terraform State"
    ManagedBy   = "Terraform"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

################################################################################
# DynamoDB Table for State Locking
################################################################################

resource "aws_dynamodb_table" "tflock" {
  name         = "${var.project_name}-${var.environment}-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name      = "${var.project_name}-${var.environment}-tflock"
    Purpose   = "Terraform State Lock"
    ManagedBy = "Terraform"
  }
}

################################################################################
# Data Sources
################################################################################

data "aws_caller_identity" "current" {}

################################################################################
# Outputs
################################################################################

output "s3_bucket_name" {
  description = "Name of the S3 bucket for Terraform state"
  value       = aws_s3_bucket.tfstate.id
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = aws_s3_bucket.tfstate.arn
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB lock table"
  value       = aws_dynamodb_table.tflock.name
}

output "backend_config" {
  description = "Backend configuration to add to your root main.tf"
  value       = <<-EOT

    Add this to your root terraform block in main.tf:

    backend "s3" {
      bucket         = "${aws_s3_bucket.tfstate.id}"
      key            = "terraform.tfstate"
      region         = "${var.aws_region}"
      dynamodb_table = "${aws_dynamodb_table.tflock.name}"
      encrypt        = true
    }

    Then run: terraform init -migrate-state
  EOT
}

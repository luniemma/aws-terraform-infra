################################################################################
# Main - AWS Infrastructure (EC2 + EKS)
################################################################################

terraform {
  required_version = ">= 1.5.0"

  # Empty backend block — concrete bucket/table/region are injected by
  # `terraform init -backend-config=...` from the GitHub Actions workflow
  # (or pass them manually on local runs).
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

################################################################################
# VPC Module
################################################################################

module "vpc" {
  source = "./modules/vpc"

  project_name         = var.project_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  enable_nat_gateway   = var.enable_nat_gateway || var.enable_eks
  enable_eks           = var.enable_eks
}

################################################################################
# EC2 Module
################################################################################

module "ec2" {
  source = "./modules/ec2"

  project_name               = var.project_name
  environment                = var.environment
  vpc_id                     = module.vpc.vpc_id
  public_subnet_ids          = module.vpc.public_subnet_ids
  private_subnet_ids         = module.vpc.private_subnet_ids
  instance_type              = var.instance_type
  ami_id                     = var.ami_id
  instance_count             = var.instance_count
  ec2_in_public_subnet       = var.ec2_in_public_subnet
  assign_eip                 = var.assign_eip
  public_key_path            = var.public_key_path
  allowed_ssh_cidrs          = var.allowed_ssh_cidrs
  root_volume_size           = var.root_volume_size
  root_volume_type           = var.root_volume_type
  additional_ebs_volumes     = var.additional_ebs_volumes
  enable_detailed_monitoring = var.enable_detailed_monitoring
  cpu_alarm_threshold        = var.cpu_alarm_threshold
  alarm_sns_topic_arn        = var.alarm_sns_topic_arn
}

################################################################################
# EKS Module
################################################################################

module "eks" {
  source = "./modules/eks"
  count  = var.enable_eks ? 1 : 0

  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = var.vpc_cidr
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids

  cluster_version                 = var.eks_cluster_version
  cluster_endpoint_private_access = var.eks_cluster_endpoint_private_access
  cluster_endpoint_public_access  = var.eks_cluster_endpoint_public_access
  cluster_log_types               = var.eks_cluster_log_types
  node_instance_types             = var.eks_node_instance_types
  node_capacity_type              = var.eks_node_capacity_type
  node_disk_size                  = var.eks_node_disk_size
  node_desired_size               = var.eks_node_desired_size
  node_min_size                   = var.eks_node_min_size
  node_max_size                   = var.eks_node_max_size
}

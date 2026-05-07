################################################################################
# Main — AWS Infrastructure (VPC + EKS)
#
# Single shared EKS cluster topology. Per-env isolation is provided by
# Kubernetes namespaces inside this one cluster (codeplex-dev, codeplex-qa,
# codeplex-staging, codeplex-prod), not by separate AWS stacks.
#
# Only one workspace exists: `platform`. See environments/platform.tfvars.
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
  enable_nat_gateway   = true
  enable_eks           = true
}

################################################################################
# EKS Module
################################################################################

# Defensive: the module previously used `count = var.enable_eks ? 1 : 0`, which
# addressed resources as `module.eks[0].*`. If anyone wraps the module in count
# again later, this `moved` block rewires state in place rather than forcing a
# destroy+create of the cluster (which is what happens when terraform sees the
# addresses as different resources).
moved {
  from = module.eks[0]
  to   = module.eks
}

module "eks" {
  source = "./modules/eks"

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

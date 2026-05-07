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

################################################################################
# App deploy access
#
# IAM role assumed via OIDC by the app repo's deploy workflow (set as the app
# repo's AWS_DEPLOY_ROLE_ARN secret). Permissions are intentionally minimal at
# the IAM layer (just eks:DescribeCluster) — actual cluster authority is granted
# via an EKS access entry mapped to AmazonEKSClusterAdminPolicy below.
#
# Reuses the GitHub Actions OIDC provider that already exists in this account
# (the same one the terraform CI role uses). Looking it up by URL lets us avoid
# managing it in this stack.
################################################################################

data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "app_deploy_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.app_repo}:*"]
    }
  }
}

resource "aws_iam_role" "app_deploy" {
  name               = "${var.project_name}-app-deploy"
  description        = "Assumed via OIDC by ${var.app_repo} deploy workflow"
  assume_role_policy = data.aws_iam_policy_document.app_deploy_assume_role.json

  tags = {
    Name = "${var.project_name}-app-deploy"
  }
}

# Minimal AWS-side perms — just enough for `aws eks update-kubeconfig`.
resource "aws_iam_role_policy" "app_deploy_eks" {
  name = "eks-describe"
  role = aws_iam_role.app_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "eks:DescribeCluster"
      Resource = module.eks.cluster_arn
    }]
  })
}

# Cluster-side authority. AmazonEKSClusterAdminPolicy is the simplest scope —
# tighten to AmazonEKSAdminPolicy + namespace-scoped binding when you have time.
resource "aws_eks_access_entry" "app_deploy" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.app_deploy.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "app_deploy_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.app_deploy.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.app_deploy]
}

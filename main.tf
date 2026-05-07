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
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
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

# Auth for the kubernetes/helm providers. The exec block calls
# `aws eks get-token` fresh on each provider request, so tokens never expire
# mid-apply (the alternative — `aws_eks_cluster_auth` — caches a 15-min token
# in state, which is fragile for long applies).
locals {
  eks_auth_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = local.eks_auth_exec.api_version
    command     = local.eks_auth_exec.command
    args        = local.eks_auth_exec.args
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = local.eks_auth_exec.api_version
      command     = local.eks_auth_exec.command
      args        = local.eks_auth_exec.args
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
# (the same one the terraform CI role uses). The ARN is deterministic, so we
# build it from the caller's account ID instead of looking it up — that avoids
# needing iam:ListOpenIDConnectProviders on the terraform CI role.
################################################################################

data "aws_caller_identity" "current" {}

locals {
  github_oidc_provider_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_partition" "current" {}

data "aws_iam_policy_document" "app_deploy_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
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

################################################################################
# Cluster add-ons — nginx-ingress controller
#
# Single LoadBalancer-backed ingress controller for the cluster. Every per-env
# Ingress (codeplex-shared in each codeplex-* namespace) shares this one NLB.
# Pinned to a chart version so upgrades are explicit. The controller's Service
# auto-provisions an NLB on apply; if the AWS account has an ELB-creation
# block, the Service stays Pending until that's lifted — the helm_release
# itself still succeeds because the chart doesn't `--wait` on LoadBalancer.
################################################################################

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.11.3" # → controller image v1.11.3

  # Cap install time so a stuck NLB provision (account ELB block) doesn't hang
  # the whole apply. The chart's resources still install; only the LB hostname
  # remains Pending — the deploy workflow's port-forward fallback handles that.
  timeout = 300
  wait    = false

  values = [
    yamlencode({
      controller = {
        service = {
          type = "LoadBalancer"
          annotations = {
            "service.beta.kubernetes.io/aws-load-balancer-type"                              = "nlb"
            "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
            "service.beta.kubernetes.io/aws-load-balancer-backend-protocol"                  = "tcp"
          }
        }
        # Keep one replica in dev to save cost; bump for HA in prod.
        replicaCount = 1
      }
    })
  ]

  depends_on = [module.eks]
}

################################################################################
# Outputs — VPC + EKS
################################################################################

# VPC
output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = module.vpc.vpc_cidr
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = module.vpc.private_subnet_ids
}

# NAT Gateway
output "nat_gateway_id" {
  description = "ID of the NAT gateway"
  value       = module.vpc.nat_gateway_id
}

output "nat_gateway_public_ip" {
  description = "Public IP of the NAT gateway"
  value       = module.vpc.nat_gateway_public_ip
}

# EKS
output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for cluster authentication"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "eks_cluster_version" {
  description = "Kubernetes version running on the cluster"
  value       = module.eks.cluster_version
}

output "eks_oidc_provider_arn" {
  description = "ARN of the OIDC provider for IRSA"
  value       = module.eks.oidc_provider_arn
}

output "eks_node_group_id" {
  description = "EKS node group ID"
  value       = module.eks.node_group_id
}

output "eks_kubeconfig_command" {
  description = "Command to update kubeconfig"
  value       = module.eks.cluster_kubeconfig_command
}

# App deploy access
output "app_deploy_role_arn" {
  description = "IAM role ARN for the app repo's deploy workflow. Set on the app repo as the AWS_DEPLOY_ROLE_ARN secret."
  value       = aws_iam_role.app_deploy.arn
}

################################################################################
# Outputs
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
  description = "ID of the NAT gateway (if created)"
  value       = module.vpc.nat_gateway_id
}

output "nat_gateway_public_ip" {
  description = "Public IP of the NAT gateway (if created)"
  value       = module.vpc.nat_gateway_public_ip
}

# EC2
output "ec2_security_group_id" {
  description = "ID of the EC2 security group"
  value       = module.ec2.security_group_id
}

output "ec2_iam_role_arn" {
  description = "ARN of the EC2 IAM role"
  value       = module.ec2.iam_role_arn
}

output "ec2_instance_profile_name" {
  description = "Name of the EC2 instance profile"
  value       = module.ec2.instance_profile_name
}

output "instance_ids" {
  description = "IDs of the EC2 instances"
  value       = module.ec2.instance_ids
}

output "instance_public_ips" {
  description = "Public IP addresses of EC2 instances (if in public subnet)"
  value       = module.ec2.instance_public_ips
}

output "instance_private_ips" {
  description = "Private IP addresses of EC2 instances"
  value       = module.ec2.instance_private_ips
}

output "instance_public_dns" {
  description = "Public DNS names of EC2 instances"
  value       = module.ec2.instance_public_dns
}

output "elastic_ips" {
  description = "Elastic IP addresses assigned to EC2 instances"
  value       = module.ec2.elastic_ips
}

output "ami_id_used" {
  description = "AMI ID used for the EC2 instances"
  value       = module.ec2.ami_id_used
}

output "launch_template_id" {
  description = "ID of the launch template"
  value       = module.ec2.launch_template_id
}

output "launch_template_latest_version" {
  description = "Latest version of the launch template"
  value       = module.ec2.launch_template_latest_version
}

output "ssh_commands" {
  description = "SSH commands to connect to the instances"
  value       = module.ec2.ssh_commands
}

# EKS
output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = var.enable_eks ? module.eks[0].cluster_name : null
}

output "eks_cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = var.enable_eks ? module.eks[0].cluster_endpoint : null
}

output "eks_cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for cluster authentication"
  value       = var.enable_eks ? module.eks[0].cluster_certificate_authority_data : null
  sensitive   = true
}

output "eks_cluster_version" {
  description = "Kubernetes version running on the cluster"
  value       = var.enable_eks ? module.eks[0].cluster_version : null
}

output "eks_oidc_provider_arn" {
  description = "ARN of the OIDC provider for IRSA"
  value       = var.enable_eks ? module.eks[0].oidc_provider_arn : null
}

output "eks_node_group_id" {
  description = "EKS node group ID"
  value       = var.enable_eks ? module.eks[0].node_group_id : null
}

output "eks_kubeconfig_command" {
  description = "Command to update kubeconfig"
  value       = var.enable_eks ? module.eks[0].cluster_kubeconfig_command : null
}

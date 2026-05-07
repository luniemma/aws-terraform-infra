################################################################################
# Variables — VPC + EKS only (single shared platform stack).
################################################################################

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
  default     = "codeplex"
}

variable "environment" {
  description = "Workspace name. Only 'platform' is supported — app envs are k8s namespaces inside the shared cluster."
  type        = string
  default     = "platform"

  validation {
    condition     = var.environment == "platform"
    error_message = "Environment must be 'platform' (the only supported workspace). App envs live as k8s namespaces inside the shared EKS cluster."
  }
}

################################################################################
# Network
################################################################################

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.10.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.10.1.0/24", "10.10.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.10.11.0/24", "10.10.12.0/24"]
}

################################################################################
# EKS
################################################################################

variable "eks_cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "eks_cluster_endpoint_private_access" {
  description = "Enable private API server endpoint"
  type        = bool
  default     = true
}

variable "eks_cluster_endpoint_public_access" {
  description = "Enable public API server endpoint"
  type        = bool
  default     = true
}

variable "eks_cluster_log_types" {
  description = "EKS control plane logging types to enable"
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "eks_node_instance_types" {
  description = "Instance types for the EKS managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "eks_node_capacity_type" {
  description = "Capacity type for the node group (ON_DEMAND or SPOT)"
  type        = string
  default     = "ON_DEMAND"
}

variable "eks_node_disk_size" {
  description = "Disk size in GB for worker nodes"
  type        = number
  default     = 50
}

variable "eks_node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "eks_node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "eks_node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 4
}

################################################################################
# App deploy access — cross-repo IAM role for the app's CI
################################################################################

variable "app_repo" {
  description = "owner/name of the app repo whose deploy workflow assumes app_deploy_role via OIDC"
  type        = string
  default     = "luniemma/codeplex-application-ai-systhem"
}

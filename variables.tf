################################################################################
# Variables
################################################################################

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
  default     = "web"
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

################################################################################
# Network
################################################################################

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "enable_nat_gateway" {
  description = "Whether to create a NAT gateway for private subnet outbound access"
  type        = bool
  default     = false
}

################################################################################
# Security
################################################################################

variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed to SSH into EC2 instances (leave empty to disable SSH)"
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.allowed_ssh_cidrs) <= 1
    error_message = "Provide at most one SSH CIDR (add more ingress rules in main.tf if needed)."
  }
}

variable "public_key_path" {
  description = "Path to the SSH public key file. Leave empty to skip key pair creation."
  type        = string
  default     = ""
}

################################################################################
# EC2 Instance
################################################################################

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "Custom AMI ID. Leave empty to use the latest Amazon Linux 2023."
  type        = string
  default     = ""
}

variable "instance_count" {
  description = "Number of EC2 instances to create"
  type        = number
  default     = 1

  validation {
    condition     = var.instance_count >= 1 && var.instance_count <= 10
    error_message = "Instance count must be between 1 and 10."
  }
}

variable "ec2_in_public_subnet" {
  description = "Place EC2 instances in public subnets (true) or private subnets (false)"
  type        = bool
  default     = true
}

variable "assign_eip" {
  description = "Assign an Elastic IP to public EC2 instances"
  type        = bool
  default     = false
}

################################################################################
# Storage
################################################################################

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

variable "root_volume_type" {
  description = "Root EBS volume type (gp3, gp2, io1, io2)"
  type        = string
  default     = "gp3"
}

variable "additional_ebs_volumes" {
  description = "List of additional EBS volumes to attach"
  type = list(object({
    device_name = string
    volume_size = number
    volume_type = string
  }))
  default = []
}

################################################################################
# Monitoring
################################################################################

variable "enable_detailed_monitoring" {
  description = "Enable detailed CloudWatch monitoring (1-minute intervals, extra cost)"
  type        = bool
  default     = false
}

variable "cpu_alarm_threshold" {
  description = "CPU utilization percentage that triggers the CloudWatch alarm"
  type        = number
  default     = 80
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN to notify on CloudWatch alarms. Leave empty to skip."
  type        = string
  default     = ""
}

################################################################################
# EKS
################################################################################

variable "enable_eks" {
  description = "Whether to create an EKS cluster"
  type        = bool
  default     = false
}

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

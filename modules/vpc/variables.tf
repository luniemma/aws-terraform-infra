variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets"
  type        = list(string)
}

variable "enable_nat_gateway" {
  description = "Whether to create a NAT gateway for private subnet outbound access"
  type        = bool
  default     = false
}

variable "enable_eks" {
  description = "Add EKS-specific tags to subnets for load balancer discovery"
  type        = bool
  default     = false
}

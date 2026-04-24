variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to deploy into"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs"
  type        = list(string)
}

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

variable "public_key_path" {
  description = "Path to the SSH public key file. Leave empty to skip key pair creation."
  type        = string
  default     = ""
}

variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed to SSH into EC2 instances"
  type        = list(string)
  default     = []
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

variable "root_volume_type" {
  description = "Root EBS volume type"
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

variable "enable_detailed_monitoring" {
  description = "Enable detailed CloudWatch monitoring"
  type        = bool
  default     = false
}

variable "cpu_alarm_threshold" {
  description = "CPU utilization percentage that triggers the CloudWatch alarm"
  type        = number
  default     = 80
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN to notify on CloudWatch alarms"
  type        = string
  default     = ""
}

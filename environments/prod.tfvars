################################################################################
# Production environment
################################################################################

aws_region   = "us-east-1"
project_name = "codeplex"
environment  = "prod"

# Network
vpc_cidr             = "10.2.0.0/16"
public_subnet_cidrs  = ["10.2.1.0/24", "10.2.2.0/24"]
private_subnet_cidrs = ["10.2.11.0/24", "10.2.12.0/24"]
enable_nat_gateway   = true

# Security — no SSH from CI; use SSM
allowed_ssh_cidrs = []
public_key_path   = ""

# EC2 — private subnets only
instance_type        = "t3.medium"
instance_count       = 2
ec2_in_public_subnet = false
assign_eip           = false

# Storage
root_volume_size = 50
root_volume_type = "gp3"

# Monitoring
enable_detailed_monitoring = true
cpu_alarm_threshold        = 70
# alarm_sns_topic_arn      = "arn:aws:sns:us-east-1:123456789012:prod-alerts"

# EKS
enable_eks              = true
eks_cluster_version     = "1.31"
eks_node_instance_types = ["t3.large"]
eks_node_capacity_type  = "ON_DEMAND"
eks_node_disk_size      = 100
eks_node_desired_size   = 3
eks_node_min_size       = 2
eks_node_max_size       = 6

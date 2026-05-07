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

# EKS — owned by environments/platform.tfvars (single shared cluster). Off here.
enable_eks = false

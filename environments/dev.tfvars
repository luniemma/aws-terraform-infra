################################################################################
# Dev environment
################################################################################

aws_region   = "us-east-1"
project_name = "myapp"
environment  = "dev"

# Network
vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24"]
enable_nat_gateway   = false

# Security — tighten before use
allowed_ssh_cidrs = []
public_key_path   = ""

# EC2
instance_type        = "t3.micro"
instance_count       = 1
ec2_in_public_subnet = true
assign_eip           = false

# Storage
root_volume_size = 20
root_volume_type = "gp3"

# Monitoring
enable_detailed_monitoring = false
cpu_alarm_threshold        = 80

# EKS (off for dev by default)
enable_eks = false

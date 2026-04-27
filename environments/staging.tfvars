################################################################################
# Staging environment
################################################################################

aws_region   = "us-east-1"
project_name = "codeplex"
environment  = "staging"

# Network
vpc_cidr             = "10.1.0.0/16"
public_subnet_cidrs  = ["10.1.1.0/24", "10.1.2.0/24"]
private_subnet_cidrs = ["10.1.11.0/24", "10.1.12.0/24"]
enable_nat_gateway   = true

# Security
allowed_ssh_cidrs = []
public_key_path   = ""

# EC2 — private subnets, reached via SSM
instance_type        = "t3.small"
instance_count       = 2
ec2_in_public_subnet = false
assign_eip           = false

# Storage
root_volume_size = 30
root_volume_type = "gp3"

# Monitoring
enable_detailed_monitoring = true
cpu_alarm_threshold        = 75

# EKS
enable_eks              = false
eks_cluster_version     = "1.31"
eks_node_instance_types = ["t3.medium"]
eks_node_desired_size   = 2
eks_node_min_size       = 1
eks_node_max_size       = 3

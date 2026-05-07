################################################################################
# Platform stack — owns the SHARED EKS cluster used by all app environments.
#
# Per-env isolation is provided by Kubernetes namespaces (codeplex-dev,
# codeplex-qa, codeplex-staging, codeplex-prod) inside this single cluster.
# The dev/staging/prod tfvars below provision per-env VPCs + EC2 only and
# leave EKS off (enable_eks = false) — only this stack creates the cluster.
#
# Backend state for this stack is keyed at: s3://<bucket>/platform/terraform.tfstate
################################################################################

aws_region   = "us-east-1"
project_name = "codeplex"
environment  = "platform"

# Network — dedicated VPC for the platform stack so the cluster is not
# entangled with any single env's VPC lifecycle.
vpc_cidr             = "10.10.0.0/16"
public_subnet_cidrs  = ["10.10.1.0/24", "10.10.2.0/24"]
private_subnet_cidrs = ["10.10.11.0/24", "10.10.12.0/24"]
enable_nat_gateway   = true

# No EC2 footprint here — this stack is the cluster only.
allowed_ssh_cidrs    = []
public_key_path      = ""
instance_count       = 1
ec2_in_public_subnet = false
assign_eip           = false

# Storage / monitoring — minimal, since EC2 is effectively unused.
root_volume_size           = 30
root_volume_type           = "gp3"
enable_detailed_monitoring = false
cpu_alarm_threshold        = 80

# EKS — the whole point of this stack.
enable_eks              = true
eks_cluster_version     = "1.31"
eks_node_instance_types = ["t3.medium"]
eks_node_capacity_type  = "ON_DEMAND"
eks_node_disk_size      = 50
eks_node_desired_size   = 2
eks_node_min_size       = 2
eks_node_max_size       = 6

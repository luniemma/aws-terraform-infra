################################################################################
# Platform stack — provisions the SHARED EKS cluster (codeplex-eks).
#
# This is the only stack. App environments (dev / qa / staging / prod) live as
# Kubernetes namespaces inside the cluster, deployed by the app repo's
# .github/workflows/deploy.yml.
#
# Backend state: s3://<bucket>/platform/terraform.tfstate
################################################################################

aws_region   = "us-east-1"
project_name = "codeplex"
environment  = "platform"

# Network
vpc_cidr             = "10.10.0.0/16"
public_subnet_cidrs  = ["10.10.1.0/24", "10.10.2.0/24"]
private_subnet_cidrs = ["10.10.11.0/24", "10.10.12.0/24"]

# EKS
eks_cluster_version     = "1.31"
eks_node_instance_types = ["t3.medium"]
eks_node_capacity_type  = "ON_DEMAND"
eks_node_disk_size      = 50
eks_node_desired_size   = 2
eks_node_min_size       = 2
eks_node_max_size       = 6

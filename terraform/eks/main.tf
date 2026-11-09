terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  common_tags = merge(
    {
      Environment = "ephemeral-bench"
      Project     = "vllm-inference-platform"
      ManagedBy   = "terraform"
    },
    var.tags
  )
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, az in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, az in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = local.common_tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
  }

  eks_managed_node_groups = {
    cpu = {
      instance_types = var.cpu_node_instance_types
      capacity_type  = var.cpu_capacity_type

      min_size     = var.cpu_node_min_count
      max_size     = var.cpu_node_max_count
      desired_size = var.cpu_node_desired_count

      labels = {
        workload = "vllm-inference"
      }

      tags = merge(local.common_tags, {
        Name     = "${var.cluster_name}-cpu"
        NodeRole = "cpu"
      })
    }

    hami_gpu = {
      instance_types = var.gpu_node_instance_types
      capacity_type  = var.gpu_capacity_type
      ami_type       = "AL2023_x86_64_NVIDIA"

      min_size     = var.gpu_node_min_count
      max_size     = var.gpu_node_max_count
      desired_size = var.gpu_node_desired_count

      labels = {
        gpu      = "on"
        workload = "hami-gpu"
      }

      tags = merge(local.common_tags, {
        Name     = "${var.cluster_name}-hami-gpu"
        NodeRole = "hami-gpu"
      })
    }
  }

  tags = local.common_tags
}

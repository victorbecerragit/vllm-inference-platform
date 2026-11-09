variable "aws_region" {
  description = "AWS region for EKS deployment"
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "vllm-ephemeral-eks"
}

variable "cluster_version" {
  description = "Kubernetes version for EKS"
  type        = string
  default     = "1.30"
}

variable "vpc_cidr" {
  description = "CIDR block for the EKS VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "cpu_node_instance_types" {
  description = "CPU node group instance types"
  type        = list(string)
  default     = ["m6i.large"]
}

variable "cpu_capacity_type" {
  description = "CPU node capacity type (ON_DEMAND or SPOT)"
  type        = string
  default     = "ON_DEMAND"
}

variable "cpu_node_desired_count" {
  description = "Desired CPU node count"
  type        = number
  default     = 1
}

variable "cpu_node_min_count" {
  description = "Minimum CPU node count"
  type        = number
  default     = 1
}

variable "cpu_node_max_count" {
  description = "Maximum CPU node count"
  type        = number
  default     = 4
}

variable "gpu_node_instance_types" {
  description = "GPU node group instance types (g6 family uses NVIDIA L4 GPUs)"
  type        = list(string)
  default     = ["g6.xlarge"]
}

variable "gpu_capacity_type" {
  description = "GPU node capacity type (SPOT recommended for cost control)"
  type        = string
  default     = "SPOT"
}

variable "gpu_node_desired_count" {
  description = "Desired GPU node count (set >0 after quota approval)"
  type        = number
  default     = 0
}

variable "gpu_node_min_count" {
  description = "Minimum GPU node count"
  type        = number
  default     = 0
}

variable "gpu_node_max_count" {
  description = "Maximum GPU node count"
  type        = number
  default     = 1
}

variable "tags" {
  description = "Additional tags applied to EKS resources"
  type        = map(string)
  default     = {}
}

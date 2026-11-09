variable "gcp_project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP Region for cluster deployment"
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "vllm-ephemeral-gke"
}

variable "node_machine_type" {
  description = "Machine type for the GKE node pool (e2-standard-4 provides 4 vCPU / 16GB RAM for CPU vLLM)"
  type        = string
  default     = "e2-standard-4"
}

variable "node_pool_initial_count" {
  description = "Initial node count for the autoscaled GKE node pool"
  type        = number
  default     = 1
}

variable "node_pool_min_count" {
  description = "Minimum node count for the autoscaled GKE node pool"
  type        = number
  default     = 1
}

variable "node_pool_max_count" {
  description = "Maximum node count for the autoscaled GKE node pool"
  type        = number
  default     = 4
}

variable "use_spot_instances" {
  description = "Use Spot VM instances to minimize costs during testing"
  type        = bool
  default     = true
}

variable "hami_gpu_machine_type" {
  description = "Machine type for the dedicated HAMI GPU node pool"
  type        = string
  default     = "n1-standard-4"
}

variable "hami_gpu_accelerator_type" {
  description = "GPU accelerator type to attach to the HAMI node pool"
  type        = string
  default     = "nvidia-tesla-t4"
}

variable "hami_gpu_accelerator_count" {
  description = "Number of GPUs to attach to each HAMI worker"
  type        = number
  default     = 1
}

variable "hami_gpu_pool_initial_count" {
  description = "Initial GPU node count for the HAMI node pool"
  type        = number
  default     = 1
}

variable "hami_gpu_pool_min_count" {
  description = "Minimum GPU node count for the HAMI node pool"
  type        = number
  default     = 1
}

variable "hami_gpu_pool_max_count" {
  description = "Maximum GPU node count for the HAMI node pool"
  type        = number
  default     = 1
}
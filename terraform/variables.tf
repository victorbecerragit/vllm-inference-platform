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
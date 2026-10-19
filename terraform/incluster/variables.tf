variable "gcp_project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region where the existing GKE cluster runs"
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "Existing GKE cluster name"
  type        = string
  default     = "vllm-ephemeral-gke"
}

variable "install_keda" {
  description = "Install KEDA via Helm in the existing cluster"
  type        = bool
  default     = true
}

variable "keda_namespace" {
  description = "Namespace where KEDA will be installed"
  type        = string
  default     = "keda"
}

variable "keda_chart_version" {
  description = "KEDA Helm chart version"
  type        = string
  default     = "2.15.1"
}

variable "install_scaledobject" {
  description = "Create the vLLM KEDA ScaledObject"
  type        = bool
  default     = false
}

variable "scaledobject_name" {
  description = "Name of the KEDA ScaledObject for vLLM"
  type        = string
  default     = "vllm-scaledobject"
}

variable "scaledobject_namespace" {
  description = "Namespace where the vLLM Deployment and ScaledObject live"
  type        = string
  default     = "vllm-inference-platform"
}

variable "scaledobject_target_deployment" {
  description = "Deployment name targeted by the KEDA ScaledObject"
  type        = string
  default     = "vllm"
}

variable "scaledobject_min_replicas" {
  description = "Minimum number of vLLM replicas managed by KEDA"
  type        = number
  default     = 1
}

variable "scaledobject_max_replicas" {
  description = "Maximum number of vLLM replicas managed by KEDA"
  type        = number
  default     = 4
}

variable "scaledobject_polling_interval_seconds" {
  description = "How often KEDA evaluates trigger metrics"
  type        = number
  default     = 15
}

variable "scaledobject_cooldown_period_seconds" {
  description = "Cooldown window before KEDA scales down"
  type        = number
  default     = 60
}

variable "scaledobject_prometheus_server_address" {
  description = "Prometheus service address used by KEDA trigger"
  type        = string
  default     = "http://prometheus:9090"
}

variable "scaledobject_prometheus_query" {
  description = "PromQL query used by the ScaledObject trigger"
  type        = string
  default     = "sum(vllm:num_requests_waiting)"
}

variable "scaledobject_threshold" {
  description = "Threshold for queue-based scale up"
  type        = number
  default     = 2
}

output "keda_enabled" {
  description = "Whether KEDA installation is enabled in the in-cluster stack"
  value       = var.install_keda
}

output "keda_namespace" {
  description = "Namespace where KEDA is installed"
  value       = var.install_keda ? helm_release.keda[0].namespace : null
}

output "scaledobject_enabled" {
  description = "Whether the vLLM ScaledObject is managed by Terraform"
  value       = var.install_scaledobject
}

output "scaledobject_name" {
  description = "Name of the Terraform-managed vLLM ScaledObject"
  value       = var.install_scaledobject ? kubernetes_manifest.vllm_scaledobject[0].manifest.metadata.name : null
}

output "scaledobject_namespace" {
  description = "Namespace of the Terraform-managed vLLM ScaledObject"
  value       = var.install_scaledobject ? kubernetes_manifest.vllm_scaledobject[0].manifest.metadata.namespace : null
}

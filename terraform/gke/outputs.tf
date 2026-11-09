output "kubernetes_cluster_name" {
  description = "GKE Cluster Name"
  value       = google_container_cluster.primary.name
}

output "gke_get_credentials_command" {
  description = "Command to configure kubectl authentication"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${google_container_cluster.primary.location} --project ${var.gcp_project_id}"
}

output "hami_gpu_node_label_command" {
  description = "Label the dedicated HAMI GPU node so the HAMI device plugin can schedule"
  value       = "kubectl label node -l cloud.google.com/gke-nodepool=${google_container_node_pool.hami_gpu_nodes.name} gpu=on --overwrite"
}
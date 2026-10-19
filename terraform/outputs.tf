output "kubernetes_cluster_name" {
  description = "GKE Cluster Name"
  value       = google_container_cluster.primary.name
}

output "gke_get_credentials_command" {
  description = "Command to configure kubectl authentication"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${google_container_cluster.primary.location} --project ${var.gcp_project_id}"
}
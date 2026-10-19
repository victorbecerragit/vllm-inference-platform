terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

data "google_client_config" "default" {}

# Enabled required GCP APIs
resource "google_project_service" "container_api" {
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

# Minimal VPC Network
resource "google_compute_network" "vpc" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.container_api]
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.cluster_name}-subnet"
  ip_cidr_range = "10.10.0.0/20"
  region        = var.gcp_region
  network       = google_compute_network.vpc.name
}

# GKE Cluster (default pool removed so the managed node pool can autoscale independently)
resource "google_container_cluster" "primary" {
  name                     = var.cluster_name
  location                 = "${var.gcp_region}-a" # Zonal cluster to minimize cost
  network                  = google_compute_network.vpc.name
  subnetwork               = google_compute_subnetwork.subnet.name
  remove_default_node_pool = true
  initial_node_count       = 1

  ip_allocation_policy {} # Enables VPC-native cluster mode

  deletion_protection = false

  depends_on = [google_project_service.container_api]
}

# Ephemeral autoscaled node pool for vLLM inference workloads.
resource "google_container_node_pool" "primary_nodes" {
  name               = "${var.cluster_name}-node-pool"
  location           = "${var.gcp_region}-a"
  cluster            = google_container_cluster.primary.name
  initial_node_count = var.node_pool_initial_count

  autoscaling {
    min_node_count = var.node_pool_min_count
    max_node_count = var.node_pool_max_count
  }

  node_config {
    machine_type = var.node_machine_type  # e.g., e2-standard-4 for CPU vLLM
    spot         = var.use_spot_instances # Enables Spot VM pricing

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    labels = {
      environment = "ephemeral-bench"
      workload    = "vllm-inference"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

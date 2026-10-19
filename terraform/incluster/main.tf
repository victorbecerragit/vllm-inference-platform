terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

data "google_client_config" "default" {}

data "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = "${var.gcp_region}-a"
}

provider "kubernetes" {
  host                   = "https://${data.google_container_cluster.primary.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(data.google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${data.google_container_cluster.primary.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(data.google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  }
}

resource "helm_release" "keda" {
  count = var.install_keda ? 1 : 0

  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = var.keda_chart_version
  namespace        = var.keda_namespace
  create_namespace = true
}

resource "kubernetes_manifest" "vllm_scaledobject" {
  count = var.install_scaledobject ? 1 : 0

  manifest = {
    apiVersion = "keda.sh/v1alpha1"
    kind       = "ScaledObject"
    metadata = {
      name      = var.scaledobject_name
      namespace = var.scaledobject_namespace
      labels = {
        app                            = "vllm"
        "app.kubernetes.io/name"       = "vllm"
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = {
      scaleTargetRef = {
        apiVersion = "apps/v1"
        kind       = "Deployment"
        name       = var.scaledobject_target_deployment
      }
      minReplicaCount = var.scaledobject_min_replicas
      maxReplicaCount = var.scaledobject_max_replicas
      pollingInterval = var.scaledobject_polling_interval_seconds
      cooldownPeriod  = var.scaledobject_cooldown_period_seconds
      advanced = {
        horizontalPodAutoscalerConfig = {
          behavior = {
            scaleUp = {
              stabilizationWindowSeconds = 0
              policies = [
                {
                  type          = "Percent"
                  value         = 100
                  periodSeconds = 15
                }
              ]
            }
            scaleDown = {
              stabilizationWindowSeconds = 120
              policies = [
                {
                  type          = "Percent"
                  value         = 50
                  periodSeconds = 30
                }
              ]
            }
          }
        }
      }
      triggers = [
        {
          type = "prometheus"
          metadata = {
            serverAddress = var.scaledobject_prometheus_server_address
            metricName    = "vllm_num_requests_waiting"
            query         = var.scaledobject_prometheus_query
            threshold     = tostring(var.scaledobject_threshold)
          }
        }
      ]
    }
  }

  depends_on = [helm_release.keda]
}

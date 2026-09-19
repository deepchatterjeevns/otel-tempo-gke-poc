# ---------------------------------------------------------------------------
# Observability layer: kube-prometheus-stack + Grafana with Tempo + spanmetrics
# datasources and the POC dashboard preloaded. Mirrors the AWS observability
# layer; only the scrape target story differs (none - same collector Service).
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  # >>> INSERT YOUR VALUES: must match deploy/terraform/backend/backend.tf <<<
  backend "gcs" {
    bucket = "gke-gitops-tfstate-498315"
    prefix = "gap-action-tracing/observability.tfstate"
  }

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.26"
    }
  }
}

data "terraform_remote_state" "gke" {
  backend = "gcs"
  config = {
    # >>> INSERT YOUR VALUES: same bucket as the GKE layer state <<<
    bucket = "gke-gitops-tfstate-498315"
    prefix = "gap-action-tracing/gke.tfstate"
  }
}

locals {
  cluster_name = data.terraform_remote_state.gke.outputs.cluster_name

  # Dashboards shipped in this repo - loaded via the Grafana sidecar.
  dashboard_files = fileset("${path.module}/../../observability/dashboards", "*.json")
}

provider "helm" {
  kubernetes {
    host                   = "https://${data.terraform_remote_state.gke.outputs.cluster_endpoint}"
    cluster_ca_certificate = base64decode(data.terraform_remote_state.gke.outputs.ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "gke-gcloud-auth-plugin"
    }
  }
}

provider "kubernetes" {
  host                   = "https://${data.terraform_remote_state.gke.outputs.cluster_endpoint}"
  cluster_ca_certificate = base64decode(data.terraform_remote_state.gke.outputs.ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "gke-gcloud-auth-plugin"
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = "monitoring"
  # >>> Pin the chart version you use; record it in the article <<<
  version    = "58.2.2"

  create_namespace = true
  wait             = true

  values = [
    yamlencode({
      fullnameOverride = "kps"

      prometheus = {
        prometheusSpec = {
          retention     = "7d"
          retentionSize = "10GB"
          resources = {
            requests = { cpu = "200m", memory = "800Mi" }
          }
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues    = false
          ruleSelectorNilUsesHelmValues          = false

          # Scrape the OTel Collector's spanmetrics exporter port via the
          # dedicated metrics Service (collector/otel-collector.yaml).
          additionalScrapeConfigs = [
            {
              job_name = "otel-spanmetrics"
              static_configs = [
                {
                  targets = ["gap-otel-collector-metrics.gap-otel:8889"]
                }
              ]
            }
          ]
        }
      }

      grafana = {
        adminPassword = "changeme" # >>> INSERT: real secret / use external secrets <<<
        persistence = {
          enabled = true
          size    = "2Gi"
        }
        sidecar = {
          dashboards = {
            enabled    = true
            label      = "grafana_dashboard"
            labelValue = "1"
          }
          datasources = {
            enabled = true
          }
        }
      }

      alertmanager = {
        enabled = false
      }
      kube-state-metrics = {
        enabled = true
      }
    })
  ]
}

# Tempo datasource with tracesToMetrics mapping - identical to the AWS build
# (the correlation config is cloud-agnostic; only the Tempo URL is in-cluster).
resource "kubernetes_config_map" "grafana_datasources" {
  metadata {
    name      = "gap-grafana-datasources"
    namespace = "monitoring"
    labels = {
      grafana_datasource = "1"
    }
  }

  data = {
    "tempo.yaml" = yamlencode({
      apiVersion = 1
      datasources = [
        {
          name       = "Tempo"
          type       = "tempo"
          uid        = "tempo"
          access     = "proxy"
          url        = "http://tempo-query-frontend.tempo:16686"
          isDefault  = false
          jsonData = {
            tracesToMetrics = {
              datasourceUid  = "prometheus"
              spanStartTimeShift = "1h"
              spanEndTimeShift   = "1h"
              tags = [
                { key = "service.name",      value = "service_name" }
                { key = "span.name",         value = "span_name" }
                { key = "service.namespace", value = "service_namespace" }
              ]
            }
          }
        }
      ]
    })
  }
}

# Dashboard import via sidecar - identical to the AWS build.
resource "kubernetes_config_map" "dashboards" {
  for_each = toset(local.dashboard_files)

  metadata {
    name      = "gap-dashboards-${trimsuffix(each.value, ".json")}"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "${each.value}" = file("${path.module}/../../observability/dashboards/${each.value}")
  }
}

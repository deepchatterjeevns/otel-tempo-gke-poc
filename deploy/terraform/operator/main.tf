# ---------------------------------------------------------------------------
# OpenTelemetry Operator layer: cert-manager + operator + GCS bucket for
# Tempo traces. Mirrors the AWS operator layer 1:1.
#
# ORDERING NOTE (same as AWS): cert-manager FIRST (webhook TLS), then the
# operator. The GCS trace bucket is created here (single owner), consumed
# by the tempo layer via remote state.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  # >>> INSERT YOUR VALUES: must match deploy/terraform/backend/backend.tf <<<
  backend "gcs" {
    bucket = "gke-gitops-tfstate-498315"
    prefix = "gap-action-tracing/operator.tfstate"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
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

provider "google" {
  # >>> INSERT: your GCP project ID + region <<<
  project = "gcplearn9-498315"
  region  = "us-central1"
}

locals {
  cluster_name = data.terraform_remote_state.gke.outputs.cluster_name
  region       = "us-central1" # >>> INSERT: your region <<<
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

# --- cert-manager: TLS for the operator's admission/conversion webhooks ----
resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  namespace  = "cert-manager"
  # >>> Pin the chart version you use; record it in the article <<<
  version    = "v1.15.3"

  create_namespace = true
  wait             = true
  wait_for_jobs    = true

  set {
    name  = "crds.enabled"
    value = "true"
  }
  set {
    name  = "replicaCount"
    value = "1" # POC sizing; 2 in production
  }
}

# --- OpenTelemetry Operator: Instrumentation + OpenTelemetryCollector CRDs --
resource "helm_release" "otel_operator" {
  name       = "otel-operator"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-operator"
  namespace  = "otel-operator"
  # >>> Pin the operator version you use; keep in sync with the CRD schema
  # URLs in .github/workflows/validate.yaml (same discipline as AWS) <<<
  version    = "0.74.2"

  create_namespace = true
  wait             = true

  depends_on = [helm_release.cert_manager]
}

# --- GCS bucket for Tempo traces (S3 -> GCS in the port) --------------------
# Same shape as the AWS bucket: short retention, disposable, force_destroy.
resource "google_storage_bucket" "tempo_traces" {
  # >>> INSERT: change the bucket name to something globally unique <<<
  name          = "gap-tracing-tempo-20260818-498315"
  location      = "US"
  force_destroy = true # POC traces are disposable; clean teardown

  uniform_bucket_level_access = true

  labels = {
    project     = "gap-tracing-poc"
    cost-center = "tracing-poc"
    github-repo = "gap-fill-poc-2026-08-18"
  }

  # 24h trace retention - matches the compactor block_retention (belt and
  # suspenders, same as the AWS lifecycle rule).
  lifecycle_rule {
    condition {
      age = 1
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = false # intentional: only state buckets get prevent_destroy
  }
}

output "tempo_traces_bucket" {
  description = "Tempo GCS backend bucket name (consumed by the tempo layer)"
  value       = google_storage_bucket.tempo_traces.name
}

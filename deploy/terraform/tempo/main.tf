# ---------------------------------------------------------------------------
# Tempo layer: GCS-backed trace backend + Workload Identity + Tempo chart.
#
# IRSA -> Workload Identity Federation is the cloud-idiom swap:
#   AWS: SA-annotated role via OIDC provider, s3:* policy on one bucket
#   GCP: KSA annotated with a GSA email; GSA granted storage.objectAccessUser
#        on one bucket. No OIDC provider to create - GKE handles the
#        federation natively when workload_identity is enabled.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  # >>> INSERT YOUR VALUES: must match deploy/terraform/backend/backend.tf <<<
  backend "gcs" {
    bucket = "gke-gitops-tfstate-498315"
    prefix = "gap-action-tracing/tempo.tfstate"
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

data "terraform_remote_state" "operator" {
  backend = "gcs"
  config = {
    # >>> INSERT YOUR VALUES: same bucket as the operator layer state <<<
    bucket = "gke-gitops-tfstate-498315"
    prefix = "gap-action-tracing/operator.tfstate"
  }
}

provider "google" {
  # >>> INSERT: your GCP project ID + region <<<
  project = "gcplearn9-498315"
  region  = "us-central1"
}

locals {
  cluster_name = data.terraform_remote_state.gke.outputs.cluster_name
  tempo_bucket = data.terraform_remote_state.operator.outputs.tempo_traces_bucket
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

# ---------------------------------------------------------------------------
# Workload Identity: Tempo's Kubernetes ServiceAccount (tempo:tempo) maps to
# this Google Service Account; only this GSA can write traces to the bucket.
# ---------------------------------------------------------------------------
resource "google_service_account" "tempo" {
  account_id   = "tempo-traces"
  display_name = "Tempo trace writer (gap POC)"
}

# Least-privilege: object create/get/list/delete on ONE bucket only.
# (GCS has no per-bucket IAM for list - the listing right sits on the
# bucket itself; object rights are bucket-scoped via this uniform grant.)
resource "google_storage_bucket_iam_member" "tempo_write" {
  bucket = local.tempo_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.tempo.email}"
}

# The KSA->GSA binding (the GCP idiom's "trust policy"):
# namespace=tempo, KSA name=tempo - the chart values below create the KSA
# with the matching annotation.
resource "google_service_account_iam_member" "tempo_ksa_binding" {
  service_account_id = google_service_account.tempo.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:gcplearn9-498315.svc.id.goog[tempo.tempo]"
  # >>> INSERT: replace gcplearn9-498315 with the real project ID - the
  # member format is serviceAccount:<project>.svc.id.goog[<namespace>.<ksa>] <<<
}

# ---------------------------------------------------------------------------
# Tempo - distributed, POC-sized, GCS-backed.
# Autopilot divergence: NO StorageClass resource (GKE ships standard-rwo
# default SC) and NO node selectors - the tempo-distributed chart runs as-is.
# ---------------------------------------------------------------------------
resource "helm_release" "tempo" {
  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo-distributed"
  namespace  = "tempo"
  # >>> Pin the chart version you use; record it in the article <<<
  version    = "1.10.0"

  create_namespace = true
  wait             = true
  wait_for_jobs    = true

  values = [yamlencode({
    fullnameOverride = "tempo"

    # KSA named "tempo" carrying the WI annotation (chart creates the KSA;
    # the GSA binding above authorizes it). This replaces the AWS build's
    # eks.amazonaws.com/role-arn annotation.
    serviceAccount = {
      create = true
      name   = "tempo"
      annotations = {
        "iam.googleapis.com/gcp-service-account" = google_service_account.tempo.email
      }
    }

    ingester = {
      replicas = 1
      resources = {
        requests = { cpu = "200m", memory = "512Mi" }
        limits   = { memory = "1Gi" }
      }
      persistence = {
        enabled = true
        # GKE Autopilot: the default StorageClass (standard-rwo, PD CSI)
        # binds this PVC - no gp3 manifest needed (AWS divergence #2).
        size = "2Gi"
      }
    }

    compactor = {
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
      }
      compaction = {
        block_retention = "24h"
      }
    }

    distributor = {
      replicas = 1
    }

    querier = {
      replicas = 1
    }

    queryFrontend = {
      replicas = 1
    }

    # GCS storage - the S3 -> GCS mapping (Tempo supports both natively).
    tempo = {
      storage = {
        trace = {
          backend = "gcs"
          gcs = {
            bucket     = local.tempo_bucket
            chunk_size = "10MB" # sane default; tune for real volumes
          }
        }
      }
    }

    multitenancyEnabled = false
  })]

  depends_on = [google_storage_bucket_iam_member.tempo_write, google_service_account_iam_member.tempo_ksa_binding]
}

# Output consumed by the observability layer + evidence scripts.
output "tempo_query_endpoint" {
  description = "Port-forward: kubectl -n tempo port-forward svc/tempo-query-frontend 3200:16686"
  value       = "tempo-query-frontend.tempo:16686"
}

output "tempo_gsa_email" {
  value = google_service_account.tempo.email
}

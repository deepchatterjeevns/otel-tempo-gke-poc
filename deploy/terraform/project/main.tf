# ---------------------------------------------------------------------------
# Project-enablement layer (GCP-SPECIFIC prerequisite - has NO AWS analog).
#
# WHY THIS LAYER EXISTS: google_project_service enablement ORDER breaks
# Terraform applies if done lazily (the classic GCP trap: container.googleapis.com
# not ready when the GKE module runs). This layer enables every API the
# higher layers need, with explicit depends_on, BEFORE anything else.
#
# Apply order: backend -> project -> network -> gke -> operator -> tempo
#              -> observability
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  # >>> INSERT YOUR VALUES: must match deploy/terraform/backend/backend.tf <<<
  backend "gcs" {
    bucket = "gke-gitops-tfstate-498315"
    prefix = "gap-action-tracing/project.tfstate"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
  }
}

provider "google" {
  # >>> INSERT: your GCP project ID + region <<<
  project = "gcplearn9-498315"
  region  = "us-central1"
}

locals {
  # Enablement ORDER matters only for dependent-resource creation, not for
  # the services themselves (they enable in parallel here; the dependency
  # is enforced downstream by the GKE module waiting on the container API).
  apis = [
    "compute.googleapis.com",        # VPC + PD + (Autopilot nodes' underlying infra)
    "container.googleapis.com",      # GKE
    "artifactregistry.googleapis.com",# demo images
    "iam.googleapis.com",            # service accounts + WI bindings
    "cloudresourcemanager.googleapis.com",
    "storage.googleapis.com",        # GCS backend + Tempo traces
    "stackdriver.googleapis.com",    # Cloud Logging (control-plane logs)
    "billingbudgets.googleapis.com",  # budget guardrail (backend layer)
    "pubsub.googleapis.com",         # budget topic
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.apis)

  service = each.value
  # Don't disable APIs on destroy - keeps the project usable between sessions.
  disable_on_destroy = false
}

output "enabled_apis" {
  value = [for s in google_project_service.apis : s.service]
}

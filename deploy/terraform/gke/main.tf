# ---------------------------------------------------------------------------
# GKE layer: Autopilot cluster (Step 0.6 rule: stateless-app POC ->
# Autopilot; no privileged/daemonset workloads in this stack).
#
# Autopilot cost model (Part C): $0.10/hr management fee WAIVED, pods
# billed per requested CPU/memory (mCPU + MiB-hours). For this POC's
# steady ~6 vCPU-equivalent request footprint that's cheaper than a
# Standard cluster's 2-node floor AND scales the idle baseline to zero.
#
# Workload Identity: the cluster-level binding lives here; per-SA grants
# (Tempo's GCS access) attach in the tempo layer.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  # >>> INSERT YOUR VALUES: must match deploy/terraform/backend/backend.tf <<<
  backend "gcs" {
    bucket = "gke-gitops-tfstate-498315"
    prefix = "gap-action-tracing/gke.tfstate"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.26"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }
}

data "terraform_remote_state" "network" {
  backend = "gcs"
  config = {
    # >>> INSERT YOUR VALUES: same bucket as the network layer state <<<
    bucket = "gke-gitops-tfstate-498315"
    prefix = "gap-action-tracing/network.tfstate"
  }
}

provider "google" {
  # >>> INSERT: your GCP project ID + region <<<
  project = "gcplearn9-498315"
  region  = "us-central1"
}

locals {
  cluster_name = "gap-tracing"
  region       = "us-central1" # >>> INSERT: your region (must match network layer) <<<
}

# Kubernetes/Helm providers authenticate via `gcloud container clusters get-credentials`.
provider "kubernetes" {
  host                   = "https://${module.gke.endpoint}"
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "gke-gcloud-auth-plugin"
  }
}

provider "helm" {
  kubernetes {
    host                   = "https://${module.gke.endpoint}"
    cluster_ca_certificate = base64decode(module.gke.ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "gke-gcloud-auth-plugin"
    }
  }
}

# Autopilot cluster - regional (us-central1), release channel Regular.
# NOTE (honest HA note): regional Autopilot spreads the control plane
# across 3 zones, but a zonal POC would cost less. We keep regional because
# Autopilot billing is pod-based, not node-based - the control-plane HA is
# effectively free with Autopilot.
module "gke" {
  source  = "terraform-google-modules/kubernetes-engine/google//modules/beta-autopilot-private"
  version = "~> 34.0"

  project_id             = "gcplearn9-498315" # >>> INSERT <<<
  name                   = local.cluster_name
  regional               = true
  region                 = local.region
  release_channel        = "REGULAR"
  network                = data.terraform_remote_state.network.outputs.vpc_name
  subnetwork             = data.terraform_remote_state.network.outputs.subnet_name
  ip_range_pods          = "gap-pods"
  ip_range_services      = "gap-services"
  # Workload Identity: ALWAYS enabled on Autopilot clusters (no flag to
  # set - unlike GKE Standard). The tempo layer's KSA->GSA binding relies
  # on this.
  enable_private_nodes    = true
  master_ipv4_cidr        = "172.16.0.0/28"

  labels = {
    project     = "gap-tracing-poc"
    cost-center = "tracing-poc"
    github-repo = "gap-fill-poc-2026-08-18"
  }
}

output "cluster_name" {
  value = module.gke.name
}

output "cluster_endpoint" {
  value = module.gke.endpoint
}

output "ca_certificate" {
  value = module.gke.ca_certificate
}

output "cluster_id" {
  value = module.gke.cluster_id
}

# ---------------------------------------------------------------------------
# Network layer: VPC + subnet for the GKE Autopilot cluster.
# No public subnets needed (Autopilot provisions its own nodes; there are
# no user-managed node pools), no NAT yet - see the NAT gateway below.
#
# Divergence vs AWS: single subnet (nodes + pods via alias-IP ranges) vs
# the AWS build's 3 private subnets. GKE's alias-IP model gives every pod
# a VPC-native address - no secondary CIDR attach needed (that was a
# Karpenter-scale concern anyway).
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  # >>> INSERT YOUR VALUES: must match deploy/terraform/backend/backend.tf <<<
  backend "gcs" {
    bucket = "gke-gitops-tfstate-498315"
    prefix = "gap-action-tracing/network.tfstate"
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

resource "google_compute_network" "vpc" {
  name                    = "gap-tracing-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "gke" {
  name          = "gap-tracing-subnet"
  region        = "us-central1" # >>> INSERT: your region <<<
  ip_cidr_range = "10.42.0.0/24"
  network       = google_compute_network.vpc.id

  # Cluster-secondary range: pod IPs (alias IPs, VPC-native).
  # Services range declared in the GKE module.
  secondary_ip_range {
    range_name    = "gap-pods"
    ip_cidr_range = "10.43.0.0/20"
  }

  # Services range consumed by the GKE layer (ip_range_services).
  secondary_ip_range {
    range_name    = "gap-services"
    ip_cidr_range = "10.44.0.0/20"
  }

  # Private Google Access: pods reach Google APIs (GCS, Artifact Registry)
  # WITHOUT a NAT gateway - FREE for Google API traffic (Part C: PGA is the
  # cost win; NAT reserved for true internet egress only).
  private_ip_google_access = true
}

# ---------------------------------------------------------------------------
# Cloud NAT - for the (rare) true-internet egress: external image pulls from
# Docker Hub (busybox, python) if not mirrored in Artifact Registry.
# Cost note (runbook has the math): NAT is ~$0.045/hr per VM-hour of use +
# per-GB. Autopilot pods don't need it for Google APIs (PGA covers those).
# ---------------------------------------------------------------------------
resource "google_compute_router" "nat" {
  name    = "gap-tracing-router"
  region  = google_compute_subnetwork.gke.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name   = "gap-tracing-nat"
  router = google_compute_router.nat.name
  region = google_compute_router.nat.region

  # Single auto-allocated IP: fine for a short-lived POC (the AWS build
  # used a single NAT gateway for the same reason).
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  # Log failures when image pulls through NAT break (debug aid).
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

output "vpc_name" {
  value = google_compute_network.vpc.name
}

output "subnet_name" {
  value = google_compute_subnetwork.gke.name
}

output "subnet_region" {
  value = google_compute_subnetwork.gke.region
}

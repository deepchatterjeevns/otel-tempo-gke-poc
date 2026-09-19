# ---------------------------------------------------------------------------
# GCS Terraform backend bootstrap + cost guardrail (google_billing_budget).
# Run this ONCE before the first `terraform init` of the other layers.
#
# GCP vs AWS note: the GCS backend has NATIVE state locking (no DynamoDB
# equivalent, no lock table to create) - one of the port's simplifications.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
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

data "google_project" "poc" {
  project_id = "gcplearn9-498315" # >>> INSERT: same as provider block <<<
}

data "google_billing_account" "poc" {
  # >>> INSERT: your billing account display name (or switch to a
  # `google_billing_budget` with the billing account ID directly) <<<
  display_name = "01D27A-363693-0C279A"
}

# Cost-attribution labels (GCP label syntax: lowercase + dashes only).
resource "google_storage_bucket" "tfstate" {
  # >>> INSERT: change the bucket name to something globally unique <<<
  # e.g. "<your-handle>-gap-tracing-tfstate"
  name          = "gke-gitops-tfstate-498315"
  location      = "US"
  force_destroy = false

  # Guard against accidental destroy - state lives here.
  lifecycle {
    prevent_destroy = true
  }

  # Versioning: recover from bad applies (same reason as the AWS build).
  versioning {
    enabled = true
  }

  uniform_bucket_level_access = true

  labels = {
    project     = "gap-tracing-poc"
    cost-center = "tracing-poc"
    github-repo = "gap-fill-poc-2026-08-18"
  }
}

output "state_bucket_name" {
  value = google_storage_bucket.tfstate.name
}

# ---------------------------------------------------------------------------
# COST GUARDRAIL (Part C hard constraint): google_billing_budget.
# Same $10 cap as the AWS build; notification via Pub/Sub topic (the GCP
# idiom - Budget API publishes forecast/actual alerts to a topic).
#
# NOTE: budgets are BILLING-ACCOUNT-level resources, not project-level.
# They see ALL spend in the billing account, so this works best on a
# dedicated POC project (which is what the runbook assumes anyway).
# ---------------------------------------------------------------------------
resource "google_pubsub_topic" "budget_alerts" {
  name = "gap-tracing-budget-alerts"
}

resource "google_billing_budget" "poc" {
  billing_account = data.google_billing_account.poc.id
  display_name    = "gap-tracing-poc"

  budget_filter {
    projects = [tostring(data.google_project.poc.number)]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = "10"
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 1.0
  }

  # Publishes to Pub/Sub on each threshold crossing (programmatic alerting;
  # pair with a Cloud Function that emails - out of scope for the POC).
  all_updates_rule {
    pubsub_topic = google_pubsub_topic.budget_alerts.id
  }
}

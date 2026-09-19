# terraform {
#   required_version = ">= 1.6.0"

#   backend "gcs" {
#     # >>> INSERT YOUR VALUES (GCS backend - native locking, no lock table) <<<
#     bucket = "gke-gitops-tfstate-498315"
#     prefix = "gap-action-tracing/terraform.tfstate"
#   }
# }

# If you comment out the backend block (state stays local) this empty block is required.
terraform {
  required_version = ">= 1.6.0"
}

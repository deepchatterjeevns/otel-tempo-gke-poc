SHELL := pwsh
CLUSTER_NAME ?= gap-tracing
GCP_PROJECT   ?= gcplearn9-498315
GCP_REGION    ?= us-central1
IMAGE_REPO    ?= us-central1-docker.pkg.dev/gcplearn9-498315/gitops-poc-apps

.PHONY: help init-bootstrap apply-project apply-network apply-gke apply-operator apply-tempo apply-observability \
        kubectl-context deploy-collector deploy-app port-forwards evidence destroy

help: ## Show this help
	@Get-Content $(MAKEFILE_LIST) | Select-String '^[a-zA-Z_-]+:.*?## ' | ForEach-Object { $$_.Line }

# ---------- Day 0: state backend + budget guardrail (run once) ----------------
init-bootstrap: ## Bootstrap GCS state bucket + billing budget (once)
	terraform -chdir=deploy/terraform/backend init
	terraform -chdir=deploy/terraform/backend apply

# ---------- Layer applies (GCP order - API enablement FIRST) -------------------
apply-project: ## Enable all required Google APIs (MUST be first)
	terraform -chdir=deploy/terraform/project init
	terraform -chdir=deploy/terraform/project apply

apply-network: ## Apply VPC + subnet (PGA on) + NAT
	terraform -chdir=deploy/terraform/network init
	terraform -chdir=deploy/terraform/network apply

apply-gke: ## Apply GKE Autopilot cluster (consumes network state)
	terraform -chdir=deploy/terraform/gke init
	terraform -chdir=deploy/terraform/gke apply

apply-operator: ## Apply cert-manager + OTel Operator + GCS trace bucket
	terraform -chdir=deploy/terraform/operator init
	terraform -chdir=deploy/terraform/operator apply

apply-tempo: ## Apply Tempo (Workload Identity + tempo-distributed chart)
	terraform -chdir=deploy/terraform/tempo init
	terraform -chdir=deploy/terraform/tempo apply

apply-observability: ## Apply kube-prometheus-stack + datasources + dashboard
	terraform -chdir=deploy/terraform/observability init
	terraform -chdir=deploy/terraform/observability apply

# ---------- K8s manifests ------------------------------------------------------
kubectl-context: ## Get kubeconfig credentials for the Autopilot cluster
	gcloud container clusters get-credentials $(CLUSTER_NAME) --region $(GCP_REGION) --project $(GCP_PROJECT)

deploy-collector: ## Deploy OTel Collector gateway + Instrumentation CR (NO SC needed - see collector/storageclass-note.txt)
	kubectl create namespace gap-otel --dry-run=client -o yaml | kubectl apply -f -
	kubectl create namespace gap-demo --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f collector/otel-collector.yaml
	kubectl apply -f collector/instrumentation.yaml

deploy-app: ## Deploy demo app + loadgen (auto-instrumented via operator)
	kubectl apply -f workloads/

# ---------- Access ---------------------------------------------------------------
port-forwards: ## Port-forward Tempo (3200) + Prometheus (9090) + Grafana (3000)
	kubectl -n tempo port-forward svc/tempo-query-frontend 3200:16686 &
	kubectl -n monitoring port-forward svc/kps-kube-prometheus-prometheus 9090:9090 &
	kubectl -n monitoring port-forward svc/kps-grafana 3000:80 &
	@echo "Tempo http://127.0.0.1:3200 | Prometheus http://127.0.0.1:9090 | Grafana http://127.0.0.1:3000"

# ---------- Evidence harness -------------------------------------------------------
build-push-images: ## Build and push frontend + backend images to Artifact Registry
	docker build --build-arg SERVICE=frontend -t $(IMAGE_REPO)/gap-demo-frontend:latest apps/
	docker build --build-arg SERVICE=backend -t $(IMAGE_REPO)/gap-demo-backend:latest apps/
	docker push $(IMAGE_REPO)/gap-demo-frontend:latest
	docker push $(IMAGE_REPO)/gap-demo-backend:latest

evidence: ## Run all four evidence scripts (needs port-forwards up)
	./evidence/run-01-ingest.ps1
	./evidence/run-02-correlation.ps1
	./evidence/run-03-latency.ps1
	./evidence/run-04-resilience.ps1
	./evidence/summarize-evidence.ps1

# ---------- Teardown (reverse order!) ----------------------------------------------
destroy: ## Destroy everything in reverse layer order
	terraform -chdir=deploy/terraform/observability destroy
	terraform -chdir=deploy/terraform/tempo destroy
	terraform -chdir=deploy/terraform/operator destroy
	terraform -chdir=deploy/terraform/gke destroy
	terraform -chdir=deploy/terraform/network destroy
	@echo "The project layer's APIs stay enabled (disable_on_destroy=false)."
	@echo "Now run the orphan hunt in docs/runbook.md (PDs, IPs, router/NAT, SA keys, GCS)."

# Runbook (GCP port): prerequisites, order, cost math, teardown, gotchas

## GCP project prerequisites (day 0 — before any apply)

1. **Billing project linked** — the POC assumes a dedicated project with
   billing enabled (the budget filters to this project).
2. **Org-policy blockers** — check for constraints that break this build:
   ```bash
   gcloud resource-manager org-policies list --project=YOUR-GCP-PROJECT-ID
   # Must NOT block: compute.googleapis.com resource locations
   #   (gcp.resourceLocations) covering us-central1; external IP access is
   #   fine (we use none); service account key creation is fine (we create
   #   NO keys - Workload Identity only).
   ```
3. **API enablement is IN CODE** (`deploy/terraform/project`) — apply that
   layer FIRST. The enablement-order trap is handled; don't enable APIs
   manually alongside it (state drift).
4. **Quotas**: Autopilot provisions nodes on demand; the relevant ceilings
   are CPUS-per-region (default 72 — fine) and PD-SSD-total-GB (default
   500 — fine). No filings needed for this POC.
5. **Tools**: gcloud CLI + `gke-gcloud-auth-plugin` (`gcloud components
   install gke-gcloud-auth-plugin`), Terraform >= 1.6, kubectl, Helm 3,
   pwsh 7+, Docker (build/push demo images to Artifact Registry — see
   the `>>> INSERT` marker in workloads/demo-app.yaml).
6. **Artifact Registry**: create a repo (or use an existing one) and
   update the image markers:
   ```bash
   gcloud artifacts repositories create gap-demo --repository-format=docker \
     --location=us-central1   # >>> INSERT: your location <<<
   docker tag gap-demo-frontend:latest us-central1-docker.pkg.dev/YOUR-GCP-PROJECT-ID/gap-demo/frontend:latest
   docker push us-central1-docker.pkg.dev/YOUR-GCP-PROJECT-ID/gap-demo/frontend:latest
   # same for backend
   ```

## Order of operations

```
 1. make init-bootstrap        # GCS state bucket + budget (once)
 2. make apply-project         # ENABLE APIs FIRST (GCP-specific layer)
 3. make apply-network         # VPC + subnet (PGA) + router/NAT
 4. make apply-gke             # Autopilot cluster
 5. make kubectl-context       # gke-gcloud-auth-plugin
 6. make apply-operator        # cert-manager -> otel-operator + trace bucket
 7. make apply-tempo           # Workload Identity + tempo-distributed
 8. make apply-observability   # prometheus stack + grafana + datasources
 9. make deploy-collector      # NO StorageClass step (GKE default SC - see
                              #   collector/storageclass-note.txt)
10. make deploy-app
11. make port-forwards         # 3 terminals
12. ./evidence/run-01-ingest.ps1 -DurationMinutes 2
13. ./evidence/run-02-correlation.ps1
14. ./evidence/run-03-latency.ps1
15. ./evidence/run-04-resilience.ps1
16. ./evidence/summarize-evidence.ps1 -SessionHours <your-hours>
17. Screenshots -> evidence/results/snapshots/
```

Layer health checks before moving on:

```bash
kubectl get pods -n cert-manager
kubectl get pods -n otel-operator
kubectl get instrumentation -A                    # gap-python present
kubectl get otelcol -n gap-otel                    # gap-otel-collector 2/2
kubectl get pods -n tempo
kubectl get pvc -n tempo                           # Bound (standard-rwo)
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana
kubectl get deploy frontend backend -n gap-demo -o yaml | grep -A2 initContainers
```

Workload Identity sanity (the GCP analog of IRSA debugging):

```bash
# From inside any tempo pod:
kubectl -n tempo exec deploy/tempo-distributor -- \
  sh -c 'curl -s -H "Metadata-Flavor: Google" "http://169.254.169.254/computeMetadata/v1/instance/service-accounts/"'
# Should list the tempo-traces@<project>.iam.gserviceaccount.com email.
```

## Cost math (Part C — show the work)

Budget: **$10/month** via `google_billing_budget` (alerts at 50% + 100%
to the Pub/Sub topic). Burn ≈ **$0.16/hr** while everything is running:

| Item | Math | $/hr |
|---|---|---|
| GKE Autopilot mgmt fee | waived | 0 |
| Pods (requests-based) | demo 4×100m + collector 2×(200m/384Mi... operator default) + tempo stack ≈ 2.4 vCPU + ~6Gi ≈ $0.11/hr at us-central1 on-demand pod rates | ~0.11 |
| Cloud NAT | ~$0.045/hr while any egress active (image pulls at bootstrap) + $0.001/GB | ~0.02 amortized |
| PDs (2×2Gi) | pd-standard $0.04/GB-mo → pennies | <0.01 |
| GCS traces + state | MB-scale, lifecycle 24h | ~0 |
| Private Google Access | FREE for Google API egress (Artifact Registry pulls, GCS puts) | 0 |

Two sessions (~7 h) ≈ **$1.10**. Between evidence runs you can delete
nothing and still pay ~$0.01/hr (scale demo to zero → pod-billed
components drop to the tempo/prom stack only) — or full destroy +
recreate < 20 min.

**Autopilot vs Standard crossover** (the honest note): a Standard GKE
cluster with one 2-node Spot pool would cost $0.10/hr fee WAIVED only
for one-Zonal-+one-cluster-per-project... in practice: mgmt fee applies
($0.10/hr) unless you already run a cluster; Spot 2×e2-medium ≈ $0.04/hr;
total ≈ $0.14/hr + you manage nodes. Autopilot ≈ $0.16/hr with ZERO node
management — for a stateless-app POC the $0.02/hr premium is noise; for
a daemonset/kernel-touching build Standard is mandatory (Step 0.6 rule).

Managed-service crossover (required Part C note): self-hosted Tempo vs
**Google Cloud Trace**: Cloud Trace is per-span priced (first 2.5M/mo
free, then $0.30/million... check current pricing), zero-ops, but
proprietary (OTel can export to it — the SDK story is identical!) — the
lock-in analysis is the same as X-Ray vs Tempo in the AWS runbook; at POC
scale both are ~free, at sustained volume self-hosted Tempo on GCS wins
the same way it wins on S3.

## Iron rule (both clouds)

NEVER run the GCP and AWS stacks concurrently. AWS session → destroy →
orphan hunt → THEN this session. Both runbooks carry the same checklist.

## Teardown (reverse order) + GCP orphan hunt

```
make destroy    # observability -> tempo -> operator -> gke -> network
                # (project layer: APIs stay enabled by design)
```

Orphan hunt (run EVERY session):

```bash
# Orphaned PDs/PVCs (the #1 GCP leftover - Autopilot PVCs are regional)
gcloud compute disks list --filter="name~^gap-tracing AND -users:*"
# Forwarding rules / LBs (none expected - no Services of type LB here;
# verify anyway)
gcloud compute forwarding-rules list --filter="name~gap"
# Static IPs (none expected)
gcloud compute addresses list
# Cloud Router / NAT artifacts (network layer deletes them; verify)
gcloud compute routers list --filter="name~gap"
gcloud compute routers describe gap-tracing-router --region=us-central1 \
  --format="value(nats[].name)"
# Service account keys (we create NONE - verify no keys appeared)
gcloud iam service-accounts keys list --iam-account=tempo-traces@YOUR-GCP-PROJECT-ID.iam.gserviceaccount.com
# GCS leftovers: trace bucket is force_destroy=true; state bucket STAYS
gcloud storage ls gs://REPLACE-WITH-GLOBALLY-UNIQUE-TEMPO-BUCKET 2>/dev/null || echo "trace bucket gone"
# Budget check (did it fire?)
gcloud billing budgets list --billing-account=YOUR-BILLING-ACCOUNT
```

State keep-alive vs recreate: the GCS state bucket persists
(prevent_destroy). Full re-create after destroy < 20 min (record your
number). Killing the whole series: `terraform
-chdir=deploy/terraform/backend destroy` (accept the prevent_destroy
prompt consciously).

## Gotchas (GCP-specific — this exact stack)

1. **API-enablement ordering breaks Terraform** — the project layer MUST
   apply before network/gke. If you hit "API not enabled" plan errors,
   you skipped layer 2 of the order. (This is THE classic GCP TF trap.)
2. **WI binding syntax** — the member string is
   `serviceAccount:<project>.svc.id.goog[<namespace>.<ksa>]`; project ID
   (not number), square brackets (not dot-separated). A wrong-format
   binding applies cleanly and then silently doesn't work — verify with
   the metadata-echo check above.
3. **GKE default SC exists on GKE but NOT EKS** — inverted gotcha vs the
   AWS build: don't apply a default StorageClass on Autopilot (it's
   rejected) and don't expect to need one.
4. **Autopilot rejects pods without resource requests** — every container
   in this repo declares them (collector CRs: the operator sets
   defaults); if you add a container, add requests or the pod is denied
   with a clear ValidationError.
5. **NAT idle cost** — Cloud NAT bills per VM-hour of active use; with
   only Google-API egress (PGA), NAT is idle 99% of the session. Don't
   route GCS/AR traffic through NAT out of habit.
6. **Deletion protection**: the GKE module sets deletion_protection on
   the cluster by default in some versions — if destroy hangs on the
   cluster, check `terraform state show` and flip the flag; the runbook
   order (gke before network) prevents most hangs.
7. **Provider beta-vs-GA drift** — this build pins `~> 5.30` GA
   resources only (beta-autopilot module uses the google-beta provider
   internally; the module handles it). Don't mix `google-beta` provider
   blocks into these layers ad hoc.
8. **Label character rules** — GCP labels are lowercase + dashes
   (`github-repo`, NOT `GithubRepo` — unlike AWS tags which are
   case-sensitive free-form). Every resource here follows the rule;
   keep it when you extend.
9. **Regional vs zonal, 3x cost honesty** — a REGIONAL cluster's control
   plane is HA (free on Autopilot); on Standard, regional = 3x mgmt fee
   ($0.30/hr). We use regional Autopilot (no fee); a zonal Standard POC
   would be the cheap-but-single-zone tradeoff. Stated honestly: this
   POC's tempo stack is single-replica — HA of the trace backend is NOT
   a claim this build makes.
10. **Spot on Autopilot needs a pod annotation**
    (`cloud.google.com/gke-spot: "true"`) — we deliberately DON'T use it
    for the tempo stack (eviction risk on the stateful trace backend —
    same reasoning as the AWS build).

## Session checklist (iron rule enforcement)

```
BEFORE: [ ] AWS stack from this POC fully destroyed (console check)
        [ ] gcloud config list shows the RIGHT project
        [ ] Region + bucket + project IDs edited in every >>> INSERT marker
AFTER:  [ ] evidence/results CSVs committed
        [ ] snapshots/README updated
        [ ] make destroy completed
        [ ] orphan hunt clean (disks, IPs, routers, SA keys, GCS)
        [ ] budget not fired (gcloud billing budgets list)
```

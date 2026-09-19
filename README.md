# OpenTelemetry + Tempo Distributed Tracing on GKE (GCP port)

> Same POC, second cloud: the AWS primary build (../../code) re-proven on
> GKE Autopilot with GCS-backed Tempo and Workload Identity. Companion repo
> for the Medium companion article in ../blog (the series' GCP number).
> Port feasibility ruling: **FULL** — every component maps; divergences are
> logged in [docs/port-divergences.md](docs/port-divergences.md).

## What this proves (identical claims, second cloud)

| Claim | How it's measured | Where |
|---|---|---|
| Distributed trace across services, queryable in Tempo | `run-01-ingest.ps1` (unchanged from AWS — Tempo API is cloud-agnostic) | `evidence/` |
| Trace↔metric correlation via spanmetrics | `run-02-correlation.ps1` (unchanged) | `evidence/` |
| Latency attributed to the right service | `run-03-latency.ps1` (unchanged) | `evidence/` |
| Pipeline survives collector pod loss | `run-04-resilience.ps1` (unchanged) | `evidence/` |

The evidence harness is byte-identical to the AWS build BY DESIGN — that's
the port's headline proof: the OTel/Tempo/Prometheus layer is fully
cloud-agnostic; only the infrastructure under it changed. Numbers are
comparable; the only non-parity line is cost (Autopilot per-pod billing —
divergence table in port-divergences.md).

## Architecture (delta from the AWS build)

```
[GKE Autopilot, regional us-central1]   (no nodes to manage; pods billed
                                         on requests; default SC exists)
  gap-demo app (auto-instrumented, identical manifests)
  gap-otel collector gateway (identical CR)
  tempo on GCS via Workload Identity:  KSA tempo/tempo
    -> annotation iam.googleapis.com/gcp-service-account
    -> GSA tempo-traces@<project>
    -> roles/storage.objectAdmin on ONE bucket
  monitoring: kube-prometheus-stack + Grafana (identical)
[VPC: 1 subnet, alias-IP pods, Private Google Access (free API egress),
 Cloud Router + NAT for internet pulls only]
```

Full mapping table + every divergence with reasons:
`docs/port-divergences.md` (the Staff-level artifact of this port).

## Repo layout

```
deploy/terraform/   backend(GCS+budget) -> project(APIs) -> network(VPC+PGA+NAT)
                    -> gke(Autopilot) -> operator -> tempo -> observability
collector/          otel-collector.yaml + instrumentation.yaml (identical to AWS)
                    storageclass-note.txt (why NO SC manifest here)
workloads/ apps/ observability/dashboards/  (identical to AWS)
evidence/           identical harness + results/
docs/               runbook.md (GCP cost math + orphan hunt), port-divergences.md
.github/workflows   CI validates BOTH subtrees (this + ../code)
```

## Quickstart

```bash
# 0. Edit every >>> INSERT YOUR VALUES marker (project IDs, bucket names,
#    region, billing account, image hostnames). grep -rn "INSERT" .
# 1. State + budget
make init-bootstrap
# 2. GCP ORDER: APIs first, then network, then cluster
make apply-project
make apply-network
make apply-gke
make kubectl-context
# 3. Platform (identical shape to AWS)
make apply-operator
make apply-tempo
make apply-observability
# 4. Workloads + evidence (available in .sh, .py, and .ps1)
make deploy-collector
make deploy-app
make port-forwards
./evidence/run-01-ingest.sh --duration-minutes 2
# ... or: python evidence/evidence.py ingest --duration-minutes 2
# ... run-02/03/04, summarize
# 5. Teardown + orphan hunt
make destroy
```

## Cost (Part C)

> [!CAUTION]
> This POC provisions real GCP infrastructure (GKE Autopilot, Cloud NAT, GCS).
> Budget $10 (google_billing_budget, Pub/Sub alerts at 50%/100%). Burn ≈
> **$0.16/hr** live (Autopilot pod-billed ≈ $0.11 + NAT ≈ $0.02 + PDs/GCS
> pennies) — full math, the Autopilot-vs-Standard crossover, and the
> scale-to-zero idle economics in `docs/runbook.md`. Two sessions ≈
> **$1.10**. 
>
> **Iron rule:** Never run concurrent with the AWS stack. Always destroy one before starting the other.


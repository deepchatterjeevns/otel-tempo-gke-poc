# Port divergences: AWS primary -> GCP port

Every intentional difference between `code/` (AWS) and `gcp/code/` (GCP),
with the reason. This log is a deliverable — the "same POC, second cloud:
what changed and what it cost" story the companion article is built on.

## Component mapping table

| # | AWS primary | GCP port | Divergence class |
|---|---|---|---|
| 1 | EKS 1.30 + managed node group (2× m7g.large Spot) | GKE Autopilot (regional, Regular channel) | **PARTIAL** — no node management at all; billing model changes (per-pod requests, not per-node) |
| 2 | S3 trace bucket (+ lifecycle 24 h) | GCS bucket (+ lifecycle age=1) | **FULL 1:1** |
| 3 | IRSA: OIDC provider + SA annotation + role policy | Workload Identity: KSA annotation `iam.googleapis.com/gcp-service-account` + GSA `roles/iam.workloadIdentityUser` binding | **PARTIAL** — same concept, different mechanics; GKE federates natively (no OIDC provider resource) |
| 4 | S3 least-priv policy (s3:Put/Get/List/Delete on bucket/*) | `roles/storage.objectAdmin` on ONE bucket via bucket IAM | **PARTIAL** — GCS roles are coarser; objectAdmin ≈ the 4 S3 ops (honest note: no narrower per-object verb set exists) |
| 5 | EBS gp3 via EBS-CSI addon + custom default StorageClass | PD via GKE's built-in default SC (`standard-rwo`) | **NATIVE-BETTER** — GKE ships a working default SC; EKS 1.30 does not. Divergence #2 in the build. |
| 6 | S3 TF state + DynamoDB lock table | GCS TF state (native locking) | **FULL 1:1, simpler** — no lock resource at all |
| 7 | AWS Budgets + email | google_billing_budget + Pub/Sub topic | **PARTIAL** — budgets are billing-account-scoped on GCP; email needs a notification channel or Cloud Function (topic-only here) |
| 8 | VPC 3 private + 3 public subnets, single NAT | VPC 1 subnet (alias-IP pods), Cloud Router + NAT, **Private Google Access ON** | **PARTIAL** — PGA makes Google API egress FREE; NAT only for true internet pulls |
| 9 | CloudWatch (unused) | Cloud Logging (unused; control-plane logs only) | N/A — traces never touch them |
| 10 | `aws eks update-kubeconfig` | `gcloud container clusters get-credentials` + `gke-gcloud-auth-plugin` | tooling only |

## Structural divergences (build-shape, not resource-shape)

### D1 — API-enablement layer exists on GCP only
`deploy/terraform/project/` has no AWS analog. Reason: GCP requires
`google_project_service` enablement BEFORE dependent resources, and lazy
enablement breaks Terraform applies (the classic ordering trap). The AWS
build's equivalent "day-0" is quota filings + IAM, which live in the
runbook instead of code.

### D2 — No StorageClass manifest on GCP
`code/collector/storageclass-gp3.yaml` → `gcp/code/collector/storageclass-note.txt`
(a note, not a manifest). Reason: GKE Autopilot ships a default SC and
*forbids* user-managed default SCs. The tempo PVC binds to `standard-rwo`
with zero config. This is the "NATIVE-BETTER" case from the feasibility
ruling: GKE solves it natively, EKS makes you do it.

### D3 — Network shape collapses
3+3 subnets + NAT-per-AZ question → 1 subnet + alias-IP pod range +
services range + single Cloud NAT. Reason: no node pools to place (Autopilot),
no secondary-CIDR exhaustion concern (VPC-native pods), PGA for API egress.

### D4 — Budget notification mechanics
AWS Budgets emails directly. GCP Budget API publishes to Pub/Sub; email
delivery requires a notification channel (created out-of-band in the
console) or a Cloud Function. The port ships the topic (programmatic
guardrail) and documents the email path — not worth a Function for a POC.

### D5 — Evidence harness: byte-identical, by design
`run-01..04.ps1` and the dashboard JSON are copied unchanged. Tempo's API,
Prometheus's API, the collector's config, and the annotation-driven
instrumentation are all cloud-agnostic — that's the port-feasibility FULL
verdict proven in code. The ONLY divergence inside the harness:
`summarize-evidence.ps1 -SessionHours` cost line (Autopilot per-pod
billing vs EC2 per-node billing — runbook math differs).

### D6 — Workload resources on Autopilot
Autopilot enforces resource requests on every container and injects its
own sidecars (e.g., `netd`). Two consequences: (a) the collector/demo
manifests already carry explicit requests (they must, or Autopilot
rejects them — the AWS manifests happen to comply); (b) pod-visible
scheduling differs slightly (GKE-managed taints on system pods), which
matters not for this POC but is worth knowing for E4's `kubectl delete pod`.

## Cost divergences (the honest math — details in runbook.md)

| Line | AWS | GCP |
|---|---|---|
| Control plane | EKS $0.10/hr | Autopilot $0 (mgmt fee waived) |
| Compute | 2× m7g.large Spot ≈ $0.09/hr flat | per-pod: ~2.4 vCPU + ~6Gi requests ≈ $0.11/hr (computed from Autopilot pod pricing) |
| Node storage | gp3 pennies | PD 2×2Gi pennies |
| NAT | $0.045/hr + data | Cloud NAT ~$0.045/hr when in use + data; **$0 idle between sessions** (no always-on VMs) |
| State/trace storage | S3 MBs | GCS MBs |
| **Total burn** | **≈ $0.20/hr** | **≈ $0.16/hr** (and drops to ~$0.01/hr when scaled to zero between evidence runs) |

Verdict for the article: Autopilot wins the idle-time economics for an
ephemeral POC (scale-to-zero), AWS wins when you need node-level control
(operators with daemonsets, CNI/kernel work). Neither is "cheaper"
universally — the billing model is the decision.

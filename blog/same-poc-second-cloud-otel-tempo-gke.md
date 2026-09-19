# Same POC, Second Cloud: OpenTelemetry and Tempo on GKE Autopilot

*The GCP companion to "Zero-Friction Observability: Deploying OpenTelemetry
and Distributed Tracing on Amazon EKS" — the same auto-instrumentation,
collector, and Tempo tracing stack, rebuilt on GKE Autopilot with GCS and
Workload Identity. The evidence scripts are byte-identical. The
infrastructure under them is not. This article is about what changed and
what it cost.*

<!-- >>> INSERT: your Medium handle in the byline; link the primary article + both repos in the intro <<< -->

---

## Table of Contents

1. [Why port a POC to a second cloud](#part-1)
2. [The mapping table: every component, honestly](#part-2)
3. [GKE Autopilot vs EKS node groups: the billing-model swap](#part-3)
4. [Workload Identity vs IRSA: same idea, different mechanics](#part-4)
5. [GCS-backed Tempo and the StorageClass inversion](#part-5)
6. [Private Google Access: the free-egress idiom](#part-6)
7. [Evidence: the same four claims, re-proven](#part-7)
8. [The cost comparison, honestly](#part-8)
9. [What the port taught me](#part-9)

---

<a name="part-1"></a>
## Part 1 — Why port a POC to a second cloud

Porting a working proof-of-concept to a second cloud is the fastest
honest teacher of cloud-idiom differences I know. Tutorials teach you
GKE's console; a port teaches you where GKE quietly solves a problem EKS
makes you solve yourself — and where AWS's model is more flexible.

The rules for this port, stated up front: the **evidence harness must
stay byte-identical** (if the claims only prove out on one cloud, the
claims are about the cloud, not the architecture), every intentional
difference gets logged with a reason, and the cost comparison is honest
per-cloud math, not a marketing table.

The full divergence log is a deliverable in the repo:
[docs/port-divergences.md](https://github.com/YOUR-USER/otel-tempo-eks-poc/blob/main/gcp/code/docs/port-divergences.md).

<a name="part-2"></a>
## Part 2 — The mapping table: every component, honestly

| AWS primary | GCP port | Ruling |
|---|---|---|
| EKS 1.30 + Spot node group | GKE Autopilot | PARTIAL — billing model changes |
| S3 trace bucket, 24h lifecycle | GCS bucket, age=1 lifecycle | FULL 1:1 |
| IRSA (OIDC provider + role) | Workload Identity (KSA→GSA) | PARTIAL — mechanics differ |
| s3:Put/Get/List/Delete policy | roles/storage.objectAdmin on one bucket | PARTIAL — GCS roles coarser |
| EBS gp3 + custom default SC | built-in default SC (standard-rwo) | NATIVE-BETTER — GKE solves it |
| S3 state + DynamoDB lock | GCS state, native locking | FULL, simpler |
| AWS Budgets email | google_billing_budget + Pub/Sub | PARTIAL — no direct email |

Two of those rows deserve their own sections (Parts 4 and 5). The others
are one-line translations the repo's Terraform makes concrete — and the
[divergence log](https://github.com/YOUR-USER/otel-tempo-eks-poc/blob/main/gcp/code/docs/port-divergences.md)
carries the per-file mapping.

<a name="part-3"></a>
## Part 3 — GKE Autopilot vs EKS node groups: the billing-model swap

The AWS build runs 2× m7g.large Spot (~$0.09/hr) and you own everything:
the AMI, the node group, the kubelet config. The GCP port has no nodes to
manage — Autopilot provisions and sizes compute for you, and bills on
**pod resource requests**.

The trap in that sentence: "bills on requests" means every millicore you
request is a line item. The AWS manifests already declared explicit
requests, so the port's cost is ~$0.11/hr for the same ~2.4 vCPU +
~6Gi of requests. But an un-requests'd DaemonSet on EKS costs nothing
extra and on Autopilot is simply *rejected* — Autopilot forces the
discipline of declaring what you actually need.

>>> INSERT: your observed Autopilot cost breakdown from the pricing calculator vs actual billing export after the session <<<

When Autopilot is wrong for the job: any workload that needs
kernel-level privileges, host networking, or daemonsets — Cilium,
Falco, node exporters. That's the Step-0 decision rule this port
follows (stateless-app POC → Autopilot; CNI/kernel work → GKE
Standard + Spot pools). This tracing stack is stateless-app-shaped
(stateful via PVCs, not via host access), so Autopilot fits.

<a name="part-4"></a>
## Part 4 — Workload Identity vs IRSA: same idea, different mechanics

Both clouds solve the same problem: a Kubernetes ServiceAccount should
get cloud permissions without long-lived keys. The mechanics diverge:

**AWS (IRSA)**: the EKS module creates an OIDC provider for the cluster;
an IAM role's trust policy references the namespace+SA; the pod's SA
carries the role ARN annotation.

**GCP (Workload Identity)**: a Google Service Account (GSA) exists;
the KSA's annotation names the GSA email
(`iam.googleapis.com/gcp-service-account`); the GSA's IAM policy grants
`roles/iam.workloadIdentityUser` to the KSA identity via the member
string `serviceAccount:<project>.svc.id.goog[<namespace>.<ksa>]`.

That member-string format is the #1 silent failure: wrong project ID or
dot-vs-bracket syntax, and the binding applies cleanly, passes every
plan, and simply doesn't authenticate. The runbook's metadata-echo check
is the fast verification:

```bash
kubectl -n tempo exec deploy/tempo-distributor -- \
  sh -c 'curl -s -H "Metadata-Flavor: Google" \
  "http://169.254.169.254/computeMetadata/v1/instance/service-accounts/"'
```

The least-privilege comparison is honest in both directions: GCS granted
`objectAdmin` on one bucket where AWS granted four specific S3 verbs.
GCS's role granularity is coarser at the object level — that's a real
divergence, logged as such, not smoothed over.

<a name="part-5"></a>
## Part 5 — GCS-backed Tempo and the StorageClass inversion

Tempo's config swap is one block: `backend: "s3"` becomes `backend: "gcs"`.
The ingester PVC story inverted:

- **EKS 1.30**: no default StorageClass exists. Without the gp3 manifest
  in the AWS repo, the ingester PVC hangs Pending forever — my runbook's
  gotcha #4 on the AWS side.
- **GKE Autopilot**: `standard-rwo` exists out of the box, and Autopilot
  *forbids* user-managed default StorageClasses. The port ships a note
  where the AWS repo ships a manifest — the same concern, opposite
  polarity. That's the NATIVE-BETTER row of the mapping table.

<a name="part-6"></a>
## Part 6 — Private Google Access: the free-egress idiom

The AWS build needs a NAT gateway ($0.045/hr flat) for the private nodes
to reach ECR and S3. The GCP port's equivalent is two-tier:

- **Private Google Access** carries all Google API egress — Artifact
  Registry image pulls, GCS trace puts, the metadata calls — **free**.
- **Cloud NAT** only sees true internet traffic (a handful of Docker Hub
  pulls if you don't mirror images).

The AWS-side cost crossover math (NAT vs VPC endpoints) is a
well-trodden blog topic; GCP's answer is simply "route Google traffic
the free way." The port's VPC layer encodes it: one subnet, PGA on,
Cloud NAT idle 99% of the session.

<a name="part-7"></a>
## Part 7 — Evidence: the same four claims, re-proven

The harness is byte-identical to the AWS build — deliberately. If a
single line had to change for the cloud, the claim it proves would be
about the cloud, not the architecture. Tempo's API, Prometheus's API,
the operator's injection webhook, the spanmetrics connector: none of
them know what they're running on.

>>> INSERT: results table — E1-E4 verdicts from evidence/results/EVIDENCE-RESULTS.md (GCP run) <<<

The one behavioral nuance worth logging: `kubectl delete pod` on the
collector (E4) runs against Autopilot's scheduler, which replaces pods
by request-shape rather than node slot. Expected identical outcomes;
recorded honestly either way:

>>> INSERT: E4 replacement-ready seconds, n=2, vs your AWS numbers <<<

<a name="part-8"></a>
## Part 8 — The cost comparison, honestly

| Line | AWS (EKS + Spot) | GCP (Autopilot) |
|---|---|---|
| Control plane | $0.10/hr | $0 (waived) |
| Compute | $0.09/hr (2× m7g Spot flat) | ~$0.11/hr (pod requests) |
| NAT/egress | $0.045/hr flat | ~$0.02/hr amortized (PGA free) |
| Disks/objects | pennies | pennies |
| **Live burn** | **≈ $0.20/hr** | **≈ $0.16/hr** |
| **Idle between runs** | $0.10/hr (control plane) | **~$0.01/hr** (scale to zero) |
| Two sessions (~7h) | ≈ $1.50 | ≈ $1.10 |

>>> INSERT: your actual totals for both sessions — the "what proving this cost" line <<<

The verdict that matters: Autopilot wins idle-time economics for an
ephemeral POC; EKS wins when you need node-level control. The billing
model IS the decision — per-node (predictable, controllable) vs
per-request (disciplined, scale-to-zero).

<a name="part-9"></a>
## Part 9 — What the port taught me

- The **divergence log** is the artifact I'd show in an interview — not
  the Terraform. Anyone can translate resources; logging *why* each
  difference exists (with the Step-0 feasibility ruling for each) is
  the staff-level work.
- **API-enablement as code** is underrated: the GCP build's project
  layer (enable every API first, in Terraform) prevents the classic
  broken-apply trap that manual console enablement causes.
- **The evidence harness is the portability test.** Zero harness changes
  was the success criterion — and it passing is the real proof that the
  OTel/Tempo stack is cloud-agnostic infrastructure, not "AWS tooling."
- Where GKE is **natively better** (default StorageClass, free Google
  API egress, native state locking), the port documents it as
  NATIVE-BETTER rather than forcing an artificial mirror — a fake
  equivalence would have been easier and worth less.

---

*Part of a gap-action mini-series pairing portfolio repos with measured
evidence. The AWS primary article is
["Zero-Friction Observability: OpenTelemetry and Distributed Tracing on Amazon EKS"](#)
— this is the GCP companion, next in the series.*

<!-- >>> INSERT: link the primary article URL here once published <<<
     >>> INSERT: link both repos (primary ../code, port ../gcp/code) in the intro <<<
     >>> INSERT: your measured numbers in Parts 3, 7, 8 (marked above) <<< -->

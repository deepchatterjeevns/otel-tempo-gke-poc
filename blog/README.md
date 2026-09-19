# Blog series notes (private) — GCP companion

## Article: Same POC, Second Cloud (this folder)

- **File**: `same-poc-second-cloud-otel-tempo-gke.md`
- **Repo**: `../code` (publish inside `otel-tempo-eks-poc` as `gcp/code`,
  or as a sibling repo `otel-tempo-gke-poc` — single repo recommended so
  the comparable-evidence story and the dual-validating CI work as-is)
- **Series numbering**: the GCP number immediately following the AWS
  primary (Zero-Friction Observability). Cross-link both ways.

## Before publishing on Medium — checklist

1. Search for `YOUR-USER` (divergence-log links in Parts 1, 2; repo links)
   and replace with the real GitHub username/repo.
2. Search for `>>> INSERT` — 6 blocks:
   - Intro: byline + primary-article link + both repo links
   - Part 3: Autopilot observed cost breakdown (calculator vs billing)
   - Part 7: GCP E1–E4 results table; E4 replacement seconds vs AWS
   - Part 8: actual session totals for both clouds
   - Footer: primary article URL
3. Run the GCP evidence session FIRST; fill markers from
   `../code/evidence/results/` (the GCP run's CSVs).
4. Publish AFTER the primary article (it's positioned as the companion).
5. Cover: the mapping table (Part 2) as a graphic — it's the shareable
   asset. draw.io/excalidraw, PNG ~1600px.
6. Medium tags (max 5): `Google Cloud`, `Kubernetes`, `GKE`,
   `OpenTelemetry`, `Observability`.
7. Title A/B: current emphasizes the series framing; alternative:
   "GKE Autopilot vs EKS: Porting an OpenTelemetry + Tempo Stack — What
   Changed and What It Cost".

## Promotion notes

- The divergence-log-as-deliverable angle (Part 9) is the hook for
  staff/senior audiences — lead with it on LinkedIn.
- The idle-economics row (Part 8: $0.10/hr vs ~$0.01/hr between runs)
  is the tweet-able line.
- Publish the AWS article first, wait ~1 week, then this one with the
  cross-link — the series framing rewards sequencing.

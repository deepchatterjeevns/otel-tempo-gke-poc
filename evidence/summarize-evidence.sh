#!/usr/bin/env bash
# =============================================================================
# Summarizes all evidence CSVs into EVIDENCE-RESULTS.md (Bash - GCP Port)
# =============================================================================

set -euo pipefail

SESSION_HOURS="0.0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-hours|-h)
            SESSION_HOURS="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
OUT_FILE="${RESULTS_DIR}/EVIDENCE-RESULTS.md"

if [[ ! -d "$RESULTS_DIR" || -z "$(ls -A ${RESULTS_DIR}/*.csv 2>/dev/null)" ]]; then
    echo "No results CSVs found yet - run the evidence scripts first."
    exit 0
fi

NOW_ISO="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

cat <<EOF > "$OUT_FILE"
# Evidence results (auto-generated - GCP Port)

Generated: ${NOW_ISO}

| Evidence | Claim | Verdict | Artifact |
|----------|-------|---------|----------|
EOF

for csv in ${RESULTS_DIR}/*.csv; do
    fname=$(basename "$csv")
    if [[ "$fname" == *"summary"* ]]; then continue; fi
    
    ev_name="$fname"
    if [[ "$fname" == ingest-* ]]; then ev_name="E1 ingest"
    elif [[ "$fname" == correlation-* ]]; then ev_name="E2 correlation"
    elif [[ "$fname" == latency-* ]]; then ev_name="E3 latency attribution"
    elif [[ "$fname" == resilience-* ]]; then ev_name="E4 resilience"
    else ev_name="${fname%.*}"; fi
    
    row_count=$(($(wc -l < "$csv") - 1))
    
    verdict="SEE LOG"
    header=$(head -n 1 "$csv")
    if [[ "$header" == *"verdict"* ]]; then
        col_idx=$(echo "$header" | awk -F',' '{for(i=1;i<=NF;i++){if($i=="verdict")print i}}')
        if [[ -n "$col_idx" ]]; then
            verdict=$(tail -n +2 "$csv" | awk -F',' -v c="$col_idx" '{print $c}' | tr -d '"' | sort | uniq -c | sort -nr | head -n1 | awk '{print $2}')
        fi
    fi
    
    echo "| $ev_name | $row_count row(s) | $verdict | results/$fname |" >> "$OUT_FILE"
done

echo "" >> "$OUT_FILE"
echo "## Cost of proving this (GCP Autopilot session)" >> "$OUT_FILE"
echo "" >> "$OUT_FILE"

is_gt_0=$(awk -v h="$SESSION_HOURS" 'BEGIN { if (h > 0) print 1; else print 0 }')
if [[ "$is_gt_0" == "1" ]]; then
    total=$(awk -v h="$SESSION_HOURS" 'BEGIN { printf "%.2f", h * 0.16 }')
    echo "- Live hours: $SESSION_HOURS | ~\$0.16/hr burn | total ~\$${total}" >> "$OUT_FILE"
else
    echo "- >>> INSERT: live session hours x \$0.16/hr (see docs/runbook.md cost math) <<<" >> "$OUT_FILE"
fi

echo "Wrote $OUT_FILE"
cat "$OUT_FILE"

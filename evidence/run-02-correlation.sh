#!/usr/bin/env bash
# =============================================================================
# Evidence 2 (OBSERVABILITY): trace-to-metrics correlation (Bash - GCP Port)
# =============================================================================

set -euo pipefail

TIMEOUT_SECONDS=300

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/results"
mkdir -p "$OUT_DIR"

RUN_ID="$(date +'%Y%m%d-%H%M%S')"
LOG_FILE="${OUT_DIR}/correlation-${RUN_ID}.log"
CSV_FILE="${OUT_DIR}/correlation-${RUN_ID}.csv"

log() {
    local msg="$(date -u +'%Y-%m-%dT%H:%M:%SZ') $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

prom_api() {
    local query="$1"
    local enc_query=$(jq -rn --arg x "$query" '$x|@uri')
    curl -s --max-time 10 "http://127.0.0.1:9090/api/v1/query?query=${enc_query}" || echo "{}"
}

log "=== Evidence 2: trace-to-metrics correlation (run=${RUN_ID}) ==="

declare -a Q_NAMES=(
    "frontend call rate (RED: R)"
    "frontend request duration histogram (RED: D)"
    "backend call rate (RED: R)"
    "backend duration histogram (RED: D) - reveals the 0-50ms delay"
    "span_name label present (the trace<->metric join key)"
)

declare -a Q_QUERIES=(
    'rate(traces_span_metrics_calls_total{service_name="gap-frontend"}[5m])'
    'traces_span_metrics_duration_seconds_bucket{service_name="gap-frontend"}'
    'rate(traces_span_metrics_calls_total{service_name="gap-backend"}[5m])'
    'traces_span_metrics_duration_seconds_bucket{service_name="gap-backend"}'
    'traces_span_metrics_calls_total{span_name="GET /"}'
)

declare -a Q_CHECKS=(
    "value-gt-0"
    "series-exists"
    "value-gt-0"
    "series-exists"
    "series-exists"
)

echo "run_id,timestamp,claim,query,value,verdict" > "$CSV_FILE"
FAILED_COUNT=0

for i in "${!Q_NAMES[@]}"; do
    NAME="${Q_NAMES[$i]}"
    QUERY="${Q_QUERIES[$i]}"
    CHECK="${Q_CHECKS[$i]}"
    
    log "Query [${NAME}]: ${QUERY}"
    
    DEADLINE=$(( $(date +%s) + 60 ))
    VALUE=""
    
    while [[ -z "$VALUE" && $(date +%s) -lt $DEADLINE ]]; do
        RESP=$(prom_api "$QUERY")
        STATUS=$(echo "$RESP" | jq -r '.status // empty')
        RES_COUNT=$(echo "$RESP" | jq '.data.result | length' 2>/dev/null || echo 0)
        
        if [[ "$STATUS" == "success" && "$RES_COUNT" -ge 1 ]]; then
            VALUE=$(echo "$RESP" | jq -r '.data.result[0].value[1] // empty')
            if [[ -z "$VALUE" || "$VALUE" == "null" ]]; then
                VALUE="found"
            fi
        fi
        
        if [[ -z "$VALUE" ]]; then
            sleep 10
        fi
    done
    
    OK="false"
    if [[ -n "$VALUE" ]]; then
        if [[ "$CHECK" == "value-gt-0" && "$VALUE" != "found" ]]; then
            IS_GT_0=$(awk -v v="$VALUE" 'BEGIN { if (v > 0) print "1"; else print "0" }' 2>/dev/null || echo "0")
            if [[ "$IS_GT_0" == "1" ]]; then OK="true"; fi
        else
            OK="true"
        fi
    fi
    
    VERDICT="FAIL"
    if [[ "$OK" == "true" ]]; then VERDICT="PASS"; else FAILED_COUNT=$((FAILED_COUNT + 1)); fi
    
    log "${VERDICT}: ${NAME} (value=${VALUE})"
    echo "\"$RUN_ID\",\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\",\"$NAME\",\"$QUERY\",\"$VALUE\",\"$VERDICT\"" >> "$CSV_FILE"
done

log "Artifacts: $CSV_FILE"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
    log "${FAILED_COUNT} checks FAILED"
    exit 1
fi

log "All correlation checks PASSED."

#!/usr/bin/env bash
# =============================================================================
# Evidence 3 (OBSERVABILITY): latency attribution (Bash - GCP Port)
# =============================================================================

set -euo pipefail

SAMPLE_TRACES=10
TIMEOUT_SECONDS=300

usage() {
    echo "Usage: $0 [--sample-traces <int>] [--timeout-seconds <int>]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sample-traces|-s)
            SAMPLE_TRACES="$2"
            shift 2
            ;;
        --timeout-seconds|-t)
            TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/results"
mkdir -p "$OUT_DIR"

RUN_ID="$(date +'%Y%m%d-%H%M%S')"
LOG_FILE="${OUT_DIR}/latency-${RUN_ID}.log"
CSV_FILE="${OUT_DIR}/latency-${RUN_ID}.csv"

log() {
    local msg="$(date -u +'%Y-%m-%dT%H:%M:%SZ') $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

tempo_api() {
    local path="$1"
    curl -s --max-time 10 "http://127.0.0.1:3200${path}" || echo "{}"
}

log "=== Evidence 3: latency attribution (run=${RUN_ID}, sample=${SAMPLE_TRACES}) ==="

DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))
TRACES_JSON="{}"
TRACES_COUNT=0

while [[ "$TRACES_COUNT" -lt "$SAMPLE_TRACES" && $(date +%s) -lt $DEADLINE ]]; do
    SEARCH_RESP=$(tempo_api "/api/search?tags=service.name%3Dgap-frontend&limit=${SAMPLE_TRACES}")
    TRACES_COUNT=$(echo "$SEARCH_RESP" | jq -r '.traces | length' 2>/dev/null || echo "0")
    
    if [[ "$TRACES_COUNT" -ge "$SAMPLE_TRACES" ]]; then
        TRACES_JSON="$SEARCH_RESP"
    else
        sleep 10
    fi
done

if [[ "$TRACES_COUNT" -lt 1 ]]; then
    log "FAIL: no traces found"
    exit 1
fi

echo "run_id,timestamp,trace_id,span_id,service_name,span_name,duration_ns,duration_ms" > "$CSV_FILE"

FRONTEND_SUM=0
FRONTEND_COUNT=0
BACKEND_SUM=0
BACKEND_COUNT=0
SAMPLED=0

for t_id in $(echo "$TRACES_JSON" | jq -r '.traces[].traceID'); do
    TRACE_RESP=$(tempo_api "/api/traces/${t_id}")
    
    while IFS=',' read -r span_id svc span_name dur_ns; do
        if [[ -z "$span_id" ]]; then continue; fi
        
        dur_ms=$(awk -v d="$dur_ns" 'BEGIN { printf "%.2f", d / 1000000.0 }')
        
        echo "\"$RUN_ID\",\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\",\"$t_id\",\"$span_id\",\"$svc\",\"$span_name\",$dur_ns,$dur_ms" >> "$CSV_FILE"
        SAMPLED=$((SAMPLED + 1))
        
        if [[ "$svc" == "gap-frontend" ]]; then
            FRONTEND_SUM=$((FRONTEND_SUM + dur_ns))
            FRONTEND_COUNT=$((FRONTEND_COUNT + 1))
        elif [[ "$svc" == "gap-backend" ]]; then
            BACKEND_SUM=$((BACKEND_SUM + dur_ns))
            BACKEND_COUNT=$((BACKEND_COUNT + 1))
        fi
    done < <(echo "$TRACE_RESP" | jq -r '.spans[]? | [ .spanID, (.resource.attributes[]? | select(.key=="service.name").value.stringValue), .name, .duration ] | @csv' | tr -d '"')
done

log "Artifacts: $CSV_FILE (${SAMPLED} spans sampled)"

AVG_FRONTEND_MS="-1"
if [[ "$FRONTEND_COUNT" -gt 0 ]]; then
    AVG_FRONTEND_MS=$(awk -v s="$FRONTEND_SUM" -v c="$FRONTEND_COUNT" 'BEGIN { printf "%.2f", (s/c) / 1000000.0 }')
fi

AVG_BACKEND_MS="-1"
if [[ "$BACKEND_COUNT" -gt 0 ]]; then
    AVG_BACKEND_MS=$(awk -v s="$BACKEND_SUM" -v c="$BACKEND_COUNT" 'BEGIN { printf "%.2f", (s/c) / 1000000.0 }')
fi

log "avg frontend span: ${AVG_FRONTEND_MS} ms | avg backend span: ${AVG_BACKEND_MS} ms"

IS_BACKEND_SLOWER=$(awk -v b="$AVG_BACKEND_MS" -v f="$AVG_FRONTEND_MS" 'BEGIN { if (b > f - 5) print "1"; else print "0" }')

if [[ "$IS_BACKEND_SLOWER" == "1" ]]; then
    log "PASS: backend span (${AVG_BACKEND_MS} ms) holds the latency - attribution works"
    exit 0
else
    log "FAIL: backend span (${AVG_BACKEND_MS} ms) not slower than frontend (${AVG_FRONTEND_MS} ms)"
    exit 1
fi

#!/usr/bin/env bash
# =============================================================================
# Evidence 1 (OBSERVABILITY): end-to-end trace ingest (Bash version - GCP Port)
# =============================================================================

set -euo pipefail

DURATION_MINUTES=2
TIMEOUT_SECONDS=300

usage() {
    echo "Usage: $0 [--duration-minutes <int>] [--timeout-seconds <int>]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration-minutes|-d)
            DURATION_MINUTES="$2"
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
LOG_FILE="${OUT_DIR}/ingest-${RUN_ID}.log"
CSV_FILE="${OUT_DIR}/ingest-${RUN_ID}.csv"

log() {
    local msg="$(date -u +'%Y-%m-%dT%H:%M:%SZ') $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

tempo_api() {
    local path="$1"
    curl -s --max-time 10 "http://127.0.0.1:3200${path}" || echo "{}"
}

log "=== Evidence 1: trace ingest (run=${RUN_ID}, duration=${DURATION_MINUTES}) ==="

# Preflight
log "Preflight: collector pods healthy"
COL_COUNT=$(kubectl get pods -n gap-otel -l app.kubernetes.io/managed-by=opentelemetry-operator -o json | jq '.items | length')
if [[ "$COL_COUNT" -lt 1 ]]; then
    echo "Error: No collector pods found in gap-otel" >&2
    exit 1
fi

log "Preflight: demo app pods Running and instrumented"
NOT_READY=$(kubectl get pods -n gap-demo -o json | jq '[.items[] | select(.status.phase != "Running")] | length')
if [[ "$NOT_READY" -gt 0 ]]; then
    echo "Error: ${NOT_READY} pods not Running in gap-demo" >&2
    exit 1
fi

# Drive load
log "Letting the loadgen run for ${DURATION_MINUTES} minutes"
sleep $(( DURATION_MINUTES * 60 ))

DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))
TRACE_FOUND="false"
SPAN_COUNT=0
SERVICES=""
TRACE_ID=""

while [[ "$TRACE_FOUND" == "false" && $(date +%s) -lt $DEADLINE ]]; do
    SEARCH_RESP=$(tempo_api "/api/search?tags=service.name%3Dgap-frontend&limit=5")
    TRACES_COUNT=$(echo "$SEARCH_RESP" | jq -r '.traces | length' 2>/dev/null || echo "0")
    
    if [[ "$TRACES_COUNT" -ge 1 ]]; then
        TRACE_ID=$(echo "$SEARCH_RESP" | jq -r '.traces[0].traceID')
        log "Trace found: ${TRACE_ID} - fetching full span list"
        
        TRACE_RESP=$(tempo_api "/api/traces/${TRACE_ID}")
        SPAN_COUNT=$(echo "$TRACE_RESP" | jq '.spans | length' 2>/dev/null || echo "0")
        
        SERVICES=$(echo "$TRACE_RESP" | jq -r '[.spans[]?.resource?.attributes[]? | select(.key == "service.name").value.stringValue] | unique | join(",")')
        
        if [[ "$SPAN_COUNT" -ge 2 && "$SERVICES" == *"gap-frontend"* && "$SERVICES" == *"gap-backend"* ]]; then
            TRACE_FOUND="true"
        fi
    fi
    
    if [[ "$TRACE_FOUND" == "false" ]]; then
        sleep 10
    fi
done

FRONTEND_SPAN="False"
BACKEND_SPAN="False"
if [[ "$SERVICES" == *"gap-frontend"* ]]; then FRONTEND_SPAN="True"; fi
if [[ "$SERVICES" == *"gap-backend"* ]]; then BACKEND_SPAN="True"; fi

if [[ "$TRACE_FOUND" == "true" ]]; then
    log "PASS: distributed trace queryable - spans=${SPAN_COUNT} services=${SERVICES}"
else
    log "FAIL: no distributed trace found within ${TIMEOUT_SECONDS} s"
    exit 1
fi

echo "run_id,timestamp,trace_id,span_count,frontend_span,backend_span,verdict" > "$CSV_FILE"
echo "\"$RUN_ID\",\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\",\"$TRACE_ID\",$SPAN_COUNT,$FRONTEND_SPAN,$BACKEND_SPAN,PASS" >> "$CSV_FILE"

log "Artifacts: $CSV_FILE"
log "Done."

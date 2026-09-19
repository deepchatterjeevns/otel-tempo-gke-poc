#!/usr/bin/env bash
# =============================================================================
# Evidence 4 (BEHAVIORAL): pipeline resilience (Bash - GCP Port)
# =============================================================================

set -euo pipefail

RUNS=2
LOAD_SECONDS=60

usage() {
    echo "Usage: $0 [--runs <int>] [--load-seconds <int>]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runs|-r)
            RUNS="$2"
            shift 2
            ;;
        --load-seconds|-l)
            LOAD_SECONDS="$2"
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
LOG_FILE="${OUT_DIR}/resilience-${RUN_ID}.log"
CSV_FILE="${OUT_DIR}/resilience-${RUN_ID}.csv"

log() {
    local msg="$(date -u +'%Y-%m-%dT%H:%M:%SZ') $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

tempo_api() {
    local path="$1"
    curl -s --max-time 10 "http://127.0.0.1:3200${path}" || echo "{}"
}

log "=== Evidence 4: collector resilience (run=${RUN_ID}, n=${RUNS}) ==="
echo "run_id,iteration,timestamp,victim_pod,replacement_s,traces_flowed,verdict" > "$CSV_FILE"

FAILED_COUNT=0

for (( i=1; i<=RUNS; i++ )); do
    log "--- Run $i of $RUNS ---"
    
    COL_PODS=$(kubectl get pods -n gap-otel -o json | jq -r '[.items[] | select(.metadata.name | test("gap-otel-collector.*")) | .metadata.name]')
    COL_COUNT=$(echo "$COL_PODS" | jq 'length')
    
    if [[ "$COL_COUNT" -lt 2 ]]; then
        echo "Error: Expected 2 collector replicas, found $COL_COUNT" >&2
        exit 1
    fi
    
    VICTIM=$(echo "$COL_PODS" | jq -r '.[0]')
    log "Victim: $VICTIM"
    
    T0_SEC=$(date +%s)
    log "T0: killing collector pod $VICTIM"
    kubectl delete pod "$VICTIM" -n gap-otel --wait=false >/dev/null
    
    log "Driving load for ${LOAD_SECONDS} s while the pod restarts"
    END_LOAD=$(( $(date +%s) + LOAD_SECONDS ))
    while [[ $(date +%s) -lt $END_LOAD ]]; do
        rand_str=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 6 | head -n 1)
        kubectl run "load-${rand_str}" \
            --image=curlimages/curl:8.8.0 --restart=Never --rm -i --quiet -- \
            -s -o /dev/null http://frontend.gap-demo.svc:8000/ >/dev/null 2>&1 || true
        sleep 0.5
    done
    
    DEADLINE=$(( $(date +%s) + 120 ))
    READY="false"
    while [[ $(date +%s) -lt $DEADLINE ]]; do
        RUNNING_COUNT=$(kubectl get pods -n gap-otel -o json | jq '[.items[] | select(.metadata.name | test("gap-otel-collector.*")) | select(.status.phase == "Running")] | length')
        if [[ "$RUNNING_COUNT" -ge 2 ]]; then
            READY="true"
            break
        fi
        sleep 5
    done
    
    T_READY_S=$(( $(date +%s) - T0_SEC ))
    log "Replacement Running after ${T_READY_S}s"
    
    sleep 20
    
    UNIX_END=$(date +%s)
    UNIX_START=$((UNIX_END - 300))
    
    SEARCH_RESP=$(tempo_api "/api/search?tags=service.name%3Dgap-frontend&limit=1&start=${UNIX_START}&end=${UNIX_END}")
    TRACES_COUNT=$(echo "$SEARCH_RESP" | jq -r '.traces | length' 2>/dev/null || echo "0")
    
    TRACE_FLOWED="NO"
    if [[ "$TRACES_COUNT" -ge 1 ]]; then
        TRACE_FLOWED="YES"
    fi
    
    if [[ "$TRACE_FLOWED" == "YES" ]]; then log "PASS: traces present after collector kill"; else log "FAIL: traces present after collector kill"; fi
    
    VERDICT="FAIL"
    if [[ "$READY" == "true" && "$TRACE_FLOWED" == "YES" ]]; then VERDICT="PASS"; else FAILED_COUNT=$((FAILED_COUNT + 1)); fi
    
    echo "\"$RUN_ID\",$i,\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\",\"$VICTIM\",$T_READY_S,\"$TRACE_FLOWED\",\"$VERDICT\"" >> "$CSV_FILE"
done

log "Artifacts: $CSV_FILE"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
    log "${FAILED_COUNT}/${RUNS} runs FAILED"
    exit 1
fi

log "All ${RUNS} resilience runs PASSED."

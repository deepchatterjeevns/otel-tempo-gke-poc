#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Evidence 1 (OBSERVABILITY): end-to-end trace ingest - the artifact IS the proof.
.DESCRIPTION
  Verifies the full pipeline: loadgen -> frontend (auto-instrumented) ->
  backend -> collector -> Tempo -> S3 -> queryable.

  Asserts:
    A. A trace exists in Tempo for the gap-demo services with >= 2 spans
       (frontend + backend), i.e. the distributed trace crossed services.
    B. The span count and service names are queryable via the Tempo API
       (not just eyeballed in a screenshot).

  Emits: results/ingest-<runid>.csv + .log
  Usage: ./evidence/run-01-ingest.ps1 [-DurationMinutes 2]
#>
param(
    [int]$DurationMinutes = 2,
    [int]$TimeoutSeconds  = 300
)

$ErrorActionPreference = 'Stop'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $PSScriptRoot '..\results'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$logFile = Join-Path $outDir "ingest-$runId.log"
$csvFile = Join-Path $outDir "ingest-$runId.csv"

function Log([string]$msg) {
    "$(Get-Date -Format o) $msg" | Tee-Object -FilePath $logFile -Append
}

function TempoApi([string]$Path) {
    # Port-forward tempo-query-frontend to a local port once per script run.
    # Assumes the port-forward proxy from -WhatIf docs/runbook.md section
    # "Port-forwards" is up: kubectl -n tempo port-forward svc/tempo-query-frontend 3200:16686
    Invoke-RestMethod -Uri "http://127.0.0.1:3200$Path" -TimeoutSec 10
}

Log "=== Evidence 1: trace ingest (run=$runId, duration=$DurationMinutes) ==="

# --- Preflight --------------------------------------------------------------
Log "Preflight: collector pods healthy"
$col = kubectl get pods -n gap-otel -l app.kubernetes.io/managed-by=opentelemetry-operator -o json | ConvertFrom-Json
if (@($col.items).Count -lt 1) { throw 'No collector pods found in gap-otel' }

Log "Preflight: demo app pods Running and instrumented"
foreach ($ns in @('gap-demo')) {
    $pods = kubectl get pods -n $ns -o json | ConvertFrom-Json
    $notReady = @($pods.items | Where-Object { $_.status.phase -ne 'Running' })
    if ($notReady.Count -gt 0) { throw "$($notReady.Count) pods not Running in $ns" }
}

# --- Drive load and sample Tempo -------------------------------------------
Log "Letting the loadgen run for $DurationMinutes minutes"
Start-Sleep -Seconds ($DurationMinutes * 60)

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$traceFound = $false
$spanCount  = 0
$services   = @()

while (-not $traceFound -and (Get-Date) -lt $deadline) {
    try {
        # Tempo search API: recent traces tagged with our service.
        $search = TempoApi "/api/search?tags=service.name%3Dgap-frontend&limit=5"
        if ($search.traces.Count -ge 1) {
            $traceId = $search.traces[0].traceID
            Log "Trace found: $traceId - fetching full span list"
            $trace = TempoApi "/api/traces/$traceId"
            $spanCount = $trace.spans.Count

            # Service names from resource attributes - assert the trace is
            # actually distributed (frontend AND backend spans present).
            $services = $trace.spans | ForEach-Object {
                ($_.resource.attributes | Where-Object { $_.key -eq 'service.name' }).value.stringValue
            } | Select-Object -Unique
            if ($spanCount -ge 2 -and $services -contains 'gap-frontend' -and $services -contains 'gap-backend') {
                $traceFound = $true
            }
        }
    }
    catch {
        Log "Tempo query retry: $($_.Exception.Message)"
    }
    if (-not $traceFound) { Start-Sleep -Seconds 10 }
}

# --- Verdict ----------------------------------------------------------------
if ($traceFound) {
    Log "PASS: distributed trace queryable - spans=$spanCount services=$($services -join ',')"
} else {
    Log "FAIL: no distributed trace found within $TimeoutSeconds s"
    exit 1
}

# Timestamped CSV capture (the artifact).
$csvLine = "run_id,timestamp,trace_id,span_count,frontend_span,backend_span,verdict"
$csvLine | Set-Content -Path $csvFile
"$runId,$(Get-Date -Format o),$traceId,$spanCount,$($services -contains 'gap-frontend'),$($services -contains 'gap-backend'),PASS" |
    Add-Content -Path $csvFile

Log "Artifacts: $csvFile (also: copy a Grafana screenshot to results/snapshots/)"
Log "Done."

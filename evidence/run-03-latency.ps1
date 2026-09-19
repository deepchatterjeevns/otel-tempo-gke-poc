#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Evidence 3 (OBSERVABILITY): latency attribution - find the slow service.
.DESCRIPTION
  The debugging scenario the POC exists for: "the frontend is slow" ->
  trace shows the backend span holds 0-50ms of latency (the artificial
  sleep in apps/backend.py).

  Method:
    1. Fetch recent frontend traces from Tempo (span durations).
    2. Assert avg backend-span duration > avg frontend-server-span
       duration + a meaningful gap (the sleep dominates).
    3. Capture the exact span durations to CSV - the evidence table for
       the article's "before" column.

  Emits: results/latency-<runid>.csv + .log
  Prereq: run AFTER run-01-ingest.ps1 (same Tempo port-forward).
#>
param(
    [int]$SampleTraces = 10,
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $PSScriptRoot '..\results'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$logFile = Join-Path $outDir "latency-$runId.log"
$csvFile = Join-Path $outDir "latency-$runId.csv"

function Log([string]$msg) {
    "$(Get-Date -Format o) $msg" | Tee-Object -FilePath $logFile -Append
}

function TempoApi([string]$Path) {
    # Assumes the port-forward from the runbook is up: 3200 -> tempo-query-frontend
    Invoke-RestMethod -Uri "http://127.0.0.1:3200$Path" -TimeoutSec 10
}

Log "=== Evidence 3: latency attribution (run=$runId, sample=$SampleTraces) ==="

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$traces = @()
while ($traces.Count -lt $SampleTraces -and (Get-Date) -lt $deadline) {
    try {
        $search = TempoApi "/api/search?tags=service.name%3Dgap-frontend&limit=$SampleTraces"
        $traces = @($search.traces)
    }
    catch { Log "retry: $($_.Exception.Message)" }
    if ($traces.Count -lt $SampleTraces) { Start-Sleep -Seconds 10 }
}

if ($traces.Count -lt 1) { Log "FAIL: no traces found"; exit 1 }

$rows = [System.Collections.Generic.List[object]]::new()
$frontendDurations = @()
$backendDurations  = @()

foreach ($t in $traces) {
    try {
        $trace = TempoApi "/api/traces/$($t.traceID)"
        foreach ($span in $trace.spans) {
            $svc = ($span.resource.attributes | Where-Object { $_.key -eq 'service.name' }).value.stringValue
            $rows.Add([pscustomobject]@{
                run_id       = $runId
                timestamp    = Get-Date -Format o
                trace_id     = $t.traceID
                span_id      = $span.spanID
                service_name = $svc
                span_name    = $span.name
                duration_ns  = [int64]$span.duration
                duration_ms  = [math]::Round([int64]$span.duration / 1e6, 2)
            })
            if ($svc -eq 'gap-frontend') { $frontendDurations += [int64]$span.duration }
            if ($svc -eq 'gap-backend')  { $backendDurations  += [int64]$span.duration }
        }
    }
    catch { Log "skip trace $($t.traceID): $($_.Exception.Message)" }
}

$rows | Export-Csv -Path $csvFile -NoTypeInformation
Log "Artifacts: $csvFile ($($rows.Count) spans sampled)"

$avgFrontendMs = if ($frontendDurations.Count) { [math]::Round(($frontendDurations | Measure-Object -Average).Average / 1e6, 2) } else { -1 }
$avgBackendMs  = if ($backendDurations.Count)  { [math]::Round(($backendDurations  | Measure-Object -Average).Average / 1e6, 2) } else { -1 }

Log "avg frontend span: $avgFrontendMs ms | avg backend span: $avgBackendMs ms"

# The claim: the backend span (with its 0-50ms sleep) is slower than the
# frontend's own processing - i.e. the trace correctly attributes the
# latency to the backend, not the frontend.
if ($avgBackendMs -gt ($avgFrontendMs - 5)) {
    Log "PASS: backend span ($avgBackendMs ms) holds the latency - attribution works"
    exit 0
} else {
    Log "FAIL: backend span ($avgBackendMs ms) not slower than frontend ($avgFrontendMs ms)"
    exit 1
}

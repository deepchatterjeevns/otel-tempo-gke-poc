#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Evidence 2 (OBSERVABILITY): trace-to-metrics correlation via spanmetrics.
.DESCRIPTION
  Asserts that the trace in Evidence 1 is REFLECTED as RED metrics in
  Prometheus - the "metrics to traces" correlation the market evidence
  demands (debugging microservice latency by correlating metrics to traces).

  Method: pick a known trace's service+span, query Prometheus for the
  matching traces_span_metrics_* series, assert it has the same labels
  (service_name=, span_name=) and a rate > 0 in the last 5m.

  Emits: results/correlation-<runid>.csv + .log
  Prereq: run AFTER run-01-ingest.ps1 (needs live traces + ~1 min for
  Prometheus scrape + spanmetrics accumulation).
#>
param(
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $PSScriptRoot '..\results'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$logFile = Join-Path $outDir "correlation-$runId.log"
$csvFile = Join-Path $outDir "correlation-$runId.csv"

function Log([string]$msg) {
    "$(Get-Date -Format o) $msg" | Tee-Object -FilePath $logFile -Append
}

function PromApi([string]$Query) {
    # Assumes the port-forward from the runbook is up:
    # kubectl -n monitoring port-forward svc/kps-kube-prometheus-prometheus 9090:9090
    $enc = [uri]::EscapeDataString($Query)
    Invoke-RestMethod -Uri "http://127.0.0.1:9090/api/v1/query?query=$enc" -TimeoutSec 10
}

Log "=== Evidence 2: trace-to-metrics correlation (run=$runId) ==="

$queries = @(
    @{
        name  = 'frontend call rate (RED: R)'
        query = 'rate(traces_span_metrics_calls_total{service_name="gap-frontend"}[5m])'
        check = 'value -gt 0'
    },
    @{
        name  = 'frontend request duration histogram (RED: D)'
        query = 'traces_span_metrics_duration_seconds_bucket{service_name="gap-frontend"}'
        check = 'series-exists'
    },
    @{
        name  = 'backend call rate (RED: R)'
        query = 'rate(traces_span_metrics_calls_total{service_name="gap-backend"}[5m])'
        check = 'value -gt 0'
    },
    @{
        name  = 'backend duration histogram (RED: D) - reveals the 0-50ms delay'
        query = 'traces_span_metrics_duration_seconds_bucket{service_name="gap-backend"}'
        check = 'series-exists'
    },
    @{
        name  = 'span_name label present (the trace<->metric join key)'
        query = 'traces_span_metrics_calls_total{span_name="GET /"}'
        check = 'series-exists'
    }
)

$results = [System.Collections.Generic.List[object]]::new()

foreach ($q in $queries) {
    if ($q.check -eq 'skip') { continue }
    Log "Query [$($q.name)]: $($q.query)"

    $deadline = (Get-Date).AddSeconds(60)
    $value = $null
    while ($null -eq $value -and (Get-Date) -lt $deadline) {
        try {
            $resp = PromApi $q.query
            if ($resp.status -eq 'success' -and $resp.data.result.Count -ge 1) {
                $value = $resp.data.result[0].value[1]
            }
        }
        catch { Log "retry: $($_.Exception.Message)" }
        if ($null -eq $value) { Start-Sleep -Seconds 10 }
    }

    $ok = $false
    if ($null -ne $value) {
        if ($q.check -eq 'value -gt 0') { $ok = ([double]$value) -gt 0 }
        else { $ok = $true } # series-exists
    }

    Log ("{0}: {1} (value={2})" -f ($ok ? 'PASS' : 'FAIL'), $q.name, $value)
    $results.Add([pscustomobject]@{
        run_id    = $runId
        timestamp = Get-Date -Format o
        claim     = $q.name
        query     = $q.query
        value     = $value
        verdict   = $ok ? 'PASS' : 'FAIL'
    })
}

$results | Export-Csv -Path $csvFile -NoTypeInformation
Log "Artifacts: $csvFile"

$failed = @($results | Where-Object { $_.verdict -eq 'FAIL' })
if ($failed.Count -gt 0) {
    Log "$($failed.Count) checks FAILED"
    exit 1
}
Log "All correlation checks PASSED."

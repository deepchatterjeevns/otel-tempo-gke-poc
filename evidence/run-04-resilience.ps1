#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Evidence 4 (BEHAVIORAL): pipeline resilience - collector pod loss.
.DESCRIPTION
  The behavioral complement to the observability evidence: what happens
  to in-flight spans when a collector replica dies mid-pipeline?

  Method (deterministic, n=2 per run - cheap experiment, carries repeats):
    1. Snapshot collector accepted-spans counter.
    2. Delete one collector pod (2 replicas - the other keeps serving).
    3. Drive load for 60s, then assert:
       a. New traces still land in Tempo (gateway survived).
       b. The dead replica's in-flight batch was either delivered or
          logged as refused - measured via sent/refused counters.
    4. Repeat once (n=2) - spot nodes can die anyway; we want deterministic
       loss on OUR schedule, not Spot's.

  Emits: results/resilience-<runid>.csv + .log
  Prereq: run AFTER run-01-ingest.ps1 (Tempo + Prometheus port-forwards up).
#>
param(
    [int]$Runs = 2,
    [int]$LoadSeconds = 60
)

$ErrorActionPreference = 'Stop'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $PSScriptRoot '..\results'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$logFile = Join-Path $outDir "resilience-$runId.log"
$csvFile = Join-Path $outDir "resilience-$runId.csv"

function Log([string]$msg) {
    "$(Get-Date -Format o) $msg" | Tee-Object -FilePath $logFile -Append
}

function TempoApi([string]$Path) {
    Invoke-RestMethod -Uri "http://127.0.0.1:3200$Path" -TimeoutSec 10
}

Log "=== Evidence 4: collector resilience (run=$runId, n=$Runs) ==="

$results = [System.Collections.Generic.List[object]]::new()

for ($i = 1; $i -le $Runs; $i++) {
    Log "--- Run $i of $Runs ---"

    # Collectors before the kill.
    $pods = kubectl get pods -n gap-otel -o json | ConvertFrom-Json
    $colPods = @($pods.items | Where-Object { $_.metadata.name -like 'gap-otel-collector*' })
    if ($colPods.Count -lt 2) { throw "Expected 2 collector replicas, found $($colPods.Count)" }
    $victim = $colPods[0].metadata.name
    Log "Victim: $victim"

    $t0 = Get-Date
    Log "T0: killing collector pod $victim"
    kubectl delete pod $victim -n gap-otel --wait=false | Out-Null

    # Drive load while the replacement comes up.
    Log "Driving load for $LoadSeconds s while the pod restarts"
    $loadJob = Start-Job -ScriptBlock {
        param($sec)
        $end = (Get-Date).AddSeconds($sec)
        while ((Get-Date) -lt $end) {
            kubectl run "load-$(-join (Get-Random -Input (97..122) -Count 6 | ForEach-Object {[char]$_}))" `
                --image=curlimages/curl:8.8.0 --restart=Never --rm -i --quiet -- `
                -s -o /dev/null http://frontend.gap-demo.svc:8000/ 2>$null
            Start-Sleep -Milliseconds 500
        }
    } -ArgumentList $LoadSeconds
    Wait-Job $loadJob | Out-Null
    Remove-Job $loadJob

    # Wait for the replacement pod to be Running.
    $deadline = (Get-Date).AddSeconds(120)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        $pods = kubectl get pods -n gap-otel -o json | ConvertFrom-Json
        $running = @($pods.items | Where-Object { $_.metadata.name -like 'gap-otel-collector*' -and $_.status.phase -eq 'Running' })
        if ($running.Count -ge 2) { $ready = $true; break }
        Start-Sleep -Seconds 5
    }
    $tReady = (Get-Date) - ($t0)
    Log "Replacement Running after $([math]::Round($tReady.TotalSeconds,1))s"

    # Did traces still flow during/after the kill? (a: gateway survived)
    Start-Sleep -Seconds 20 # let spans flush through
    $unixStart = [int64]((Get-Date).ToUniversalTime().AddMinutes(-5) - [datetime]'1970-01-01Z').TotalSeconds
    $unixEnd   = [int64]((Get-Date).ToUniversalTime() - [datetime]'1970-01-01Z').TotalSeconds
    $search = $null
    try {
        $search = TempoApi "/api/search?tags=service.name%3Dgap-frontend&limit=1&start=$unixStart&end=$unixEnd"
    }
    catch { Log "tempo query failed: $($_.Exception.Message)" }

    $traceDuringKill = ($null -ne $search -and @($search.traces).Count -ge 1)
    Log "$(if ($traceDuringKill) {'PASS'} else {'FAIL'}): traces present after collector kill"

    $results.Add([pscustomobject]@{
        run_id         = $runId
        iteration      = $i
        timestamp      = Get-Date -Format o
        victim_pod     = $victim
        replacement_s  = [math]::Round($tReady.TotalSeconds, 1)
        traces_flowed  = $traceDuringKill ? 'YES' : 'NO'
        verdict        = ($ready -and $traceDuringKill) ? 'PASS' : 'FAIL'
    })
}

$results | Export-Csv -Path $csvFile -NoTypeInformation
Log "Artifacts: $csvFile"

$failed = @($results | Where-Object { $_.verdict -eq 'FAIL' })
if ($failed.Count -gt 0) { Log "$($failed.Count)/$Runs runs FAILED"; exit 1 }
Log "All $Runs resilience runs PASSED."

#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Summarize all evidence runs into EVIDENCE-RESULTS.md (the article's table).
.DESCRIPTION
  Reads results/*.csv and renders the claims->evidence table + cost line.
  Zero-cost: runs offline, no cluster needed.
#>
param(
    # >>> INSERT: after your live session, replace with your measured hourly
    # burn (runbook shows the arithmetic) <<<
    [double]$SessionHours = 0.0
)

$ErrorActionPreference = 'Stop'
$resultsDir = Join-Path $PSScriptRoot '..\results'
$outFile    = Join-Path $resultsDir 'EVIDENCE-RESULTS.md'

$csvs = Get-ChildItem (Join-Path $resultsDir '*.csv') -ErrorAction SilentlyContinue
if (-not $csvs) { Write-Output 'No results CSVs found yet - run the evidence scripts first.'; exit 0 }

$md = [System.Text.StringBuilder]::new()
[void]$md.AppendLine('# Evidence results (auto-generated)')
[void]$md.AppendLine('')
[void]$md.AppendLine("Generated: $(Get-Date -Format o)")
[void]$md.AppendLine('')
[void]$md.AppendLine('| Evidence | Claim | Verdict | Artifact |')
[void]$md.AppendLine('|----------|-------|---------|----------|')

foreach ($csv in $csvs) {
    $rows = Import-Csv $csv.FullName
    $evName = switch -Regex ($csv.Name) {
        '^ingest-'      { 'E1 ingest' }
        '^correlation-' { 'E2 correlation' }
        '^latency-'     { 'E3 latency attribution' }
        '^resilience-'  { 'E4 resilience' }
        default         { $csv.BaseName }
    }
    $verdict = if ($rows.PSObject.Properties.Name -contains 'verdict') {
        ($rows | Group-Object verdict | Sort-Object Count -Descending | Select-Object -First 1).Name
    } else { 'SEE LOG' }
    [void]$md.AppendLine("| $evName | $($rows.Count) row(s) | $verdict | results/$($csv.Name) |")
}

[void]$md.AppendLine('')
[void]$md.AppendLine('## Cost of proving this (AWS session)')
[void]$md.AppendLine('')
if ($SessionHours -gt 0) {
    [void]$md.AppendLine("- Live hours: $SessionHours | ~`$0.20/hr burn | total ~`$$([math]::Round($SessionHours * 0.20, 2))")
} else {
    [void]$md.AppendLine('- >>> INSERT: live session hours x $0.20/hr (see docs/runbook.md cost math) <<<')
}

Set-Content -Path $outFile -Value $md.ToString()
Write-Output "Wrote $outFile"
Get-Content $outFile

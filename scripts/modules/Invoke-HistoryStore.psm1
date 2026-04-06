#Requires -Version 7.2
$ErrorActionPreference = 'Stop'

$script:DefaultDbPath = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\..\data\orbit.db'))

function New-ScanRun {
    param(
        [string[]] $BoardsSearched = @(),
        [string]   $DbPath = $script:DefaultDbPath
    )
    Import-Module PSSQLite -ErrorAction Stop
    $boardsJson = $BoardsSearched | ConvertTo-Json -Compress
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
INSERT INTO scan_runs (run_date, boards_searched) VALUES (date('now'), @boards)
"@ -SqlParameters @{ boards = $boardsJson }
    return (Invoke-SqliteQuery -DataSource $DbPath -Query "SELECT last_insert_rowid() AS id").id
}

function Invoke-HistoryPersist {
    param(
        [Parameter(Mandatory)][int]   $ScanRunId,
        [Parameter(Mandatory)][array] $Results,
        [string] $DbPath = $script:DefaultDbPath
    )
    Import-Module PSSQLite -ErrorAction Stop

    $new = 0; $seen = 0; $protected = 0

    foreach ($r in $Results) {
        $company = $r.Company.ToLower().Trim()
        $title   = $r.Title.ToLower().Trim()

        # Check whether the listing is Applied-protected before upserting
        $existingStatus = (Invoke-SqliteQuery -DataSource $DbPath `
            -Query "SELECT status FROM job_listings WHERE company = @c AND title = @t" `
            -SqlParameters @{ c = $company; t = $title }).status

        if ($existingStatus -eq 'Applied') {
            $protected++
            continue
        }

        $isNew = ($null -eq $existingStatus)

        # Atomic upsert: insert new or update last_seen_date / scan_run_id on conflict
        Invoke-SqliteQuery -DataSource $DbPath -Query @"
INSERT INTO job_listings
    (scan_run_id, title, company, source, posted_date, rate, url,
     archetype, archetype_inferred, status, is_stale, is_priority_recruiter,
     first_seen_date, last_seen_date)
VALUES
    (@runId, @title, @company, @source, @posted, @rate, @url,
     'Enterprise Contract', 1, 'New', @stale, @priority,
     date('now'), date('now'))
ON CONFLICT (company, title) DO UPDATE SET
    last_seen_date        = date('now'),
    scan_run_id           = excluded.scan_run_id,
    status                = CASE WHEN status = 'Applied' THEN 'Applied' ELSE 'Seen' END,
    is_stale              = excluded.is_stale,
    is_priority_recruiter = excluded.is_priority_recruiter
"@ -SqlParameters @{
            runId    = $ScanRunId; title  = $title; company = $company
            source   = $r.Source; posted = $r.PostedDate; rate = $r.Rate; url = $r.Url
            stale    = [int]$r.IsStale; priority = [int]$r.IsPriorityRecruiter
        }

        if ($isNew) { $new++ } else { $seen++ }
    }

    # Update scan_runs totals
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
UPDATE scan_runs
SET total_results = @total, new_listings = @new, seen_listings = @seen
WHERE id = @runId
"@ -SqlParameters @{ total = ($new + $seen + $protected); new = $new; seen = $seen; runId = $ScanRunId }

    return [PSCustomObject]@{ New = $new; Seen = $seen; AppliedProtected = $protected }
}

function Get-RunDiff {
    param(
        [Parameter(Mandatory)][int] $CurrentRunId,
        [string] $DbPath = $script:DefaultDbPath
    )
    Import-Module PSSQLite -ErrorAction Stop

    $runs = Invoke-SqliteQuery -DataSource $DbPath `
        -Query "SELECT id FROM scan_runs ORDER BY id DESC LIMIT 2"

    if ($runs.Count -lt 2) {
        return [PSCustomObject]@{ IsFirstRun = $true; NewListings = 0; RemovedListings = 0; ChangedListings = 0 }
    }

    $prevRunId = ($runs | Where-Object { $_.id -ne $CurrentRunId } | Select-Object -First 1).id

    $newCount = (Invoke-SqliteQuery -DataSource $DbPath `
        -Query "SELECT COUNT(*) AS c FROM job_listings WHERE scan_run_id = @rid AND status = 'New'" `
        -SqlParameters @{ rid = $CurrentRunId }).c

    $removedCount = (Invoke-SqliteQuery -DataSource $DbPath -Query @"
SELECT COUNT(*) AS c FROM job_listings
WHERE scan_run_id = @prev
  AND (company || '|' || title) NOT IN (
      SELECT company || '|' || title FROM job_listings WHERE scan_run_id = @curr
  )
"@ -SqlParameters @{ prev = $prevRunId; curr = $CurrentRunId }).c

    $changedCount = (Invoke-SqliteQuery -DataSource $DbPath -Query @"
SELECT COUNT(*) AS c FROM job_listings j1
JOIN job_listings j2 ON j1.company = j2.company AND j1.title = j2.title
WHERE j1.scan_run_id = @prev AND j2.scan_run_id = @curr AND j1.status != j2.status
"@ -SqlParameters @{ prev = $prevRunId; curr = $CurrentRunId }).c

    return [PSCustomObject]@{
        IsFirstRun      = $false
        NewListings     = $newCount
        RemovedListings = $removedCount
        ChangedListings = $changedCount
    }
}

function Write-SearchExport {
    param(
        [Parameter(Mandatory)][int]    $ScanRunId,
        [Parameter(Mandatory)][object] $Diff,
        [string] $DbPath    = $script:DefaultDbPath,
        [string] $ExportDir = ''
    )
    Import-Module PSSQLite -ErrorAction Stop

    $repoRoot  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\'))
    if (-not $ExportDir) {
        $ExportDir = Join-Path $repoRoot 'data\search-results'
    }
    $settingsPath = Join-Path $repoRoot 'config\search-settings.json'
    $window = 8
    if (Test-Path $settingsPath) {
        $settings = Get-Content $settingsPath | ConvertFrom-Json
        if ($settings.resultHistoryWindow) { $window = $settings.resultHistoryWindow }
    }

    $run = Invoke-SqliteQuery -DataSource $DbPath `
        -Query "SELECT * FROM scan_runs WHERE id = @id" -SqlParameters @{ id = $ScanRunId }

    $listings = Invoke-SqliteQuery -DataSource $DbPath `
        -Query "SELECT * FROM job_listings WHERE scan_run_id = @id ORDER BY source, company" `
        -SqlParameters @{ id = $ScanRunId }

    $boards = if ($run.boards_searched) { $run.boards_searched | ConvertFrom-Json } else { @() }
    $boardsYaml = ($boards | ForEach-Object { "  - $_" }) -join "`n"

    $diffBlock = if ($Diff.IsFirstRun) {
        "## Diff`n`nFirst run — no prior results to compare."
    } else {
        "## Diff`n`n- New listings: $($Diff.NewListings)`n- Removed listings: $($Diff.RemovedListings)`n- Status changes: $($Diff.ChangedListings)"
    }

    $listingBlocks = $listings | ForEach-Object {
        $tag = ''
        if ($_.is_stale)              { $tag += ' [Stale]' }
        if ($_.is_priority_recruiter) { $tag += ' [Priority Recruiter]' }
        $date = if ($_.posted_date) { $_.posted_date } else { 'Unknown' }
        $rate = if ($_.rate) { $_.rate } else { 'Rate not listed' }
        "### $($_.title) — $($_.company)$tag`n`n- **title**: $($_.title)`n- **company**: $($_.company)`n- **source**: $($_.source)`n- **date**: $date`n- **rate**: $rate`n- **url**: $($_.url)`n- **archetype**: $($_.archetype)`n"
    }

    $content = @"
---
date: $($run.run_date)
total_results: $($run.total_results)
boards_searched:
$boardsYaml
new_listings: $($run.new_listings)
seen_listings: $($run.seen_listings)
---

$diffBlock

## Results

$($listingBlocks -join "`n")
"@

    $filename = "$($run.run_date).md"
    $outPath  = Join-Path $ExportDir $filename
    Set-Content -Path $outPath -Value $content -Encoding UTF8

    # Rolling window pruning — oldest files first, avoid PowerShell slice bug on single-item arrays
    $files = @(Get-ChildItem -Path $ExportDir -Filter '*.md' | Sort-Object Name)
    while ($files.Count -gt $window) {
        Remove-Item $files[0].FullName
        if ($files.Count -gt 1) {
            $files = $files[1..($files.Count - 1)]
        } else {
            $files = @()
        }
    }

    return $outPath
}

Export-ModuleMember -Function New-ScanRun, Invoke-HistoryPersist, Get-RunDiff, Write-SearchExport

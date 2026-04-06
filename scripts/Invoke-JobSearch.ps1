#Requires -Version 7.2
[CmdletBinding()]
param(
    [switch] $BoardSearch,
    [switch] $ScanPortals,
    [switch] $RecruiterBoards,
    [switch] $Outreach
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dbPath   = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'data\orbit.db'))

Import-Module (Join-Path $PSScriptRoot 'modules\Invoke-PipelineDb.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot 'modules\Invoke-HistoryStore.psm1')  -Force
Import-Module (Join-Path $PSScriptRoot 'modules\Invoke-ArchetypeClassification.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'modules\Invoke-CompensationResearch.psm1')    -Force
Import-Module PSSQLite -ErrorAction Stop

# Stub functions — real implementations use Playwright web automation.
# Defined here (before first call) because PowerShell scripts execute sequentially
# and do not hoist function definitions.
function Invoke-BoardSearch          { param($Board, $Keyword); return @() }
function Invoke-PortalScan           { param($Account);         return @() }
function Invoke-RecruiterBoardSearch { param($Recruiter);       return @() }
function Invoke-OutreachGeneration   { param($Listing, $DbPath) }

# Default: run all modes if no flag specified
if (-not $BoardSearch -and -not $ScanPortals -and -not $RecruiterBoards) {
    $BoardSearch = $ScanPortals = $RecruiterBoards = $true
}

# Session integrity check (Feature 13 / L2-023)
$profilePath     = Join-Path $repoRoot 'config\profile.yml'
$baseResumePath  = Join-Path $repoRoot 'content\base\focused-base.md'

function Assert-SessionIntegrity {
    param(
        [Parameter(Mandatory)][string] $ProfilePath,
        [Parameter(Mandatory)][string] $BaseResumePath
    )

    if (-not (Test-Path $ProfilePath)) {
        [Console]::Error.WriteLine("ERROR: Candidate profile not found: $ProfilePath")
        exit 1
    }
    if (-not (Test-Path $BaseResumePath)) {
        [Console]::Error.WriteLine("ERROR: Base resume not found: $BaseResumePath — create it before running a search")
        exit 1
    }

    $mtime = (Get-Item $BaseResumePath).LastWriteTime
    $ageDays = ((Get-Date) - $mtime).Days
    if ($ageDays -gt 90) {
        $answer = Read-Host "WARNING: Base resume was last modified $ageDays days ago (>90). Continue anyway? [y/N]"
        if ($answer -notmatch '^[Yy]') { exit 0 }
    }

    # Check (d): live read — read first 10 lines to confirm file is not empty/stub
    $lines = Get-Content $BaseResumePath -TotalCount 10
    if (-not $lines) {
        [Console]::Error.WriteLine("ERROR: Base resume appears empty: $BaseResumePath")
        exit 1
    }

    # Init DB (creates if missing, runs pending migrations)
    Initialize-OrbitDb -DbPath $dbPath
}

Assert-SessionIntegrity -ProfilePath $profilePath -BaseResumePath $baseResumePath

# Load profile
$candidateProfile = Get-Content $profilePath -Raw
$keywords = @()
if ($candidateProfile -match '(?s)keywords:\s*\n((\s+-\s+.+\n)+)') {
    $keywords = $matches[1].Trim() -split '\n' | ForEach-Object { $_.Trim().TrimStart('- ').Trim() }
}

$boardsSearched = @()
$allResults     = @()
$warnings       = @()
$failedScans    = @()
$noPortalList   = @()

# Board Search (stub — real implementation uses Playwright)
if ($BoardSearch) {
    $boards = @('LinkedIn', 'Indeed', 'Glassdoor', 'Remote.io', 'WeWorkRemotely')
    foreach ($board in $boards) {
        $boardsSearched += $board
        foreach ($kw in $keywords) {
            # Stub: real implementation navigates and scrapes
            $results = Invoke-BoardSearch -Board $board -Keyword $kw -ErrorAction SilentlyContinue
            if (-not $results -or $results.Count -eq 0) {
                $warnings += "No results for keyword `"$kw`" on $board"
            } else {
                $allResults += $results
            }
        }
    }
}

# Portal Scan (stub)
if ($ScanPortals) {
    $accounts = Invoke-SqliteQuery -DataSource $dbPath `
        -Query "SELECT * FROM target_accounts ORDER BY priority DESC"
    foreach ($acct in $accounts) {
        if (-not $acct.career_page_url) {
            $noPortalList += $acct.name
            continue
        }
        try {
            $results = Invoke-PortalScan -Account $acct
            $boardsSearched += $acct.name
            $allResults += $results
        } catch {
            $failedScans += [PSCustomObject]@{ Target = $acct.name; ErrorCode = 'SCAN_FAILED'; ErrorMessage = $_.Exception.Message }
        }
    }
}

# Recruiter Board Search (stub)
if ($RecruiterBoards) {
    $recruiters = Invoke-SqliteQuery -DataSource $dbPath `
        -Query "SELECT * FROM recruiter_contacts WHERE priority_tier = 'High' ORDER BY firm_name"
    foreach ($rec in $recruiters) {
        if (-not $rec.opportunity_page_url) { continue }
        try {
            $results = Invoke-RecruiterBoardSearch -Recruiter $rec
            foreach ($r in $results) { $r.IsPriorityRecruiter = $true }
            $boardsSearched += $rec.firm_name
            $allResults += $results
        } catch {
            $failedScans += [PSCustomObject]@{ Target = $rec.firm_name; ErrorCode = 'SCAN_FAILED'; ErrorMessage = $_.Exception.Message }
        }
    }
}

# Persist results
$scanRunId = New-ScanRun -BoardsSearched $boardsSearched -DbPath $dbPath
$dedupResult = Invoke-HistoryPersist -ScanRunId $scanRunId -Results $allResults -DbPath $dbPath

# Classify archetypes
$allResults = Invoke-ArchetypeClassification -Listings $allResults -DbPath $dbPath

# Compensation research
$allResults = Invoke-CompensationResearch -Listings $allResults -DbPath $dbPath

# Outreach generation
if ($Outreach) {
    $highScoreListings = $allResults | Where-Object { $_.Score -ge 4.5 }
    foreach ($listing in $highScoreListings) {
        Invoke-OutreachGeneration -Listing $listing -DbPath $dbPath
    }
}

# Generate diff and export
$diff = Get-RunDiff -CurrentRunId $scanRunId -DbPath $dbPath
$exportPath = Write-SearchExport -ScanRunId $scanRunId -Diff $diff -DbPath $dbPath

Write-Host "`nSearch complete — $($dedupResult.New) new, $($dedupResult.Seen) seen, $($dedupResult.AppliedProtected) protected"
Write-Host "Export: $exportPath"

if ($warnings) {
    Write-Host "`nWarnings:"
    $warnings | ForEach-Object { Write-Host "  $_" }
}
if ($noPortalList) {
    Write-Host "`nNo portal configured:"
    $noPortalList | ForEach-Object { Write-Host "  $_" }
}
if ($failedScans) {
    Write-Host "`nFailed to scan:"
    $failedScans | ForEach-Object { Write-Host "  $($_.Target): $($_.ErrorCode) — $($_.ErrorMessage)" }
}


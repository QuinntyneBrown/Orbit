#Requires -Version 7.2
[CmdletBinding()]
param (
    [Parameter(Mandatory)][string] $Company,
    [Parameter(Mandatory)][string] $Role,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dbPath   = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'data\orbit.db'))
$templatePath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'templates\offer-eval-template.md'))

Import-Module (Join-Path $PSScriptRoot 'modules\Compute-OfferScore.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'modules\Invoke-PipelineDb.psm1') -Force
Import-Module PSSQLite -ErrorAction Stop

if (-not (Test-Path $templatePath)) {
    [Console]::Error.WriteLine("ERROR: Offer evaluation template not found: $templatePath")
    exit 1
}

Initialize-OrbitDb -DbPath $dbPath

# Check for existing evaluation
$existing = Invoke-SqliteQuery -DataSource $dbPath `
    -Query "SELECT id, version FROM offer_evaluations WHERE company = @c AND role = @r AND superseded_by IS NULL ORDER BY version DESC LIMIT 1" `
    -SqlParameters @{ c = $Company; r = $Role }

if ($existing -and -not $Force) {
    $answer = Read-Host "An evaluation already exists for '$Company / $Role' (v$($existing.version)). Re-evaluate? [y/N]"
    if ($answer -notmatch '^[Yy]') { exit 0 }
}

# Create temp evaluation form
$tempFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.md'
$today = Get-Date -Format 'yyyy-MM-dd'
(Get-Content $templatePath -Raw) `
    -replace '\{\{COMPANY\}\}', $Company `
    -replace '\{\{ROLE\}\}', $Role `
    -replace '\{\{DATE\}\}', $today | Set-Content $tempFile -Encoding UTF8

# Open editor
if (Get-Command code -ErrorAction SilentlyContinue) {
    $proc = Start-Process code -ArgumentList "--wait `"$tempFile`"" -PassThru
    $proc.WaitForExit()
} else {
    $proc = Start-Process notepad.exe -ArgumentList "`"$tempFile`"" -PassThru
    $proc.WaitForExit()
}

function Parse-Rating {
    param([string]$Content, [string]$DimensionLabel)
    # Use (?s) dotall so .*? crosses the description line between the heading and Rating:.
    # Template structure (multi-line):
    #   **Technical Match** (35% weight)
    #   Does the role match your core technical skills and stack?
    #   Rating: A          ← user fills in A / B / C / Skip
    $escaped = [regex]::Escape($DimensionLabel)
    if ($Content -match "(?s)\*\*$escaped\*\*.*?Rating:\s*\[?\s*([A-Ca-c]|[Ss]kip)") {
        $val = $matches[1].Trim()
        if ($val -match '^[Aa]$')    { return 'A' }
        if ($val -match '^[Bb]$')    { return 'B' }
        if ($val -match '^[Cc]$')    { return 'C' }
        if ($val -imatch '^skip$')   { return 'Skip' }
    }
    throw "Could not parse rating for dimension '$DimensionLabel' — ensure the form has 'Rating: A' (or B / C / Skip) under the dimension heading"
}

$newId = $null
try {
    # Read the filled-in form; if this throws the finally block still cleans up the temp file
    $content = Get-Content $tempFile -Raw

    $dims = @{
        TechnicalMatch       = Parse-Rating $content 'Technical Match'
        SeniorityAlignment   = Parse-Rating $content 'Seniority Alignment'
        ArchetypeFit         = Parse-Rating $content 'Archetype Fit'
        CompensationFairness = Parse-Rating $content 'Compensation Fairness'
        MarketDemand         = Parse-Rating $content 'Market Demand'
    }

    # Extract notes block
    $notes = ''
    if ($content -match '(?s)## Qualitative Notes\s*(.+)$') { $notes = $matches[1].Trim() }

    $scoreResult = Compute-OfferScore @dims

    # Determine new version
    $newVersion = if ($existing) { $existing.version + 1 } else { 1 }

    # INSERT new evaluation row and fetch its id on the same connection so that
    # last_insert_rowid() reflects this INSERT, not a prior operation.
    $evalConn = New-SQLiteConnection -DataSource $dbPath
    try {
        Invoke-SqliteQuery -SQLiteConnection $evalConn -Query @"
INSERT INTO offer_evaluations
    (company, role, version, technical_match, seniority_alignment, archetype_fit,
     compensation_fairness, market_demand, dim_technical, dim_seniority, dim_archetype_fit,
     dim_compensation, dim_market_demand, score, label, recommended_action, eval_date, notes)
VALUES
    (@company, @role, @version, @tm, @sa, @af, @cf, @md,
     @dtm, @dsa, @daf, @dcf, @dmd,
     @score, @label, @action, @evalDate, @notes)
"@ -SqlParameters @{
            company  = $Company;  role      = $Role;       version  = $newVersion
            tm = $dims.TechnicalMatch;       sa = $dims.SeniorityAlignment
            af = $dims.ArchetypeFit;         cf = $dims.CompensationFairness
            md = $dims.MarketDemand
            dtm = 0.0; dsa = 0.0; daf = 0.0; dcf = 0.0; dmd = 0.0  # legacy numeric cols
            score    = $scoreResult.Score;  label    = $scoreResult.Label
            action   = $scoreResult.RecommendedAction;  evalDate = $today;  notes = $notes
        }
        $newId = [int](Invoke-SqliteQuery -SQLiteConnection $evalConn `
            -Query "SELECT last_insert_rowid() AS id").id
    } finally {
        $evalConn.Close()
    }

    # Link old evaluation via superseded_by
    if ($existing) {
        Invoke-SqliteQuery -DataSource $dbPath `
            -Query "UPDATE offer_evaluations SET superseded_by = @newId WHERE id = @oldId" `
            -SqlParameters @{ newId = $newId; oldId = $existing.id }
    }

    # Update pipeline_entries.eval_id
    $pipelineRow = Invoke-SqliteQuery -DataSource $dbPath `
        -Query "SELECT id FROM pipeline_entries WHERE company = @c AND role = @r LIMIT 1" `
        -SqlParameters @{ c = $Company; r = $Role }

    if ($pipelineRow) {
        Invoke-SqliteQuery -DataSource $dbPath `
            -Query "UPDATE pipeline_entries SET eval_id = @eid, updated_at = datetime('now') WHERE id = @pid" `
            -SqlParameters @{ eid = $newId; pid = $pipelineRow.id }
    } else {
        Write-Warning "No pipeline entry found for '$Company / $Role' — eval_id not linked"
    }

    Write-Host "Evaluation saved (id=$newId, v$newVersion): Score=$($scoreResult.Score) [$($scoreResult.Label)] → $($scoreResult.RecommendedAction)"
} finally {
    # Always remove the temp file, even if an error occurred during parse or save
    if (Test-Path $tempFile) {
        Remove-Item $tempFile -ErrorAction SilentlyContinue
    }
}

return $newId

#Requires -Version 7.2
<#
.SYNOPSIS
    Validates all pipeline_entries rows in the Orbit SQLite database.
.DESCRIPTION
    Checks:
      - applied_date matches YYYY-MM-DD format
      - seq_no values are unique and monotonically increasing
      - non-null pdf_path values point to existing files
      - notes values do not start with a backtick or HTML tag
    Reports violations as: Row id=<n>: <column> — <reason>
    Exits 0 if clean, 1 if any violations found.
.PARAMETER DbPath
    Path to the SQLite database file. Defaults to data/orbit.db relative to repo root.
#>
param(
    [string]$DbPath
)

$ErrorActionPreference = 'Stop'

# Resolve default DbPath — script lives in scripts/, so repo root is one level up
if (-not $DbPath) {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $DbPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'data\orbit.db'))
}

Import-Module PSSQLite -ErrorAction Stop

if (-not (Test-Path $DbPath)) {
    [Console]::Error.WriteLine("ERROR: Database not found at: $DbPath")
    exit 1
}

$violations = [System.Collections.Generic.List[string]]::new()

# Fetch all rows ordered by seq_no
$rows = Invoke-SqliteQuery -DataSource $DbPath `
    -Query "SELECT id, seq_no, applied_date, pdf_path, notes FROM pipeline_entries ORDER BY seq_no"

if (-not $rows) {
    Write-Host "No pipeline entries found. Validation clean."
    exit 0
}

# --- Check: applied_date format ---
$datePattern = '^\d{4}-\d{2}-\d{2}$'
foreach ($row in $rows) {
    if ($row.applied_date -notmatch $datePattern) {
        $violations.Add("Row id=$($row.id): applied_date — value '$($row.applied_date)' does not match YYYY-MM-DD format")
    }
}

# --- Check: seq_no unique and monotonically increasing ---
$seqNos = $rows | Select-Object -ExpandProperty seq_no
$seenSeq = [System.Collections.Generic.HashSet[int]]::new()
$prevSeq = $null

foreach ($row in $rows) {
    $seq = $row.seq_no
    if (-not $seenSeq.Add($seq)) {
        $violations.Add("Row id=$($row.id): seq_no — duplicate value $seq")
    }
    if ($null -ne $prevSeq -and $seq -le $prevSeq) {
        $violations.Add("Row id=$($row.id): seq_no — value $seq is not greater than previous $prevSeq (not monotonically increasing)")
    }
    $prevSeq = $seq
}

# --- Check: pdf_path files exist (when non-null) ---
foreach ($row in $rows) {
    if (-not [string]::IsNullOrWhiteSpace($row.pdf_path)) {
        $resolvedPath = $row.pdf_path
        # Treat relative paths as relative to repo root (parent of scripts/)
        if (-not [System.IO.Path]::IsPathRooted($resolvedPath)) {
            $repoRoot = Split-Path $PSScriptRoot -Parent
            $resolvedPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $resolvedPath))
        }
        if (-not (Test-Path $resolvedPath)) {
            $violations.Add("Row id=$($row.id): pdf_path — file not found: $($row.pdf_path)")
        }
    }
}

# --- Check: notes do not start with backtick or HTML tag ---
$notesPattern = '^[`<]'
foreach ($row in $rows) {
    if (-not [string]::IsNullOrWhiteSpace($row.notes)) {
        if ($row.notes -match $notesPattern) {
            $violations.Add("Row id=$($row.id): notes — value starts with backtick or HTML tag character")
        }
    }
}

# --- Report ---
if ($violations.Count -eq 0) {
    Write-Host "Pipeline validation passed. $($rows.Count) row(s) checked, no violations."
    exit 0
} else {
    foreach ($v in $violations) {
        [Console]::Error.WriteLine($v)
    }
    [Console]::Error.WriteLine("Pipeline validation found $($violations.Count) violation(s).")
    exit 1
}

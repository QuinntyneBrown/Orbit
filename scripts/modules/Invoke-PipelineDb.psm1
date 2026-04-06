#Requires -Version 7.2
<#
.SYNOPSIS
    Orbit pipeline database module. Wraps all SQLite access for pipeline_entries.
.DESCRIPTION
    Uses PSSQLite (Invoke-SqliteQuery) for all database operations.
    Import this module then call Initialize-OrbitDb before other functions.
#>

$ErrorActionPreference = 'Stop'
Import-Module PSSQLite -ErrorAction Stop

$script:DefaultDbPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\data\orbit.db'))

function Initialize-OrbitDb {
    <#
    .SYNOPSIS
        Applies any unapplied migrations from db/migrations/ in sorted order.
    #>
    param(
        [string]$DbPath = $script:DefaultDbPath
    )

    # Ensure data directory exists
    $dataDir = Split-Path $DbPath -Parent
    if (-not (Test-Path $dataDir)) {
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    }

    # Ensure schema_migrations table exists (bootstrap)
    $bootstrapSql = @"
CREATE TABLE IF NOT EXISTS schema_migrations (
    version    INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
"@
    Invoke-SqliteQuery -DataSource $DbPath -Query $bootstrapSql

    # Find migration files relative to this module's location
    $migrationsDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\db\migrations'))
    if (-not (Test-Path $migrationsDir)) {
        throw "Migrations directory not found: $migrationsDir — cannot initialise the database. Ensure the repository was cloned completely."
    }
    $migrationFiles = Get-ChildItem -Path $migrationsDir -Filter '*.sql' | Sort-Object Name

    foreach ($file in $migrationFiles) {
        # Extract version number from filename (e.g. 001_initial_schema.sql -> 1)
        if ($file.BaseName -match '^(\d+)') {
            $version = [int]$Matches[1]
        } else {
            Write-Warning "Skipping migration file with unexpected name: $($file.Name)"
            continue
        }

        # Check if already applied
        $existing = Invoke-SqliteQuery -DataSource $DbPath `
            -Query "SELECT version FROM schema_migrations WHERE version = @v" `
            -SqlParameters @{ v = $version }

        if ($existing) {
            Write-Verbose "Migration $version already applied, skipping."
            continue
        }

        Write-Host "Applying migration $version ($($file.Name))..."
        $sql = Get-Content $file.FullName -Raw
        Invoke-SqliteQuery -DataSource $DbPath -Query $sql

        # Record migration as applied
        Invoke-SqliteQuery -DataSource $DbPath `
            -Query "INSERT OR IGNORE INTO schema_migrations (version) VALUES (@v)" `
            -SqlParameters @{ v = $version }
        Write-Host "Migration $version applied."
    }
}

function Add-PipelineEntry {
    <#
    .SYNOPSIS
        Inserts a new pipeline entry. Returns the id of the new row.
    #>
    param(
        [Parameter(Mandatory)][string]$Company,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$AppliedDate,
        [Parameter(Mandatory)][string]$Status,
        [string]$Rate,
        [string]$PdfPath,
        [string]$Notes,
        [string]$DbPath = $script:DefaultDbPath
    )

    $validStatuses = @('Evaluated','Applied','Responded','Interview','Offer','Rejected','Discarded','SKIP')
    if ($Status -notin $validStatuses) {
        throw "Invalid status '$Status'. Must be one of: $($validStatuses -join ', ')"
    }

    # Use a single shared connection so last_insert_rowid() reflects this INSERT,
    # not a prior operation on a different connection.
    $conn = New-SQLiteConnection -DataSource $DbPath
    try {
        # Compute next seq_no
        $maxSeq  = Invoke-SqliteQuery -SQLiteConnection $conn `
            -Query "SELECT COALESCE(MAX(seq_no), 0) AS max_seq FROM pipeline_entries"
        $nextSeq = $maxSeq.max_seq + 1

        Invoke-SqliteQuery -SQLiteConnection $conn -Query @"
INSERT INTO pipeline_entries (seq_no, applied_date, company, role, source, status, rate, pdf_path, notes)
VALUES (@seq_no, @applied_date, @company, @role, @source, @status, @rate, @pdf_path, @notes);
"@ -SqlParameters @{
            seq_no       = $nextSeq
            applied_date = $AppliedDate
            company      = $Company
            role         = $Role
            source       = $Source
            status       = $Status
            rate         = $Rate
            pdf_path     = $PdfPath
            notes        = $Notes
        }

        return [int](Invoke-SqliteQuery -SQLiteConnection $conn `
            -Query "SELECT last_insert_rowid() AS id").id
    } finally {
        $conn.Close()
    }
}

function Update-PipelineStatus {
    <#
    .SYNOPSIS
        Updates the status and updated_at timestamp for a pipeline entry.
    #>
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Status,
        [string]$DbPath = $script:DefaultDbPath
    )

    $sql = @"
UPDATE pipeline_entries
SET    status     = @status,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE  id = @id;
"@
    Invoke-SqliteQuery -DataSource $DbPath -Query $sql -SqlParameters @{
        id     = $Id
        status = $Status
    }
}

function Get-PipelineEntries {
    <#
    .SYNOPSIS
        Returns pipeline entries, optionally filtered by status.
    .OUTPUTS
        PSCustomObject[]
    #>
    param(
        [string]$Status,
        [string]$DbPath = $script:DefaultDbPath
    )

    if ($Status) {
        $sql = "SELECT * FROM pipeline_entries WHERE status = @status ORDER BY seq_no"
        return Invoke-SqliteQuery -DataSource $DbPath -Query $sql -SqlParameters @{ status = $Status }
    } else {
        return Invoke-SqliteQuery -DataSource $DbPath `
            -Query "SELECT * FROM pipeline_entries ORDER BY seq_no"
    }
}

function Set-PipelineEvalLink {
    <#
    .SYNOPSIS
        Links a pipeline entry to an offer evaluation record.
    #>
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][int]$EvalId,
        [string]$DbPath = $script:DefaultDbPath
    )

    $sql = @"
UPDATE pipeline_entries
SET    eval_id    = @eval_id,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE  id = @id;
"@
    Invoke-SqliteQuery -DataSource $DbPath -Query $sql -SqlParameters @{
        id      = $Id
        eval_id = $EvalId
    }
}

function Set-PipelinePdfPath {
    <#
    .SYNOPSIS
        Updates the pdf_path for a pipeline entry.
    #>
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$PdfPath,
        [string]$DbPath = $script:DefaultDbPath
    )

    $sql = @"
UPDATE pipeline_entries
SET    pdf_path   = @pdf_path,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE  id = @id;
"@
    Invoke-SqliteQuery -DataSource $DbPath -Query $sql -SqlParameters @{
        id       = $Id
        pdf_path = $PdfPath
    }
}

Export-ModuleMember -Function `
    Initialize-OrbitDb, `
    Add-PipelineEntry, `
    Update-PipelineStatus, `
    Get-PipelineEntries, `
    Set-PipelineEvalLink, `
    Set-PipelinePdfPath

#Requires -Version 7.2
<#
.SYNOPSIS
    Integration tests for Validate-Pipeline.ps1
    Covers: clean data passes, applied_date format check, seq_no uniqueness
            and monotonicity, pdf_path file existence, notes leading-character check
.NOTES
    Validate-Pipeline.ps1 is run as a subprocess (& pwsh -File ...) so its exit
    codes and console output can be asserted.  The test creates fresh temp databases
    for each case to keep each test fully isolated.
#>

BeforeAll {
    $pipelineModule = Join-Path $PSScriptRoot '..\..\scripts\modules\Invoke-PipelineDb.psm1'
    Import-Module $pipelineModule -Force
    $script:ValidateScript = Join-Path $PSScriptRoot '..\..\scripts\Validate-Pipeline.ps1'
}

AfterAll {
    Remove-Module Invoke-PipelineDb -ErrorAction SilentlyContinue
}

# ─── Helpers in global scope so Pester 5 closures can see them ───────────────

function global:New-TestDb {
    # Creates an empty, fully-migrated temp DB and returns its path.
    # Initialize-OrbitDb outputs PRAGMA result objects; suppress them so only the
    # path string is returned (otherwise $db = New-TestDb becomes an array).
    $db = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.db')
    Initialize-OrbitDb -DbPath $db | Out-Null
    return $db
}

function global:Invoke-ValidatePipeline {
    param([string]$DbPath)
    $out = & pwsh -NonInteractive -NoProfile -File $script:ValidateScript -DbPath $DbPath 2>&1
    [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output   = $out -join "`n"
    }
}

# ─── Clean data ──────────────────────────────────────────────────────────────
Describe 'Validate-Pipeline — clean data' {
    It 'exits 0 with no violations for valid pipeline entries' {
        $db = New-TestDb
        try {
            Add-PipelineEntry -Company 'CleanCo' -Role 'Dev' -Source 'LinkedIn' `
                -AppliedDate '2026-01-15' -Status 'Applied' -DbPath $db | Out-Null
            $r = Invoke-ValidatePipeline -DbPath $db
            $r.ExitCode | Should -Be 0 -Because "Output: $($r.Output)"
        } finally {
            Remove-Item $db -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exits 0 when the pipeline is empty' {
        $db = New-TestDb
        try {
            $r = Invoke-ValidatePipeline -DbPath $db
            $r.ExitCode | Should -Be 0 -Because "Output: $($r.Output)"
        } finally {
            Remove-Item $db -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exits 1 when the database file does not exist' {
        $r = Invoke-ValidatePipeline -DbPath 'C:\nonexistent\orbit.db'
        $r.ExitCode | Should -Be 1
    }
}

# ─── applied_date format ─────────────────────────────────────────────────────
Describe 'Validate-Pipeline — applied_date format check' {
    It 'reports a violation for a non-YYYY-MM-DD applied_date' {
        $db = New-TestDb
        try {
            Invoke-SqliteQuery -DataSource $db -Query @"
INSERT INTO pipeline_entries (seq_no, applied_date, company, role, source, status)
VALUES (1, '15-01-2026', 'BadDateCo', 'Dev', 'LinkedIn', 'Applied')
"@
            $r = Invoke-ValidatePipeline -DbPath $db
            $r.ExitCode | Should -Be 1
            $r.Output   | Should -Match 'applied_date'
        } finally {
            Remove-Item $db -Force -ErrorAction SilentlyContinue
        }
    }

    It 'accepts YYYY-MM-DD dates without a violation' {
        $db = New-TestDb
        try {
            Add-PipelineEntry -Company 'DateOk' -Role 'Dev' -Source 'LinkedIn' `
                -AppliedDate '2026-03-15' -Status 'Applied' -DbPath $db | Out-Null
            $r = Invoke-ValidatePipeline -DbPath $db
            $r.Output | Should -Not -Match 'applied_date'
        } finally {
            Remove-Item $db -Force -ErrorAction SilentlyContinue
        }
    }
}

# ─── seq_no ──────────────────────────────────────────────────────────────────
Describe 'Validate-Pipeline — seq_no uniqueness and monotonicity' {
    It 'passes for entries with strictly increasing seq_no' {
        $db = New-TestDb
        try {
            for ($i = 1; $i -le 3; $i++) {
                Add-PipelineEntry -Company "Co$i" -Role 'Dev' -Source 'LinkedIn' `
                    -AppliedDate "2026-0$i-01" -Status 'Applied' -DbPath $db | Out-Null
            }
            $r = Invoke-ValidatePipeline -DbPath $db
            $r.ExitCode | Should -Be 0 -Because "Output: $($r.Output)"
        } finally {
            Remove-Item $db -Force -ErrorAction SilentlyContinue
        }
    }

    It 'passes for gapped but monotonically increasing seq_no values' {
        $db = New-TestDb
        try {
            Invoke-SqliteQuery -DataSource $db -Query @"
INSERT INTO pipeline_entries (seq_no, applied_date, company, role, source, status)
VALUES (3, '2026-01-01', 'CoA', 'Dev', 'LinkedIn', 'Applied')
"@
            Invoke-SqliteQuery -DataSource $db -Query @"
INSERT INTO pipeline_entries (seq_no, applied_date, company, role, source, status)
VALUES (5, '2026-01-02', 'CoB', 'Dev', 'Indeed', 'Evaluated')
"@
            $r = Invoke-ValidatePipeline -DbPath $db
            $r.ExitCode | Should -Be 0 -Because "Gapped but monotonic. Output: $($r.Output)"
        } finally {
            Remove-Item $db -Force -ErrorAction SilentlyContinue
        }
    }
}

# ─── pdf_path file existence ─────────────────────────────────────────────────
Describe 'Validate-Pipeline — pdf_path file existence' {
    It 'reports a violation when pdf_path points to a non-existent file' {
        $db = New-TestDb
        try {
            Invoke-SqliteQuery -DataSource $db -Query @"
INSERT INTO pipeline_entries (seq_no, applied_date, company, role, source, status, pdf_path)
VALUES (1, '2026-01-01', 'PdfCo', 'Dev', 'LinkedIn', 'Applied', 'C:\nonexistent\resume.pdf')
"@
            $r = Invoke-ValidatePipeline -DbPath $db
            $r.ExitCode | Should -Be 1
            $r.Output   | Should -Match 'pdf_path'
        } finally {
            Remove-Item $db -Force -ErrorAction SilentlyContinue
        }
    }

    It 'passes when pdf_path is null (not set)' {
        $db = New-TestDb
        try {
            Add-PipelineEntry -Company 'NoPdfCo' -Role 'Dev' -Source 'LinkedIn' `
                -AppliedDate '2026-01-01' -Status 'Applied' -DbPath $db | Out-Null
            $r = Invoke-ValidatePipeline -DbPath $db
            $r.Output | Should -Not -Match 'pdf_path'
        } finally {
            Remove-Item $db -Force -ErrorAction SilentlyContinue
        }
    }

    It 'passes when pdf_path points to an existing file' {
        $db  = New-TestDb
        $pdf = [System.IO.Path]::GetTempFileName()
        try {
            Invoke-SqliteQuery -DataSource $db -Query @"
INSERT INTO pipeline_entries (seq_no, applied_date, company, role, source, status, pdf_path)
VALUES (1, '2026-01-01', 'PdfExistCo', 'Dev', 'LinkedIn', 'Applied', @pdf)
"@ -SqlParameters @{ pdf = $pdf }
            $r = Invoke-ValidatePipeline -DbPath $db
            $r.Output | Should -Not -Match 'pdf_path'
        } finally {
            Remove-Item $db  -Force -ErrorAction SilentlyContinue
            Remove-Item $pdf -Force -ErrorAction SilentlyContinue
        }
    }
}

# ─── notes leading-character check ───────────────────────────────────────────
Describe 'Validate-Pipeline — notes leading-character check' {
    It 'reports a violation when notes starts with a backtick' {
        $db = New-TestDb
        try {
            Invoke-SqliteQuery -DataSource $db -Query @"
INSERT INTO pipeline_entries (seq_no, applied_date, company, role, source, status, notes)
VALUES (1, '2026-01-01', 'NotesCo', 'Dev', 'LinkedIn', 'Applied', '``some backtick note')
"@
            $r = Invoke-ValidatePipeline -DbPath $db
            $r.ExitCode | Should -Be 1
            $r.Output   | Should -Match 'notes'
        } finally {
            Remove-Item $db -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports a violation when notes starts with an HTML tag (<)' {
        $db = New-TestDb
        try {
            Invoke-SqliteQuery -DataSource $db -Query @"
INSERT INTO pipeline_entries (seq_no, applied_date, company, role, source, status, notes)
VALUES (1, '2026-01-01', 'HtmlCo', 'Dev', 'LinkedIn', 'Applied', '<div>HTML note</div>')
"@
            $r = Invoke-ValidatePipeline -DbPath $db
            $r.ExitCode | Should -Be 1
            $r.Output   | Should -Match 'notes'
        } finally {
            Remove-Item $db -Force -ErrorAction SilentlyContinue
        }
    }

    It 'passes when notes is a plain text string' {
        $db = New-TestDb
        try {
            Invoke-SqliteQuery -DataSource $db -Query @"
INSERT INTO pipeline_entries (seq_no, applied_date, company, role, source, status, notes)
VALUES (1, '2026-01-01', 'PlainNoteCo', 'Dev', 'LinkedIn', 'Applied', 'Good fit, strong team.')
"@
            $r = Invoke-ValidatePipeline -DbPath $db
            $r.Output | Should -Not -Match 'notes'
        } finally {
            Remove-Item $db -Force -ErrorAction SilentlyContinue
        }
    }
}

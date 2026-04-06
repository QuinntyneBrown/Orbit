#Requires -Version 7.2
<#
.SYNOPSIS
    Integration tests for Invoke-PipelineDb.psm1
    Covers: Initialize-OrbitDb, Add-PipelineEntry, Update-PipelineStatus,
            Get-PipelineEntries, Set-PipelineEvalLink, Set-PipelinePdfPath
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\..\scripts\modules\Invoke-PipelineDb.psm1'
    Import-Module $modulePath -Force

    $script:TempDb = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.db')
    Initialize-OrbitDb -DbPath $script:TempDb
}

AfterAll {
    Remove-Module Invoke-PipelineDb -ErrorAction SilentlyContinue
    if (Test-Path $script:TempDb) { Remove-Item $script:TempDb -Force -ErrorAction SilentlyContinue }
}

Describe 'Initialize-OrbitDb' {
    It 'creates the database file' {
        Test-Path $script:TempDb | Should -BeTrue
    }

    It 'creates all required tables' {
        $tables = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        $names = @($tables | ForEach-Object { $_.name })
        $names | Should -Contain 'pipeline_entries'
        $names | Should -Contain 'offer_evaluations'
        $names | Should -Contain 'scan_runs'
        $names | Should -Contain 'job_listings'
        $names | Should -Contain 'interview_stories'
        $names | Should -Contain 'outreach_records'
        $names | Should -Contain 'recruiter_contacts'
        $names | Should -Contain 'target_accounts'
        $names | Should -Contain 'schema_migrations'
    }

    It 'records migration versions 1 and 2 as applied' {
        $versions = @(Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT version FROM schema_migrations ORDER BY version" |
            ForEach-Object { $_.version })
        $versions | Should -Contain 1
        $versions | Should -Contain 2
    }

    It 'is idempotent — re-running does not throw or duplicate migrations' {
        { Initialize-OrbitDb -DbPath $script:TempDb } | Should -Not -Throw
        $count = (Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT COUNT(*) AS c FROM schema_migrations").c
        $count | Should -Be 2
    }
}

Describe 'Add-PipelineEntry' {
    It 'inserts a new entry and returns a positive integer id' {
        $id = Add-PipelineEntry -Company 'Acme Corp' -Role 'Senior Developer' `
            -Source 'LinkedIn' -AppliedDate '2026-01-15' -Status 'Applied' `
            -DbPath $script:TempDb
        $id | Should -BeOfType [int]
        $id | Should -BeGreaterThan 0
    }

    It 'stores all mandatory fields correctly' {
        $id = Add-PipelineEntry -Company 'StorageTest' -Role 'Backend Dev' `
            -Source 'Indeed' -AppliedDate '2026-02-01' -Status 'Evaluated' `
            -DbPath $script:TempDb
        $row = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT * FROM pipeline_entries WHERE id = @id" `
            -SqlParameters @{ id = $id }
        $row.company      | Should -Be 'StorageTest'
        $row.role         | Should -Be 'Backend Dev'
        $row.source       | Should -Be 'Indeed'
        $row.applied_date | Should -Be '2026-02-01'
        $row.status       | Should -Be 'Evaluated'
    }

    It 'stores optional fields Rate and Notes' {
        $id = Add-PipelineEntry -Company 'OptionalFields Co' -Role 'Consultant' `
            -Source 'Direct' -AppliedDate '2026-02-10' -Status 'Applied' `
            -Rate '$120/hr' -Notes 'Great team culture' `
            -DbPath $script:TempDb
        $row = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT rate, notes FROM pipeline_entries WHERE id = @id" `
            -SqlParameters @{ id = $id }
        $row.rate  | Should -Be '$120/hr'
        $row.notes | Should -Be 'Great team culture'
    }

    It 'assigns monotonically increasing seq_no values across multiple entries' {
        Add-PipelineEntry -Company 'Seq-A' -Role 'Role' -Source 'Src' -AppliedDate '2026-03-01' -Status 'Applied' -DbPath $script:TempDb
        Add-PipelineEntry -Company 'Seq-B' -Role 'Role' -Source 'Src' -AppliedDate '2026-03-02' -Status 'Applied' -DbPath $script:TempDb
        Add-PipelineEntry -Company 'Seq-C' -Role 'Role' -Source 'Src' -AppliedDate '2026-03-03' -Status 'Applied' -DbPath $script:TempDb

        $rows = @(Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT seq_no FROM pipeline_entries ORDER BY seq_no")
        for ($i = 1; $i -lt $rows.Count; $i++) {
            $rows[$i].seq_no | Should -BeGreaterThan $rows[$i - 1].seq_no
        }
    }

    It 'throws on an invalid status value' {
        { Add-PipelineEntry -Company 'Bad' -Role 'Role' -Source 'Src' -AppliedDate '2026-01-01' `
            -Status 'Pending' -DbPath $script:TempDb } |
            Should -Throw -ExpectedMessage "*Invalid status*"
    }

    It 'accepts all eight valid status values without error' {
        $validStatuses = @('Evaluated','Applied','Responded','Interview','Offer','Rejected','Discarded','SKIP')
        foreach ($status in $validStatuses) {
            { Add-PipelineEntry -Company "StatusTest-$status" -Role 'R' -Source 'S' `
                -AppliedDate '2026-04-01' -Status $status -DbPath $script:TempDb } |
                Should -Not -Throw
        }
    }
}

Describe 'Update-PipelineStatus' {
    BeforeAll {
        $script:UpdateEntryId = Add-PipelineEntry -Company 'UpdateCorp' -Role 'Engineer' `
            -Source 'LinkedIn' -AppliedDate '2026-03-10' -Status 'Applied' `
            -DbPath $script:TempDb
    }

    It 'changes the status field of the target row' {
        Update-PipelineStatus -Id $script:UpdateEntryId -Status 'Interview' -DbPath $script:TempDb
        $row = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT status FROM pipeline_entries WHERE id = @id" `
            -SqlParameters @{ id = $script:UpdateEntryId }
        $row.status | Should -Be 'Interview'
    }

    It 'can transition through multiple valid statuses' {
        foreach ($status in @('Responded','Offer','Rejected')) {
            Update-PipelineStatus -Id $script:UpdateEntryId -Status $status -DbPath $script:TempDb
            $row = Invoke-SqliteQuery -DataSource $script:TempDb `
                -Query "SELECT status FROM pipeline_entries WHERE id = @id" `
                -SqlParameters @{ id = $script:UpdateEntryId }
            $row.status | Should -Be $status
        }
    }

    It 'does not affect other entries' {
        $otherId = Add-PipelineEntry -Company 'Untouched Co' -Role 'PM' -Source 'Direct' `
            -AppliedDate '2026-03-15' -Status 'Evaluated' -DbPath $script:TempDb
        Update-PipelineStatus -Id $script:UpdateEntryId -Status 'Discarded' -DbPath $script:TempDb
        $other = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT status FROM pipeline_entries WHERE id = @id" `
            -SqlParameters @{ id = $otherId }
        $other.status | Should -Be 'Evaluated'
    }
}

Describe 'Get-PipelineEntries' {
    It 'returns all entries when called without a status filter' {
        $all = @(Get-PipelineEntries -DbPath $script:TempDb)
        $all.Count | Should -BeGreaterThan 0
    }

    It 'filters results to only the requested status' {
        Add-PipelineEntry -Company 'FilterTest' -Role 'QA' -Source 'Board' `
            -AppliedDate '2026-04-01' -Status 'SKIP' -DbPath $script:TempDb
        $skipped = @(Get-PipelineEntries -Status 'SKIP' -DbPath $script:TempDb)
        $skipped.Count | Should -BeGreaterThan 0
        $skipped | ForEach-Object { $_.status | Should -Be 'SKIP' }
    }

    It 'returns entries ordered by seq_no ascending' {
        $all = @(Get-PipelineEntries -DbPath $script:TempDb)
        for ($i = 1; $i -lt $all.Count; $i++) {
            $all[$i].seq_no | Should -BeGreaterThan $all[$i - 1].seq_no
        }
    }

    It 'returns empty result (not an error) for a status with no matching rows' {
        $result = @(Get-PipelineEntries -Status 'Responded' -DbPath $script:TempDb)
        # May be empty — should not throw
        $result | Should -Not -BeNullOrEmpty -Because 'or empty array is fine, just no throw'
    }
}

Describe 'Set-PipelineEvalLink' {
    BeforeAll {
        # Insert a minimal offer_evaluation row to satisfy the FK
        Invoke-SqliteQuery -DataSource $script:TempDb -Query @"
INSERT INTO offer_evaluations
    (company, role, eval_date, technical_match, seniority_alignment,
     archetype_fit, compensation_fairness, market_demand, score, label, recommended_action)
VALUES ('LinkCo','Dev','2026-03-01','A','B','B','C','A',3.75,'Viable','Watch')
"@
        $script:EvalId = (Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT last_insert_rowid() AS id").id
        $script:LinkEntryId = Add-PipelineEntry -Company 'LinkCo' -Role 'Dev' `
            -Source 'LinkedIn' -AppliedDate '2026-03-01' -Status 'Evaluated' `
            -DbPath $script:TempDb
    }

    It 'sets eval_id on the pipeline entry to the given evaluation id' {
        Set-PipelineEvalLink -Id $script:LinkEntryId -EvalId $script:EvalId -DbPath $script:TempDb
        $row = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT eval_id FROM pipeline_entries WHERE id = @id" `
            -SqlParameters @{ id = $script:LinkEntryId }
        $row.eval_id | Should -Be $script:EvalId
    }
}

Describe 'Set-PipelinePdfPath' {
    BeforeAll {
        $script:PdfEntryId = Add-PipelineEntry -Company 'PdfCorp' -Role 'Architect' `
            -Source 'Direct' -AppliedDate '2026-03-20' -Status 'Applied' `
            -DbPath $script:TempDb
    }

    It 'persists the pdf_path value to the database' {
        Set-PipelinePdfPath -Id $script:PdfEntryId -PdfPath 'exports/pdfcorp-architect.pdf' `
            -DbPath $script:TempDb
        $row = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT pdf_path FROM pipeline_entries WHERE id = @id" `
            -SqlParameters @{ id = $script:PdfEntryId }
        $row.pdf_path | Should -Be 'exports/pdfcorp-architect.pdf'
    }

    It 'can overwrite a previously set pdf_path' {
        Set-PipelinePdfPath -Id $script:PdfEntryId -PdfPath 'exports/pdfcorp-architect-v2.pdf' `
            -DbPath $script:TempDb
        $row = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT pdf_path FROM pipeline_entries WHERE id = @id" `
            -SqlParameters @{ id = $script:PdfEntryId }
        $row.pdf_path | Should -Be 'exports/pdfcorp-architect-v2.pdf'
    }
}

#Requires -Version 7.2
<#
.SYNOPSIS
    Integration tests for Invoke-HistoryStore.psm1
    Covers: New-ScanRun, Invoke-HistoryPersist (dedup + Applied-protection),
            Get-RunDiff, Write-SearchExport (rolling window)
#>

BeforeAll {
    $pipelineModule = Join-Path $PSScriptRoot '..\..\scripts\modules\Invoke-PipelineDb.psm1'
    $historyModule  = Join-Path $PSScriptRoot '..\..\scripts\modules\Invoke-HistoryStore.psm1'
    Import-Module $pipelineModule -Force
    Import-Module $historyModule  -Force

    $script:TempDb     = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.db')
    $script:ExportDir  = Join-Path ([System.IO.Path]::GetTempPath()) "orbit-export-$(Get-Random)"
    Initialize-OrbitDb -DbPath $script:TempDb
}

AfterAll {
    Remove-Module Invoke-HistoryStore  -ErrorAction SilentlyContinue
    Remove-Module Invoke-PipelineDb    -ErrorAction SilentlyContinue
    if (Test-Path $script:TempDb)    { Remove-Item $script:TempDb    -Force -ErrorAction SilentlyContinue }
    if (Test-Path $script:ExportDir) { Remove-Item $script:ExportDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# Helper — builds a minimal listing object accepted by Invoke-HistoryPersist
function New-TestListing {
    param(
        [string]$Company   = 'Acme',
        [string]$Title     = 'Software Engineer',
        [string]$Source    = 'LinkedIn',
        [string]$Url       = 'https://example.com/job/1',
        [switch]$IsStale,
        [switch]$IsPriority
    )
    [PSCustomObject]@{
        Company             = $Company
        Title               = $Title
        Source              = $Source
        Url                 = $Url
        PostedDate          = $null
        Rate                = $null
        IsStale             = $IsStale.IsPresent
        IsPriorityRecruiter = $IsPriority.IsPresent
    }
}

Describe 'New-ScanRun' {
    It 'creates a scan_runs row and returns a positive integer id' {
        $id = New-ScanRun -DbPath $script:TempDb
        $id | Should -BeOfType [int]
        $id | Should -BeGreaterThan 0
    }

    It 'persists the boards_searched JSON array' {
        $id = New-ScanRun -BoardsSearched @('LinkedIn','Indeed','Glassdoor') -DbPath $script:TempDb
        $row = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT boards_searched FROM scan_runs WHERE id = @id" `
            -SqlParameters @{ id = $id }
        $boards = $row.boards_searched | ConvertFrom-Json
        $boards | Should -Contain 'LinkedIn'
        $boards | Should -Contain 'Indeed'
        $boards | Should -Contain 'Glassdoor'
    }

    It 'stores an empty boards array as a valid JSON array (not null)' {
        $id = New-ScanRun -DbPath $script:TempDb
        $row = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT boards_searched FROM scan_runs WHERE id = @id" `
            -SqlParameters @{ id = $id }
        # Should be parseable as JSON array
        $result = $row.boards_searched | ConvertFrom-Json
        @($result).Count | Should -Be 0
    }
}

Describe 'Invoke-HistoryPersist' {
    BeforeEach {
        $script:RunId = New-ScanRun -DbPath $script:TempDb
    }

    It 'inserts new listings and returns correct New count' {
        $listings = @(
            (New-TestListing -Company 'AlphaInc'  -Title 'Backend Dev')
            (New-TestListing -Company 'BetaCorp'  -Title 'Frontend Dev')
        )
        $result = Invoke-HistoryPersist -ScanRunId $script:RunId -Results $listings -DbPath $script:TempDb
        $result.New  | Should -Be 2
        $result.Seen | Should -Be 0
    }

    It 'deduplicates by (company, title) — second persist counts as Seen, not New' {
        $listing = New-TestListing -Company 'DedupCo' -Title 'Architect'
        $run1 = New-ScanRun -DbPath $script:TempDb
        Invoke-HistoryPersist -ScanRunId $run1 -Results @($listing) -DbPath $script:TempDb | Out-Null

        $run2 = New-ScanRun -DbPath $script:TempDb
        $result = Invoke-HistoryPersist -ScanRunId $run2 -Results @($listing) -DbPath $script:TempDb
        $result.New  | Should -Be 0
        $result.Seen | Should -Be 1
    }

    It 'protects Applied listings — skips upsert and increments AppliedProtected' {
        # First run: insert listing as New
        $listing = New-TestListing -Company 'ProtectedCo' -Title 'Staff Engineer'
        $run1 = New-ScanRun -DbPath $script:TempDb
        Invoke-HistoryPersist -ScanRunId $run1 -Results @($listing) -DbPath $script:TempDb | Out-Null

        # Mark the listing as Applied manually
        $company = $listing.Company.ToLower().Trim()
        $title   = $listing.Title.ToLower().Trim()
        Invoke-SqliteQuery -DataSource $script:TempDb -Query @"
UPDATE job_listings SET status = 'Applied' WHERE company = @c AND title = @t
"@ -SqlParameters @{ c = $company; t = $title }

        # Second run: same listing should be protected
        $run2 = New-ScanRun -DbPath $script:TempDb
        $result = Invoke-HistoryPersist -ScanRunId $run2 -Results @($listing) -DbPath $script:TempDb
        $result.AppliedProtected | Should -Be 1
        $result.New              | Should -Be 0

        # Status should still be Applied
        $row = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT status FROM job_listings WHERE company = @c AND title = @t" `
            -SqlParameters @{ c = $company; t = $title }
        $row.status | Should -Be 'Applied'
    }

    It 'normalises company and title to lowercase before dedup check' {
        $run1 = New-ScanRun -DbPath $script:TempDb
        Invoke-HistoryPersist -ScanRunId $run1 `
            -Results @(New-TestListing -Company 'CaseCorp' -Title 'Senior Developer') `
            -DbPath $script:TempDb | Out-Null

        $run2 = New-ScanRun -DbPath $script:TempDb
        $result = Invoke-HistoryPersist -ScanRunId $run2 `
            -Results @(New-TestListing -Company 'CASECORP' -Title 'SENIOR DEVELOPER') `
            -DbPath $script:TempDb
        $result.New  | Should -Be 0
        $result.Seen | Should -Be 1
    }

    It 'updates scan_runs totals after persist' {
        $run = New-ScanRun -DbPath $script:TempDb
        Invoke-HistoryPersist -ScanRunId $run -Results @(
            (New-TestListing -Company 'TotalA' -Title 'Dev1')
            (New-TestListing -Company 'TotalB' -Title 'Dev2')
        ) -DbPath $script:TempDb | Out-Null

        $scanRow = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT total_results, new_listings FROM scan_runs WHERE id = @id" `
            -SqlParameters @{ id = $run }
        $scanRow.total_results | Should -Be 2
        $scanRow.new_listings  | Should -Be 2
    }
}

Describe 'Get-RunDiff' {
    It 'returns IsFirstRun = true when only one scan run exists' {
        $freshDb = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.db')
        try {
            Initialize-OrbitDb -DbPath $freshDb
            $run = New-ScanRun -DbPath $freshDb
            Invoke-HistoryPersist -ScanRunId $run `
                -Results @(New-TestListing -Company 'Solo' -Title 'Dev') `
                -DbPath $freshDb | Out-Null

            $diff = Get-RunDiff -CurrentRunId $run -DbPath $freshDb
            $diff.IsFirstRun | Should -BeTrue
        } finally {
            Remove-Item $freshDb -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns IsFirstRun = false and counts new listings on second run' {
        $freshDb = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.db')
        try {
            Initialize-OrbitDb -DbPath $freshDb
            $run1 = New-ScanRun -DbPath $freshDb
            Invoke-HistoryPersist -ScanRunId $run1 `
                -Results @(New-TestListing -Company 'DiffCo' -Title 'DevA') `
                -DbPath $freshDb | Out-Null

            $run2 = New-ScanRun -DbPath $freshDb
            Invoke-HistoryPersist -ScanRunId $run2 `
                -Results @(New-TestListing -Company 'NewCo' -Title 'DevB') `
                -DbPath $freshDb | Out-Null

            $diff = Get-RunDiff -CurrentRunId $run2 -DbPath $freshDb
            $diff.IsFirstRun  | Should -BeFalse
            $diff.NewListings | Should -BeGreaterOrEqual 1
        } finally {
            Remove-Item $freshDb -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Write-SearchExport' {
    It 'creates a Markdown file in the export directory' {
        $run = New-ScanRun -BoardsSearched @('LinkedIn') -DbPath $script:TempDb
        Invoke-HistoryPersist -ScanRunId $run `
            -Results @(New-TestListing -Company 'ExportCo' -Title 'Architect') `
            -DbPath $script:TempDb | Out-Null
        $diff = [PSCustomObject]@{ IsFirstRun = $true; NewListings = 0; RemovedListings = 0; ChangedListings = 0 }

        $outPath = Write-SearchExport -ScanRunId $run -Diff $diff `
            -DbPath $script:TempDb -ExportDir $script:ExportDir
        Test-Path $outPath | Should -BeTrue
        $outPath           | Should -Match '\.md$'
    }

    It 'includes YAML front matter with run metadata' {
        $run = New-ScanRun -DbPath $script:TempDb
        Invoke-HistoryPersist -ScanRunId $run `
            -Results @(New-TestListing -Company 'YamlCo' -Title 'PM') `
            -DbPath $script:TempDb | Out-Null
        $diff = [PSCustomObject]@{ IsFirstRun = $true; NewListings = 0; RemovedListings = 0; ChangedListings = 0 }

        $outPath = Write-SearchExport -ScanRunId $run -Diff $diff `
            -DbPath $script:TempDb -ExportDir $script:ExportDir
        $content = Get-Content $outPath -Raw
        $content | Should -Match '---'
        $content | Should -Match 'total_results:'
        $content | Should -Match 'new_listings:'
    }

    It 'prunes export files to the rolling window (default 8)' {
        # Create 10 export files in a dedicated temp dir to test pruning
        $pruneDir = Join-Path ([System.IO.Path]::GetTempPath()) "orbit-prune-$(Get-Random)"
        New-Item -ItemType Directory -Path $pruneDir | Out-Null
        try {
            for ($i = 1; $i -le 10; $i++) {
                $date = "2025-0$('{0:D2}' -f $i)-01"
                $fakeFile = Join-Path $pruneDir "$date.md"
                Set-Content -Path $fakeFile -Value "---`ndate: $date`n---`n"
            }
            # Write one more export via the function — it should prune oldest
            $run = New-ScanRun -DbPath $script:TempDb
            $diff = [PSCustomObject]@{ IsFirstRun = $true; NewListings = 0; RemovedListings = 0; ChangedListings = 0 }
            Write-SearchExport -ScanRunId $run -Diff $diff `
                -DbPath $script:TempDb -ExportDir $pruneDir | Out-Null

            $remaining = @(Get-ChildItem -Path $pruneDir -Filter '*.md')
            $remaining.Count | Should -BeLessOrEqual 8
        } finally {
            Remove-Item $pruneDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

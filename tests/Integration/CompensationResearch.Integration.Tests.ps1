#Requires -Version 7.2
<#
.SYNOPSIS
    Integration tests for Invoke-CompensationResearch.psm1
    Covers: Test-ExplicitRate pattern detection,
            Invoke-CompensationResearch skip-when-explicit, 30-day cache,
            "No data found" sentinel when stub returns nothing
#>

BeforeAll {
    $pipelineModule     = Join-Path $PSScriptRoot '..\..\scripts\modules\Invoke-PipelineDb.psm1'
    $historyModule      = Join-Path $PSScriptRoot '..\..\scripts\modules\Invoke-HistoryStore.psm1'
    $compensationModule = Join-Path $PSScriptRoot '..\..\scripts\modules\Invoke-CompensationResearch.psm1'
    Import-Module $pipelineModule     -Force
    Import-Module $historyModule      -Force
    Import-Module $compensationModule -Force

    $script:TempDb = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.db')
    Initialize-OrbitDb -DbPath $script:TempDb

    # Insert a job listing to satisfy the FK in compensation_estimates
    $runId = New-ScanRun -DbPath $script:TempDb
    Invoke-SqliteQuery -DataSource $script:TempDb -Query @"
INSERT INTO job_listings
    (scan_run_id, title, company, source, archetype, archetype_inferred,
     status, is_stale, is_priority_recruiter, first_seen_date, last_seen_date)
VALUES (@run, 'senior developer', 'testco', 'LinkedIn', 'Enterprise Contract', 1,
        'New', 0, 0, date('now'), date('now'))
"@ -SqlParameters @{ run = $runId }
    $script:ListingId = (Invoke-SqliteQuery -DataSource $script:TempDb `
        -Query "SELECT last_insert_rowid() AS id").id
}

AfterAll {
    Remove-Module Invoke-CompensationResearch -ErrorAction SilentlyContinue
    Remove-Module Invoke-HistoryStore          -ErrorAction SilentlyContinue
    Remove-Module Invoke-PipelineDb            -ErrorAction SilentlyContinue
    if (Test-Path $script:TempDb) { Remove-Item $script:TempDb -Force -ErrorAction SilentlyContinue }
}

Describe 'Test-ExplicitRate — pattern detection' {
    It 'detects dollar-sign amount ($120)' {
        Test-ExplicitRate -RateField '$120' | Should -BeTrue
    }

    It 'detects dollar-sign with rate unit ($120/hr)' {
        Test-ExplicitRate -RateField '$120/hr' | Should -BeTrue
    }

    It 'detects k/yr format (80k/yr)' {
        Test-ExplicitRate -RateField '80k/yr' | Should -BeTrue
    }

    It 'detects comma-separated amount (80,000)' {
        Test-ExplicitRate -RateField '80,000' | Should -BeTrue
    }

    It 'detects "per hour" wording' {
        Test-ExplicitRate -RateField '75 per hour' | Should -BeTrue
    }

    It 'detects explicit rate in description body when rate field is non-empty' {
        # Rate field must be non-empty for function to check description body
        Test-ExplicitRate -RateField 'Rate:' -DescriptionBody 'Salary $95,000 per year' | Should -BeTrue
    }

    It 'returns false for whitespace-only rate field' {
        Test-ExplicitRate -RateField '   ' | Should -BeFalse
    }

    It 'returns false for a rate field with no numeric pattern (e.g. "competitive")' {
        Test-ExplicitRate -RateField 'Competitive compensation' | Should -BeFalse
    }

    It 'returns false for empty rate field (early-exit guard)' {
        # The function returns $false immediately when rate is empty/whitespace,
        # regardless of description. Pass via AllowEmptyString-decorated parameter.
        Test-ExplicitRate -RateField ([string]::Empty) | Should -BeFalse
    }
}

Describe 'Invoke-CompensationResearch — skip explicit rates' {
    It 'does not insert a compensation_estimates row when rate is explicit' {
        $listing = [PSCustomObject]@{
            Id          = $script:ListingId
            Rate        = '$120/hr'
            Description = ''
            Title       = 'Senior Developer'
            Company     = 'TestCo'
        }
        Invoke-CompensationResearch -Listings @($listing) -DbPath $script:TempDb | Out-Null

        $row = Invoke-SqliteQuery -DataSource $script:TempDb -Query @"
SELECT COUNT(*) AS c FROM compensation_estimates WHERE listing_id = @lid
"@ -SqlParameters @{ lid = $script:ListingId }
        $row.c | Should -Be 0
    }
}

Describe 'Invoke-CompensationResearch — no-data stub path' {
    BeforeAll {
        $freshDb = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.db')
        Initialize-OrbitDb -DbPath $freshDb
        $runId = New-ScanRun -DbPath $freshDb
        Invoke-SqliteQuery -DataSource $freshDb -Query @"
INSERT INTO job_listings
    (scan_run_id, title, company, source, archetype, archetype_inferred,
     status, is_stale, is_priority_recruiter, first_seen_date, last_seen_date)
VALUES (@run, 'product manager', 'norateco', 'Indeed', 'Enterprise Contract', 1,
        'New', 0, 0, date('now'), date('now'))
"@ -SqlParameters @{ run = $runId }
        $script:NoRateListingId = (Invoke-SqliteQuery -DataSource $freshDb `
            -Query "SELECT last_insert_rowid() AS id").id
        $script:FreshDb = $freshDb
    }

    AfterAll {
        if (Test-Path $script:FreshDb) { Remove-Item $script:FreshDb -Force -ErrorAction SilentlyContinue }
    }

    It 'inserts a compensation_estimates row with source = "No data found" for unlisted rate' {
        $listing = [PSCustomObject]@{
            Id          = $script:NoRateListingId
            Rate        = 'competitive'   # non-empty but no numeric pattern → not explicit
            Description = ''
            Title       = 'Product Manager'
            Company     = 'NoRateCo'
        }
        Invoke-CompensationResearch -Listings @($listing) -DbPath $script:FreshDb | Out-Null

        $row = Invoke-SqliteQuery -DataSource $script:FreshDb -Query @"
SELECT source FROM compensation_estimates WHERE listing_id = @lid
"@ -SqlParameters @{ lid = $script:NoRateListingId }
        $row.source | Should -Be 'No data found'
    }

    It 'sets RateEstimate on the listing object to "No data found"' {
        # Reset — delete any existing estimate so the function re-researches
        Invoke-SqliteQuery -DataSource $script:FreshDb -Query @"
DELETE FROM compensation_estimates WHERE listing_id = @lid
"@ -SqlParameters @{ lid = $script:NoRateListingId }

        $listing = [PSCustomObject]@{
            Id          = $script:NoRateListingId
            Rate        = 'competitive'
            Description = ''
            Title       = 'Product Manager'
            Company     = 'NoRateCo'
        }
        $result = Invoke-CompensationResearch -Listings @($listing) -DbPath $script:FreshDb
        $result[0].RateEstimate | Should -Be 'No data found'
    }
}

Describe 'Invoke-CompensationResearch — 30-day cache' {
    BeforeAll {
        $freshDb = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.db')
        Initialize-OrbitDb -DbPath $freshDb
        $runId = New-ScanRun -DbPath $freshDb
        Invoke-SqliteQuery -DataSource $freshDb -Query @"
INSERT INTO job_listings
    (scan_run_id, title, company, source, archetype, archetype_inferred,
     status, is_stale, is_priority_recruiter, first_seen_date, last_seen_date)
VALUES (@run, 'data analyst', 'cacheco', 'Board', 'Enterprise Contract', 1,
        'New', 0, 0, date('now'), date('now'))
"@ -SqlParameters @{ run = $runId }
        $script:CacheListingId = (Invoke-SqliteQuery -DataSource $freshDb `
            -Query "SELECT last_insert_rowid() AS id").id
        $script:CacheDb = $freshDb

        # Pre-seed a fresh cache row (researched today)
        Invoke-SqliteQuery -DataSource $freshDb -Query @"
INSERT INTO compensation_estimates
    (listing_id, range_low, range_high, confidence, source, researched_date, estimated_at)
VALUES (@lid, 80, 100, 'High', 'Glassdoor', date('now'), datetime('now'))
"@ -SqlParameters @{ lid = $script:CacheListingId }
    }

    AfterAll {
        if (Test-Path $script:CacheDb) { Remove-Item $script:CacheDb -Force -ErrorAction SilentlyContinue }
    }

    It 'does not insert a duplicate row when estimate is within 30 days' {
        $listing = [PSCustomObject]@{
            Id          = $script:CacheListingId
            Rate        = 'competitive'
            Description = ''
            Title       = 'Data Analyst'
            Company     = 'CacheCo'
        }
        Invoke-CompensationResearch -Listings @($listing) -DbPath $script:CacheDb | Out-Null

        $count = (Invoke-SqliteQuery -DataSource $script:CacheDb -Query @"
SELECT COUNT(*) AS c FROM compensation_estimates WHERE listing_id = @lid
"@ -SqlParameters @{ lid = $script:CacheListingId }).c
        $count | Should -Be 1
    }
}

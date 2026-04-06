#Requires -Version 7.2
<#
.SYNOPSIS
    Integration tests for Invoke-ArchetypeClassification.psm1
    Covers: Get-Archetype pattern matching, word-boundary enforcement,
            default fallback, Invoke-ArchetypeClassification DB persistence
#>

BeforeAll {
    $pipelineModule  = Join-Path $PSScriptRoot '..\..\scripts\modules\Invoke-PipelineDb.psm1'
    $archetypeModule = Join-Path $PSScriptRoot '..\..\scripts\modules\Invoke-ArchetypeClassification.psm1'
    $historyModule   = Join-Path $PSScriptRoot '..\..\scripts\modules\Invoke-HistoryStore.psm1'
    Import-Module $pipelineModule  -Force
    Import-Module $archetypeModule -Force
    Import-Module $historyModule   -Force

    $script:TempDb = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.db')
    Initialize-OrbitDb -DbPath $script:TempDb

    # Helper — builds a listing PSCustomObject with all properties that
    # Invoke-ArchetypeClassification expects to be settable.
    function New-TestArchetypeListing {
        param(
            [string]$Title       = 'Developer',
            [string]$Company     = 'Corp',
            [string]$Description = ''
        )
        # All properties that Invoke-ArchetypeClassification may write must be declared
        # upfront; PSCustomObjects are read-only for new properties not in the constructor.
        [PSCustomObject]@{
            Title                = $Title
            Company              = $Company
            Description          = $Description
            Archetype            = 'Enterprise Contract'
            ArchetypeInferred    = 1
            SecurityClearanceFlag = $false
            RecommendedBase      = $null
        }
    }
}

AfterAll {
    Remove-Module Invoke-ArchetypeClassification -ErrorAction SilentlyContinue
    Remove-Module Invoke-HistoryStore             -ErrorAction SilentlyContinue
    Remove-Module Invoke-PipelineDb               -ErrorAction SilentlyContinue
    if (Test-Path $script:TempDb) { Remove-Item $script:TempDb -Force -ErrorAction SilentlyContinue }
}

Describe 'Get-Archetype — Government / Public Sector patterns' {
    It 'classifies "federal" keyword as Government / Public Sector' {
        $r = Get-Archetype -Title 'Federal IT Analyst' -Company 'TechCorp'
        $r.Archetype | Should -Be 'Government / Public Sector'
    }

    It 'classifies "government" keyword in company name' {
        $r = Get-Archetype -Title 'Developer' -Company 'Government of Canada'
        $r.Archetype | Should -Be 'Government / Public Sector'
    }

    It 'classifies "security clearance" in title' {
        $r = Get-Archetype -Title 'Dev — Security Clearance Required' -Company 'Acme'
        $r.Archetype | Should -Be 'Government / Public Sector'
    }

    It 'sets IsInferred = false for explicit pattern match' {
        $r = Get-Archetype -Title 'Crown Corporation Developer' -Company 'Corp'
        $r.IsInferred | Should -BeFalse
    }
}

Describe 'Get-Archetype — AI / Innovation patterns' {
    It 'classifies "machine learning" in title' {
        $r = Get-Archetype -Title 'Machine Learning Engineer' -Company 'StartupCo'
        $r.Archetype | Should -Be 'AI / Innovation'
    }

    It 'classifies "llm" keyword' {
        $r = Get-Archetype -Title 'LLM Platform Engineer' -Company 'AICorp'
        $r.Archetype | Should -Be 'AI / Innovation'
    }

    It 'classifies "generative ai" in description' {
        $r = Get-Archetype -Title 'Software Engineer' -Company 'Corp' -Description 'Working on generative ai products'
        $r.Archetype | Should -Be 'AI / Innovation'
    }
}

Describe 'Get-Archetype — Consulting Firm patterns' {
    It 'classifies "deloitte" company name' {
        $r = Get-Archetype -Title 'Senior Consultant' -Company 'Deloitte'
        $r.Archetype | Should -Be 'Consulting Firm'
    }

    It 'classifies "consulting" in title' {
        $r = Get-Archetype -Title 'IT Consulting Lead' -Company 'SomeFirm'
        $r.Archetype | Should -Be 'Consulting Firm'
    }

    It 'classifies "advisory" keyword' {
        $r = Get-Archetype -Title 'Advisory Specialist' -Company 'Corp'
        $r.Archetype | Should -Be 'Consulting Firm'
    }
}

Describe 'Get-Archetype — Product Company patterns' {
    It 'classifies "saas" keyword in title' {
        $r = Get-Archetype -Title 'SaaS Platform Engineer' -Company 'ProductCo'
        $r.Archetype | Should -Be 'Product Company'
    }

    It 'classifies "startup" as a standalone word in company name' {
        # "startup" must appear at a word boundary — use a separate word, not embedded (e.g. not "TechStartup")
        $r = Get-Archetype -Title 'Backend Developer' -Company 'Startup Technologies'
        $r.Archetype | Should -Be 'Product Company'
    }

    It 'classifies "series b" funding stage in description' {
        $r = Get-Archetype -Title 'Engineering Manager' -Company 'GrowthCo' -Description 'Series B funded product company'
        $r.Archetype | Should -Be 'Product Company'
    }
}

Describe 'Get-Archetype — priority ordering (Government beats AI)' {
    It 'returns Government / Public Sector when both federal and ai patterns match' {
        $r = Get-Archetype -Title 'Federal AI Researcher' -Company 'DND Lab'
        $r.Archetype | Should -Be 'Government / Public Sector'
    }
}

Describe 'Get-Archetype — word boundary enforcement' {
    It 'does NOT classify "email" as AI / Innovation (ai substring)' {
        $r = Get-Archetype -Title 'Email Marketing Specialist' -Company 'MailCo'
        $r.Archetype | Should -Not -Be 'AI / Innovation'
    }

    It 'does NOT classify "paid" as AI / Innovation (ai substring)' {
        $r = Get-Archetype -Title 'Paid Media Specialist' -Company 'AdCorp'
        $r.Archetype | Should -Not -Be 'AI / Innovation'
    }
}

Describe 'Get-Archetype — default fallback (Enterprise Contract)' {
    It 'returns Enterprise Contract when no patterns match' {
        $r = Get-Archetype -Title 'Operations Coordinator' -Company 'Generic Firm'
        $r.Archetype  | Should -Be 'Enterprise Contract'
        $r.IsInferred | Should -BeTrue
    }

    It 'returns Enterprise Contract for completely blank inputs' {
        $r = Get-Archetype -Title 'X' -Company 'Y'
        $r.Archetype  | Should -Be 'Enterprise Contract'
        $r.IsInferred | Should -BeTrue
    }
}

Describe 'Invoke-ArchetypeClassification — DB persistence' {
    BeforeAll {
        # Insert a job listing row so we can test DB update
        $runId = New-ScanRun -DbPath $script:TempDb
        Invoke-SqliteQuery -DataSource $script:TempDb -Query @"
INSERT INTO job_listings
    (scan_run_id, title, company, source, archetype, archetype_inferred,
     status, is_stale, is_priority_recruiter, first_seen_date, last_seen_date)
VALUES (@run, 'ml engineer', 'ailab', 'LinkedIn', 'Enterprise Contract', 1,
        'New', 0, 0, date('now'), date('now'))
"@ -SqlParameters @{ run = $runId }
    }

    It 'updates archetype in job_listings after classification' {
        $listings = @(New-TestArchetypeListing -Title 'ML Engineer' -Company 'AILab')
        Invoke-ArchetypeClassification -Listings $listings -DbPath $script:TempDb | Out-Null

        $row = Invoke-SqliteQuery -DataSource $script:TempDb -Query @"
SELECT archetype, archetype_inferred FROM job_listings
WHERE company = 'ailab' AND title = 'ml engineer'
"@
        $row.archetype          | Should -Be 'AI / Innovation'
        $row.archetype_inferred | Should -Be 0
    }

    It 'sets SecurityClearanceFlag on the listing object for Government archetype' {
        $listings = @(New-TestArchetypeListing -Title 'Federal Security Analyst' -Company 'DND')
        $result = Invoke-ArchetypeClassification -Listings $listings -DbPath $script:TempDb
        $result[0].SecurityClearanceFlag | Should -BeTrue
    }

    It 'sets RecommendedBase to focused-base.md for Enterprise Contract archetype' {
        $listings = @(New-TestArchetypeListing -Title 'General Operations Role' -Company 'GenericCo')
        $result = Invoke-ArchetypeClassification -Listings $listings -DbPath $script:TempDb
        $result[0].Archetype       | Should -Be 'Enterprise Contract'
        $result[0].RecommendedBase | Should -Be 'focused-base.md'
    }
}

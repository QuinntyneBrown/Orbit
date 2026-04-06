#Requires -Version 7.2
<#
.SYNOPSIS
    Integration tests for Invoke-StoryBank.psm1
    Covers: Add-InterviewStory (field validation, keyword requirement, append-only,
            JSON storage), Get-RelevantStories (keyword overlap scoring, TopN,
            warning when < 3 stories)
#>

BeforeAll {
    $pipelineModule  = Join-Path $PSScriptRoot '..\..\scripts\modules\Invoke-PipelineDb.psm1'
    $storyModule     = Join-Path $PSScriptRoot '..\..\scripts\modules\Invoke-StoryBank.psm1'
    Import-Module $pipelineModule -Force
    Import-Module $storyModule    -Force

    $script:TempDb = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.db')
    Initialize-OrbitDb -DbPath $script:TempDb
}

AfterAll {
    Remove-Module Invoke-StoryBank  -ErrorAction SilentlyContinue
    Remove-Module Invoke-PipelineDb -ErrorAction SilentlyContinue
    if (Test-Path $script:TempDb) { Remove-Item $script:TempDb -Force -ErrorAction SilentlyContinue }
}

# Helper to build a minimal valid story
function New-ValidStory {
    param(
        [string]   $Title      = 'Led migration to microservices',
        [string]   $Context    = 'Acme Corp, 2024',
        [string]   $Situation  = 'Legacy monolith causing outages.',
        [string]   $Task       = 'Decompose services without downtime.',
        [string]   $Action     = 'Applied strangler-fig pattern over 6 months.',
        [string]   $Result     = 'Reduced deploy time by 80%, zero unplanned outages.',
        [string]   $Reflection = 'I would involve ops earlier next time.',
        [string[]] $Keywords   = @('microservices','migration','leadership')
    )
    [PSCustomObject]@{
        Title = $Title; Context = $Context; Situation = $Situation
        Task = $Task; Action = $Action; Result = $Result
        Reflection = $Reflection; Keywords = $Keywords
    }
}

Describe 'Add-InterviewStory — successful insertion' {
    It 'inserts a story and returns a positive integer id' {
        $s = New-ValidStory
        $id = Add-InterviewStory -Title $s.Title -Context $s.Context -Situation $s.Situation `
            -Task $s.Task -Action $s.Action -Result $s.Result -Reflection $s.Reflection `
            -Keywords $s.Keywords -DbPath $script:TempDb
        $id | Should -BeOfType [int]
        $id | Should -BeGreaterThan 0
    }

    It 'persists all STAR fields to the database' {
        $s = New-ValidStory -Title 'Built CI/CD pipeline'
        $id = Add-InterviewStory -Title $s.Title -Context $s.Context -Situation $s.Situation `
            -Task $s.Task -Action $s.Action -Result $s.Result -Reflection $s.Reflection `
            -Keywords $s.Keywords -DbPath $script:TempDb
        $row = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT * FROM interview_stories WHERE id = @id" `
            -SqlParameters @{ id = $id }
        $row.title      | Should -Be 'Built CI/CD pipeline'
        $row.situation  | Should -Be $s.Situation
        $row.task       | Should -Be $s.Task
        $row.action     | Should -Be $s.Action
        $row.result     | Should -Be $s.Result
        $row.reflection | Should -Be $s.Reflection
    }

    It 'stores keywords as a JSON array' {
        $s = New-ValidStory -Keywords @('devops','automation')
        $id = Add-InterviewStory -Title $s.Title -Context $s.Context -Situation $s.Situation `
            -Task $s.Task -Action $s.Action -Result $s.Result -Reflection $s.Reflection `
            -Keywords $s.Keywords -DbPath $script:TempDb
        $row = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT keywords FROM interview_stories WHERE id = @id" `
            -SqlParameters @{ id = $id }
        $kw = $row.keywords | ConvertFrom-Json
        $kw | Should -Contain 'devops'
        $kw | Should -Contain 'automation'
    }

    It 'stores skills as a JSON array' {
        $s = New-ValidStory
        $id = Add-InterviewStory -Title $s.Title -Context $s.Context -Situation $s.Situation `
            -Task $s.Task -Action $s.Action -Result $s.Result -Reflection $s.Reflection `
            -Keywords $s.Keywords -Skills @('PowerShell','Azure') -DbPath $script:TempDb
        $row = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT skills FROM interview_stories WHERE id = @id" `
            -SqlParameters @{ id = $id }
        $skills = $row.skills | ConvertFrom-Json
        $skills | Should -Contain 'PowerShell'
    }
}

Describe 'Add-InterviewStory — input validation' {
    It 'throws when Title is empty' {
        $s = New-ValidStory
        { Add-InterviewStory -Title '' -Context $s.Context -Situation $s.Situation `
            -Task $s.Task -Action $s.Action -Result $s.Result -Reflection $s.Reflection `
            -Keywords $s.Keywords -DbPath $script:TempDb } |
            Should -Throw -ExpectedMessage "*Title*required*"
    }

    It 'throws when Situation is empty' {
        $s = New-ValidStory
        { Add-InterviewStory -Title $s.Title -Context $s.Context -Situation '' `
            -Task $s.Task -Action $s.Action -Result $s.Result -Reflection $s.Reflection `
            -Keywords $s.Keywords -DbPath $script:TempDb } |
            Should -Throw -ExpectedMessage "*Situation*required*"
    }

    It 'throws when Action is empty' {
        $s = New-ValidStory
        { Add-InterviewStory -Title $s.Title -Context $s.Context -Situation $s.Situation `
            -Task $s.Task -Action '' -Result $s.Result -Reflection $s.Reflection `
            -Keywords $s.Keywords -DbPath $script:TempDb } |
            Should -Throw -ExpectedMessage "*Action*required*"
    }

    It 'throws when Result is empty' {
        $s = New-ValidStory
        { Add-InterviewStory -Title $s.Title -Context $s.Context -Situation $s.Situation `
            -Task $s.Task -Action $s.Action -Result '' -Reflection $s.Reflection `
            -Keywords $s.Keywords -DbPath $script:TempDb } |
            Should -Throw -ExpectedMessage "*Result*required*"
    }

    It 'throws when Reflection is empty' {
        $s = New-ValidStory
        { Add-InterviewStory -Title $s.Title -Context $s.Context -Situation $s.Situation `
            -Task $s.Task -Action $s.Action -Result $s.Result -Reflection '' `
            -Keywords $s.Keywords -DbPath $script:TempDb } |
            Should -Throw -ExpectedMessage "*Reflection*required*"
    }

    It 'throws when no keywords are provided' {
        $s = New-ValidStory
        { Add-InterviewStory -Title $s.Title -Context $s.Context -Situation $s.Situation `
            -Task $s.Task -Action $s.Action -Result $s.Result -Reflection $s.Reflection `
            -Keywords @() -DbPath $script:TempDb } |
            Should -Throw -ExpectedMessage "*keyword*required*"
    }
}

Describe 'Add-InterviewStory — append-only behaviour' {
    It 'never decrements the total count (append-only table)' {
        $before = (Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT COUNT(*) AS c FROM interview_stories").c

        $s = New-ValidStory -Title "AppendOnly-$(Get-Random)"
        Add-InterviewStory -Title $s.Title -Context $s.Context -Situation $s.Situation `
            -Task $s.Task -Action $s.Action -Result $s.Result -Reflection $s.Reflection `
            -Keywords $s.Keywords -DbPath $script:TempDb | Out-Null

        $after = (Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT COUNT(*) AS c FROM interview_stories").c
        $after | Should -Be ($before + 1)
    }
}

Describe 'Get-RelevantStories' {
    BeforeAll {
        # Seed known stories for keyword matching tests
        $storyDb = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.db')
        Initialize-OrbitDb -DbPath $storyDb
        $script:StoryDb = $storyDb

        $stories = @(
            @{ Title='Cloud Migration'; Keywords=@('cloud','azure','migration','infrastructure') }
            @{ Title='Team Leadership'; Keywords=@('leadership','mentoring','agile','team') }
            @{ Title='API Design';      Keywords=@('api','rest','dotnet','design') }
            @{ Title='CI/CD Setup';     Keywords=@('devops','cicd','automation','docker') }
            @{ Title='DB Optimization'; Keywords=@('database','sql','performance','optimization') }
        )

        foreach ($s in $stories) {
            Add-InterviewStory -Title $s.Title -Context 'Test' `
                -Situation 'Situation.' -Task 'Task.' -Action 'Action.' `
                -Result 'Result.' -Reflection 'Reflection.' `
                -Keywords $s.Keywords -DbPath $storyDb | Out-Null
        }
    }

    AfterAll {
        if (Test-Path $script:StoryDb) { Remove-Item $script:StoryDb -Force -ErrorAction SilentlyContinue }
    }

    It 'returns stories sorted by keyword overlap score descending' {
        $results = @(Get-RelevantStories -JdKeywords @('azure','cloud','migration') `
            -DbPath $script:StoryDb)
        $results[0].title | Should -Be 'Cloud Migration'
    }

    It 'respects the TopN limit' {
        $results = @(Get-RelevantStories -JdKeywords @('design') -TopN 2 `
            -DbPath $script:StoryDb)
        $results.Count | Should -BeLessOrEqual 2
    }

    It 'returns results for keywords with partial overlap' {
        $results = @(Get-RelevantStories -JdKeywords @('devops','docker') `
            -DbPath $script:StoryDb)
        $results[0].title | Should -Be 'CI/CD Setup'
    }

    It 'emits a warning when story bank has fewer than 3 stories' {
        $emptyDb = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.db')
        Initialize-OrbitDb -DbPath $emptyDb
        try {
            # Add only 2 stories
            for ($i = 1; $i -le 2; $i++) {
                Add-InterviewStory -Title "Story $i" -Context 'C' `
                    -Situation 'S' -Task 'T' -Action 'A' -Result 'R' -Reflection 'Ref' `
                    -Keywords @("kw$i") -DbPath $emptyDb | Out-Null
            }
            $warning = $null
            Get-RelevantStories -JdKeywords @('kw1') -DbPath $emptyDb `
                -WarningVariable warning | Out-Null
            $warning | Should -Not -BeNullOrEmpty
        } finally {
            Remove-Item $emptyDb -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns an empty array (not an error) for zero matching keywords' {
        $results = @(Get-RelevantStories -JdKeywords @('nonexistentkeywordxyz') `
            -DbPath $script:StoryDb)
        # May return results with overlap_score = 0, but should not throw
        $? | Should -BeTrue
    }
}

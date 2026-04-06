#Requires -Version 7.2
$ErrorActionPreference = 'Stop'

$script:DefaultDbPath = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\..\data\orbit.db'))

function Get-RelevantStories {
    param(
        [Parameter(Mandatory)][string[]] $JdKeywords,
        [int]    $TopN   = 5,
        [string] $DbPath = $script:DefaultDbPath
    )
    Import-Module PSSQLite -ErrorAction Stop

    $totalCount = (Invoke-SqliteQuery -DataSource $DbPath `
        -Query "SELECT COUNT(*) AS c FROM interview_stories").c

    if ($totalCount -lt 3) {
        Write-Warning "Story bank has fewer than 3 stories ($totalCount total). Add more stories for better interview preparation."
    }

    # ConvertTo-Json -InputObject avoids the PS7 gotcha where @() | ConvertTo-Json returns "null"
    $kwJson = ConvertTo-Json -InputObject @($JdKeywords) -Compress

    $stories = Invoke-SqliteQuery -DataSource $DbPath -Query @"
SELECT id, title, situation, task, action, result, reflection, keywords,
       (
           SELECT COUNT(*) FROM json_each(keywords) AS k
           WHERE lower(k.value) IN (
               SELECT lower(value) FROM json_each(@kwJson)
           )
       ) AS overlap_score
FROM interview_stories
ORDER BY overlap_score DESC, id DESC
LIMIT @topN
"@ -SqlParameters @{ kwJson = $kwJson; topN = $TopN }

    return $stories
}

function Add-InterviewStory {
    param(
        [Parameter(Mandatory)][string]   $Title,
        [Parameter(Mandatory)][string]   $Context,
        [Parameter(Mandatory)][string]   $Situation,
        [Parameter(Mandatory)][string]   $Task,
        [Parameter(Mandatory)][string]   $Action,
        [Parameter(Mandatory)][string]   $Result,
        [Parameter(Mandatory)][string]   $Reflection,
        [string[]] $Skills   = @(),
        [string[]] $Keywords = @(),
        [string]   $DbPath   = $script:DefaultDbPath
    )
    Import-Module PSSQLite -ErrorAction Stop

    # Spec L2-019 AC1: all STAR fields must be non-empty; keywords require at least one entry
    foreach ($field in @(
            @{ Name = 'Title';      Value = $Title      }
            @{ Name = 'Situation';  Value = $Situation  }
            @{ Name = 'Task';       Value = $Task       }
            @{ Name = 'Action';     Value = $Action     }
            @{ Name = 'Result';     Value = $Result     }
            @{ Name = 'Reflection'; Value = $Reflection }
        )) {
        if ([string]::IsNullOrWhiteSpace($field.Value)) {
            throw "$($field.Name) is required and must not be empty."
        }
    }
    if ($Keywords.Count -eq 0) {
        throw "At least one keyword is required for story bank entries."
    }

    $skillsJson   = ConvertTo-Json -InputObject @($Skills)   -Compress
    $keywordsJson = ConvertTo-Json -InputObject @($Keywords) -Compress

    $conn = New-SQLiteConnection -DataSource $DbPath
    try {
        Invoke-SqliteQuery -SQLiteConnection $conn -Query @"
INSERT INTO interview_stories
    (title, context, situation, task, action, result, reflection, skills, keywords)
VALUES (@title, @context, @situation, @task, @action, @result, @reflection, @skills, @keywords)
"@ -SqlParameters @{
            title = $Title; context = $Context; situation = $Situation; task = $Task
            action = $Action; result = $Result; reflection = $Reflection
            skills = $skillsJson; keywords = $keywordsJson
        }
        return [int](Invoke-SqliteQuery -SQLiteConnection $conn `
            -Query "SELECT last_insert_rowid() AS id").id
    } finally {
        $conn.Close()
    }
}

Export-ModuleMember -Function Get-RelevantStories, Add-InterviewStory

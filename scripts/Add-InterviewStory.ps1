#Requires -Version 7.2
[CmdletBinding()]
param(
    [string] $Title,
    [string] $Context,
    [string] $Situation,
    [string] $Task,
    [string] $Action,
    [string] $Result,
    [string] $Reflection,
    [string[]] $Skills   = @(),
    [string[]] $Keywords = @()
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dbPath   = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'data\orbit.db'))

Import-Module (Join-Path $PSScriptRoot 'modules\Invoke-PipelineDb.psm1') -Force
Import-Module PSSQLite -ErrorAction Stop

Initialize-OrbitDb -DbPath $dbPath

function Prompt-Field {
    param([string] $Label, [string] $Value)
    if ($Value) { return $Value }
    return (Read-Host $Label).Trim()
}

$Title      = Prompt-Field 'Story title (short name)'         $Title
$Context    = Prompt-Field 'Context (company/role/period)'    $Context
$Situation  = Prompt-Field 'Situation (S in STAR)'            $Situation
$Task       = Prompt-Field 'Task (T in STAR)'                 $Task
$Action     = Prompt-Field 'Action (A in STAR)'               $Action
$Result     = Prompt-Field 'Result (R in STAR)'               $Result
$Reflection = Prompt-Field 'Reflection (learning/growth)'     $Reflection

if (-not $Skills) {
    $skillsInput = Read-Host 'Skills (comma-separated, or press Enter to skip)'
    if ($skillsInput) { $Skills = $skillsInput -split ',' | ForEach-Object { $_.Trim() } }
}
if (-not $Keywords) {
    $kwInput = Read-Host 'Keywords for JD matching (comma-separated, or Enter to skip)'
    if ($kwInput) { $Keywords = $kwInput -split ',' | ForEach-Object { $_.Trim() } }
}

$skillsJson  = $Skills  | ConvertTo-Json -Compress
$keywordsJson= $Keywords | ConvertTo-Json -Compress

Invoke-SqliteQuery -DataSource $dbPath -Query @"
INSERT INTO interview_stories
    (title, context, situation, task, action, result, reflection, skills, keywords)
VALUES
    (@title, @context, @situation, @task, @action, @result, @reflection, @skills, @keywords)
"@ -SqlParameters @{
    title = $Title; context = $Context; situation = $Situation; task = $Task
    action = $Action; result = $Result; reflection = $Reflection
    skills = $skillsJson; keywords = $keywordsJson
}

$newId = (Invoke-SqliteQuery -DataSource $dbPath -Query "SELECT last_insert_rowid() AS id").id
Write-Host "Story saved (id=$newId): $Title"
return $newId

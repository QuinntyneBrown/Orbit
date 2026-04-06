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
Import-Module (Join-Path $PSScriptRoot 'modules\Invoke-StoryBank.psm1') -Force
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

# Spec L2-019 AC1: all STAR fields (+ Context) must be non-empty; at least one keyword required
foreach ($check in @(
        @{ Name = 'Title';      Value = $Title      }
        @{ Name = 'Context';    Value = $Context    }
        @{ Name = 'Situation';  Value = $Situation  }
        @{ Name = 'Task';       Value = $Task       }
        @{ Name = 'Action';     Value = $Action     }
        @{ Name = 'Result';     Value = $Result     }
        @{ Name = 'Reflection'; Value = $Reflection }
    )) {
    if ([string]::IsNullOrWhiteSpace($check.Value)) {
        [Console]::Error.WriteLine("ERROR: $($check.Name) is required and must not be empty.")
        exit 1
    }
}
if ($Keywords.Count -eq 0) {
    [Console]::Error.WriteLine("ERROR: At least one keyword is required for story bank entries.")
    exit 1
}

$newId = Add-InterviewStory `
    -Title $Title -Context $Context -Situation $Situation -Task $Task `
    -Action $Action -Result $Result -Reflection $Reflection `
    -Skills $Skills -Keywords $Keywords -DbPath $dbPath

Write-Host "Story saved (id=$newId): $Title"
return $newId

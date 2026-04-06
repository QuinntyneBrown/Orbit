#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Name,
    [switch] $Notes,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)

$sourceBase      = Join-Path $repoRoot 'content\base\focused-base.md'
$notesTemplate   = Join-Path $repoRoot 'templates\notes-template.md'
$variantOut      = Join-Path $repoRoot "content\tailored\resume-$Name.md"
$notesOut        = Join-Path $repoRoot "content\notes\$Name.md"

# Validate slug format
if ($Name -notmatch '^[a-z0-9-]+$') {
    Write-Error "Name must be lowercase letters, numbers, and hyphens only: '$Name'"
    exit 1
}

if (-not (Test-Path $sourceBase)) {
    Write-Error "Base resume not found: $sourceBase"
    exit 2
}

# Check overwrite
if ((Test-Path $variantOut) -and -not $Force) {
    $answer = Read-Host "File already exists: $variantOut`nOverwrite? [y/N]"
    if ($answer -notmatch '^[Yy]') {
        Write-Host "Cancelled."
        exit 1
    }
}

Copy-Item -Path $sourceBase -Destination $variantOut -Force
Write-Host "Created variant: $variantOut"

if ($Notes) {
    if (-not (Test-Path $notesTemplate)) {
        Write-Warning "Notes template not found at $notesTemplate — creating empty notes file"
        New-Item -ItemType File -Path $notesOut -Force | Out-Null
    } else {
        if ((Test-Path $notesOut) -and -not $Force) {
            $answer = Read-Host "Notes file already exists: $notesOut`nOverwrite? [y/N]"
            if ($answer -notmatch '^[Yy]') {
                Write-Host "Skipped notes file."
                exit 0
            }
        }
        Copy-Item -Path $notesTemplate -Destination $notesOut -Force
        Write-Host "Created notes: $notesOut"
    }
}

exit 0

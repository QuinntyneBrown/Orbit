#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

$protectedPaths = @(
    'data/orbit.db',
    'data/orbit.db-wal',
    'data/orbit.db-shm',
    'data/search-results/',
    'content/tailored/',
    'content/outreach/',
    'content/notes/',
    'config/profile.yml',
    'resumes/',
    'exports/'
)

$gitStatus = git -C $repoRoot status --porcelain 2>&1

$violations = @()
foreach ($path in $protectedPaths) {
    # Anchor on word boundaries so that e.g. data/orbit.db does not match
    # data/orbit.db-wal — both are in the list but are distinct protected paths.
    $escaped = [regex]::Escape($path.TrimEnd('/'))
    if ($gitStatus -match "(^|\s)$escaped(/|\s|$)") {
        $violations += $path
    }
}

if ($violations) {
    [Console]::Error.WriteLine("GITIGNORE VIOLATIONS — the following protected paths appear in git status:")
    $violations | ForEach-Object { [Console]::Error.WriteLine("  $_") }
    [Console]::Error.WriteLine("Add them to .gitignore or remove them from the repository.")
    exit 1
}

Write-Host "Gitignore check passed — no protected paths exposed."
exit 0

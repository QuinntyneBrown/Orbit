#Requires -Version 7.2
$ErrorActionPreference = 'Stop'

$script:RuleCache = $null
$script:DefaultDbPath = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\..\data\orbit.db'))

function Get-Archetype {
    param(
        [Parameter(Mandatory)][string] $Title,
        [Parameter(Mandatory)][string] $Company,
        [string] $Description = ''
    )

    if (-not $script:RuleCache) {
        $rulesPath = [System.IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot '..\..\config\archetype-rules.json'))
        if (-not (Test-Path $rulesPath)) {
            throw "Archetype rules file not found: $rulesPath"
        }
        $script:RuleCache = Get-Content $rulesPath | ConvertFrom-Json |
            Sort-Object priority
    }

    $haystack = ("$Title $Company $Description").ToLower()

    foreach ($rule in $script:RuleCache) {
        foreach ($pattern in $rule.patterns) {
            # Use word-boundary regex (not substring Contains) to avoid false positives —
            # e.g. "ai" must not match "mail", "paid", "email"; "ml" must not match "xml".
            # Trim the pattern first to strip any trailing spaces used in the config for
            # disambiguation (e.g. "ey ") — \b provides cleaner boundary enforcement.
            $escaped = [regex]::Escape($pattern.ToLower().Trim())
            if ($haystack -match "\b$escaped\b") {
                return [PSCustomObject]@{
                    Archetype  = $rule.archetype
                    IsInferred = $false
                }
            }
        }
    }

    # Default fallback
    return [PSCustomObject]@{
        Archetype  = 'Enterprise Contract'
        IsInferred = $true
    }
}

function Invoke-ArchetypeClassification {
    param(
        [Parameter(Mandatory)][array]  $Listings,
        [string] $DbPath = $script:DefaultDbPath
    )
    Import-Module PSSQLite -ErrorAction Stop

    foreach ($listing in $Listings) {
        $result = Get-Archetype -Title $listing.Title -Company $listing.Company -Description ($listing.Description ?? '')
        $listing.Archetype         = $result.Archetype
        $listing.ArchetypeInferred = [int]$result.IsInferred

        # Special flags
        if ($result.Archetype -eq 'Government / Public Sector') {
            $listing.SecurityClearanceFlag = $true
        }
        if ($result.Archetype -eq 'Enterprise Contract') {
            $listing.RecommendedBase = 'focused-base.md'
        }

        # Persist classification back to job_listings. Use normalised company+title
        # (same key used by the dedup upsert) to locate the row.
        if ($DbPath -and (Test-Path $DbPath)) {
            $company = $listing.Company.ToLower().Trim()
            $title   = $listing.Title.ToLower().Trim()
            Invoke-SqliteQuery -DataSource $DbPath -Query @"
UPDATE job_listings
SET archetype          = @archetype,
    archetype_inferred = @inferred
WHERE company = @company AND title = @title
"@ -SqlParameters @{
                archetype = $result.Archetype
                inferred  = [int]$result.IsInferred
                company   = $company
                title     = $title
            }
        }
    }

    return $Listings
}

Export-ModuleMember -Function Get-Archetype, Invoke-ArchetypeClassification

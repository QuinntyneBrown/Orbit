#Requires -Version 7.2
$ErrorActionPreference = 'Stop'

$script:RuleCache = $null

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
            if ($haystack.Contains($pattern.ToLower())) {
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
        [string] $DbPath = ''
    )

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
    }

    return $Listings
}

Export-ModuleMember -Function Get-Archetype, Invoke-ArchetypeClassification

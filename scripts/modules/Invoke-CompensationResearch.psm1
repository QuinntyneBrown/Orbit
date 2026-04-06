#Requires -Version 7.2
$ErrorActionPreference = 'Stop'

$script:DefaultDbPath = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\..\data\orbit.db'))

function Test-ExplicitRate {
    param(
        [Parameter(Mandatory)][string] $RateField,
        [string] $DescriptionBody = ''
    )
    if ([string]::IsNullOrWhiteSpace($RateField)) { return $false }
    # Matches patterns like $120, $120/hr, $80k, 80,000, etc.
    $patterns = @(
        '\$\d+',          # $120, $120/hr
        '\d+[kK]/yr',     # 80k/yr
        '\d{2,3},\d{3}',  # 80,000
        '\d+\s*per\s+hour'
    )
    foreach ($p in $patterns) {
        if ($RateField -match $p -or $DescriptionBody -match $p) { return $true }
    }
    return $false
}

function Invoke-CompensationResearch {
    param(
        [Parameter(Mandatory)][array]  $Listings,
        [string] $DbPath = $script:DefaultDbPath
    )
    Import-Module PSSQLite -ErrorAction Stop

    foreach ($listing in $Listings) {
        if (Test-ExplicitRate -RateField ($listing.Rate ?? '') -DescriptionBody ($listing.Description ?? '')) {
            continue  # Has explicit rate — skip per L2-016 AC3
        }

        # Check cache — skip if researched within 30 days
        $cached = Invoke-SqliteQuery -DataSource $DbPath -Query @"
SELECT * FROM compensation_estimates
WHERE listing_id = @lid
  AND estimated_at > date('now', '-30 days')
"@ -SqlParameters @{ lid = $listing.Id }

        if ($cached) {
            $listing.RateEstimate = Format-RateEstimate $cached
            continue
        }

        # Perform research (stub — real implementation queries public salary sources)
        $estimate = Invoke-SalaryResearch -Title $listing.Title -Company $listing.Company

        # Upsert into compensation_estimates
        Invoke-SqliteQuery -DataSource $DbPath -Query @"
INSERT INTO compensation_estimates (listing_id, range_low, range_high, confidence, source, researched_date)
VALUES (@lid, @low, @high, @conf, @src, date('now'))
ON CONFLICT (listing_id) DO UPDATE SET
    range_low    = excluded.range_low,
    range_high   = excluded.range_high,
    confidence   = excluded.confidence,
    source       = excluded.source,
    estimated_at = datetime('now'),
    researched_date = date('now')
"@ -SqlParameters @{
            lid  = $listing.Id
            low  = $estimate.RangeLow
            high = $estimate.RangeHigh
            conf = $estimate.Confidence
            src  = $estimate.Source
        }

        $listing.RateEstimate = Format-RateEstimate $estimate
    }

    return $Listings
}

function Invoke-SalaryResearch {
    param(
        [string] $Title,
        [string] $Company
    )
    # Stub: real implementation would query public salary sources
    # Returns no-data sentinel per L2-016 AC4 when no data found
    return [PSCustomObject]@{
        RangeLow   = $null
        RangeHigh  = $null
        Confidence = $null
        Source     = 'No data found'
    }
}

function Format-RateEstimate {
    param([object] $Estimate)
    if ($Estimate.Source -eq 'No data found' -or $null -eq $Estimate.RangeLow) {
        return 'No data found'
    }
    return "`$$($Estimate.RangeLow)–`$$($Estimate.RangeHigh)/hr ($($Estimate.Confidence) confidence) — Source: $($Estimate.Source)"
}

Export-ModuleMember -Function Invoke-CompensationResearch, Test-ExplicitRate

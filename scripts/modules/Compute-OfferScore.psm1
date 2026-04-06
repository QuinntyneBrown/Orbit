#Requires -Version 7.2
$ErrorActionPreference = 'Stop'

function Compute-OfferScore {
    param (
        [Parameter(Mandatory)][string] $TechnicalMatch,
        [Parameter(Mandatory)][string] $SeniorityAlignment,
        [Parameter(Mandatory)][string] $ArchetypeFit,
        [Parameter(Mandatory)][string] $CompensationFairness,
        [Parameter(Mandatory)][string] $MarketDemand
    )

    $weights = @{
        TechnicalMatch      = 0.35
        SeniorityAlignment  = 0.25
        ArchetypeFit        = 0.20
        CompensationFairness= 0.10
        MarketDemand        = 0.10
    }

    $ratingMap = @{ A = 5.0; B = 3.5; C = 2.0; Skip = 0.0 }

    $dims = [ordered]@{
        TechnicalMatch       = $TechnicalMatch
        SeniorityAlignment   = $SeniorityAlignment
        ArchetypeFit         = $ArchetypeFit
        CompensationFairness = $CompensationFairness
        MarketDemand         = $MarketDemand
    }

    foreach ($key in $dims.Keys) {
        $val = $dims[$key]
        if ([string]::IsNullOrWhiteSpace($val)) {
            throw "Missing dimension rating for '$key' — all five dimensions are required (L2-010 AC4)"
        }
        if (-not $ratingMap.ContainsKey($val)) {
            throw "Invalid rating '$val' for dimension '$key'. Valid values: A, B, C, Skip"
        }
    }

    $score = 0.0
    foreach ($key in $dims.Keys) {
        $score += $ratingMap[$dims[$key]] * $weights[$key]
    }
    $score = [Math]::Round($score, 2)

    $label = switch ($true) {
        ($score -ge 4.5) { 'Priority' }
        ($score -ge 3.0) { 'Viable'   }
        default          { 'Low Fit'  }
    }

    $recommendedAction = switch ($true) {
        ($score -ge 4.5) { 'Tailor' }
        ($score -ge 3.0) { 'Watch'  }
        default          { 'Skip'   }
    }

    return [PSCustomObject]@{
        Score             = $score
        Label             = $label
        RecommendedAction = $recommendedAction
    }
}

Export-ModuleMember -Function Compute-OfferScore

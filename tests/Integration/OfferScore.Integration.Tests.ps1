#Requires -Version 7.2
<#
.SYNOPSIS
    Integration tests for Compute-OfferScore.psm1
    Covers: score arithmetic, threshold labels/actions, input validation
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\..\scripts\modules\Compute-OfferScore.psm1'
    Import-Module $modulePath -Force
}

AfterAll {
    Remove-Module Compute-OfferScore -ErrorAction SilentlyContinue
}

Describe 'Compute-OfferScore — score arithmetic' {
    It 'computes maximum score (5.0) when all dimensions are A' {
        $result = Compute-OfferScore -TechnicalMatch A -SeniorityAlignment A `
            -ArchetypeFit A -CompensationFairness A -MarketDemand A
        $result.Score | Should -Be 5.0
    }

    It 'computes zero score when all dimensions are Skip' {
        $result = Compute-OfferScore -TechnicalMatch Skip -SeniorityAlignment Skip `
            -ArchetypeFit Skip -CompensationFairness Skip -MarketDemand Skip
        $result.Score | Should -Be 0.0
    }

    It 'computes correct weighted score for a mixed A/B/C/Skip set' {
        # TechnicalMatch=A(5.0*0.35=1.75), SeniorityAlignment=B(3.5*0.25=0.875),
        # ArchetypeFit=B(3.5*0.20=0.70), CompensationFairness=C(2.0*0.10=0.20), MarketDemand=Skip(0*0.10=0)
        # Total = 3.525, rounded to 2dp = 3.53
        $result = Compute-OfferScore -TechnicalMatch A -SeniorityAlignment B `
            -ArchetypeFit B -CompensationFairness C -MarketDemand Skip
        $result.Score | Should -Be 3.53
    }

    It 'computes all-B score correctly (3.5 * 1.0 weights = 3.5)' {
        $result = Compute-OfferScore -TechnicalMatch B -SeniorityAlignment B `
            -ArchetypeFit B -CompensationFairness B -MarketDemand B
        $result.Score | Should -Be 3.5
    }

    It 'applies correct weights (TechnicalMatch has highest weight at 35%)' {
        $heavyTech = Compute-OfferScore -TechnicalMatch A -SeniorityAlignment Skip `
            -ArchetypeFit Skip -CompensationFairness Skip -MarketDemand Skip
        $lightMarket = Compute-OfferScore -TechnicalMatch Skip -SeniorityAlignment Skip `
            -ArchetypeFit Skip -CompensationFairness Skip -MarketDemand A
        $heavyTech.Score | Should -BeGreaterThan $lightMarket.Score
    }
}

Describe 'Compute-OfferScore — labels and recommended actions' {
    It 'assigns Priority label and Tailor action when score >= 4.5' {
        $result = Compute-OfferScore -TechnicalMatch A -SeniorityAlignment A `
            -ArchetypeFit A -CompensationFairness A -MarketDemand A
        $result.Score             | Should -BeGreaterOrEqual 4.5
        $result.Label             | Should -Be 'Priority'
        $result.RecommendedAction | Should -Be 'Tailor'
    }

    It 'assigns Viable label and Watch action when score is between 3.0 and 4.49' {
        $result = Compute-OfferScore -TechnicalMatch B -SeniorityAlignment B `
            -ArchetypeFit B -CompensationFairness B -MarketDemand B
        $result.Score             | Should -BeGreaterOrEqual 3.0
        $result.Score             | Should -BeLessThan 4.5
        $result.Label             | Should -Be 'Viable'
        $result.RecommendedAction | Should -Be 'Watch'
    }

    It 'assigns Low Fit label and Skip action when score < 3.0' {
        $result = Compute-OfferScore -TechnicalMatch C -SeniorityAlignment C `
            -ArchetypeFit C -CompensationFairness C -MarketDemand C
        $result.Score             | Should -BeLessThan 3.0
        $result.Label             | Should -Be 'Low Fit'
        $result.RecommendedAction | Should -Be 'Skip'
    }

    It 'score exactly 4.5 is Priority (boundary check)' {
        # A*0.35 + A*0.25 + A*0.20 + A*0.10 + Skip*0.10 = 1.75+1.25+1.00+0.50+0 = 4.5
        $result = Compute-OfferScore -TechnicalMatch A -SeniorityAlignment A `
            -ArchetypeFit A -CompensationFairness A -MarketDemand Skip
        $result.Score | Should -Be 4.5
        $result.Label | Should -Be 'Priority'
    }

    It 'returns a single Label string (not an array) due to switch break statements' {
        # Regression guard: verify the switch($true) break fix prevents fallthrough
        $result = Compute-OfferScore -TechnicalMatch A -SeniorityAlignment A `
            -ArchetypeFit A -CompensationFairness A -MarketDemand A
        @($result.Label).Count             | Should -Be 1
        @($result.RecommendedAction).Count | Should -Be 1
    }
}

Describe 'Compute-OfferScore — input validation' {
    It 'throws when a dimension value is not A, B, C, or Skip' {
        { Compute-OfferScore -TechnicalMatch X -SeniorityAlignment A `
            -ArchetypeFit A -CompensationFairness A -MarketDemand A } |
            Should -Throw -ExpectedMessage "*Invalid rating*"
    }

    It 'throws when a dimension value is empty' {
        { Compute-OfferScore -TechnicalMatch '' -SeniorityAlignment A `
            -ArchetypeFit A -CompensationFairness A -MarketDemand A } |
            Should -Throw
    }

    It 'returns a PSCustomObject with Score, Label, and RecommendedAction properties' {
        $result = Compute-OfferScore -TechnicalMatch A -SeniorityAlignment B `
            -ArchetypeFit C -CompensationFairness A -MarketDemand B
        $result | Get-Member -Name Score             | Should -Not -BeNullOrEmpty
        $result | Get-Member -Name Label             | Should -Not -BeNullOrEmpty
        $result | Get-Member -Name RecommendedAction | Should -Not -BeNullOrEmpty
    }
}

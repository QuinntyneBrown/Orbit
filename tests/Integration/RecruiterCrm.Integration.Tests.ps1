#Requires -Version 7.2
<#
.SYNOPSIS
    Integration tests for Invoke-RecruiterCrm.psm1
    Covers: Add-RecruiterContact (validation, defaults, uniqueness),
            Update-RecruiterContact (COALESCE updates),
            Get-FollowUpDue (90-day threshold),
            Set-AccountCrossRef (auto-link by name),
            Add-TargetAccount (upsert behaviour)
#>

BeforeAll {
    $pipelineModule = Join-Path $PSScriptRoot '..\..\scripts\modules\Invoke-PipelineDb.psm1'
    $crmModule      = Join-Path $PSScriptRoot '..\..\scripts\modules\Invoke-RecruiterCrm.psm1'
    Import-Module $pipelineModule -Force
    Import-Module $crmModule      -Force

    $script:TempDb = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.db')
    Initialize-OrbitDb -DbPath $script:TempDb
}

AfterAll {
    Remove-Module Invoke-RecruiterCrm -ErrorAction SilentlyContinue
    Remove-Module Invoke-PipelineDb    -ErrorAction SilentlyContinue
    if (Test-Path $script:TempDb) { Remove-Item $script:TempDb -Force -ErrorAction SilentlyContinue }
}

Describe 'Add-RecruiterContact' {
    It 'inserts a contact and returns a positive integer id' {
        $id = Add-RecruiterContact -FirmName 'TechRecruit Inc' -DbPath $script:TempDb
        $id | Should -BeOfType [int]
        $id | Should -BeGreaterThan 0
    }

    It 'stores all provided fields correctly' {
        $id = Add-RecruiterContact -FirmName 'FullFields Agency' `
            -ContactName 'Jane Smith' -ContactLinkedin 'linkedin.com/in/janesmith' `
            -PriorityTier 'High' -EngagementStatus 'Active' -Notes 'Top vendor' `
            -DbPath $script:TempDb
        $row = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT * FROM recruiter_contacts WHERE id = @id" `
            -SqlParameters @{ id = $id }
        $row.firm_name         | Should -Be 'FullFields Agency'
        $row.contact_name      | Should -Be 'Jane Smith'
        $row.priority_tier     | Should -Be 'High'
        $row.engagement_status | Should -Be 'Active'
        $row.notes             | Should -Be 'Top vendor'
    }

    It 'defaults PriorityTier to Medium and EngagementStatus to Active' {
        $id = Add-RecruiterContact -FirmName 'DefaultsTest LLC' -DbPath $script:TempDb
        $row = Invoke-SqliteQuery -DataSource $script:TempDb `
            -Query "SELECT priority_tier, engagement_status FROM recruiter_contacts WHERE id = @id" `
            -SqlParameters @{ id = $id }
        $row.priority_tier     | Should -Be 'Medium'
        $row.engagement_status | Should -Be 'Active'
    }

    It 'throws on an invalid PriorityTier' {
        { Add-RecruiterContact -FirmName 'BadTier Corp' -PriorityTier 'Critical' `
            -DbPath $script:TempDb } |
            Should -Throw -ExpectedMessage "*Invalid PriorityTier*"
    }

    It 'throws on an invalid EngagementStatus' {
        { Add-RecruiterContact -FirmName 'BadStatus Corp' -EngagementStatus 'Pending' `
            -DbPath $script:TempDb } |
            Should -Throw -ExpectedMessage "*Invalid EngagementStatus*"
    }

    It 'accepts all valid PriorityTier values' {
        foreach ($tier in @('High','Medium','Low')) {
            { Add-RecruiterContact -FirmName "TierTest-$tier-$(Get-Random)" `
                -PriorityTier $tier -DbPath $script:TempDb } |
                Should -Not -Throw
        }
    }

    It 'accepts all valid EngagementStatus values' {
        foreach ($status in @('Active','Passive','Dormant','Closed')) {
            { Add-RecruiterContact -FirmName "StatusTest-$status-$(Get-Random)" `
                -EngagementStatus $status -DbPath $script:TempDb } |
                Should -Not -Throw
        }
    }
}

Describe 'Update-RecruiterContact' {
    BeforeAll {
        $script:UpdateFirm = "UpdateFirm-$(Get-Random)"
        Add-RecruiterContact -FirmName $script:UpdateFirm -PriorityTier 'Medium' `
            -EngagementStatus 'Active' -DbPath $script:TempDb | Out-Null
    }

    It 'updates engagement_status when specified' {
        Update-RecruiterContact -FirmName $script:UpdateFirm `
            -EngagementStatus 'Dormant' -DbPath $script:TempDb
        $row = Invoke-SqliteQuery -DataSource $script:TempDb -Query @"
SELECT engagement_status FROM recruiter_contacts WHERE firm_name = @f
"@ -SqlParameters @{ f = $script:UpdateFirm }
        $row.engagement_status | Should -Be 'Dormant'
    }

    It 'updates last_contacted_date when specified' {
        Update-RecruiterContact -FirmName $script:UpdateFirm `
            -LastContactedDate '2026-01-15' -DbPath $script:TempDb
        $row = Invoke-SqliteQuery -DataSource $script:TempDb -Query @"
SELECT last_contacted_date FROM recruiter_contacts WHERE firm_name = @f
"@ -SqlParameters @{ f = $script:UpdateFirm }
        $row.last_contacted_date | Should -Be '2026-01-15'
    }

    It 'preserves existing values when a field is not specified (COALESCE behaviour)' {
        # Update only notes — EngagementStatus should remain as previously set
        Update-RecruiterContact -FirmName $script:UpdateFirm `
            -Notes 'Updated note' -DbPath $script:TempDb
        $row = Invoke-SqliteQuery -DataSource $script:TempDb -Query @"
SELECT engagement_status, notes FROM recruiter_contacts WHERE firm_name = @f
"@ -SqlParameters @{ f = $script:UpdateFirm }
        $row.engagement_status | Should -Be 'Dormant'  # from previous test
        $row.notes             | Should -Be 'Updated note'
    }
}

Describe 'Get-FollowUpDue' {
    It 'returns High-priority contacts with null last_contacted_date' {
        $firmName = "NullDateHigh-$(Get-Random)"
        Add-RecruiterContact -FirmName $firmName -PriorityTier 'High' `
            -DbPath $script:TempDb | Out-Null
        $due = @(Get-FollowUpDue -DbPath $script:TempDb)
        $due | Where-Object { $_.firm_name -eq $firmName } | Should -Not -BeNullOrEmpty
    }

    It 'returns High-priority contacts last contacted more than 90 days ago' {
        $firmName = "OldContactHigh-$(Get-Random)"
        Add-RecruiterContact -FirmName $firmName -PriorityTier 'High' `
            -LastContactedDate '2025-01-01' -DbPath $script:TempDb | Out-Null
        $due = @(Get-FollowUpDue -DbPath $script:TempDb)
        $due | Where-Object { $_.firm_name -eq $firmName } | Should -Not -BeNullOrEmpty
    }

    It 'does NOT return High-priority contacts contacted recently (within 90 days)' {
        $firmName = "RecentHigh-$(Get-Random)"
        $recentDate = (Get-Date).AddDays(-10).ToString('yyyy-MM-dd')
        Add-RecruiterContact -FirmName $firmName -PriorityTier 'High' `
            -LastContactedDate $recentDate -DbPath $script:TempDb | Out-Null
        $due = @(Get-FollowUpDue -DbPath $script:TempDb)
        $due | Where-Object { $_.firm_name -eq $firmName } | Should -BeNullOrEmpty
    }

    It 'does NOT return Medium-priority contacts regardless of last contact date' {
        $firmName = "OldMedium-$(Get-Random)"
        Add-RecruiterContact -FirmName $firmName -PriorityTier 'Medium' `
            -LastContactedDate '2025-01-01' -DbPath $script:TempDb | Out-Null
        $due = @(Get-FollowUpDue -DbPath $script:TempDb)
        $due | Where-Object { $_.firm_name -eq $firmName } | Should -BeNullOrEmpty
    }
}

Describe 'Add-TargetAccount' {
    It 'inserts a target account and returns a positive id' {
        $id = Add-TargetAccount -Company 'Acme Tech' -DbPath $script:TempDb
        $id | Should -BeGreaterThan 0
    }

    It 'upserts on duplicate company name — updates priority and career_page_url' {
        $company = "UpsertCo-$(Get-Random)"
        Add-TargetAccount -Company $company -Priority 'Low' -DbPath $script:TempDb | Out-Null
        Add-TargetAccount -Company $company -Priority 'High' `
            -CareerPageUrl 'https://example.com/careers' -DbPath $script:TempDb | Out-Null

        $row = Invoke-SqliteQuery -DataSource $script:TempDb -Query @"
SELECT priority, career_page_url FROM target_accounts WHERE name = @n
"@ -SqlParameters @{ n = $company }
        $row.priority        | Should -Be 'High'
        $row.career_page_url | Should -Be 'https://example.com/careers'
    }

    It 'throws on an invalid AtsType' {
        { Add-TargetAccount -Company 'BadAts' -AtsType 'SmartRecruiters' `
            -DbPath $script:TempDb } |
            Should -Throw -ExpectedMessage "*Invalid AtsType*"
    }

    It 'accepts all valid AtsType values' {
        foreach ($ats in @('Greenhouse','Ashby','Lever','Wellfound','Workable')) {
            { Add-TargetAccount -Company "AtsTest-$ats-$(Get-Random)" -AtsType $ats `
                -DbPath $script:TempDb } |
                Should -Not -Throw
        }
    }

    It 'throws on an invalid Priority' {
        { Add-TargetAccount -Company 'BadPriority' -Priority 'Critical' `
            -DbPath $script:TempDb } |
            Should -Throw -ExpectedMessage "*Invalid Priority*"
    }
}

Describe 'Set-AccountCrossRef' {
    It 'links a target account to a recruiter contact with matching name' {
        $firmName = "CrossRefFirm-$(Get-Random)"
        Add-RecruiterContact -FirmName $firmName -DbPath $script:TempDb | Out-Null
        Add-TargetAccount    -Company $firmName  -DbPath $script:TempDb | Out-Null

        $linked = Set-AccountCrossRef -DbPath $script:TempDb
        $linked | Should -BeGreaterOrEqual 1

        $row = Invoke-SqliteQuery -DataSource $script:TempDb -Query @"
SELECT recruiter_contact_id FROM target_accounts WHERE name = @n
"@ -SqlParameters @{ n = $firmName }
        $row.recruiter_contact_id | Should -Not -BeNullOrEmpty
    }

    It 'does not re-link already-linked accounts' {
        $firmName = "AlreadyLinked-$(Get-Random)"
        Add-RecruiterContact -FirmName $firmName -DbPath $script:TempDb | Out-Null
        Add-TargetAccount    -Company $firmName  -DbPath $script:TempDb | Out-Null
        Set-AccountCrossRef -DbPath $script:TempDb | Out-Null  # first link

        # Second call should return 0 newly linked (already linked)
        $linked = Set-AccountCrossRef -DbPath $script:TempDb
        $linked | Should -Be 0
    }
}

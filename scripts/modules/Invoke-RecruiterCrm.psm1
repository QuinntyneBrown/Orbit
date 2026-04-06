#Requires -Version 7.2
$ErrorActionPreference = 'Stop'

$script:DefaultDbPath = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\..\data\orbit.db'))

function Add-RecruiterContact {
    param(
        [Parameter(Mandatory)][string] $FirmName,
        [string] $ContactName,
        [string] $ContactLinkedin,
        [string] $PriorityTier        = 'Medium',
        [string] $OpportunityPageUrl,
        [string] $LastContactedDate,
        [string] $EngagementStatus    = 'Active',
        [string] $Notes,
        [string] $DbPath = $script:DefaultDbPath
    )
    Import-Module PSSQLite -ErrorAction Stop
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
INSERT INTO recruiter_contacts
    (firm_name, contact_name, contact_linkedin, priority_tier,
     opportunity_page_url, last_contacted_date, engagement_status, notes)
VALUES (@firm, @name, @linkedin, @tier, @url, @contacted, @status, @notes)
"@ -SqlParameters @{
        firm      = $FirmName;     name      = $ContactName
        linkedin  = $ContactLinkedin; tier   = $PriorityTier
        url       = $OpportunityPageUrl; contacted = $LastContactedDate
        status    = $EngagementStatus; notes = $Notes
    }
    return (Invoke-SqliteQuery -DataSource $DbPath -Query "SELECT last_insert_rowid() AS id").id
}

function Update-RecruiterContact {
    param(
        [Parameter(Mandatory)][string] $FirmName,
        [string] $LastContactedDate,
        [string] $EngagementStatus,
        [string] $Notes,
        [string] $DbPath = $script:DefaultDbPath
    )
    Import-Module PSSQLite -ErrorAction Stop
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
UPDATE recruiter_contacts SET
    last_contacted_date = COALESCE(@contacted, last_contacted_date),
    engagement_status   = COALESCE(@status, engagement_status),
    notes               = COALESCE(@notes, notes),
    updated_at          = datetime('now')
WHERE firm_name = @firm
"@ -SqlParameters @{
        firm      = $FirmName
        contacted = $LastContactedDate
        status    = $EngagementStatus
        notes     = $Notes
    }
}

function Get-FollowUpDue {
    param([string] $DbPath = $script:DefaultDbPath)
    Import-Module PSSQLite -ErrorAction Stop
    return Invoke-SqliteQuery -DataSource $DbPath -Query @"
SELECT * FROM recruiter_contacts
WHERE priority_tier = 'High'
  AND (last_contacted_date IS NULL
       OR last_contacted_date <= date('now', '-90 days'))
ORDER BY last_contacted_date ASC
"@
}

function Set-AccountCrossRef {
    param([string] $DbPath = $script:DefaultDbPath)
    Import-Module PSSQLite -ErrorAction Stop

    $unlinked = Invoke-SqliteQuery -DataSource $DbPath -Query @"
SELECT ta.id AS ta_id, rc.id AS rc_id
FROM target_accounts ta
JOIN recruiter_contacts rc ON lower(ta.name) = lower(rc.firm_name)
WHERE ta.recruiter_contact_id IS NULL
"@

    $count = 0
    foreach ($row in $unlinked) {
        Invoke-SqliteQuery -DataSource $DbPath -Query @"
UPDATE target_accounts SET recruiter_contact_id = @rcId WHERE id = @taId
"@ -SqlParameters @{ rcId = $row.rc_id; taId = $row.ta_id }
        $count++
    }
    return $count
}

function Add-TargetAccount {
    param(
        [Parameter(Mandatory)][string] $Company,
        [string] $CareerPageUrl,
        [string] $AtsType,
        [string] $Priority = 'Medium',
        [string] $Notes,
        [string] $DbPath = $script:DefaultDbPath
    )
    Import-Module PSSQLite -ErrorAction Stop
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
INSERT INTO target_accounts (name, career_page_url, ats_type, priority, notes)
VALUES (@company, @url, @ats, @priority, @notes)
ON CONFLICT (name) DO UPDATE SET
    career_page_url = COALESCE(excluded.career_page_url, career_page_url),
    ats_type        = COALESCE(excluded.ats_type, ats_type),
    priority        = excluded.priority,
    notes           = COALESCE(excluded.notes, notes)
"@ -SqlParameters @{
        company  = $Company; url      = $CareerPageUrl
        ats      = $AtsType; priority = $Priority; notes = $Notes
    }
    return (Invoke-SqliteQuery -DataSource $DbPath -Query "SELECT last_insert_rowid() AS id").id
}

Export-ModuleMember -Function Add-RecruiterContact, Update-RecruiterContact, Get-FollowUpDue, Set-AccountCrossRef, Add-TargetAccount

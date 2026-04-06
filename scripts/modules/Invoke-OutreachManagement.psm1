#Requires -Version 7.2
$ErrorActionPreference = 'Stop'

$script:DefaultDbPath  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\data\orbit.db'))
$script:OutreachDir    = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\content\outreach'))

function ConvertTo-Slug {
    param([string] $Value)
    $slug = $Value.ToLower() -replace '[^a-z0-9\s-]', '' -replace '\s+', '-' -replace '-+', '-'
    return $slug.Trim('-')
}

function New-OutreachFile {
    param(
        [Parameter(Mandatory)][string] $Company,
        [Parameter(Mandatory)][string] $Role,
        [Parameter(Mandatory)][string] $MessageText,
        [Parameter(Mandatory)][string] $Type,  # linkedin-message | email | follow-up
        [int]    $ListingId = 0,
        [string] $DbPath    = $script:DefaultDbPath,
        [string] $OutreachDir = $script:OutreachDir
    )
    Import-Module PSSQLite -ErrorAction Stop

    $companySlug = ConvertTo-Slug $Company
    $roleSlug    = ConvertTo-Slug $Role

    # Determine version
    $maxVersion = (Invoke-SqliteQuery -DataSource $DbPath -Query @"
SELECT COALESCE(MAX(version), 0) AS v FROM outreach_records
WHERE company = @c AND role = @r AND type = @t
"@ -SqlParameters @{ c = $Company; r = $Role; t = $Type }).v

    $newVersion = $maxVersion + 1
    $suffix     = if ($newVersion -gt 1) { "-v$newVersion" } else { '' }
    $filename   = "$companySlug-$roleSlug-$Type$suffix.txt"
    $filePath   = Join-Path $OutreachDir $filename

    if (-not (Test-Path $OutreachDir)) {
        New-Item -ItemType Directory -Path $OutreachDir -Force | Out-Null
    }

    if (Test-Path $filePath) {
        throw "Output file already exists (version collision): $filePath"
    }

    Set-Content -Path $filePath -Value $MessageText -Encoding UTF8

    $lidParam = if ($ListingId -gt 0) { $ListingId } else { $null }
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
INSERT INTO outreach_records (listing_id, file_path, type, version, company, role)
VALUES (@lid, @path, @type, @version, @company, @role)
"@ -SqlParameters @{
        lid     = $lidParam; path    = $filePath
        type    = $Type;     version = $newVersion
        company = $Company;  role    = $Role
    }

    return $filePath
}

function New-LinkedInMessage {
    param(
        [Parameter(Mandatory)][string] $Company,
        [Parameter(Mandatory)][string] $Role,
        [string] $CandidateName  = '',
        [string] $ValueProp      = '',
        [int]    $ListingId      = 0,
        [string] $DbPath         = $script:DefaultDbPath
    )

    # Compose message from profile if no value prop provided
    $opening  = "Hi there,`n`nI came across the $Role position at $Company and wanted to reach out."
    $value    = if ($ValueProp) { $ValueProp } else {
        "I bring strong experience in software architecture and delivery, with a track record of leading complex technical initiatives from design through production."
    }
    $cta = "I'd welcome the chance to connect and learn more about the role. Are you available for a quick call?"

    $message = "$opening`n`n$value`n`n$cta`n`nBest,`n$CandidateName"

    return New-OutreachFile -Company $Company -Role $Role -MessageText $message `
        -Type 'linkedin-message' -ListingId $ListingId -DbPath $DbPath
}

Export-ModuleMember -Function New-OutreachFile, New-LinkedInMessage, ConvertTo-Slug

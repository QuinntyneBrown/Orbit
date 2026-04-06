#Requires -Version 7.2
<#
.SYNOPSIS
    Verifies that key sections in focused-base.md are consistent with comprehensive-base.md.
.DESCRIPTION
    Reads content/base/focused-base.md and content/base/comprehensive-base.md.
    Extracts:
      - Current role title (first ## heading after the top-level # heading)
      - Certifications section content
      - Contact details (email, phone, LinkedIn from YAML front matter or first lines)
    Rules:
      - If a section exists in focused but not in comprehensive -> ERROR (exit 1)
      - If shared sections differ in value -> WARN to stderr
    Exits 0 if clean, 1 if any errors.
#>

$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path $PSScriptRoot -Parent
$focusedPath = Join-Path $repoRoot 'content\base\focused-base.md'
$comprehensivePath = Join-Path $repoRoot 'content\base\comprehensive-base.md'

$hasError = $false

function Read-FileOrExit {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        [Console]::Error.WriteLine("ERROR: File not found: $Path")
        exit 1
    }
    return Get-Content $Path -Raw
}

$focusedContent      = Read-FileOrExit $focusedPath
$comprehensiveContent = Read-FileOrExit $comprehensivePath

# ── Helper: extract current role title ──────────────────────────────────────
function Get-CurrentRoleTitle {
    param([string]$Content)
    # Find first '## ' heading (the one after the top-level '# ' name heading)
    $lines = $Content -split "`n"
    $foundH1 = $false
    foreach ($line in $lines) {
        if (-not $foundH1 -and $line -match '^# ') {
            $foundH1 = $true
            continue
        }
        if ($foundH1 -and $line -match '^## (.+)') {
            return $Matches[1].Trim()
        }
    }
    return $null
}

# ── Helper: extract a named section's content ────────────────────────────────
function Get-Section {
    param([string]$Content, [string]$SectionHeading)
    # Returns the text between the named ## heading and the next ## heading (or EOF)
    $pattern = "(?ms)^## $([regex]::Escape($SectionHeading))\s*$(.+?)(?=^## |\Z)"
    if ($Content -match $pattern) {
        return $Matches[1].Trim()
    }
    return $null
}

# ── Helper: extract YAML front matter value ──────────────────────────────────
function Get-YamlValue {
    param([string]$Content, [string]$Key)
    if ($Content -match "(?m)^---\s*$(.+?)^---\s*$" -or $Content -match "(?ms)^---(.+?)---") {
        $frontMatter = $Matches[1]
        if ($frontMatter -match "(?m)^$([regex]::Escape($Key)):\s*(.+)$") {
            return $Matches[1].Trim()
        }
    }
    return $null
}

# ── Check 1: Current role title ──────────────────────────────────────────────
$focusedRole      = Get-CurrentRoleTitle $focusedContent
$comprehensiveRole = Get-CurrentRoleTitle $comprehensiveContent

if ($null -ne $focusedRole) {
    if ($null -eq $comprehensiveRole) {
        [Console]::Error.WriteLine("ERROR: Current role title found in focused-base.md but not in comprehensive-base.md.")
        $hasError = $true
    } elseif ($focusedRole -ne $comprehensiveRole) {
        [Console]::Error.WriteLine("WARN: Current role title differs. Focused='$focusedRole' Comprehensive='$comprehensiveRole'")
    }
}

# ── Check 2: Certifications section ─────────────────────────────────────────
$certSectionNames = @('Certifications', 'Certifications & Training', 'Credentials')
$focusedCerts      = $null
$comprehensiveCerts = $null
$focusedCertHeading = $null

foreach ($heading in $certSectionNames) {
    $val = Get-Section $focusedContent $heading
    if ($null -ne $val) {
        $focusedCerts = $val
        $focusedCertHeading = $heading
        break
    }
}
foreach ($heading in $certSectionNames) {
    $val = Get-Section $comprehensiveContent $heading
    if ($null -ne $val) {
        $comprehensiveCerts = $val
        break
    }
}

if ($null -ne $focusedCerts) {
    if ($null -eq $comprehensiveCerts) {
        [Console]::Error.WriteLine("ERROR: Certifications section found in focused-base.md but not in comprehensive-base.md.")
        $hasError = $true
    } elseif ($focusedCerts -ne $comprehensiveCerts) {
        [Console]::Error.WriteLine("WARN: Certifications section content differs between focused and comprehensive resumes.")
    }
}

# ── Check 3: Contact details (YAML front matter keys) ───────────────────────
$contactKeys = @('email', 'phone', 'linkedin')
foreach ($key in $contactKeys) {
    $focusedVal      = Get-YamlValue $focusedContent $key
    $comprehensiveVal = Get-YamlValue $comprehensiveContent $key

    if ($null -ne $focusedVal) {
        if ($null -eq $comprehensiveVal) {
            [Console]::Error.WriteLine("ERROR: Contact field '$key' found in focused-base.md but not in comprehensive-base.md.")
            $hasError = $true
        } elseif ($focusedVal -ne $comprehensiveVal) {
            [Console]::Error.WriteLine("WARN: Contact field '$key' differs. Focused='$focusedVal' Comprehensive='$comprehensiveVal'")
        }
    }
}

# ── Result ───────────────────────────────────────────────────────────────────
if ($hasError) {
    exit 1
} else {
    Write-Host "verify-sync: all checks passed."
    exit 0
}

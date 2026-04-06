#Requires -Version 7.2
<#
.SYNOPSIS
    Runs the full Orbit integration test suite using Pester.
.DESCRIPTION
    Discovers and executes all *.Integration.Tests.ps1 files under tests/Integration/.
    Requires Pester 5.x and PSSQLite to be installed.

    Install prerequisites (run once):
        Install-Module Pester   -MinimumVersion 5.0 -Force -Scope CurrentUser
        Install-Module PSSQLite -Force -Scope CurrentUser
.PARAMETER Tag
    Optional: run only tests with this Pester tag.
.PARAMETER TestName
    Optional: run only tests whose Describe/It label matches this string.
.PARAMETER PassThru
    Return the Pester result object to the caller.
.EXAMPLE
    # Run all integration tests
    .\tests\Run-Tests.ps1

    # Run only OfferScore tests
    .\tests\Run-Tests.ps1 -TestName 'Compute-OfferScore'
#>
param(
    [string] $Tag,
    [string] $TestName,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'

# --- Prerequisite checks ---
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge '5.0' })) {
    Write-Error "Pester 5.x is required. Run: Install-Module Pester -MinimumVersion 5.0 -Force -Scope CurrentUser"
    exit 1
}

if (-not (Get-Module -ListAvailable PSSQLite)) {
    Write-Error "PSSQLite is required. Run: Install-Module PSSQLite -Force -Scope CurrentUser"
    exit 1
}

# --- Configure Pester ---
$config = New-PesterConfiguration

$testRoot = Join-Path $PSScriptRoot 'Integration'
$config.Run.Path = $testRoot

$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled   = $true
$config.TestResult.OutputPath = Join-Path $PSScriptRoot 'TestResults.xml'
$config.TestResult.OutputFormat = 'NUnitXml'

if ($Tag)      { $config.Filter.Tag      = @($Tag) }
if ($TestName) { $config.Filter.FullName = $TestName }

$config.Run.PassThru = $PassThru.IsPresent -or ($null -ne $Tag) -or ($null -ne $TestName)

# --- Run ---
Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "  Orbit Integration Test Suite" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

$result = Invoke-Pester -Configuration $config

# --- Summary ---
if ($result) {
    Write-Host ""
    if ($result.FailedCount -gt 0) {
        Write-Host "FAILED: $($result.FailedCount) test(s) failed." -ForegroundColor Red
        exit 1
    } else {
        Write-Host "PASSED: All $($result.PassedCount) test(s) passed." -ForegroundColor Green
        exit 0
    }
}

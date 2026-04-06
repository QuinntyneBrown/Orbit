#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]] $Roles,
    [int] $MaxJobs = 4
)

$ErrorActionPreference = 'Stop'
$repoRoot    = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$newVariant  = Join-Path $repoRoot 'new-variant.ps1'
$startTime   = Get-Date

$jobs     = @()
$results  = @()
$queue    = [System.Collections.Queue]::new($Roles)

Write-Host "Batch tailor: $($Roles.Count) roles, max $MaxJobs concurrent"

while ($queue.Count -gt 0 -or $jobs.Count -gt 0) {
    # Start new jobs up to MaxJobs
    while ($queue.Count -gt 0 -and $jobs.Count -lt $MaxJobs) {
        $role = $queue.Dequeue()
        $job  = Start-Job -ScriptBlock {
            param($Script, $Role)
            $exitCode = 0
            try {
                & pwsh -NonInteractive -File $Script -Name $Role -Notes -Force
                $exitCode = $LASTEXITCODE
            } catch {
                $exitCode = 99
            }
            return @{ Role = $Role; ExitCode = $exitCode }
        } -ArgumentList $newVariant, $role
        $jobs += [PSCustomObject]@{ Job = $job; Role = $role; StartTime = (Get-Date) }
        Write-Host "  Started: $role (job $($job.Id))"
    }

    # Check for completed jobs
    $stillRunning = @()
    foreach ($j in $jobs) {
        if ($j.Job.State -in 'Completed','Failed','Stopped') {
            $output   = Receive-Job -Job $j.Job -ErrorAction SilentlyContinue
            $elapsed  = ((Get-Date) - $j.StartTime).TotalSeconds
            # Use explicit null check — ExitCode 0 is falsy but means success
            $exitCode = if ($null -ne $output -and $null -ne $output.ExitCode) { [int]$output.ExitCode } else { 1 }
            $results += [PSCustomObject]@{
                Role      = $j.Role
                ExitCode  = $exitCode
                ElapsedSec= [Math]::Round($elapsed, 1)
                Status    = if ($exitCode -eq 0) { 'Succeeded' } else { 'Failed' }
            }
            Remove-Job -Job $j.Job -Force
            Write-Host "  $($results[-1].Status): $($j.Role) ($($results[-1].ElapsedSec)s)"
        } else {
            $stillRunning += $j
        }
    }
    $jobs = $stillRunning

    if ($queue.Count -gt 0 -or $jobs.Count -gt 0) {
        Start-Sleep -Milliseconds 500
    }
}

$totalElapsed = [Math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
$succeeded    = ($results | Where-Object Status -eq 'Succeeded').Count
$failed       = ($results | Where-Object Status -eq 'Failed').Count

Write-Host "`nBatch complete: $succeeded succeeded, $failed failed, ${totalElapsed}s total"
if ($failed -gt 0) {
    $results | Where-Object Status -eq 'Failed' | ForEach-Object {
        Write-Host "  FAILED: $($_.Role) (exit $($_.ExitCode))"
    }
}

exit ($failed -gt 0 ? 1 : 0)

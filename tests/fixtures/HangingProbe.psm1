# HangingProbe.psm1
# TEST FIXTURE ONLY -- lives under tests/fixtures/, NEVER under probes/ (06-RESEARCH.md
# Open Question 3): a real .env misconfiguration must never let the production
# discovery scan (lib/ProbeHost.psm1's Get-EnabledProbeModulePaths, a plain
# Get-ChildItem probes/*.psm1) accidentally pick this up and activate it.
#
# Deliberately sleeps far past any realistic hard timeout (60s) to drive the MON-05
# abandonment path: lib/ProbeHost.psm1's Invoke-ProbeWithTimeout runs Invoke-Probe
# inside its own throwaway child [powershell] instance and races it against
# AsyncWaitHandle.WaitOne(HardTimeoutMilliseconds) -- this fixture proves that race
# actually abandons a hung probe rather than blocking the host forever.
#
# Exports: Invoke-Probe

Set-StrictMode -Version Latest

function Invoke-Probe {
    <#
    .SYNOPSIS
    Test fixture Invoke-Probe that sleeps 60 seconds -- far longer than any realistic
    per-probe HardTimeoutMilliseconds this repo would ever configure (RESEARCH.md
    recommends a probe poll cadence of ~15-30s total, so a single poll's hard timeout
    is expected to be a small fraction of a second to a few seconds). A test racing
    this against a short timeout (e.g. 500ms) proves the probe host abandons it well
    before this sleep ever completes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Config
    )

    Start-Sleep -Seconds 60

    return [pscustomobject]@{
        name    = 'hanging'
        title   = 'Hanging Probe (test fixture)'
        status  = 'ok'
        metrics = @()
        detail  = 'this probe should never be allowed to reach this line under a hard timeout'
    }
}

Export-ModuleMember -Function Invoke-Probe

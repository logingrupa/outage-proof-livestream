# MalformedProbe.psm1
# TEST FIXTURE ONLY -- lives under tests/fixtures/, NEVER under probes/ (06-RESEARCH.md
# Open Question 3), matching HangingProbe.psm1's own convention in this same directory.
#
# Deliberately returns a broken/partial result shape -- no 'status' property at all, and
# 'metrics' as a plain string rather than an array -- to drive lib/ProbeHost.psm1's
# safe-default normalization path (T-06-08 in 06-04-PLAN.md's threat register: "a
# malformed probe result shape corrupting the persisted file" -- mitigated by the host
# normalizing name/title and coercing an invalid status to 'unknown', never a host
# crash and never a raw pass-through of untrusted third-party/church-authored shape
# into Save-ProbeResult's ValidateSet'd -Status parameter).
#
# Exports: Invoke-Probe

Set-StrictMode -Version Latest

function Invoke-Probe {
    <#
    .SYNOPSIS
    Test fixture Invoke-Probe returning a deliberately partial/broken result: no
    'status' property (Save-ProbeResult's -Status is ValidateSet'd to
    ok|degraded|down|unknown, so a raw pass-through would throw), and 'metrics' as a
    non-array string (the D-02 schema requires an array of {label,value,unit}).
    Probe modules are explicitly less-trusted, potentially church-authored input
    (MON-01) -- this fixture proves the host never trusts a probe's shape blindly.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Config
    )

    return [pscustomobject]@{
        name    = 'malformed'
        title   = $null
        metrics = 'not-an-array'
        detail  = 'deliberately malformed for T-06-08 safe-default testing'
    }
}

Export-ModuleMember -Function Invoke-Probe

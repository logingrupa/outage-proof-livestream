# Backoff.psm1
# Pure full-jitter exponential backoff delay calculator (D-02).
# delay = RandomValue x min(ceilingMs, baseMs x 2^attemptNumber). Un-jittered backoff would
# synchronize every church's pusher onto the same retry schedule during a broad relay
# outage -- full jitter spreads reconnect times across the retry window so simultaneous
# outages do not converge on the shared relay (T-02-STORM). This is the reconnect-delay
# source for RES-01: the pusher increments the attempt on each classified
# NetworkDeath/RecordingEnded failure and resets it after a sustained-healthy window.
# No file/process/network access, no wall-clock reads, no sleeping -- a pure function of
# its inputs (CLAUDE.md functional-style requirement).
#
# Exports: Get-NextBackoffDelayMilliseconds

Set-StrictMode -Version Latest

$script:DefaultBackoffBaseMilliseconds = 1000
$script:DefaultBackoffCeilingMilliseconds = 30000

function Get-NextBackoffDelayMilliseconds {
    <#
    .SYNOPSIS
    Full-jitter exponential backoff (AWS full-jitter formula): delay = RandomValue x
    min(CeilingMilliseconds, BaseMilliseconds x 2^AttemptNumber). The ceiling clamp
    (T-02-BOFLOOP) bounds the delay regardless of attempt number -- no unbounded growth.
    The injectable RandomValue parameter is the testability seam: production callers omit
    it and real jitter fires via Get-Random; tests pass 0.0/1.0 to assert exact boundaries
    deterministically.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [int] $AttemptNumber,
        [int] $BaseMilliseconds = $script:DefaultBackoffBaseMilliseconds,
        [int] $CeilingMilliseconds = $script:DefaultBackoffCeilingMilliseconds,
        [double] $RandomValue = (Get-Random -Minimum 0.0 -Maximum 1.0)
    )

    $cap = [Math]::Min($CeilingMilliseconds, $BaseMilliseconds * [Math]::Pow(2, $AttemptNumber))
    return [int]($cap * $RandomValue)
}

Export-ModuleMember -Function Get-NextBackoffDelayMilliseconds

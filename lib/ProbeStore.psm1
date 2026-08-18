# ProbeStore.psm1
# The D-06 monitoring-plugin bridge: a probe host runspace (06-04) polls a
# church-authored probe plugin and this module atomically persists the
# normalized result to state/probes/<name>.json; the dashboard fold (06-06)
# reads it back. This is the FOURTH copy of this repo's atomic
# write-temp-then-rename idiom (offset, control, stats, now probes) --
# duplicated here DELIBERATELY, mirroring lib/StatsStore.psm1 almost
# verbatim, because extracting a shared helper would mean touching the
# live-proven OffsetStore write path for tidiness, which is not worth the
# risk (StatsStore.psm1 header lines 33-37; logged as known DRY debt in
# 05-CONTEXT.md's Deferred Ideas).
#
# SAFE-DEFAULT CONTRACT (state up front, StatsStore-header voice): a missing,
# corrupt, or empty probe result file is NOT an error -- it means "not polled
# yet / disabled", the normal state for any probe the operator hasn't enabled
# (D-03) or hasn't been polled yet since supervisor start. Read-ProbeResult is
# COMPLETELY SILENT -- no logger call of any kind on any path -- because the
# dashboard folds this file into its ~1s /api/stats poll (D-12) for the
# entire time the machine is idle; a single logged line per read would emit
# tens of thousands of lines a day and rotate the pusher's real diagnostic
# history off disk within hours (matching StatsStore's own D-14 rationale).
#
# STALENESS OWNERSHIP (D-07): the payload carries updatedEpochSeconds (via
# Get-MonotonicSeconds, Clock.psm1) and staleAfterEpochSeconds -- the
# writer's (Save-ProbeResult's) own declared deadline, not a dashboard-side
# guess and NEVER supplied by the probe plugin module itself (probes/*.psm1
# never stamps its own timestamps). Only the probe host, which knows its own
# poll cadence and hard-timeout, can say when silence stops being normal.
#
# Exports: Save-ProbeResult, Read-ProbeResult

Set-StrictMode -Version Latest

# Get-MonotonicSeconds only -- this module never logs (see the silent-reader
# contract above), so Logging.psm1 is deliberately NOT imported: importing a
# logger this module must never call would invite exactly the mistake the
# header forbids.
Import-Module (Join-Path $PSScriptRoot 'Clock.psm1')

function Save-ProbeResult {
    <#
    .SYNOPSIS
    Atomically persists a normalized probe result (schema below) to
    ProbeResultFilePath: writes a temp file in the same directory, then
    renames it over the final path with the single-syscall atomic replace
    [System.IO.File]::Move(src, dst, overwrite:$true) -- copied verbatim
    from Save-PusherStats's discipline (StatsStore.psm1), including the
    5-attempt/20ms-backoff retry loop on a transient IOException/
    UnauthorizedAccessException. A reader never observes a half-written
    payload.

    This is the phase's D-02 normalized schema, fixed here once:

      schemaVersion            int      literal 1
      name                     string   stable id, e.g. "vps-relay"
      title                    string   human panel heading, e.g. "VPS Relay"
      status                   string   'ok'|'degraded'|'down'|'unknown'
      metrics                  array    [{ label, value, unit }]
      detail                   string or $null   optional one-line note
      updatedEpochSeconds      double   Get-MonotonicSeconds at write time (D-07)
      staleAfterEpochSeconds   double   updatedEpochSeconds + StaleWithinSeconds

    StaleWithinSeconds (default 30.0) is the writer's own declared staleness
    deadline (D-07) -- probes poll far less often than the dashboard's 1s
    stats cadence (StatsStore's default is 3.0s), so the default here is
    wider to match a realistic probe poll interval.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ProbeResultFilePath,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [ValidateSet('ok', 'degraded', 'down', 'unknown')] [string] $Status,
        [array] $Metrics = @(),
        [string] $Detail,
        [double] $StaleWithinSeconds = 30.0
    )

    $absoluteProbeResultFilePath = [System.IO.Path]::GetFullPath($ProbeResultFilePath)
    $stateDirectory = Split-Path -Parent $absoluteProbeResultFilePath
    if ($stateDirectory -and -not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $updatedEpochSeconds = Get-MonotonicSeconds
    $staleAfterEpochSeconds = $updatedEpochSeconds + $StaleWithinSeconds

    $payloadObject = [ordered]@{
        schemaVersion          = 1
        name                   = $Name
        title                  = $Title
        status                 = $Status
        metrics                = $Metrics
        detail                 = $Detail
        updatedEpochSeconds    = $updatedEpochSeconds
        staleAfterEpochSeconds = $staleAfterEpochSeconds
    }
    $payload = $payloadObject | ConvertTo-Json -Compress -Depth 4

    $temporaryPath = Join-Path $stateDirectory ("probes-{0}.{1}.tmp" -f $Name, [Guid]::NewGuid())
    [System.IO.File]::WriteAllText($temporaryPath, $payload)

    # Same transient-denial retry discipline as Save-PusherStats/Save-PusherOffset:
    # the write stays atomic even across retries because the temp file is already
    # fully written and the PREVIOUS good probe result file is never deleted, so
    # the worst case on total exhaustion is a skipped update, never a corrupt/
    # missing file. A persistent denial (real ACL problem) still throws loudly
    # after the final attempt -- the probe host (06-04) is responsible for making
    # sure that throw can never terminate the probe poll loop.
    $maximumMoveAttempts = 5
    $moveBackoffMilliseconds = 20
    for ($attempt = 1; ; $attempt++) {
        try {
            [System.IO.File]::Move($temporaryPath, $absoluteProbeResultFilePath, $true)
            break
        } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if ($attempt -ge $maximumMoveAttempts) {
                if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
                throw
            }
            Start-Sleep -Milliseconds $moveBackoffMilliseconds
        }
    }
}

function Read-ProbeResult {
    <#
    .SYNOPSIS
    Loads the probe result payload from ProbeResultFilePath, or $null when
    there is nothing trustworthy to read -- no file, empty file, or corrupt/
    unparseable JSON. $null means "not polled yet / disabled" (D-07), a
    normal and common state, NOT an error: this function makes NO logger
    call on any path (see module header for why). Never throws.

    .OUTPUTS
    PSCustomObject (the parsed payload) or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $ProbeResultFilePath
    )

    if (-not (Test-Path -LiteralPath $ProbeResultFilePath)) {
        return $null
    }

    try {
        $absoluteProbeResultFilePath = [System.IO.Path]::GetFullPath($ProbeResultFilePath)
        $rawProbeResultJson = [System.IO.File]::ReadAllText($absoluteProbeResultFilePath)
        if ([string]::IsNullOrWhiteSpace($rawProbeResultJson)) {
            return $null
        }
        return $rawProbeResultJson | ConvertFrom-Json
    } catch {
        # Corrupt/truncated JSON == "not polled yet / disabled", never a fault
        # (D-07): never a fabricated value rendered as fact, just an honest
        # "no signal" -- matches Read-PusherStats' identical bias.
        return $null
    }
}

Export-ModuleMember -Function Save-ProbeResult, Read-ProbeResult

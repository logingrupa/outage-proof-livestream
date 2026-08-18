# StatsStore.psm1
# The D-15 rework: pusher.ps1's metrics ($resilienceState, offset, rates) live in a
# process that exists ONLY while streaming; supervisor.ps1's dashboard lives in the
# always-on process. This module is the bridge -- it atomically persists the full
# stats payload to state/stats.json (pusher.ps1 writes, supervisor.ps1's dashboard
# reads), reusing Save-PusherOffset's exact write-temp-then-rename discipline
# (OffsetStore.psm1) because the failure mode is identical: a scanner (Windows
# Defender real-time, Search indexer, a backup agent) holding a momentary handle on
# the destination is an observed real failure on this box, not a hypothetical.
#
# SAFE-DEFAULT CONTRACT (state up front, ControlFlag-header voice): missing, corrupt,
# or empty stats.json is NOT an error -- it means "not streaming", which is the normal
# idle state for all but a few hours a week. This is a DIFFERENT bias than
# OffsetStore's: OffsetStore's Restore-PusherOffset biases toward re-send (never lose
# bytes) and logs every fallback loudly, because a missing offset is rare and
# interesting. StatsStore's Read-PusherStats instead biases toward "unknown/idle" and
# is COMPLETELY SILENT -- no logger call of any kind on any path (matching
# Read-PusherControlFileDesiredValue's convention, ControlFlag.psm1) -- because the
# dashboard polls this file roughly once a second for the entire time the machine is
# idle (all week between services). A single logged line per read would emit ~86,000
# lines a day and rotate the pusher's real diagnostic history off disk within hours
# (D-14/SVC-03). Safe defaults in this repo are chosen per question, not per module --
# this module's question ("is anything streaming right now?") is answered "no, and
# never fabricate a number" per D-13, not "yes, assume the last good value".
#
# STALENESS OWNERSHIP (D-06): the payload carries updatedEpochSeconds (via
# Get-MonotonicSeconds, Clock.psm1) and staleAfterEpochSeconds -- the writer's own
# declared deadline, not a dashboard-side guess. Only pusher.ps1 knows when it is
# about to go deliberately quiet for a backoff sleep (up to 30s), so only pusher.ps1
# can say when silence stops being normal; a fixed dashboard-side threshold would
# misreport a mid-backoff pusher as lost contact.
#
# D-07: this is the THIRD copy of the atomic write-temp-then-rename idiom in this repo
# (offset, control, now stats). Duplicated here DELIBERATELY -- extracting a shared
# helper would mean touching the live-proven OffsetStore write path, and the offset
# writer is not worth risking for tidiness. Logged as known DRY debt in
# 05-CONTEXT.md's Deferred Ideas.
#
# Exports: Save-PusherStats, Read-PusherStats

Set-StrictMode -Version Latest

# Get-MonotonicSeconds only -- this module never logs (see the silent-reader contract
# above), so Logging.psm1 is deliberately NOT imported: importing a logger this module
# must never call would invite exactly the mistake the header forbids.
Import-Module (Join-Path $PSScriptRoot 'Clock.psm1')

function Save-PusherStats {
    <#
    .SYNOPSIS
    Atomically persists the full stats payload (schema below) to StatsFilePath: writes
    a temp file in the same directory, then renames it over the final path with the
    single-syscall atomic replace [System.IO.File]::Move(src, dst, overwrite:$true) --
    copied verbatim from Save-PusherOffset's discipline (OffsetStore.psm1), including
    the 5-attempt/20ms-backoff retry loop on a transient IOException/
    UnauthorizedAccessException. A reader never observes a half-written payload.

    This is the phase's central contract -- 05-05 (view model) and 05-06 (pusher
    publish) both build against this exact schema, so it is fixed here, once:

      schemaVersion             int      literal 1
      pusherState                string   'Streaming'|'Rotating'|'Draining'|'Stopped'|'WaitingForRecording'
      recordingFilePath          string   current recording file
      offsetBytes                long     bytes ffmpeg's stdin ACCEPTED
      fileLengthBytes             long     current recording file length
      sendBytesPerSecond          double   send-rate window
      recordBytesPerSecond        double   record-rate window
      secondsBehindLive           double   delay behind live
      backoffAttemptNumber        int      current backoff streak
      cumulativeReconnectCount    int      never-resetting session total
      lastClassificationCause     string or $null  'NetworkDeath'|'FfmpegCrash'|'RecordingEnded'|$null
      catchUpCapUtilization        double   0..1 (or beyond, uncapped display is the dashboard's call)
      outageActive                 bool
      updatedEpochSeconds          double   Get-MonotonicSeconds at write time (D-06)
      staleAfterEpochSeconds       double   updatedEpochSeconds + StaleWithinSeconds
      lastSuccessfulSendEpochSeconds double or $null  Get-MonotonicSeconds at the last
                                     successful ffmpeg-stdin write (DASH-08); $null
                                     before the first successful send ever happens --
                                     never a fabricated 0 (D-13)
      sessionStartEpochSeconds      double or $null  Get-MonotonicSeconds captured
                                     ONCE at Start-Pusher entry (260718-epo/FEAT-B) --
                                     the same value is threaded through every publish
                                     call this session so LiveUptimeSeconds/
                                     SessionDurationSeconds can be derived on the
                                     dashboard side; $null before a session has
                                     started, never a fabricated 0 (D-13)

    StaleWithinSeconds (default 3.0) is the writer's own declared staleness deadline
    (D-06) -- 05-06 passes a widened value before a backoff sleep so the dashboard
    never misreports a deliberately-quiet pusher as lost contact.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StatsFilePath,
        [Parameter(Mandatory)] [string] $PusherState,
        [string] $RecordingFilePath,
        [Parameter(Mandatory)] [long] $OffsetBytes,
        [Parameter(Mandatory)] [long] $FileLengthBytes,
        [Parameter(Mandatory)] [double] $SendBytesPerSecond,
        [Parameter(Mandatory)] [double] $RecordBytesPerSecond,
        [Parameter(Mandatory)] [double] $SecondsBehindLive,
        [Parameter(Mandatory)] [int] $BackoffAttemptNumber,
        [Parameter(Mandatory)] [int] $CumulativeReconnectCount,
        [string] $LastClassificationCause,
        [Parameter(Mandatory)] [double] $CatchUpCapUtilization,
        [Parameter(Mandatory)] [bool] $OutageActive,
        [double] $StaleWithinSeconds = 3.0,
        [Nullable[double]] $LastSuccessfulSendEpochSeconds = $null,
        [Nullable[double]] $SessionStartEpochSeconds = $null,
        # RELAY_PROTOCOL the session was started with ('srt'|'tcp', 2026-07-26) -- static per
        # pusher process, published so the operator can SEE which transport is live.
        [string] $RelayProtocol = 'srt'
    )

    $absoluteStatsFilePath = [System.IO.Path]::GetFullPath($StatsFilePath)
    $stateDirectory = Split-Path -Parent $absoluteStatsFilePath
    if ($stateDirectory -and -not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $updatedEpochSeconds = Get-MonotonicSeconds
    $staleAfterEpochSeconds = $updatedEpochSeconds + $StaleWithinSeconds

    $payloadObject = [ordered]@{
        schemaVersion            = 1
        pusherState              = $PusherState
        recordingFilePath        = $RecordingFilePath
        offsetBytes              = $OffsetBytes
        fileLengthBytes          = $FileLengthBytes
        sendBytesPerSecond       = $SendBytesPerSecond
        recordBytesPerSecond     = $RecordBytesPerSecond
        secondsBehindLive        = $SecondsBehindLive
        backoffAttemptNumber     = $BackoffAttemptNumber
        cumulativeReconnectCount = $CumulativeReconnectCount
        lastClassificationCause  = $LastClassificationCause
        catchUpCapUtilization    = $CatchUpCapUtilization
        outageActive             = $OutageActive
        updatedEpochSeconds      = $updatedEpochSeconds
        staleAfterEpochSeconds   = $staleAfterEpochSeconds
        lastSuccessfulSendEpochSeconds = $LastSuccessfulSendEpochSeconds
        sessionStartEpochSeconds = $SessionStartEpochSeconds
        relayProtocol            = $RelayProtocol
    }
    $payload = $payloadObject | ConvertTo-Json -Compress

    $temporaryPath = Join-Path $stateDirectory ("stats.{0}.tmp" -f [Guid]::NewGuid())
    [System.IO.File]::WriteAllText($temporaryPath, $payload)

    # Same transient-denial retry discipline as Save-PusherOffset (OffsetStore.psm1):
    # the write stays atomic even across retries because the temp file is already
    # fully written and the PREVIOUS good stats file is never deleted, so the worst
    # case on total exhaustion is a skipped update, never a corrupt/missing file. A
    # persistent denial (real ACL problem) still throws loudly after the final
    # attempt -- 05-06 is responsible for making sure that throw can never terminate
    # the pusher's hot loop (a stats write is a nice-to-have, D-05/T-05-11).
    $maximumMoveAttempts = 5
    $moveBackoffMilliseconds = 20
    for ($attempt = 1; ; $attempt++) {
        try {
            [System.IO.File]::Move($temporaryPath, $absoluteStatsFilePath, $true)
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

function Read-PusherStats {
    <#
    .SYNOPSIS
    Loads the stats payload from StatsFilePath, or $null when there is nothing
    trustworthy to read -- no file, empty file, or corrupt/unparseable JSON. $null
    means "not streaming" (D-04), a normal and common state, NOT an error: this
    function makes NO logger call on any path (see module header for why -- a
    per-poll log here would blow the rotating log budget within hours). Never throws.

    This deliberately diverges from Restore-PusherOffset's shape (OffsetStore.psm1),
    which logs loudly on every fallback because a missing offset is rare/interesting --
    a missing stats.json is the normal idle state, read about once a second.

    .OUTPUTS
    PSCustomObject (the parsed payload) or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $StatsFilePath
    )

    if (-not (Test-Path -LiteralPath $StatsFilePath)) {
        return $null
    }

    try {
        $absoluteStatsFilePath = [System.IO.Path]::GetFullPath($StatsFilePath)
        $rawStatsJson = [System.IO.File]::ReadAllText($absoluteStatsFilePath)
        if ([string]::IsNullOrWhiteSpace($rawStatsJson)) {
            return $null
        }
        return $rawStatsJson | ConvertFrom-Json
    } catch {
        # Corrupt/truncated JSON == "not streaming", never a fault (D-04/D-13): never a
        # fabricated value rendered as fact, just an honest "no signal".
        return $null
    }
}

Export-ModuleMember -Function Save-PusherStats, Read-PusherStats

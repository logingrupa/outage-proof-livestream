# SessionState.psm1
# Sole owner of state/session.json -- the supervisor-written, dashboard-read record of
# "how did the last pusher run end, and is a new recording waiting?" (260718-epo).
#
# WHY THIS EXISTS: a clean end-of-service (pusher.ps1 exit 0) leaves stats.json stale
# within a few seconds (StatsStore.psm1's own D-06 staleness deadline), and
# Get-DashboardViewModel's existing ConnectionState resolution order has no way to
# distinguish "the pusher finished normally" from "the pusher crashed or lost contact"
# -- both look identical from stats.json alone (not-alive + stale). session.json is
# the supervisor's own durable record of which one actually happened, written once per
# pusher exit (supervisor.ps1's Invoke-Supervisor) and read once per /api/stats poll
# (Dashboard.psm1's ApiStats route) so the dashboard can render a calm "Service
# finished" screen instead of the "Lost contact -- restart the service" alarm.
#
# SILENT-READER CONTRACT (StatsStore.psm1/ControlFlag.psm1 parity): Read-SessionState
# never logs on any path -- the dashboard polls it roughly once a second for the entire
# time the machine is idle (all week between services), and a per-poll log line would
# blow the bounded log budget (D-14/SVC-03) within hours. Missing/empty/corrupt
# session.json is NOT an error -- it degrades to $null, which the caller
# (Get-DashboardViewModel) reads as "no session record" and falls back to today's
# existing Idle behavior. Never throws on any read path.
#
# ATOMIC WRITE (the repo's now-FOURTH copy of the same idiom, StatsStore.psm1/
# ControlFlag.psm1/Config.psm1's Write-DotEnvFile): write a temp file in the same
# directory, then [System.IO.File]::Move(src, dst, $true) with the identical
# 5-attempt/20ms-backoff retry on a transient IOException/UnauthorizedAccessException
# those modules already use. Duplicated deliberately, not extracted -- see those
# modules' own headers for why (touching a live-proven write path for tidiness is not
# worth the risk). FinishedRecordingLastWriteUtc is stored as an ISO 8601 round-trip
# string (ToString('o')) -- JSON has no native DateTime type, and 'o' is the one format
# that survives a String -> ConvertTo-Json -> ConvertFrom-Json -> DateTime.Parse
# round-trip without ambiguity (culture-invariant, includes offset).
#
# CONSERVATIVE-BY-DEFAULT PICKUP DECISION (T-epo-01): Get-NewRecordingPickupDecision is
# pure and biased the same way ControlFlag.psm1's Get-PusherDesiredState is biased --
# any missing/ambiguous/equal input resolves to "not detected", never a false positive
# that could auto-start a live stream unattended. ShouldAutoStart additionally requires
# AutoPickupEnabled (AUTO_PICKUP, default OFF, lib/Config.psm1) -- detection and
# auto-start are two separate questions, and only the second one is gated by the
# operator's opt-in.
#
# Exports: Save-SessionState, Read-SessionState, Get-NewRecordingPickupDecision

Set-StrictMode -Version Latest

# Clock.psm1 only -- this module never logs (see the silent-reader contract above), so
# Logging.psm1 is deliberately NOT imported: importing a logger this module must never
# call would invite exactly the mistake the header forbids (StatsStore.psm1's own
# import-discipline precedent).
Import-Module (Join-Path $PSScriptRoot 'Clock.psm1')

function Save-SessionState {
    <#
    .SYNOPSIS
    Atomically persists the supervisor's session-outcome record to
    SessionStateFilePath: writes a temp file in the same directory, then renames it
    over the final path with the single-syscall atomic replace
    [System.IO.File]::Move(src, dst, overwrite:$true) -- copied verbatim from
    Save-PusherStats's discipline (StatsStore.psm1), including the 5-attempt/20ms
    backoff retry loop on a transient IOException/UnauthorizedAccessException. A
    reader never observes a half-written payload; the previous good file is never
    deleted before the new one is confirmed written.

    Schema (fixed here, once):
      schemaVersion                 int      literal 1
      lastExitReason                string or $null  'clean-end-of-service'|
                                     'config-fail'|'crash'|$null
      lastExitEpochSeconds          double or $null  Get-MonotonicSeconds at the
                                     pusher's exit (never a fabricated 0)
      finishedRecordingFilePath     string or $null  the just-finished recording's
                                     FullName, recorded only on a clean finish
      finishedRecordingLastWriteUtc string or $null  ISO 8601 ('o' format) of the
                                     finished recording's LastWriteTimeUtc
      newRecordingDetectedFilePath  string or $null  set once a strictly-newer
                                     recording is observed after a clean finish
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SessionStateFilePath,
        [AllowNull()] [AllowEmptyString()] [string] $LastExitReason = $null,
        [AllowNull()] [Nullable[double]] $LastExitEpochSeconds = $null,
        [AllowNull()] [AllowEmptyString()] [string] $FinishedRecordingFilePath = $null,
        [AllowNull()] [Nullable[datetime]] $FinishedRecordingLastWriteUtc = $null,
        [AllowNull()] [AllowEmptyString()] [string] $NewRecordingDetectedFilePath = $null
    )

    $absoluteSessionStateFilePath = [System.IO.Path]::GetFullPath($SessionStateFilePath)
    $stateDirectory = Split-Path -Parent $absoluteSessionStateFilePath
    if ($stateDirectory -and -not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $finishedRecordingLastWriteUtcText = if ($null -ne $FinishedRecordingLastWriteUtc) {
        $FinishedRecordingLastWriteUtc.ToString('o')
    } else {
        $null
    }

    $payloadObject = [ordered]@{
        schemaVersion                 = 1
        lastExitReason                = $LastExitReason
        lastExitEpochSeconds          = $LastExitEpochSeconds
        finishedRecordingFilePath     = $FinishedRecordingFilePath
        finishedRecordingLastWriteUtc = $finishedRecordingLastWriteUtcText
        newRecordingDetectedFilePath  = $NewRecordingDetectedFilePath
    }
    $payload = $payloadObject | ConvertTo-Json -Compress

    $temporaryPath = Join-Path $stateDirectory ("session.{0}.tmp" -f [Guid]::NewGuid())
    [System.IO.File]::WriteAllText($temporaryPath, $payload)

    # Same transient-denial retry discipline as Save-PusherStats (StatsStore.psm1): the
    # write stays atomic across retries because the temp file is already fully written
    # and the PREVIOUS good session file is never deleted, so the worst case on total
    # exhaustion is a skipped update, never a corrupt/missing file. A persistent denial
    # (real ACL problem) still throws loudly after the final attempt -- the caller
    # (supervisor.ps1's Invoke-Supervisor) is responsible for making sure that throw
    # can never terminate the process that owns crash restart (a session-state write
    # is a nice-to-have, mirroring Publish-PusherStats's own guard).
    $maximumMoveAttempts = 5
    $moveBackoffMilliseconds = 20
    for ($attempt = 1; ; $attempt++) {
        try {
            [System.IO.File]::Move($temporaryPath, $absoluteSessionStateFilePath, $true)
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

function Read-SessionState {
    <#
    .SYNOPSIS
    Loads the session-outcome payload from SessionStateFilePath, or $null when there is
    nothing trustworthy to read -- no file, empty file, or corrupt/unparseable JSON.
    $null means "no session record" (a normal, common state -- most of the week between
    services, and every fresh install before its first pusher exit), NOT an error: this
    function makes NO logger call on any path (see module header for why). Never throws.

    .OUTPUTS
    PSCustomObject (the parsed payload) or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $SessionStateFilePath
    )

    if (-not (Test-Path -LiteralPath $SessionStateFilePath)) {
        return $null
    }

    try {
        $absoluteSessionStateFilePath = [System.IO.Path]::GetFullPath($SessionStateFilePath)
        $rawSessionJson = [System.IO.File]::ReadAllText($absoluteSessionStateFilePath)
        if ([string]::IsNullOrWhiteSpace($rawSessionJson)) {
            return $null
        }
        return $rawSessionJson | ConvertFrom-Json
    } catch {
        # Corrupt/truncated JSON == "no trustworthy session record", never a fault --
        # matches Read-PusherStats's own D-04/D-13 precedent (StatsStore.psm1).
        return $null
    }
}

function Get-NewRecordingPickupDecision {
    <#
    .SYNOPSIS
    Pure decision (no I/O): given the just-finished recording's identity and the
    newest matching file currently in the recording folder, decides whether a NEW
    recording has appeared and whether auto-pickup should act on it.

    NewRecordingDetected is $true ONLY when:
      - NewestRecordingFilePath is non-empty, AND
      - FinishedRecordingFilePath is non-empty, AND
      - the two paths differ (OrdinalIgnoreCase), AND
      - both mtimes are present, AND
      - NewestRecordingLastWriteUtc is STRICTLY greater than
        FinishedRecordingLastWriteUtc.

    Every other combination -- the newest file equal to the finished path, a same-or-
    older mtime (the just-finished file re-observed), a missing newest/finished path,
    a missing mtime -- resolves to $false. This is the safety property (T-epo-01): the
    just-finished file must never be mistaken for a new recording and re-picked (no
    duplicate-byte re-send, D-11/D-12).

    ShouldAutoStart = NewRecordingDetected -and AutoPickupEnabled: detection and
    auto-start are two separate questions. Detection always runs (so the dashboard can
    always surface a one-click Start notice); only auto-start is gated by the
    operator's AUTO_PICKUP opt-in (default OFF, lib/Config.psm1).

    .OUTPUTS
    PSCustomObject: NewRecordingDetected ([bool]), NewRecordingFilePath ([string] or
    $null), ShouldAutoStart ([bool]).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $FinishedRecordingFilePath,
        [AllowNull()] [Nullable[datetime]] $FinishedRecordingLastWriteUtc,
        [AllowNull()] [AllowEmptyString()] [string] $NewestRecordingFilePath,
        [AllowNull()] [Nullable[datetime]] $NewestRecordingLastWriteUtc,
        [Parameter(Mandatory)] [bool] $AutoPickupEnabled
    )

    $hasNewestPath = -not [string]::IsNullOrEmpty($NewestRecordingFilePath)
    $hasFinishedPath = -not [string]::IsNullOrEmpty($FinishedRecordingFilePath)
    $pathsDiffer = $hasNewestPath -and $hasFinishedPath -and
        -not [string]::Equals($NewestRecordingFilePath, $FinishedRecordingFilePath, [System.StringComparison]::OrdinalIgnoreCase)
    $bothMtimesPresent = ($null -ne $NewestRecordingLastWriteUtc) -and ($null -ne $FinishedRecordingLastWriteUtc)
    $isStrictlyNewer = $bothMtimesPresent -and ($NewestRecordingLastWriteUtc -gt $FinishedRecordingLastWriteUtc)

    $newRecordingDetected = $hasNewestPath -and $hasFinishedPath -and $pathsDiffer -and $isStrictlyNewer

    $newRecordingFilePath = if ($newRecordingDetected) { $NewestRecordingFilePath } else { $null }
    $shouldAutoStart = $newRecordingDetected -and $AutoPickupEnabled

    return [pscustomobject]@{
        NewRecordingDetected = $newRecordingDetected
        NewRecordingFilePath = $newRecordingFilePath
        ShouldAutoStart      = $shouldAutoStart
    }
}

Export-ModuleMember -Function Save-SessionState, Read-SessionState, Get-NewRecordingPickupDecision

# Dashboard.psm1
# The dashboard's DECISIONS live here, never its I/O. Get-DashboardViewModel answers
# "what should the operator see right now?" -- the one place that truth is computed,
# mirroring this repo's established "pure decision function, side effects at the
# edges" convention (supervisor.ps1's Get-SupervisorExitDecision, Rotation.psm1's
# Get-EndOfServiceDecision, Backoff.psm1's Get-NextBackoffDelayMilliseconds).
#
# WHY THIS MATTERS (D-10): buttons must reflect observed reality, never what was last
# clicked. StartEnabled/StopEnabled/CutEnabled are derived solely from
# PusherProcessAlive (a live CIM observation, lib/PusherProcess.psm1) and the computed
# ConnectionState -- never from the control flag's stated intent and never from any
# client-side "optimistic" state. A Start button that looks armed while a pusher is
# already streaming is a double-push hazard this function exists to prevent.
#
# PER D-26 this same object IS the /api/stats response body -- one shape serves both
# the rendered page and the public JSON contract. 05-07 extends this module with the
# HTTP surface; nothing in this function may ever reach for a listener, a file, or the
# clock -- the caller reads stats, reads the flag, checks liveness, and reads the
# clock, then passes plain values in. That is why this function can be tested with
# every I/O cmdlet in the process mocked to throw and still return a correct answer.
#
# STALENESS IS READ FROM THE PAYLOAD, NOT FROM A FIXED THRESHOLD (D-06). A pusher in
# backoff sleeps out its full-jitter delay (up to Backoff.psm1's ceiling, 30s) before
# looping, so a flat few-second threshold would flip the dashboard to "lost contact"
# between backoff cycles -- exactly when the operator is watching an outage most
# closely. Only the pusher knows it is about to go deliberately quiet, so only the
# pusher's own published staleAfterEpochSeconds (StatsStore.psm1) can say when silence
# stops being normal. A payload missing that field, or carrying a non-numeric one (an
# older/partial build), is treated as stale rather than guessed at.
#
# CONNECTIONSTATE RESOLUTION ORDER IS THE CONTRACT (first match wins):
#   1a. -not PusherProcessAlive AND SessionState says clean-end-of-service OR
#       finished-with-undelivered-backlog (260718-j58/Front C) AND the control flag is
#       'stopped' -> Finished (260718-epo: a clean end-of-service is distinguishable
#                     from a crash ONLY via the supervisor's own session.json record --
#                     stats.json alone cannot tell the two apart, both look like
#                     "not alive, stale". Checked BEFORE the plain Idle branch below so
#                     a genuine finish never renders as the "Lost contact" alarm. The
#                     two finish tokens share this ONE ConnectionState -- the Reason
#                     (keyed off PendingBytes) is what tells them apart honestly.)
#   1b. -not PusherProcessAlive       -> Idle     (every other not-alive case, including
#                                                  a dead pusher's leftover stats file --
#                                                  the normal idle state, not lost
#                                                  contact -- checked BEFORE staleness)
#   2. IsStale                       -> Unknown
#   3. Stats.outageActive            -> Reconnecting (checked before pusherState: the
#                                                  pusher's own state is still
#                                                  'Streaming' mid-outage, but the
#                                                  outage is what the operator must see)
#   4. Stats.pusherState -eq 'Draining' -> Draining
#   5. Stats.pusherState -eq 'WaitingForRecording' -> WaitingForRecording (260809-ow9,
#                                                  START-STALE-01 -- the pusher is alive
#                                                  and holding a stale-file Start guard,
#                                                  deliberately sending nothing; Stop
#                                                  stays available)
#   6. otherwise                     -> Streaming (this is where 'Rotating' lands -- a
#                                                  healthy mid-service event that must
#                                                  never render as an error)
#
# NEVER A FABRICATED VALUE (D-13). Every stats-derived property is $null -- never a
# zero -- when Stats is $null or the relevant field is unreadable. A drain ETA is
# either honest or absent: $null unless the pusher is alive, stats are fresh, and
# sendBytesPerSecond is strictly positive (guarded with -gt 0/-le 0, not -eq 0,
# matching Get-SecondsBehindLive's and Get-CatchUpSendCeiling's existing precedent).
# "0s behind live" while nothing streams is the most convincing lie this dashboard
# could tell an operator deciding when to end a live service.
#
# STRICTMODE-SAFE AGAINST A PARTIAL PAYLOAD: every read off $Stats goes through
# Test-DashboardStatsHasProperty first, so an older/partial stats.json (a
# schemaVersion 0 file, or one missing a field a newer writer would include) degrades
# to ConnectionState='Unknown' rather than throwing PropertyNotFound out of an HTTP
# handler polled roughly once a second (T-05-20).
#
# 05-07 EXTENDS THIS MODULE WITH THE HTTP SURFACE (routing helpers, the request
# handler, the listener lifecycle). This module now owns both the dashboard's
# DECISIONS and its HTTP I/O -- but Get-DashboardViewModel and the Task 1 routing
# helpers (Test-DashboardRequestOrigin, Resolve-DashboardStaticPath,
# Get-DashboardContentType, Get-DashboardRouteMatch) stay exactly as pure as before:
# nothing in any of THOSE functions may ever reach for a listener, a file, or the
# clock. Invoke-DashboardRequestHandler (Task 2) and the listener lifecycle functions
# (Task 3) are deliberately NOT pure -- they are the thin edge that reads/writes,
# calling the pure functions above to decide and the existing modules
# (ControlFlag/PusherProcess/StatsStore/Clock/Config) to act. Logging.psm1 is imported
# here (not -Force, matching ControlFlag.psm1/Config.psm1's WR-02 convention) because
# the handler calls Write-Log directly; ControlFlag/PusherProcess/StatsStore/Clock/
# Config are NOT imported by this module -- the caller (05-09's supervisor.ps1, and
# every test file here) is responsible for importing them, exactly as their own
# exported functions are consumed by any other caller in this codebase.
#
# Exports: Get-DashboardViewModel, Test-DashboardRequestOrigin,
#          Resolve-DashboardStaticPath, Get-DashboardContentType,
#          Get-DashboardRouteMatch, Invoke-DashboardRequestHandler,
#          Test-RecordingFileDeletable, Get-ProbePanelViewModel,
#          Get-ProbeResultsForDashboard

Set-StrictMode -Version Latest

# WR-02 convention (ControlFlag.psm1/Config.psm1 parity): Invoke-DashboardRequestHandler
# calls Write-Log directly, so relying on the caller to have imported Logging would
# turn a CommandNotFoundException loose on the first dashboard request. Deliberately
# NOT -Force: a re-import must not reset Logging's already-configured LogDirectory
# back to its module default mid-service.
Import-Module (Join-Path $PSScriptRoot 'Logging.psm1')

# 05.1-03: ApiRecordings (Task 2) and Test-RecordingFileDeletable (Task 1) both reuse
# Get-NewestMatchingRecordingFile as the single "what is live" authority (RESEARCH.md
# Pattern 2) -- imported here, not re-implemented, so this module and Plan 04's delete
# route can never disagree about which file is the live/newest one.
Import-Module (Join-Path $PSScriptRoot 'Rotation.psm1')

# 06-06: Get-ProbeResultsForDashboard (the edge reader below) reads state/probes/*.json
# via Read-ProbeResult -- the FOURTH copy of the silent-safe-default reader convention
# (StatsStore.psm1), imported here for the identical reason Rotation.psm1 is: the
# handler is the one place probe files are ever touched, never Get-DashboardViewModel.
Import-Module (Join-Path $PSScriptRoot 'ProbeStore.psm1')

# 260718-epo: the ApiStats handler reads state/session.json via Read-SessionState (the
# supervisor's own clean-finish/auto-pickup record) and feeds it into
# Get-DashboardViewModel -- imported here for the identical reason ProbeStore.psm1 is,
# never inside the pure view-model function itself.
Import-Module (Join-Path $PSScriptRoot 'SessionState.psm1')

# 260722-xbr/NIC-TELEMETRY-01: the ApiStats handler reads the SRT-path NIC's transmitted-
# bytes counter via Get-NicSentBytes and folds a derived bytes/sec onto the view model --
# imported here for the identical reason ProbeStore.psm1/SessionState.psm1 are.
Import-Module (Join-Path $PSScriptRoot 'NicTelemetry.psm1')

# T-05-25: the body-size cap for POST /api/control and POST /api/config. A control
# POST is a few dozen bytes; an unbounded read on a localhost socket is a trivial
# memory-exhaustion vector against the process that owns crash restart.
$script:MaxDashboardRequestBodyBytes = 65536

# 260722-xbr/NIC-TELEMETRY-01: the previous NIC counter sample (SentBytes + the
# monotonic-clock moment it was read), held across polls within this runspace so the
# ApiStats branch can derive bytes/sec between consecutive polls via
# Get-NicUploadBytesPerSecond. $null until the first successful counter read (the
# priming poll never has a rate to report -- D-13, never fabricated).
$script:LastNicSample = $null

function Test-DashboardStatsHasProperty {
    <#
    .SYNOPSIS
    Private (never exported): StrictMode-safe existence check for a property on the
    (possibly $null, possibly partial) Stats payload. Never throws.

    .OUTPUTS
    Bool.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        $Stats,
        [Parameter(Mandatory)] [string] $PropertyName
    )

    return ($null -ne $Stats) -and ($Stats.PSObject.Properties.Name -contains $PropertyName)
}

function Get-DashboardViewModel {
    <#
    .SYNOPSIS
    Pure decision function: derives everything the dashboard renders -- connection
    state, honest button gating, staleness, and a never-fabricated drain ETA -- from
    four plain inputs. No file access, no process access, no wall-clock read, no logging.
    See module header for the ConnectionState resolution order and the staleness/ETA
    honesty rules; both are load-bearing, not incidental.

    .OUTPUTS
    PSCustomObject -- this object IS the /api/stats response body (D-26):
    ConnectionState, StartEnabled, StopEnabled, CutEnabled, IsStale,
    SecondsSinceUpdate, DelaySecondsBehindLive, DrainEtaSeconds, SentBytes,
    PendingBytes, TotalBytes, SendBytesPerSecond, RecordBytesPerSecond,
    RecordingFilePath, RecordingFileGrowing, BackoffAttemptNumber,
    CumulativeReconnectCount, OutageActive, LastClassificationCause,
    CatchUpCapUtilization, LastSuccessfulSendAgeSeconds, SessionFinished,
    LiveUptimeSeconds, SessionDurationSeconds, NewRecordingDetected,
    NewRecordingFilePath, Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $ControlFlagDesiredState,
        [Parameter(Mandatory)] [bool] $PusherProcessAlive,
        [AllowNull()] [Parameter(Mandatory)] $Stats,
        [Parameter(Mandatory)] [double] $NowMonotonicSeconds,
        [AllowNull()] $SessionState = $null
    )

    # Staleness: read the writer's own declared deadline off the payload (D-06).
    # Missing or non-numeric staleAfterEpochSeconds (an older/partial build) falls
    # back to "stale" rather than guessing a window -- never silently trust an
    # unreadable deadline.
    $hasStaleDeadline = Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'staleAfterEpochSeconds'
    $staleAfterEpochSeconds = if ($hasStaleDeadline) { $Stats.staleAfterEpochSeconds } else { $null }
    $isStaleDeadlineNumeric = $hasStaleDeadline -and (
        $staleAfterEpochSeconds -is [double] -or $staleAfterEpochSeconds -is [int] -or
        $staleAfterEpochSeconds -is [long] -or $staleAfterEpochSeconds -is [decimal]
    )
    $isStale = ($null -eq $Stats) -or (-not $isStaleDeadlineNumeric) -or ($NowMonotonicSeconds -gt $staleAfterEpochSeconds)

    $outageActive = if (Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'outageActive') { [bool]$Stats.outageActive } else { $false }
    $pusherState = if (Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'pusherState') { $Stats.pusherState } else { $null }

    # 260718-epo: read off the (possibly $null, possibly partial) SessionState through
    # the SAME StrictMode-safe guard the Stats payload already uses, so an older/
    # missing session.json degrades to today's existing Idle behavior rather than
    # throwing out of an HTTP handler polled roughly once a second (T-05-20 precedent).
    $lastExitReason = if (Test-DashboardStatsHasProperty -Stats $SessionState -PropertyName 'lastExitReason') { $SessionState.lastExitReason } else { $null }
    $newRecordingDetectedFilePathRaw = if (Test-DashboardStatsHasProperty -Stats $SessionState -PropertyName 'newRecordingDetectedFilePath') { $SessionState.newRecordingDetectedFilePath } else { $null }
    # 260718-j58/Front C: BOTH documented finish tokens resolve to 'Finished' --
    # 'clean-end-of-service' (everything drained) and 'finished-with-undelivered-backlog'
    # (a bounded end-of-service give-up, Task 4). Distinguishing the two is the Reason's
    # job below (via PendingBytes), not the ConnectionState's.
    $sessionFinishedClean = ($lastExitReason -eq 'clean-end-of-service' -or $lastExitReason -eq 'finished-with-undelivered-backlog') -and ($ControlFlagDesiredState -eq 'stopped')

    # PendingBytes computed BEFORE the ConnectionState resolution block (260718-j58,
    # relocated from its former later position) so the Finished branch's Reason can key
    # off it -- an honest "how much, if any, is still undelivered" beats a Reason that
    # blanket-claims everything was sent regardless of what actually happened (Task 3).
    $hasOffsetBytes = Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'offsetBytes'
    $hasFileLengthBytes = Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'fileLengthBytes'
    # Never negative -- a resume-margin rewind (offsetBytes momentarily greater than
    # fileLengthBytes) is a real state this pusher enters, not corruption.
    $pendingBytes = if ($hasOffsetBytes -and $hasFileLengthBytes) { [Math]::Max(0, [long]($Stats.fileLengthBytes - $Stats.offsetBytes)) } else { $null }

    # ConnectionState resolution order is the contract -- see module header.
    if ((-not $PusherProcessAlive) -and $sessionFinishedClean) {
        $connectionState = 'Finished'
        if ($null -ne $pendingBytes -and $pendingBytes -gt 0) {
            # Honest wording (Task 3): never claims everything was sent when it wasn't --
            # names the undelivered amount and the exact recovery path (D-05 margin only).
            $undeliveredMegabytes = [Math]::Round($pendingBytes / 1MB, 2)
            $reason = "The service ended with ${undeliveredMegabytes}MB still undelivered -- the relay was unreachable and the pusher gave up rather than reconnect forever. The recording is intact on disk; starting the pusher again delivers the remainder from the exact byte offset (only a small re-send margin, never a gap)."
        } else {
            $reason = 'The service finished normally -- everything recorded was sent and the pusher is ready for the next service.'
        }
    } elseif (-not $PusherProcessAlive) {
        $connectionState = 'Idle'
        $reason = 'The pusher process is not running, so nothing is being pushed to the relay -- Start is available.'
    } elseif ($isStale) {
        $connectionState = 'Unknown'
        $reason = 'Stats are older than the writer''s own declared deadline -- a deliberately-quiet backoff sleep looks identical to lost contact from here, so this is reported as unknown rather than guessed at.'
    } elseif ($outageActive) {
        $connectionState = 'Reconnecting'
        $reason = 'The pusher reports an active outage and is retrying automatically -- the recording file on disk is the buffer, so no content is lost while this continues.'
    } elseif ($pusherState -eq 'Draining') {
        $connectionState = 'Draining'
        $reason = 'The operator requested a stop and the pusher is sending its already-recorded backlog before exiting -- controls stay locked until it finishes.'
    } elseif ($pusherState -eq 'WaitingForRecording') {
        # 260809-ow9/START-STALE-01: the pusher is running but deliberately sending
        # nothing -- the newest recording in the folder is not currently growing, so
        # opening it would push stale content onto a live stream. Stop stays available
        # (StopEnabled below does not exclude this state) so the operator retains
        # control while waiting.
        $connectionState = 'WaitingForRecording'
        $reason = 'The pusher is running but is deliberately waiting -- the newest recording in the folder is not currently growing, so nothing is being sent. It will latch onto a fresh recording automatically as soon as one appears or starts growing.'
    } else {
        $connectionState = 'Streaming'
        $reason = 'The pusher is alive, stats are fresh, and no outage is active -- streaming normally (this also covers a healthy mid-service file rotation).'
    }

    $startEnabled = -not $PusherProcessAlive
    $stopEnabled = $PusherProcessAlive -and ($connectionState -ne 'Draining')
    $cutEnabled = $PusherProcessAlive -and ($connectionState -ne 'Draining')

    $secondsSinceUpdate = $null
    if (Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'updatedEpochSeconds') {
        $secondsSinceUpdate = $NowMonotonicSeconds - $Stats.updatedEpochSeconds
    }

    # D-13: an honest "unknown" beats a frozen number rendered as if it were live.
    $delaySecondsBehindLive = $null
    if ($PusherProcessAlive -and -not $isStale -and (Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'secondsBehindLive')) {
        $delaySecondsBehindLive = $Stats.secondsBehindLive
    }

    $sentBytes = if ($hasOffsetBytes) { $Stats.offsetBytes } else { $null }
    $totalBytes = if ($hasFileLengthBytes) { $Stats.fileLengthBytes } else { $null }

    $hasSendRate = Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'sendBytesPerSecond'
    $sendBytesPerSecond = if ($hasSendRate) { $Stats.sendBytesPerSecond } else { $null }

    # DrainEtaSeconds: $null unless alive, fresh, and a strictly positive send rate is
    # known -- guarded with -gt 0 (not -eq 0), matching Get-SecondsBehindLive's and
    # Get-CatchUpSendCeiling's existing cold-window precedent. A fabricated ETA is
    # worse than none (D-13).
    $drainEtaSeconds = $null
    if ($PusherProcessAlive -and -not $isStale -and $hasSendRate -and $sendBytesPerSecond -gt 0 -and $null -ne $pendingBytes) {
        $drainEtaSeconds = $pendingBytes / $sendBytesPerSecond
    }

    $recordBytesPerSecond = $null
    if (Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'recordBytesPerSecond') {
        $recordBytesPerSecond = $Stats.recordBytesPerSecond
    }

    # DASH-08/D-13: guarded exactly like DelaySecondsBehindLive above -- alive, fresh,
    # AND the field present and numeric, else $null (never a fabricated "just sent").
    # An older/partial build's stats.json (missing this field entirely) degrades to
    # $null the same way a missing staleAfterEpochSeconds degrades IsStale to stale.
    $lastSuccessfulSendAgeSeconds = $null
    if ($PusherProcessAlive -and -not $isStale -and (Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'lastSuccessfulSendEpochSeconds')) {
        $lastSuccessfulSendEpochSeconds = $Stats.lastSuccessfulSendEpochSeconds
        $isLastSuccessfulSendNumeric = (
            $lastSuccessfulSendEpochSeconds -is [double] -or $lastSuccessfulSendEpochSeconds -is [int] -or
            $lastSuccessfulSendEpochSeconds -is [long] -or $lastSuccessfulSendEpochSeconds -is [decimal]
        )
        if ($isLastSuccessfulSendNumeric) {
            $lastSuccessfulSendAgeSeconds = $NowMonotonicSeconds - $lastSuccessfulSendEpochSeconds
        }
    }

    # SESS-02/D-13: never fabricated -- $null unless stats are fresh (staleness already
    # accounts for Stats being $null entirely, see $isStale above). RecordingFileGrowing
    # additionally requires the pusher to be alive and an observed positive record rate,
    # matching DrainEtaSeconds's -gt 0 (not -eq 0) cold-window guard above.
    $recordingFilePath = $null
    if ((-not $isStale) -and (Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'recordingFilePath')) {
        $recordingFilePath = $Stats.recordingFilePath
    }
    $recordingFileGrowing = $PusherProcessAlive -and (-not $isStale) -and $recordBytesPerSecond -gt 0

    $backoffAttemptNumber = $null
    if (Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'backoffAttemptNumber') {
        $backoffAttemptNumber = $Stats.backoffAttemptNumber
    }

    $cumulativeReconnectCount = $null
    if (Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'cumulativeReconnectCount') {
        $cumulativeReconnectCount = $Stats.cumulativeReconnectCount
    }

    $lastClassificationCause = $null
    if (Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'lastClassificationCause') {
        $lastClassificationCause = $Stats.lastClassificationCause
    }

    $catchUpCapUtilization = $null
    if (Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'catchUpCapUtilization') {
        $catchUpCapUtilization = $Stats.catchUpCapUtilization
    }

    $sessionFinished = ($connectionState -eq 'Finished')

    # LiveUptimeSeconds (260718-epo/FEAT-B): honest -- $null unless alive, fresh, and
    # the writer's own sessionStartEpochSeconds is present and numeric (D-13, never a
    # fabricated "0s live"). Mirrors DelaySecondsBehindLive's own alive+fresh guard.
    $hasSessionStart = Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'sessionStartEpochSeconds'
    $sessionStartEpochSecondsRaw = if ($hasSessionStart) { $Stats.sessionStartEpochSeconds } else { $null }
    $isSessionStartNumeric = $hasSessionStart -and (
        $sessionStartEpochSecondsRaw -is [double] -or $sessionStartEpochSecondsRaw -is [int] -or
        $sessionStartEpochSecondsRaw -is [long] -or $sessionStartEpochSecondsRaw -is [decimal]
    )
    $liveUptimeSeconds = $null
    if ($PusherProcessAlive -and -not $isStale -and $isSessionStartNumeric) {
        $liveUptimeSeconds = $NowMonotonicSeconds - $sessionStartEpochSecondsRaw
    }

    # SessionDurationSeconds: deliberately NOT gated on alive/fresh -- this must survive
    # staleness so the finished screen (rendered only once the pusher is no longer
    # alive) can still show the total session length. Computed from the stats
    # payload's own updatedEpochSeconds (the last moment stats were published, which
    # for a clean finish is the terminal 'Stopped' publish) minus sessionStartEpochSeconds,
    # only when both are present and numeric (D-13, never fabricated).
    $hasUpdatedEpochSeconds = Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'updatedEpochSeconds'
    $updatedEpochSecondsRaw = if ($hasUpdatedEpochSeconds) { $Stats.updatedEpochSeconds } else { $null }
    $isUpdatedEpochSecondsNumeric = $hasUpdatedEpochSeconds -and (
        $updatedEpochSecondsRaw -is [double] -or $updatedEpochSecondsRaw -is [int] -or
        $updatedEpochSecondsRaw -is [long] -or $updatedEpochSecondsRaw -is [decimal]
    )
    $sessionDurationSeconds = $null
    if ($isUpdatedEpochSecondsNumeric -and $isSessionStartNumeric) {
        $sessionDurationSeconds = $updatedEpochSecondsRaw - $sessionStartEpochSecondsRaw
    }

    # NewRecordingDetected/NewRecordingFilePath (260718-epo/FEAT-C): true only when the
    # supervisor's session.json carries a non-empty newRecordingDetectedFilePath --
    # Invoke-AutoPickupTick (supervisor.ps1) is the sole writer of this field.
    $newRecordingDetected = -not [string]::IsNullOrEmpty($newRecordingDetectedFilePathRaw)
    $newRecordingFilePath = if ($newRecordingDetected) { $newRecordingDetectedFilePathRaw } else { $null }

    # RelayProtocol (2026-07-26 tcp path): honest passthrough of which transport the RUNNING
    # pusher session was started with; $null (never a fabricated 'srt') when the stats writer
    # predates the field (D-13).
    $relayProtocol = if (Test-DashboardStatsHasProperty -Stats $Stats -PropertyName 'relayProtocol') { $Stats.relayProtocol } else { $null }

    return [pscustomobject]@{
        ConnectionState          = $connectionState
        StartEnabled             = $startEnabled
        StopEnabled              = $stopEnabled
        CutEnabled               = $cutEnabled
        IsStale                  = $isStale
        SecondsSinceUpdate       = $secondsSinceUpdate
        DelaySecondsBehindLive   = $delaySecondsBehindLive
        DrainEtaSeconds          = $drainEtaSeconds
        SentBytes                = $sentBytes
        PendingBytes             = $pendingBytes
        TotalBytes               = $totalBytes
        SendBytesPerSecond       = $sendBytesPerSecond
        RecordBytesPerSecond     = $recordBytesPerSecond
        RecordingFilePath        = $recordingFilePath
        RecordingFileGrowing     = $recordingFileGrowing
        BackoffAttemptNumber     = $backoffAttemptNumber
        CumulativeReconnectCount = $cumulativeReconnectCount
        OutageActive             = $outageActive
        LastClassificationCause  = $lastClassificationCause
        CatchUpCapUtilization    = $catchUpCapUtilization
        LastSuccessfulSendAgeSeconds = $lastSuccessfulSendAgeSeconds
        SessionFinished          = $sessionFinished
        LiveUptimeSeconds        = $liveUptimeSeconds
        SessionDurationSeconds   = $sessionDurationSeconds
        NewRecordingDetected     = $newRecordingDetected
        NewRecordingFilePath     = $newRecordingFilePath
        RelayProtocol            = $relayProtocol
        Reason                   = $reason
    }
}

function Test-DashboardRequestOrigin {
    <#
    .SYNOPSIS
    The T-05-01 CSRF gate for the two state-changing routes (/api/control,
    /api/config). Returns $true ONLY when:
      - Origin is present and equals http://localhost:{DashboardPort} EXACTLY
        (ordinal compare -- never StartsWith, or http://localhost:8787.evil.com
        would pass), OR
      - Origin is absent and Sec-Fetch-Site is 'same-origin' (localhost is a
        browser-trustworthy origin, so a real dashboard page always presents at
        least one of the two headers).

    FAIL CLOSED when both headers are absent -- a DELIBERATE tradeoff, not an
    oversight. This costs something real: `curl -X POST .../api/control` is
    refused, so this endpoint is browser-only. The alternative -- treating "no
    headers" as trusted -- hands the exact CSRF bypass back to any attacker whose
    request simply omits both headers, which makes the whole check worthless. If a
    future scripted client genuinely needs in, the answer is an explicit
    shared-secret header (authentication), which D-23 defers until LAN access is on
    the table -- do not "fix" this strictness by trusting the absent case, that
    silently reopens the hole this function exists to close.

    Takes header VALUES, never a listener request object -- keeping this a pure,
    unit-testable security decision with no listener in scope (05-07 Task 1).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $OriginHeader,
        [AllowNull()] [AllowEmptyString()] [string] $SecFetchSiteHeader,
        [Parameter(Mandatory)] [int] $DashboardPort
    )

    $expectedOrigin = "http://localhost:$DashboardPort"

    if (-not [string]::IsNullOrEmpty($OriginHeader)) {
        return [string]::Equals($OriginHeader, $expectedOrigin, [System.StringComparison]::Ordinal)
    }

    if (-not [string]::IsNullOrEmpty($SecFetchSiteHeader)) {
        return [string]::Equals($SecFetchSiteHeader, 'same-origin', [System.StringComparison]::Ordinal)
    }

    return $false
}

function Test-RecordingFileDeletable {
    <#
    .SYNOPSIS
    Pure decision (SESS-04, D-07): a candidate file is deletable only if it is NOT the
    newest matching file in the recording folder. Deliberately conservative -- this
    protects the newest file unconditionally, even in the instant before OBS's first
    byte lands on it, rather than trying to detect "growing" and risking the exact race
    the phase objective flags (a freshly-created file that has not grown yet at the
    moment of the check). This is the single "what is live" authority also used by
    Plan 04's delete route (RESEARCH.md Pattern 2) -- both callers resolve
    $NewestMatchingFile via Rotation.psm1's Get-NewestMatchingRecordingFile and pass it
    in here; this function itself performs no filesystem access.

    .OUTPUTS
    Bool.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $CandidateFileFullName,
        [Parameter(Mandatory)] [AllowNull()] $NewestMatchingFile
    )

    if ($null -eq $NewestMatchingFile) { return $true }
    return -not [string]::Equals($CandidateFileFullName, $NewestMatchingFile.FullName, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ProbePanelViewModel {
    <#
    .SYNOPSIS
    06-06: pure staleness/status normaliser for a single probe result -- mirrors
    Get-DashboardViewModel's own purity contract exactly (no file access, no process
    access, no wall-clock read, no logging; now is passed in). Probe modules
    (probes/*.psm1, church-authored) are less-trusted input, same posture already
    applied to stats.json, so every field read goes through the existing
    Test-DashboardStatsHasProperty guard rather than trusting the payload shape.

    Staleness ownership matches D-07/Phase 5's D-06: the probe host's own declared
    staleAfterEpochSeconds deadline decides staleness, never a fixed threshold here. A
    stale probe (now > staleAfterEpochSeconds) is forced to status='unknown' regardless
    of its last-known status -- a stale probe must never render as live -- and carries
    lastUpdateAgeSeconds (now - updatedEpochSeconds) so the client can render "stale --
    last update Ns ago" (D-13: never fabricated -- $null while genuinely fresh, the
    same never-fabricate bias Get-DashboardViewModel already uses for DrainEtaSeconds
    etc.). A missing/non-numeric staleAfterEpochSeconds degrades to stale, the same
    "unreadable deadline is never trusted" bias Get-DashboardViewModel's own IsStale
    computation uses.

    .OUTPUTS
    PSCustomObject: name, title, status, metrics, detail, lastUpdateAgeSeconds.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $ProbeResult,
        [Parameter(Mandatory)] [double] $NowMonotonicSeconds
    )

    $name = if (Test-DashboardStatsHasProperty -Stats $ProbeResult -PropertyName 'name') { $ProbeResult.name } else { $null }
    $title = if (Test-DashboardStatsHasProperty -Stats $ProbeResult -PropertyName 'title') { $ProbeResult.title } else { $null }
    $status = if (Test-DashboardStatsHasProperty -Stats $ProbeResult -PropertyName 'status') { $ProbeResult.status } else { 'unknown' }
    $detail = if (Test-DashboardStatsHasProperty -Stats $ProbeResult -PropertyName 'detail') { $ProbeResult.detail } else { $null }

    # PowerShell array-return safety (this repo's established convention, e.g.
    # Rotation.psm1/06-04's ternary-branch note): assigning through an `if {} else {}`
    # EXPRESSION unwraps a genuine single-element array down to its bare element via
    # pipeline output collapsing -- a real metrics=[{...}] one-metric probe result
    # would silently lose its array-ness (Count would read as the hashtable's own key
    # count, not 1). A plain if/else STATEMENT assignment is a direct reference copy,
    # never routed through the output stream, so it cannot collapse.
    if (Test-DashboardStatsHasProperty -Stats $ProbeResult -PropertyName 'metrics') {
        $metrics = $ProbeResult.metrics
    } else {
        $metrics = @()
    }

    $hasStaleDeadline = Test-DashboardStatsHasProperty -Stats $ProbeResult -PropertyName 'staleAfterEpochSeconds'
    $staleAfterEpochSeconds = if ($hasStaleDeadline) { $ProbeResult.staleAfterEpochSeconds } else { $null }
    $isStaleDeadlineNumeric = $hasStaleDeadline -and (
        $staleAfterEpochSeconds -is [double] -or $staleAfterEpochSeconds -is [int] -or
        $staleAfterEpochSeconds -is [long] -or $staleAfterEpochSeconds -is [decimal]
    )
    $isStale = (-not $isStaleDeadlineNumeric) -or ($NowMonotonicSeconds -gt $staleAfterEpochSeconds)

    $lastUpdateAgeSeconds = $null
    if ($isStale) {
        $status = 'unknown'
        if (Test-DashboardStatsHasProperty -Stats $ProbeResult -PropertyName 'updatedEpochSeconds') {
            $lastUpdateAgeSeconds = $NowMonotonicSeconds - $ProbeResult.updatedEpochSeconds
        }
    }

    return [pscustomobject]@{
        name                 = $name
        title                = $title
        status               = $status
        metrics              = $metrics
        detail               = $detail
        lastUpdateAgeSeconds = $lastUpdateAgeSeconds
    }
}

function Get-ProbeResultsForDashboard {
    <#
    .SYNOPSIS
    06-06: the edge I/O reader for the ApiStats probes[] fold -- the ONLY place probe
    files are ever touched (Get-DashboardViewModel stays untouched and I/O-free, per the
    module's documented boundary). Reads every *.json file in ProbesDirectory via
    Read-ProbeResult (ProbeStore.psm1's silent-safe reader: a missing/corrupt/empty
    probe file returns $null and is skipped here, never thrown -- Pitfall 5, T-06-05),
    normalises each surviving result via Get-ProbePanelViewModel, and returns the array.

    An absent or empty ProbesDirectory returns an empty array -- NEVER $null (unary-
    comma array-return safety, this repo's established StrictMode convention) -- so
    MON-04's zero-plugin baseline is `probes: []` on the wire, not a missing/null field.

    Makes NO Write-Log call on any path (D-25/D-14/SVC-03 precedent this module's
    ApiStats branch already documents): this reader runs on every ~1s /api/stats poll,
    and a per-poll log line would rotate the pusher's real diagnostic history off disk
    within hours.

    .OUTPUTS
    Array of PSCustomObject (Get-ProbePanelViewModel's shape). Never $null.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)] [string] $ProbesDirectory,
        [Parameter(Mandatory)] [double] $NowMonotonicSeconds
    )

    if (-not (Test-Path -LiteralPath $ProbesDirectory)) {
        return , @()
    }

    $probeResultFiles = Get-ChildItem -LiteralPath $ProbesDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue
    $probeViewModels = @()
    foreach ($probeResultFile in $probeResultFiles) {
        $probeResult = Read-ProbeResult -ProbeResultFilePath $probeResultFile.FullName
        if ($null -eq $probeResult) {
            # Missing/corrupt/empty (Pitfall 5, T-06-05) == "not polled yet /
            # disabled" per Read-ProbeResult's own contract -- skipped, never thrown.
            continue
        }
        $probeViewModels += Get-ProbePanelViewModel -ProbeResult $probeResult -NowMonotonicSeconds $NowMonotonicSeconds
    }

    return , $probeViewModels
}

function Resolve-DashboardStaticPath {
    <#
    .SYNOPSIS
    Path math only (T-05-02) -- no filesystem probe of any kind, deliberately: the
    handler (05-07 Task 2) owns the existence check, this function owns only
    deciding whether a requested path is even allowed to be looked at. Maps '/' to
    'index.html'; strips any query string; URL-decodes ONCE via
    [System.Uri]::UnescapeDataString BEFORE the boundary check (decoding after would
    let '%2e%2e%2f' walk straight past it); rejects a null byte; rejects an
    absolute/rooted path smuggled into the request (e.g. '/C:/Windows/win.ini',
    which .NET's Path.Combine would otherwise silently let override the root
    entirely); then applies the EXACT boundary guard
    lib/OffsetStore.psm1's Resolve-ResumeOffset uses (T-03-04): GetFullPath both
    sides, and require the candidate to StartsWith the root's path PLUS a trailing
    DirectorySeparatorChar, using OrdinalIgnoreCase -- the trailing separator is
    what stops a sibling directory merely named like the root (e.g.
    'dashboard-secrets') from passing a naive prefix check.

    Never throws -- any failure (malformed encoding, refused path) returns $null,
    which the handler turns into a 404. Never reports WHY a path was refused: a
    traversal attempt and a genuine typo must be indistinguishable from outside.

    .OUTPUTS
    String (absolute path) or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $RequestPath,
        [Parameter(Mandatory)] [string] $DashboardRootPath
    )

    try {
        $pathOnly = $RequestPath.Split('?')[0]
        if ([string]::IsNullOrEmpty($pathOnly) -or $pathOnly -eq '/') {
            $pathOnly = '/index.html'
        }

        $decodedPath = [System.Uri]::UnescapeDataString($pathOnly)
        if ($decodedPath.IndexOf([char] 0) -ge 0) {
            return $null
        }

        $relativePath = $decodedPath.TrimStart('/', '\')
        if ([string]::IsNullOrEmpty($relativePath)) {
            $relativePath = 'index.html'
        }

        # A rooted candidate (a drive letter, or a path starting with a separator
        # even after the TrimStart above -- e.g. a second leading slash surviving
        # decode) would make [System.IO.Path]::Combine/Join-Path return the
        # candidate UNCHANGED, silently discarding the root entirely (a documented
        # .NET Path.Combine behavior, not a hypothetical) -- refuse it outright
        # rather than let that trap decide the outcome.
        if ([System.IO.Path]::IsPathRooted($relativePath)) {
            return $null
        }

        $absoluteRootPath = [System.IO.Path]::GetFullPath($DashboardRootPath)
        $candidatePath = [System.IO.Path]::GetFullPath((Join-Path $absoluteRootPath $relativePath))

        $rootWithTrailingSeparator = $absoluteRootPath.TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar
        ) + [System.IO.Path]::DirectorySeparatorChar
        $isInsideRoot = $candidatePath.StartsWith($rootWithTrailingSeparator, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $isInsideRoot) {
            return $null
        }

        return $candidatePath
    } catch {
        return $null
    }
}

function Get-DashboardContentType {
    <#
    .SYNOPSIS
    Maps a static file's extension to a Content-Type. Text types carry an explicit
    charset=utf-8 (dashboard/ files are always written UTF-8, no build step means no
    bundler to normalise this for us); anything unrecognised degrades to
    application/octet-stream rather than guessing.

    .OUTPUTS
    String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($extension) {
        '.html' { return 'text/html; charset=utf-8' }
        '.js' { return 'text/javascript; charset=utf-8' }
        '.css' { return 'text/css; charset=utf-8' }
        default { return 'application/octet-stream' }
    }
}

function Get-DashboardRouteMatch {
    <#
    .SYNOPSIS
    Pure string dispatch, no side effects -- decides WHICH handler branch a request
    belongs to, nothing more. A known API path with the wrong HTTP method returns
    'MethodNotAllowed' rather than falling through to the static server: GET on
    /api/control must not silently 404, because a 404 would tell an operator
    debugging their setup that the route does not exist when it does. Any unknown
    path (including every real static asset) falls through to 'StaticFile' -- the
    handler 404s if the file turns out not to exist.

    .OUTPUTS
    String: one of 'ApiStats', 'ApiControl', 'ApiConfig', 'ApiConfigRead',
    'ApiRecordings', 'ApiRecordingsDelete', 'StaticFile', 'MethodNotAllowed'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $HttpMethod,
        [Parameter(Mandatory)] [string] $UrlPath
    )

    $pathOnly = $UrlPath.Split('?')[0]

    switch ($pathOnly) {
        '/api/stats' {
            if ($HttpMethod -eq 'GET') { return 'ApiStats' }
            return 'MethodNotAllowed'
        }
        '/api/control' {
            if ($HttpMethod -eq 'POST') { return 'ApiControl' }
            return 'MethodNotAllowed'
        }
        '/api/config' {
            if ($HttpMethod -eq 'POST') { return 'ApiConfig' }
            if ($HttpMethod -eq 'GET') { return 'ApiConfigRead' }
            return 'MethodNotAllowed'
        }
        '/api/recordings' {
            if ($HttpMethod -eq 'GET') { return 'ApiRecordings' }
            return 'MethodNotAllowed'
        }
        '/api/recordings/delete' {
            if ($HttpMethod -eq 'POST') { return 'ApiRecordingsDelete' }
            return 'MethodNotAllowed'
        }
        default {
            return 'StaticFile'
        }
    }
}

function Read-DashboardRequestBody {
    <#
    .SYNOPSIS
    Private (never exported): reads at most MaxBodyBytes+1 bytes from a request's
    InputStream via a BOUNDED loop -- never ReadToEnd() -- so an unbounded POST cannot
    exhaust memory in the process that owns crash restart (T-05-25). Reading one byte
    past the cap is what lets the caller distinguish "exactly at the cap" from "over
    the cap" without needing Content-Length (which a caller need not send correctly).

    .OUTPUTS
    [pscustomobject]@{ Body = <string or $null>; TooLarge = <bool> }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $InputStream,
        [Parameter(Mandatory)] [int] $MaxBodyBytes
    )

    $buffer = [byte[]]::new($MaxBodyBytes + 1)
    $totalBytesRead = 0
    while ($totalBytesRead -lt $buffer.Length) {
        $bytesRead = $InputStream.Read($buffer, $totalBytesRead, $buffer.Length - $totalBytesRead)
        if ($bytesRead -le 0) { break }
        $totalBytesRead += $bytesRead
    }

    if ($totalBytesRead -gt $MaxBodyBytes) {
        return [pscustomobject]@{ Body = $null; TooLarge = $true }
    }

    $bodyText = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $totalBytesRead)
    return [pscustomobject]@{ Body = $bodyText; TooLarge = $false }
}

function Get-DashboardStaticFileBytes {
    <#
    .SYNOPSIS
    Private (never exported): thin wrapper around [System.IO.File]::ReadAllBytes,
    isolated purely as a testability seam -- Test 12 (T-05-02) asserts a refused
    traversal path never reaches this call, and mocking a raw static .NET method call
    directly is not possible with this codebase's test tooling, so the read is wrapped
    in a named, mockable function instead (the same seam pattern as cut.ps1's
    Stop-PusherProcesses being isolated so its ORDER can be asserted).
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    return [System.IO.File]::ReadAllBytes($Path)
}

function Write-DashboardResponseBytes {
    <#
    .SYNOPSIS
    Private (never exported): sets StatusCode/ContentType and writes Bytes to the
    response's OutputStream. A single choke point so every branch below writes a
    response the exact same way, and so a future header addition (e.g. Cache-Control)
    has one place to land per branch rather than N copy-pasted write sites.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Response,
        [Parameter(Mandatory)] [int] $StatusCode,
        [Parameter(Mandatory)] [string] $ContentType,
        [byte[]] $Bytes = @()
    )

    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    if ($Bytes.Length -gt 0) {
        $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    }
}

function ConvertTo-DashboardJsonBytes {
    <#
    .SYNOPSIS
    Private (never exported): UTF8-encodes a JSON string built from ConvertTo-Json,
    the one conversion every JSON-returning branch below needs.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)] [string] $Json
    )

    return [System.Text.Encoding]::UTF8.GetBytes($Json)
}

function Invoke-DashboardRequestHandler {
    <#
    .SYNOPSIS
    The thin edge (05-07 Task 2): reads the request, calls the pure Task 1 functions
    to decide, calls the existing modules (ControlFlag/PusherProcess/StatsStore/Clock/
    Config, plus cut.ps1's Stop-PusherProcesses) to act, writes the response. All the
    judgment already lives in tested pure functions -- this function's only job is
    wiring and I/O.

    -Context is deliberately UNTYPED rather than [System.Net.HttpListenerContext]:
    that .NET type has no public constructor, so a literal type constraint would make
    this function untestable without a real, running HttpListener. A real
    HttpListenerContext (05-09's production caller) satisfies the same
    .Request/.Response shape this function reads and writes, so this is a testability
    seam, not a behavior change -- tests/Dashboard.Tests.ps1's New-FakeDashboardContext
    builds a duck-typed stand-in backed by real System.IO.MemoryStream instances.

    D-03: THE WHOLE BODY IS WRAPPED IN TRY/CATCH. On any exception: log at Error, write
    a 500 with a generic body, and swallow -- an exception escaping this function would
    take down supervisor.ps1, the one process that owns crash restart (Phase 4). The
    dashboard is a passenger; the supervisor's job is keeping the stream alive.
    $Response.Close() runs in a FINALLY so a faulted request can never leak a
    connection until the listener starves.

    ApiStats makes NO Write-Log call (D-25/D-14/SVC-03): the browser polls this route
    roughly once a second, and a per-poll log line would rotate the pusher's real
    diagnostic history off disk within hours. Control actions and config writes ARE
    logged at Info -- rare, operator-initiated, exactly what a volunteer needs at 10:55
    on a Sunday. ApiRecordings makes NO Write-Log call either, for the same reason --
    it is operator-triggered but potentially repeated.

    05.1-03: RecordingFolderPath/RecordingFilenameGlob/StateFilePath are three NEW
    OPTIONAL params (default $null) -- this plan lands in Wave 1 but supervisor.ps1
    does not thread them until a later wave. ApiRecordings degrades honestly (500,
    never throws) when RecordingFolderPath is not yet supplied; StateFilePath is
    declared here only as the runspace-boundary contract a later plan threads through.

    260722-xbr/NIC-TELEMETRY-01: SrtNicName/NicUploadLogPath are two more OPTIONAL
    params (default $null), threaded from Start-DashboardHost (supervisor.ps1). A
    machine with no resolved NIC (or the dashboard running before this ships) degrades
    to inert -- the entire NIC block in the ApiStats branch is guarded on SrtNicName
    being non-blank, so an absent value behaves exactly like today, pre-260722-xbr.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string] $ScriptRoot,
        [Parameter(Mandatory)] [string] $ControlFilePath,
        [Parameter(Mandatory)] [string] $StatsFilePath,
        [Parameter(Mandatory)] [string] $DashboardRootPath,
        [Parameter(Mandatory)] [string] $EnvFilePath,
        [Parameter(Mandatory)] [int] $DashboardPort,
        [string] $RecordingFolderPath = $null,
        [string] $RecordingFilenameGlob = $null,
        [string] $StateFilePath = $null,
        [string] $SrtNicName = $null,
        [string] $NicUploadLogPath = $null
    )

    $response = $null
    try {
        $response = $Context.Response
        $request = $Context.Request
        $httpMethod = $request.HttpMethod
        $urlPath = $request.Url.AbsolutePath
        $route = Get-DashboardRouteMatch -HttpMethod $httpMethod -UrlPath $urlPath

        switch ($route) {
            'ApiStats' {
                $stats = Read-PusherStats -StatsFilePath $StatsFilePath
                $desiredState = Get-PusherDesiredState -ControlFilePath $ControlFilePath
                $pusherAlive = Test-PusherProcessAlive -ScriptRoot $ScriptRoot
                $nowMonotonicSeconds = Get-MonotonicSeconds

                # 260718-epo: derived from ScriptRoot the SAME way $probesDirectory
                # below already is -- deliberately NO new runspace param to thread
                # (mirrors the probes fold's own precedent). A missing/corrupt
                # session.json degrades honestly to $null (Read-SessionState's own
                # silent-safe contract), which Get-DashboardViewModel already treats
                # as "no session record" -> today's existing Idle behavior.
                $sessionStateFilePath = Join-Path $ScriptRoot 'state/session.json'
                $sessionState = Read-SessionState -SessionStateFilePath $sessionStateFilePath

                $viewModel = Get-DashboardViewModel -ControlFlagDesiredState $desiredState `
                    -PusherProcessAlive $pusherAlive -Stats $stats -NowMonotonicSeconds $nowMonotonicSeconds `
                    -SessionState $sessionState

                # 06-06/D-12: fold enabled probe results into this SAME response -- one
                # poll path, not a second /api/probes route. Read AFTER
                # Get-DashboardViewModel (which stays pure/untouched) so a broken probe
                # file can never affect the local-stats computation above it (MON-04's
                # inverse, Pitfall 5/T-06-05).
                $probesDirectory = Join-Path $ScriptRoot 'state/probes'
                $probeResults = Get-ProbeResultsForDashboard -ProbesDirectory $probesDirectory -NowMonotonicSeconds $nowMonotonicSeconds
                $viewModel | Add-Member -MemberType NoteProperty -Name 'probes' -Value $probeResults

                # 260722-xbr/NIC-TELEMETRY-01: read the SRT-path NIC's transmitted-bytes
                # counter at this SAME ~1s poll cadence, independent of whether the pusher
                # is alive (the NIC counter is system-wide). Guarded entirely on SrtNicName
                # being non-blank so a machine with no resolved adapter (or the dashboard
                # running before this shipped) behaves exactly as today (T-xbr-02). This
                # whole block still lives inside the handler's own top-level try/catch, so
                # a surprise here can never take down the supervisor.
                if (-not [string]::IsNullOrEmpty($SrtNicName)) {
                    $currentSentBytes = Get-NicSentBytes -NicName $SrtNicName

                    $nicUploadBps = $null
                    if ($null -ne $currentSentBytes -and $null -ne $script:LastNicSample) {
                        $nicUploadBps = Get-NicUploadBytesPerSecond -PreviousSentBytes $script:LastNicSample.SentBytes `
                            -CurrentSentBytes $currentSentBytes `
                            -IntervalSeconds ($nowMonotonicSeconds - $script:LastNicSample.MonotonicSeconds)
                    }

                    if ($null -ne $currentSentBytes) {
                        $script:LastNicSample = @{ SentBytes = $currentSentBytes; MonotonicSeconds = $nowMonotonicSeconds }
                    }

                    $viewModel | Add-Member -MemberType NoteProperty -Name 'NicUploadBps' -Value $nicUploadBps
                    $viewModel | Add-Member -MemberType NoteProperty -Name 'NicName' -Value $SrtNicName

                    if ($null -ne $nicUploadBps -and -not [string]::IsNullOrEmpty($NicUploadLogPath)) {
                        $pusherSendBitrateBps = if ($pusherAlive -and $null -ne $viewModel.SendBytesPerSecond) { $viewModel.SendBytesPerSecond } else { $null }
                        Add-NicUploadSample -LogFilePath $NicUploadLogPath -TimestampUtc ([DateTime]::UtcNow.ToString('o')) `
                            -NicName $SrtNicName -UploadBps $nicUploadBps -PusherSendBitrateBps $pusherSendBitrateBps
                    }
                }

                $json = $viewModel | ConvertTo-Json -Compress -Depth 4
                Write-DashboardResponseBytes -Response $response -StatusCode 200 -ContentType 'application/json' `
                    -Bytes (ConvertTo-DashboardJsonBytes -Json $json)
            }

            'ApiControl' {
                $originHeader = $request.Headers['Origin']
                $secFetchSiteHeader = $request.Headers['Sec-Fetch-Site']
                if (-not (Test-DashboardRequestOrigin -OriginHeader $originHeader -SecFetchSiteHeader $secFetchSiteHeader -DashboardPort $DashboardPort)) {
                    Write-DashboardResponseBytes -Response $response -StatusCode 403 -ContentType 'application/json' `
                        -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"forbidden"}')
                    break
                }

                $bodyResult = Read-DashboardRequestBody -InputStream $request.InputStream -MaxBodyBytes $script:MaxDashboardRequestBodyBytes
                if ($bodyResult.TooLarge) {
                    Write-DashboardResponseBytes -Response $response -StatusCode 413 -ContentType 'application/json' `
                        -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"payload too large"}')
                    break
                }

                $action = $null
                try {
                    $action = ($bodyResult.Body | ConvertFrom-Json).action
                } catch {
                    $action = $null
                }

                # Explicit allow-list, mirroring ControlFlag.psm1's own
                # ValidateSet('stopped','streaming') convention (T-05-06) -- an
                # unrecognised action never reaches either control function.
                switch ($action) {
                    'start' {
                        Set-PusherDesiredState -ControlFilePath $ControlFilePath -DesiredState 'streaming'
                        Write-Log -Level Info -Message 'Dashboard control: Start requested'
                        Write-DashboardResponseBytes -Response $response -StatusCode 200 -ContentType 'application/json' `
                            -Bytes (ConvertTo-DashboardJsonBytes -Json '{"success":true}')
                    }
                    'stop' {
                        Set-PusherDesiredState -ControlFilePath $ControlFilePath -DesiredState 'stopped'
                        Write-Log -Level Info -Message 'Dashboard control: Stop requested'
                        Write-DashboardResponseBytes -Response $response -StatusCode 200 -ContentType 'application/json' `
                            -Bytes (ConvertTo-DashboardJsonBytes -Json '{"success":true}')
                    }
                    'cut' {
                        # Flag FIRST, then kill -- cut.ps1's header explains why the
                        # order is load-bearing (a kill-first ordering lets the
                        # supervisor relaunch the stream the operator just cut). D-08
                        # is LOCKED: this calls the existing seam, never a second one.
                        Set-PusherDesiredState -ControlFilePath $ControlFilePath -DesiredState 'stopped'
                        Stop-PusherProcesses -ScriptRoot $ScriptRoot | Out-Null
                        Write-Log -Level Warning -Message 'Dashboard control: Cut requested -- the un-sent backlog is abandoned'
                        Write-DashboardResponseBytes -Response $response -StatusCode 200 -ContentType 'application/json' `
                            -Bytes (ConvertTo-DashboardJsonBytes -Json '{"success":true}')
                    }
                    'reset-resume' {
                        # SESS-03/D-05: this arm inherits the CSRF gate already checked
                        # above -- never a second Test-DashboardRequestOrigin call here.
                        # Refuse while the pusher is alive: wiping the resume anchor out
                        # from under a live gapless stream would be an unrecoverable
                        # content-loss bug, not a convenience. Only when stopped does
                        # Remove-Item run -- a missing StateFilePath is ALREADY the safe
                        # default Restore-PusherOffset falls back to (OffsetStore.psm1:
                        # 90-93), so this never writes a sentinel/marker file, only
                        # removes the existing one (idempotent: a file that is already
                        # gone is just as fresh as one just cleared).
                        if (Test-PusherProcessAlive -ScriptRoot $ScriptRoot) {
                            Write-DashboardResponseBytes -Response $response -StatusCode 409 -ContentType 'application/json' `
                                -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"stop the pusher before resetting resume state"}')
                            break
                        }

                        Remove-Item -LiteralPath $StateFilePath -Force -ErrorAction SilentlyContinue
                        Write-Log -Level Info -Message 'Dashboard control: Reset resume state'
                        Write-DashboardResponseBytes -Response $response -StatusCode 200 -ContentType 'application/json' `
                            -Bytes (ConvertTo-DashboardJsonBytes -Json '{"success":true}')
                    }
                    default {
                        Write-DashboardResponseBytes -Response $response -StatusCode 400 -ContentType 'application/json' `
                            -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"invalid action"}')
                    }
                }
            }

            'ApiConfig' {
                $originHeader = $request.Headers['Origin']
                $secFetchSiteHeader = $request.Headers['Sec-Fetch-Site']
                if (-not (Test-DashboardRequestOrigin -OriginHeader $originHeader -SecFetchSiteHeader $secFetchSiteHeader -DashboardPort $DashboardPort)) {
                    Write-DashboardResponseBytes -Response $response -StatusCode 403 -ContentType 'application/json' `
                        -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"forbidden"}')
                    break
                }

                $bodyResult = Read-DashboardRequestBody -InputStream $request.InputStream -MaxBodyBytes $script:MaxDashboardRequestBodyBytes
                if ($bodyResult.TooLarge) {
                    Write-DashboardResponseBytes -Response $response -StatusCode 413 -ContentType 'application/json' `
                        -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"payload too large"}')
                    break
                }

                # No pre-validation/pre-filtering here beyond basic JSON shape --
                # Write-DotEnvFile (lib/Config.psm1) owns the schema allow-list and the
                # validation (D-16); duplicating that logic at the edge would create a
                # second definition to drift (T-05-03).
                $changes = @{}
                $parsedOk = $true
                try {
                    $parsedBody = $bodyResult.Body | ConvertFrom-Json
                    foreach ($property in $parsedBody.PSObject.Properties) {
                        $changes[$property.Name] = [string] $property.Value
                    }
                } catch {
                    $parsedOk = $false
                }

                if (-not $parsedOk) {
                    Write-DashboardResponseBytes -Response $response -StatusCode 400 -ContentType 'application/json' `
                        -Bytes (ConvertTo-DashboardJsonBytes -Json '{"success":false,"problems":["malformed request body"]}')
                    break
                }

                $writeResult = Write-DotEnvFile -Path $EnvFilePath -Changes $changes
                Write-Log -Level Info -Message "Dashboard config write: success=$($writeResult.Success)"
                $writeStatusCode = if ($writeResult.Success) { 200 } else { 400 }
                Write-DashboardResponseBytes -Response $response -StatusCode $writeStatusCode -ContentType 'application/json' `
                    -Bytes (ConvertTo-DashboardJsonBytes -Json ($writeResult | ConvertTo-Json -Compress))
            }

            'ApiConfigRead' {
                # D-18: serve Get-RedactedConfig's output only, never the raw config --
                # the repo is public/shareable, and this is the one HTTP surface that
                # must never become the place a secret leaks (Test 10's canary).
                $config = Read-PusherConfig -Path $EnvFilePath
                $redactedConfig = Get-RedactedConfig -Config $config
                $json = $redactedConfig | ConvertTo-Json -Compress
                Write-DashboardResponseBytes -Response $response -StatusCode 200 -ContentType 'application/json' `
                    -Bytes (ConvertTo-DashboardJsonBytes -Json $json)
            }

            'ApiRecordings' {
                # 05.1-03/design_note: RecordingFolderPath is not threaded until a later
                # wave -- a misconfigured (un-threaded) call degrades honestly (500)
                # rather than throwing out of Get-ChildItem against an empty path.
                if ([string]::IsNullOrEmpty($RecordingFolderPath)) {
                    Write-DashboardResponseBytes -Response $response -StatusCode 500 -ContentType 'application/json' `
                        -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"recordings folder not configured"}')
                    break
                }

                # T-05.1-06/T-03-01: -LiteralPath + -Filter (no ".." traversal semantics)
                # -- never a hand-concatenated filename into a path.
                $matchingFiles = Get-ChildItem -LiteralPath $RecordingFolderPath -Filter $RecordingFilenameGlob -File
                # T-05.1-07: isLive is derived server-side via the SAME newest-file
                # authority Test-RecordingFileDeletable/Plan 04's delete route use --
                # never a client claim, so client and server cannot disagree.
                $newestMatchingFile = Get-NewestMatchingRecordingFile -RecordingFolderPath $RecordingFolderPath -RecordingFilenameGlob $RecordingFilenameGlob

                $recordings = @($matchingFiles | ForEach-Object {
                    [pscustomobject]@{
                        name             = $_.Name
                        fullName         = $_.FullName
                        sizeBytes        = $_.Length
                        lastWriteTimeUtc = $_.LastWriteTimeUtc
                        isLive           = -not (Test-RecordingFileDeletable -CandidateFileFullName $_.FullName -NewestMatchingFile $newestMatchingFile)
                    }
                })

                $json = $recordings | ConvertTo-Json -Compress -Depth 4 -AsArray
                Write-DashboardResponseBytes -Response $response -StatusCode 200 -ContentType 'application/json' `
                    -Bytes (ConvertTo-DashboardJsonBytes -Json $json)
            }

            'ApiRecordingsDelete' {
                # SESS-04/T-05.1-09: CSRF gate FIRST, exact copy of ApiControl/ApiConfig's
                # check -- no side effect below this point runs until it passes.
                $originHeader = $request.Headers['Origin']
                $secFetchSiteHeader = $request.Headers['Sec-Fetch-Site']
                if (-not (Test-DashboardRequestOrigin -OriginHeader $originHeader -SecFetchSiteHeader $secFetchSiteHeader -DashboardPort $DashboardPort)) {
                    Write-DashboardResponseBytes -Response $response -StatusCode 403 -ContentType 'application/json' `
                        -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"forbidden"}')
                    break
                }

                $bodyResult = Read-DashboardRequestBody -InputStream $request.InputStream -MaxBodyBytes $script:MaxDashboardRequestBodyBytes
                if ($bodyResult.TooLarge) {
                    Write-DashboardResponseBytes -Response $response -StatusCode 413 -ContentType 'application/json' `
                        -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"payload too large"}')
                    break
                }

                $filename = $null
                try {
                    $filename = ($bodyResult.Body | ConvertFrom-Json).filename
                } catch {
                    $filename = $null
                }
                if ([string]::IsNullOrEmpty($filename)) {
                    Write-DashboardResponseBytes -Response $response -StatusCode 400 -ContentType 'application/json' `
                        -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"malformed request body"}')
                    break
                }

                # T-05.1-10/T-05-02/WR-01: shares ONLY the core GetFullPath-both-sides +
                # StartsWith(root + trailing separator, OrdinalIgnoreCase) idiom with
                # Resolve-DashboardStaticPath/Resolve-ResumeOffset -- it does NOT carry
                # those functions' additional layers (URL/percent-decoding awareness, an
                # explicit null-byte rejection, an explicit IsPathRooted rejection before
                # the join). The StartsWith check below still catches the rooted-path case
                # here too (a rooted candidate degrades to an unreachable-but-still-inside
                # path rather than a real escape), so this is not a known bypass, but it is
                # weaker defense-in-depth than Resolve-DashboardStaticPath's guard -- do not
                # assume the two are interchangeable. Refused BEFORE any
                # Test-Path/Get-Item/Remove-Item touches the filesystem.
                $absoluteRecordingFolderPath = [System.IO.Path]::GetFullPath($RecordingFolderPath)
                $candidateFileFullName = [System.IO.Path]::GetFullPath((Join-Path $absoluteRecordingFolderPath $filename))
                $recordingFolderWithTrailingSeparator = $absoluteRecordingFolderPath.TrimEnd(
                    [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar
                ) + [System.IO.Path]::DirectorySeparatorChar
                $isInsideRecordingFolder = $candidateFileFullName.StartsWith($recordingFolderWithTrailingSeparator, [System.StringComparison]::OrdinalIgnoreCase)
                if (-not $isInsideRecordingFolder) {
                    Write-DashboardResponseBytes -Response $response -StatusCode 400 -ContentType 'application/json' `
                        -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"invalid filename"}')
                    break
                }

                # CR-02: the candidate must ALSO be a member of the actual glob-matched
                # enumeration, not merely "inside RecordingFolderPath and not the newest
                # file". RecordingFolderPath defaults to the same folder as StateFilePath
                # (Config.psm1's shipped schema defaults both to 'state/'), so without
                # this check a non-recording file -- e.g. state/offset.json -- sitting
                # beside real recordings passes both other gates and gets deleted with no
                # liveness gate at all, silently defeating reset-resume's D-05 invariant.
                $matchingRecordingFiles = Get-ChildItem -LiteralPath $RecordingFolderPath -Filter $RecordingFilenameGlob -File
                $candidateIsAMatchingRecording = $matchingRecordingFiles | Where-Object {
                    [string]::Equals($_.FullName, $candidateFileFullName, [System.StringComparison]::OrdinalIgnoreCase)
                }
                if (-not $candidateIsAMatchingRecording) {
                    Write-DashboardResponseBytes -Response $response -StatusCode 400 -ContentType 'application/json' `
                        -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"not a recognised recording"}')
                    break
                }

                # T-05.1-11/D-07: the SAME newest-file authority ApiRecordings/Test-
                # RecordingFileDeletable already use -- never a client isLive claim, and
                # deliberately NEVER gated on Test-PusherProcessAlive (Pattern 2 / RESEARCH
                # Anti-Patterns A3): a per-file guard is the only one immune to the exact
                # growth-race Pitfall 3 describes.
                $newestMatchingFile = Get-NewestMatchingRecordingFile -RecordingFolderPath $RecordingFolderPath -RecordingFilenameGlob $RecordingFilenameGlob
                if (-not (Test-RecordingFileDeletable -CandidateFileFullName $candidateFileFullName -NewestMatchingFile $newestMatchingFile)) {
                    Write-DashboardResponseBytes -Response $response -StatusCode 409 -ContentType 'application/json' `
                        -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"cannot delete the live recording"}')
                    break
                }

                # CR-01/Pitfall 4: Remove-Item's cmdlet failures are non-terminating
                # unless -ErrorAction Stop is passed -- the dashboard's runspace
                # (supervisor.ps1's $listenerLoopScriptBlock) never sets
                # $ErrorActionPreference = 'Stop', so without this flag a locked-file
                # failure (AV/backup/indexer holding a handle on a just-rotated file)
                # writes a non-terminating error nothing captures, and execution falls
                # through to reporting {"success":true} while the file is still on disk.
                # -ErrorAction Stop converts that failure into the terminating
                # IOException/UnauthorizedAccessException the catch blocks below expect.
                try {
                    Remove-Item -LiteralPath $candidateFileFullName -Force -ErrorAction Stop
                    Write-Log -Level Info -Message "Dashboard control: Deleted recording '$candidateFileFullName'"
                    Write-DashboardResponseBytes -Response $response -StatusCode 200 -ContentType 'application/json' `
                        -Bytes (ConvertTo-DashboardJsonBytes -Json '{"success":true}')
                } catch [System.IO.IOException] {
                    Write-DashboardResponseBytes -Response $response -StatusCode 409 -ContentType 'application/json' `
                        -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"file is currently in use -- try again in a moment"}')
                } catch [System.UnauthorizedAccessException] {
                    Write-DashboardResponseBytes -Response $response -StatusCode 409 -ContentType 'application/json' `
                        -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"file is currently in use -- try again in a moment"}')
                }
            }

            'StaticFile' {
                $resolvedPath = Resolve-DashboardStaticPath -RequestPath $urlPath -DashboardRootPath $DashboardRootPath
                if (-not $resolvedPath -or -not [System.IO.File]::Exists($resolvedPath)) {
                    Write-DashboardResponseBytes -Response $response -StatusCode 404 -ContentType 'text/plain; charset=utf-8' `
                        -Bytes (ConvertTo-DashboardJsonBytes -Json 'not found')
                    break
                }

                # Cache-Control: no-store -- a cached app.js after an operator edits it
                # is a confusing bug on a no-build-step page whose whole point is direct
                # editability.
                $response.Headers['Cache-Control'] = 'no-store'
                $fileBytes = Get-DashboardStaticFileBytes -Path $resolvedPath
                Write-DashboardResponseBytes -Response $response -StatusCode 200 `
                    -ContentType (Get-DashboardContentType -Path $resolvedPath) -Bytes $fileBytes
            }

            'MethodNotAllowed' {
                Write-DashboardResponseBytes -Response $response -StatusCode 405 -ContentType 'application/json' `
                    -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"method not allowed"}')
            }
        }
    } catch {
        try { Write-Log -Level Error -Message "Dashboard request handler fault: $($_.Exception.Message)" } catch { }
        if ($response) {
            try {
                Write-DashboardResponseBytes -Response $response -StatusCode 500 -ContentType 'application/json' `
                    -Bytes (ConvertTo-DashboardJsonBytes -Json '{"error":"internal error"}')
            } catch { }
        }
    } finally {
        if ($response) {
            try { $response.Close() } catch { }
        }
    }
}

function Start-DashboardListener {
    <#
    .SYNOPSIS
    Starts an HttpListener bound to http://localhost:$DashboardPort/ ONLY (D-22). A
    'localhost'-hostname prefix needs no admin rights and no `netsh http add urlacl`;
    binding 0.0.0.0/a wildcard prefix needs both AND puts an unauthenticated control
    surface -- one that can START and CUT a live stream -- on the church LAN. D-23
    records the condition explicitly: if LAN access is ever wanted, auth stops being
    optional in the same breath. A future "just bind it to 0.0.0.0" is a security
    decision, not a one-word diff -- this comment exists so that is recognised, not
    silently reopened.

    If .Start() fails (most commonly: another process already owns the port), rethrow
    with a message naming the port and pointing at DASHBOARD_PORT in .env --
    HttpListenerException's native text ("Failed to listen on prefix...") does not
    tell a volunteer what to change.

    .OUTPUTS
    A started [System.Net.HttpListener].
    #>
    [CmdletBinding()]
    [OutputType([System.Net.HttpListener])]
    param(
        [Parameter(Mandatory)] [int] $DashboardPort
    )

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$DashboardPort/")

    try {
        $listener.Start()
    } catch {
        throw "Dashboard listener could not bind to port $DashboardPort -- another process may already be using it. Change DASHBOARD_PORT in .env to a free port and try again. (Underlying error: $($_.Exception.Message))"
    }

    return $listener
}

function Stop-DashboardListener {
    <#
    .SYNOPSIS
    Stops and disposes an HttpListener, guarded so a shutdown path can never throw --
    a leaked listener holds the port and produces exactly the port-conflict error
    Start-DashboardListener exists to make readable, on the very next start.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Net.HttpListener] $Listener
    )

    try { $Listener.Stop() } catch { }
    try { $Listener.Close() } catch { }
}

function Invoke-DashboardListenerLoop {
    <#
    .SYNOPSIS
    Blocking accept loop: calls Listener.GetContext() and dispatches each request to
    Invoke-DashboardRequestHandler. Runspace-hosted per 05-01's HOST DECISION
    (05-SPIKE-FINDINGS.md) -- the supervisor's main thread spends a pusher run inside
    Wait-PusherProcessExit (supervisor.ps1), waiting on the pusher in 1 s polls with
    dashboard maintenance between them; a blocking GetContext() there would stop it
    reacting to the pusher's exit, and a 1 s cadence would delay every request. So this
    loop gets its OWN execution context (05-09 hosts it in a runspace) and may use the
    simple blocking .GetContext() call rather than RESEARCH.md Pattern 1's bounded-wait
    Task.WaitAny interleave -- there is nothing on this thread to starve.

    -MaxRequests bounds the loop for tests (mirrors Invoke-Supervisor's -MaxTicks seam
    exactly, same reason, same default); 0 (default) means unbounded, the production
    shape.

    GetContext() is wrapped in its OWN try/catch -- 05-01's fault-probe finding: under
    a runspace's default $ErrorActionPreference = 'Continue', an uncaught GetContext()
    exception on a stopped listener is a NON-TERMINATING error and spins forever
    rather than reaching a terminal invocation state. A caught GetContext() exception
    is treated as a normal shutdown signal (the listener was stopped) and the loop
    returns cleanly, without logging a scary Error for what is an ordinary shutdown.

    The handler dispatch itself is wrapped in a SECOND, separate try/catch: the
    handler already self-guards (Task 2, D-03), so this is defense in depth against
    anything the handler's own guard missed. Log at Error and keep looping -- a fault
    here must never stop the loop from serving the next request.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Net.HttpListener] $Listener,
        [Parameter(Mandatory)] [string] $ScriptRoot,
        [Parameter(Mandatory)] [string] $ControlFilePath,
        [Parameter(Mandatory)] [string] $StatsFilePath,
        [Parameter(Mandatory)] [string] $DashboardRootPath,
        [Parameter(Mandatory)] [string] $EnvFilePath,
        [Parameter(Mandatory)] [int] $DashboardPort,
        [string] $RecordingFolderPath = $null,
        [string] $RecordingFilenameGlob = $null,
        [string] $StateFilePath = $null,
        [string] $SrtNicName = $null,
        [string] $NicUploadLogPath = $null,
        [int] $MaxRequests = 0
    )

    $requestsServed = 0
    while (($MaxRequests -le 0) -or ($requestsServed -lt $MaxRequests)) {
        try {
            $context = $Listener.GetContext()
        } catch {
            # A stopped/closed/faulted listener surfaces here -- this is the normal
            # shutdown path (05-01 fault-probe finding), not a scary error. Return
            # cleanly rather than looping forever on a broken accept call.
            return
        }

        try {
            Invoke-DashboardRequestHandler -Context $context -ScriptRoot $ScriptRoot `
                -ControlFilePath $ControlFilePath -StatsFilePath $StatsFilePath `
                -DashboardRootPath $DashboardRootPath -EnvFilePath $EnvFilePath `
                -DashboardPort $DashboardPort -RecordingFolderPath $RecordingFolderPath `
                -RecordingFilenameGlob $RecordingFilenameGlob -StateFilePath $StateFilePath `
                -SrtNicName $SrtNicName -NicUploadLogPath $NicUploadLogPath
        } catch {
            try { Write-Log -Level Error -Message "Dashboard listener loop fault: $($_.Exception.Message)" } catch { }
        }

        $requestsServed++
    }
}

Export-ModuleMember -Function Get-DashboardViewModel, Test-DashboardRequestOrigin, Test-RecordingFileDeletable, Get-ProbePanelViewModel, Get-ProbeResultsForDashboard, Resolve-DashboardStaticPath, Get-DashboardContentType, Get-DashboardRouteMatch, Invoke-DashboardRequestHandler, Start-DashboardListener, Stop-DashboardListener, Invoke-DashboardListenerLoop

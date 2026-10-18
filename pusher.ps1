<#
.SYNOPSIS
Phase 1 entry point (D-16, D-23): a single sequential main-thread loop that wires
OffsetStore -> Tailer -> Pacer -> FfmpegProcess -> OffsetStore.Commit into one
paced tail -> stdin -> SRT loop.

Flow: restore the persisted offset, rewind by a bounded resume safety margin (D-05
-- see Start-Pusher), open the recording file and seek to that resume position,
start ffmpeg, then loop every pollIntervalMilliseconds: consult the Pacer using the
observed growth rate to decide Wait/Throttle/ReadFast BEFORE reading (D-11/D-12 --
this deliberately maintains a 5-10s buffer behind live rather than draining the
instant bytes appear); on Throttle/ReadFast, read a stable 188-aligned chunk and
write it to ffmpeg's stdin; the offset advances and is committed ONLY after that
Write() call returns (D-04), at the bounded cadence of every 250 ms or 256 KB,
whichever first (D-07). If ffmpeg's stdin write hangs past the watchdog timeout,
FfmpegProcess kills it and signals RestartNeeded -- this loop seeks the FileStream
back by the unsent chunk's length (never skip bytes, D-05) and restarts ffmpeg
before retrying.

Phase 1 scope only (D-16): no runspaces, no jobs, no dashboard (Phase 5+). Phase 2
added reconnect/backoff; Phase 3 added folder+glob rotation detection and the
two-signal end-of-service gate (this file). Configuration lives in top-of-script
variables (D-19) -- no .env yet, that is Phase 4 scope.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Exit-code contract (D-12/SVC-01): 0 = clean end-of-service (Start-Pusher's own
# terminal branch, below) -- the Scheduled Task must NOT relaunch after a
# legitimate service end. $script:ExitCodeConfigError (2) = config validation
# failure (D-08), distinct from an unexpected crash (any other non-zero exit,
# e.g. an uncaught exception) so a config-error restart storm is
# distinguishable from a transient crash in Task Scheduler's history (T-04-13).
# Code 4 (261018) = another pusher of this install holds the per-install Pusher mutex;
# this one stood down before it touched the offset, the control flag, the recording or
# ffmpeg, so the supervisor waits instead of counting a crash.
# ---------------------------------------------------------------------------
$script:ExitCodeConfigError = 2
# Front C (260718-j58/Task 3/EOS-DRAIN-01): a bounded end-of-service give-up with
# undelivered backlog still on disk (recoverable from the exact persisted offset) --
# distinct from both a fully-drained clean finish (0) and a config error (2), so
# supervisor.ps1 can map it to its own honest StayDown reason
# ('finished-with-undelivered-backlog') rather than either of those two existing tokens.
$script:ExitCodeUndeliveredBacklog = 3
# Another pusher for this install is already running (261018, B6): the per-install Pusher
# mutex is held. Exiting here, before any state is touched, is what makes a supervisor
# relaunch safe next to a pusher that outlived its supervisor.
$script:ExitCodeAnotherPusherRunning = 4
# How long a starting pusher waits for the Pusher mutex before standing down. Long enough
# for a predecessor that is still releasing it (a cut and an immediate start); short
# enough that a genuine duplicate does not linger.
$script:PusherSingleInstanceWaitSeconds = 15
# The directory that names this install's Pusher mutex. Production: the script's own
# directory, the same root the supervisor derives its probe name from. A single
# top-of-script line so tests that run a scratch copy of this script from the repo root
# can point it at a throwaway path and never take the production mutex.
$pusherSingleInstanceScopeRoot = $PSScriptRoot
# The single terminal exit-code holder (Task 4 sets this to 3 on a bounded drain
# give-up); a fully-drained finish leaves it at 0, matching the pre-existing contract.
$script:pusherTerminalExitCode = 0

# ---------------------------------------------------------------------------
# Config + Logging module imports (CFG-01/D-08) -- these two must be available
# BEFORE the config load/validate decision, and before any hot-path module
# (OffsetStore/Tailer/Pacer/FfmpegProcess/Backoff/Rotation) is imported below,
# so a bad .env fails fast, before ffmpeg or the recording file is ever touched.
# ---------------------------------------------------------------------------
Import-Module (Join-Path $PSScriptRoot 'lib/Logging.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Config.psm1') -Force

# ---------------------------------------------------------------------------
# Load + validate .env (CFG-01/D-08/D-19's graduation to real config, Phase 4).
# $envPath stays a single top-of-script assignment line, mirroring the pattern
# New-TestTunedPusherCopy already uses for other tuning vars (tests/TestHelpers.psm1).
# ---------------------------------------------------------------------------
$envPath = Join-Path $PSScriptRoot '.env'
$config = Read-PusherConfig -Path $envPath

# Anchor CWD-relative .env-sourced paths to the script directory (D-04) BEFORE
# validating, so Test-PusherConfig checks the same resolved path the hot loop
# will actually use -- a Scheduled Task launches with CWD = %windir%\system32,
# so a relative recording/state path must never be trusted, or validated, as-is
# (replaces the old WR-03 literal block; the anchoring now lives in Config.psm1).
$config = Resolve-PusherConfigPaths -Config $config -ScriptRoot $PSScriptRoot

$configProblems = Test-PusherConfig -Config $config
if ($configProblems.Count -gt 0) {
    foreach ($configProblem in $configProblems) {
        Write-Log -Level Error -Message "Config validation failed: $configProblem"
    }
    exit $script:ExitCodeConfigError
}

# Inject the loaded log directory + size/count into Logging (D-14/D-15) before
# any further logging, so logs are bounded and Session-0-safe from the first
# real log line onward. The log directory is anchored the same way as the
# recording/state paths above (D-04) -- it is not itself an .env override
# (D-06 keeps the log location off the operator-facing surface), so this stays
# a fixed script-root-relative path, wired explicitly here rather than relying
# on Logging.psm1's own internal default.
Set-LogDirectory -Path (Join-Path $PSScriptRoot 'state/logs')
Set-LogRotationPolicy -MaxSizeBytes $config.LogMaxSizeBytes -RetentionCount $config.LogRetentionCount

# Single-instance guard (261018, B6): one pusher per install. A supervisor that died
# mid-service can leave its pusher running, and the five-minute watchdog then starts a new
# supervisor; two pushers on one recording would replay old content to YouTube
# (2026-09-13). The guard sits before the 'Config loaded' line and every hot-path import,
# so a loser has touched no offset, control flag, recording or ffmpeg when it exits. A
# crashed or killed holder leaves the mutex abandoned, which counts as free.
Import-Module (Join-Path $PSScriptRoot 'lib/SupervisorSingleInstance.psm1') -Force
$script:PusherSingleInstanceMutex = Enter-SupervisorSingleInstance -MutexName (Get-SupervisorSingleInstanceMutexName -ScriptRoot $pusherSingleInstanceScopeRoot -Role 'Pusher') -WaitSeconds $script:PusherSingleInstanceWaitSeconds
if ($null -eq $script:PusherSingleInstanceMutex) {
    Write-Log -Level Warning -Message "Another pusher for this install ('$PSScriptRoot') is already running ($(Get-ProcessIdentityLogText)) -- this pusher exits without touching the offset, the control flag, the recording or ffmpeg."
    exit $script:ExitCodeAnotherPusherRunning
}

# Redacted config summary (D-07/T-04-12): the SRT passphrase is never logged,
# set or blank -- Get-RedactedConfig masks it before this line ever sees it.
Write-Log -Level Info -Message "Config loaded and validated: $(Get-RedactedConfig -Config $config | ConvertTo-Json -Compress)"

# ---------------------------------------------------------------------------
# Hot-path module imports (D-23) -- only reached once config has validated.
# ---------------------------------------------------------------------------
Import-Module (Join-Path $PSScriptRoot 'lib/OffsetStore.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Tailer.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Pacer.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/FfmpegProcess.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Backoff.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Rotation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/ControlFlag.psm1') -Force
# Clock.psm1/StatsStore.psm1 (05-06, the D-15 rework): the shared monotonic clock
# (replacing this file's own former private copy, see Get-MonotonicSeconds's removal
# below) and the state/stats.json publisher supervisor.ps1's dashboard reads.
Import-Module (Join-Path $PSScriptRoot 'lib/Clock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/StatsStore.psm1') -Force

# ---------------------------------------------------------------------------
# Bind the existing script-scoped tuning variables from $config (D-19's
# graduation to .env, Phase 4/CFG-01). Each stays a single top-of-script
# `$var = ...` assignment line so New-TestTunedPusherCopy's regex rewrite
# (tests/TestHelpers.psm1) and Start-Pusher's own reads of these names both
# keep working unchanged.
# ---------------------------------------------------------------------------
$recordingFolderPath          = $config.RecordingFolderPath      # OBS recording folder to watch (D-01)
$recordingFilenameGlob        = $config.RecordingFilenameGlob    # OBS output filename pattern (D-01)
$relayHost                   = $config.RelayHost                # SRT relay target host
$relayPort                   = $config.RelayPort                # SRT relay target port
$relayProtocol               = $config.RelayProtocol            # 'srt' (tunnel path) or 'tcp' (raw mpegts over MPTCP-proxied TCP; 2026-07-26 ARQ-storm escape)
$latencyMicroseconds         = $config.LatencyMicroseconds       # SRT latency, microseconds (D-19)
$srtMaxBandwidthBytesPerSecond = $config.SrtMaxBandwidthBytesPerSecond # SRT maxbw ceiling on aggregate send incl. retransmits; prevents uncapped-ARQ congestion collapse (debug/srt-throughput-degraded-today.md); 0 = unlimited
$srtSendBufferBytes          = $config.SrtSendBufferBytes         # TIER 1: SRT sndbuf; larger sender buffer rides a loss burst before stdin backpressure; 0 = omit (debug/srt-throughput-degraded-today.md)
$srtFlightFlagSizeBytes      = $config.SrtFlightFlagSizeBytes     # TIER 1: SRT ffs (flow-control window, packets); match relay 65536; 0 = omit
$srtLossMaxTtl               = $config.SrtLossMaxTtl              # TIER 1: SRT lossmaxttl (reorder tolerance); match relay 4096; 0 = omit
$srtNakReport                = $config.SrtNakReport              # TIER 1: SRT nakreport (loss signalling); '' = omit (libsrt auto), 'true'/'false' explicit
$streamId                    = $config.StreamId                  # SRT streamid
$packetSizeBytes             = $config.PacketSizeBytes           # SRT pkt_size, 7 * 188 (D-19)
$lingerSeconds                = $config.LingerSeconds            # SRT drain-before-close (01-01 spike deviation)
$chunkSizeBytes               = $config.ChunkSizeBytes           # 348 * 188 bytes, ~64 KB (D-14)
$pollIntervalMilliseconds     = $config.PollIntervalMilliseconds # file poll interval (D-13)
$stateFilePath                = $config.StateFilePath            # crash-safe persisted offset (D-08)
$persistIntervalMilliseconds  = $config.PersistIntervalMilliseconds # offset commit cadence bound (D-07)
$persistIntervalBytes         = $config.PersistIntervalBytes     # 256 KB, offset commit cadence bound (D-07)
$watchdogTimeoutMilliseconds  = $config.WatchdogTimeoutMilliseconds # stdin Write() hang timeout (D-18)
$coldStartResumeMarginBytes   = $config.ColdStartResumeMarginBytes # cold-start resume margin fallback, no rate observed yet (D-12/Pattern 3)
$targetLowSeconds             = $config.TargetLowSeconds         # pacing healthy-band low bound (D-12)
$targetHighSeconds            = $config.TargetHighSeconds        # pacing healthy-band high bound (D-12)
$backoffBaseMilliseconds      = $config.BackoffBaseMilliseconds  # full-jitter backoff base, ms (D-02)
$backoffCeilingMilliseconds   = $config.BackoffCeilingMilliseconds # full-jitter backoff ceiling, ms (D-02)
$ffmpegCrashRestartDelayMilliseconds = $config.FfmpegCrashRestartDelayMilliseconds # short fixed delay for FfmpegCrash, ms -- never the exponential schedule (Anti-Patterns)
$catchUpMultiplier            = $config.CatchUpMultiplier        # ReadFast send-rate cap, x observed growth rate (D-06; default 1.5, Pitfall 4)
$absoluteSendCeilingBytesPerSecond = $config.SendCeilingBytesPerSecond # when > 0, absolute send cap REPLACING the multiplier x record-rate ceiling (decouples send rate from OBS bitrate)
$coldStartCatchUpCeilingBytesPerSecond = $config.ColdStartCatchUpCeilingBytesPerSecond # ~6 Mbit/s conservative absolute cap before a rate is observed (D-07)
$growthRateSmoothingSeconds   = $config.GrowthRateSmoothingSeconds # EWMA time-constant for the growth-rate estimate (260718-h23/DASH-BRIEF-1/2); <=0 disables smoothing (raw passthrough)
$srtLatencySeconds            = $latencyMicroseconds / 1000000.0   # SRT latency in seconds, feeds the D-12 margin formula
$resumeMarginFloorBytes       = $config.ResumeMarginFloorBytes   # >= one chunk (D-12)
$resumeMarginCeilingBytes     = $config.ResumeMarginCeilingBytes # 2 MB safety ceiling on the resume re-send margin (D-12)
$sustainedHealthyWindowSeconds = $config.SustainedHealthyWindowSeconds # backoff attempt-counter reset threshold, > ceiling (Pitfall 4)
$sessionResumeStaleAfterSeconds = $config.SessionResumeStaleAfterSeconds # SESS-01/D-01/D-02: a resolved resume file last written longer ago than this is a prior session, not this one
$recordingStartStaleAfterSeconds = $config.RecordingStartStaleAfterSeconds # START-STALE-01/260809-ow9: guards ONLY Start-Pusher's initial file pick (null-resume branch), never the mid-session rotation path
$srtConnectionTimeoutMicroseconds = $config.SrtConnectionTimeoutMicroseconds # explicit SRT connection-ESTABLISHMENT bound only -- confirmed (02-07) to have no effect on post-connection dead-peer detection latency; see lib/FfmpegProcess.psm1's $script:DefaultSrtConnectionTimeoutMicroseconds
# RES-01 bug fix (02-07): using only $srtLatencySeconds (500ms) as the resume margin's
# latency input left a real, empirically-confirmed permanent-gap window in a mid-push
# SRT-listener-kill integration test -- once the listener dies, ffmpeg's SRT caller does
# NOT notice for a while (this ffmpeg/libsrt build's own internal dead-peer detection,
# NOT bounded by any ffmpeg-exposed option here, per CLAUDE.md's "ffmpeg does NOT give
# you this" SRT caveat), so the pusher keeps ACCEPTING (and committing, D-04) stdin bytes
# that can never reach any listener during that whole silent window. 02-07's integration
# test measured this delay directly (repeated hard repro, ffmpeg process alone, no
# pusher.ps1 involved) at a stable ~5.4-5.5s regardless of the (ineffective) timeout=
# setting above -- $networkDeathDetectionDelaySeconds below is set comfortably above that
# measured ceiling (D-05 bias: prefer re-send/over-cover over any risk of under-covering
# and permanently skipping bytes). This is an EMPIRICALLY-DERIVED safety constant, not a
# configured/guaranteed bound -- re-measure if the ffmpeg/libsrt build ever changes.
$networkDeathDetectionDelaySeconds = $config.NetworkDeathDetectionDelaySeconds
$resumeMarginLatencySeconds    = $srtLatencySeconds + $networkDeathDetectionDelaySeconds
$ffmpegPath                   = $config.FfmpegPath               # override for tests
$obsProcessName                = $config.ObsProcessName          # OBS process name for liveness check (D-07/D-09)
$growthStallSustainedWindowSeconds = $config.GrowthStallSustainedWindowSeconds # two-signal primary stall window, seconds (D-07)
$growthStallDegradedWindowSeconds  = $config.GrowthStallDegradedWindowSeconds  # 3x primary, liveness-uninspectable fallback (D-09)
$srtStallToleranceSeconds      = $config.SrtStallToleranceSeconds # Front A (260718-j58): bounded ceiling the pusher holds ONE SRT session through transient backpressure before escalating to the existing NetworkDeath reconnect path
$endOfServiceReconnectMaxDurationSeconds = $config.EndOfServiceReconnectMaxDurationSeconds # Front C (260718-j58/Task 4): bounded give-up ceiling (wall-clock) for the end-of-service drain's reconnect-through-a-relay-drop behavior
$endOfServiceReconnectMaxAttempts        = $config.EndOfServiceReconnectMaxAttempts        # Front C (260718-j58/Task 4): bounded give-up ceiling (attempt count) for the same drain reconnect behavior
$obsLivenessOverride           = $null                  # override for tests (test-injection scriptblock, D-09) -- not a Config.psm1 schema key (04-01 decision, YAGNI)
# The operator's control flag (locked extension item 6): the SAME file start.ps1 /
# stop.ps1 / cut.ps1 and Phase 5's dashboard buttons write. Resolved through
# Get-PusherControlFilePath rather than repeating the literal, so the file the pusher
# reads can never drift from the file the operator's Stop writes. Deliberately NOT an
# .env key -- it is a fixed script-root-relative location like state/logs (D-06), and
# it stays a single top-of-script `$var = ...` assignment line so
# New-TestTunedPusherCopy's regex rewrite (tests/TestHelpers.psm1) can point a tuned
# copy at its own scratch flag instead of this machine's live one.
$controlFilePath               = Get-PusherControlFilePath -ScriptRoot $PSScriptRoot
# stats.json (05-06, the D-15 rework): resolved as a SIBLING of the already-anchored
# $stateFilePath (state/offset.json -> state/stats.json) rather than a second
# independent Join-Path $PSScriptRoot -- this way a test's tuned $stateFilePath
# override (New-TestTunedPusherCopy) carries $statsFilePath along with it into the
# same scratch state/ directory automatically, with no separate test-harness
# override needed. Production resolves next to the real state/offset.json, exactly
# like $controlFilePath resolves next to state/control.json.
$statsFilePath                 = Join-Path (Split-Path -Parent $stateFilePath) 'stats.json'

function Get-ResolvedObsLiveness {
    <#
    .SYNOPSIS
    Resolves OBS liveness via $obsLivenessOverride when set (a test-injection
    scriptblock, D-09 testability) -- otherwise via a real Test-ObsProcessLiveness
    process-table check against $obsProcessName. Reads the top-of-script config
    variables directly, matching Start-Pusher's own existing convention.
    #>
    [CmdletBinding()]
    [OutputType([bool], [System.Nullable[bool]])]
    param()

    if ($obsLivenessOverride -is [scriptblock]) {
        return & $obsLivenessOverride
    }
    return Test-ObsProcessLiveness -ProcessName $obsProcessName
}

function Get-ResolvedExplicitStopRequest {
    <#
    .SYNOPSIS
    Resolves the operator's explicit stop (locked extension item 6) from the control
    flag at $controlFilePath -- $true ONLY when the file explicitly says
    desired='stopped'. Mirrors Get-ResolvedObsLiveness: its whole job is to read the
    top-of-script config variable so the gate below can stay callable with an unchanged
    parameter shape from every existing call site.

    A missing or unreadable flag is NOT a stop (Test-PusherExplicitStopRequested's
    header explains why at length): silence is not a stop, and a live church service
    must never end on the strength of a parse error.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return (Test-PusherExplicitStopRequested -ControlFilePath $controlFilePath)
}

function Update-PusherStateForEndOfService {
    <#
    .SYNOPSIS
    The end-of-service gate (D-07/D-09/Pitfall 1), extracted once (WR-03) so
    Start-Pusher's call sites can never independently drift out of sync (a future
    tuning fix applied to one copy and missed in the other would silently reintroduce
    either a false-stop or a no-stop regression in exactly the gate this phase exists
    to get right). The locked extension's third signal was added HERE, in the one
    gate, rather than sprinkled at the call sites, for the same reason.

    A no-op unless PusherState.Value is currently 'Streaming' (D-02: rotation/drain
    already in progress is never re-evaluated here). Transitions PusherState.Value to
    'Draining' and logs exactly once, only when the combiner
    (Get-EndOfServiceDecision) actually returns 'Draining'.

    -ExplicitSignalOnly is what makes the per-tick call site affordable and safe. It
    means "only the operator's flag may fire here", and it buys two things:
      * No Get-Process per tick. Get-ResolvedObsLiveness scans the process table; the
        per-tick site runs every poll interval for the whole service, the two Phase 3
        sites only run on idle paths.
      * The automatic two-signal gate stays EXACTLY where Phase 3 put it. Letting the
        heuristics fire per-tick would let them fire while a large backlog is still
        un-sent, and the final-drain loop disables pacing -- so an OBS-death detected
        mid-catch-up would burst the whole backlog past the catch-up cap, congesting
        the bonded WAN this project is capped to protect. This extension ADDS a
        signal; it changes nothing about the automatic case.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double] $GrowthStalledSeconds,
        [Parameter(Mandatory)] [double] $SustainedWindowSeconds,
        [Parameter(Mandatory)] [double] $DegradedWindowSeconds,
        [Parameter(Mandatory)] [ref] $PusherState,
        [switch] $ExplicitSignalOnly
    )

    if ($PusherState.Value -ne 'Streaming') {
        return
    }

    $explicitStopRequested = Get-ResolvedExplicitStopRequest
    if ($ExplicitSignalOnly -and -not $explicitStopRequested) {
        return
    }

    $obsLivenessResult = Get-ResolvedObsLiveness
    $endOfServiceDecision = Get-EndOfServiceDecision -GrowthStalledSeconds $GrowthStalledSeconds `
        -ObsLivenessResult $obsLivenessResult -SustainedWindowSeconds $SustainedWindowSeconds `
        -DegradedWindowSeconds $DegradedWindowSeconds -ExplicitStopRequested $explicitStopRequested

    if ($endOfServiceDecision -ne 'Draining') {
        return
    }

    $PusherState.Value = 'Draining'
    if ($explicitStopRequested) {
        # Distinct from both heuristic lines below on purpose: the operator reading
        # this at 10:55 on a Sunday must be able to tell "I stopped this" apart from
        # "the pusher decided the service was over", because those two lines lead to
        # completely different next actions.
        Write-Log -Level Warning -Message "Explicit operator stop (control flag desired=stopped) -- draining the remaining backlog before exiting, no heuristic window consulted (OBS liveness=$obsLivenessResult, growth stalled ${GrowthStalledSeconds}s)"
    } elseif ($null -eq $obsLivenessResult) {
        Write-Log -Level Warning -Message "End-of-service detected on the weaker degraded single signal (OBS liveness uninspectable, D-09): growth stalled ${GrowthStalledSeconds}s -- draining final tail (D-07/D-11)"
    } else {
        Write-Log -Level Warning -Message "End-of-service detected (OBS liveness=$obsLivenessResult, growth stalled ${GrowthStalledSeconds}s) -- draining final tail (D-07/D-11)"
    }
}

function Get-StatsWindowAverageBytesPerSecond {
    <#
    .SYNOPSIS
    Defensive accessor (05-06/D-05/T-05-11) for a Pacer.psm1 growth-rate window's
    .AverageBytesPerSecond: $growthRateWindow/$sendRateWindow both START as a plain
    empty array (@()) and only become the hashtable Update-GrowthRateWindow returns
    once that function has actually run at least once this session/rotation. A
    stats publish reached before that first call (only realistically possible from
    the `finally` block, if the hot loop throws before its first iteration
    completes) would otherwise read .AverageBytesPerSecond off a plain array under
    Set-StrictMode -Version Latest -- and that throw would happen while EVALUATING
    Publish-PusherStats' arguments, in the CALLER's scope, before Publish-PusherStats'
    own try/catch is ever entered, so it could NOT be swallowed there. Returns 0.0 for
    that untouched state -- the same "no rate observed yet" sentinel
    Update-GrowthRateWindow itself returns for a fresh window.

    -Smoothed (260718-h23/DASH-BRIEF-1/2): when set, returns the window's
    .SmoothedBytesPerSecond instead -- the EWMA value the dashboard's send/record
    bitrate now displays, so the operator's number matches the number driving
    pacing/the catch-up cap. Falls through to the exact same
    AverageBytesPerSecond/0.0 logic above when the window is untouched (plain
    array) OR does not carry a SmoothedBytesPerSecond key, keeping the
    StrictMode-safe guard intact for both accessor modes.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param($Window, [switch] $Smoothed)

    if ($Smoothed -and $Window -is [hashtable] -and $Window.ContainsKey('SmoothedBytesPerSecond')) {
        return $Window.SmoothedBytesPerSecond
    }
    if ($Window -is [hashtable] -and $Window.ContainsKey('AverageBytesPerSecond')) {
        return $Window.AverageBytesPerSecond
    }
    return 0.0
}

function Publish-PusherStats {
    <#
    .SYNOPSIS
    Wraps Save-PusherStats (lib/StatsStore.psm1) so a stats write can NEVER reach the
    hot path's failure surface (D-05/T-05-11): the whole body is a try/catch that logs
    a Warning and swallows. A stats write is a nice-to-have; Save-PusherStats rethrows
    after 5 failed atomic-rename attempts (a scanner holding a momentary handle on
    stats.json is an observed real failure, per lib/StatsStore.psm1's own header), and
    this script runs under $ErrorActionPreference = 'Stop' (top of this file) --
    an unwrapped call would let that rare contention kill a live service.
    -WarningAction Continue is pinned explicitly on the Write-Log call (not just
    relying on Write-Log's own internal pin) for the same reason 02-07 pinned it at
    every other loud call site in this codebase: Write-Log is an implicit advanced
    function (it declares [Parameter(Mandatory)] parameters), so it inherits this
    script's ambient $ErrorActionPreference/$WarningActionPreference from the caller
    unless a caller explicitly overrides it, and a Warning-level log must never become
    a terminating call here (D-10).
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
        [Nullable[double]] $SessionStartEpochSeconds = $null
    )

    try {
        Save-PusherStats -StatsFilePath $StatsFilePath -PusherState $PusherState `
            -RecordingFilePath $RecordingFilePath -OffsetBytes $OffsetBytes -FileLengthBytes $FileLengthBytes `
            -SendBytesPerSecond $SendBytesPerSecond -RecordBytesPerSecond $RecordBytesPerSecond `
            -SecondsBehindLive $SecondsBehindLive -BackoffAttemptNumber $BackoffAttemptNumber `
            -CumulativeReconnectCount $CumulativeReconnectCount -LastClassificationCause $LastClassificationCause `
            -CatchUpCapUtilization $CatchUpCapUtilization -OutageActive $OutageActive -StaleWithinSeconds $StaleWithinSeconds `
            -LastSuccessfulSendEpochSeconds $LastSuccessfulSendEpochSeconds -SessionStartEpochSeconds $SessionStartEpochSeconds `
            -RelayProtocol $relayProtocol
    } catch {
        Write-Log -Level Warning -WarningAction Continue -Message "Stats publish to '$StatsFilePath' failed -- the stream is unaffected (D-05/T-05-11, nice-to-have only): $($_.Exception.Message)"
    }
}

function Invoke-PusherReconnectEscalation {
    <#
    .SYNOPSIS
    The ONE reconnect+resume escalation action (D-02/D-05/D-11/D-12, Front A/260718-j58)
    -- classifies the outage start log line, backs off, rewinds $FileStream by the D-12
    dynamic margin (byte-exact, never skips), publishes outage stats with a widened
    staleness deadline, sleeps, and restarts ffmpeg. Every call site that decides a
    write failure is genuine death (or a stall past the bounded
    SRT_STALL_TOLERANCE_SECONDS ceiling) calls THIS ONE function -- the mid-stream
    write-failure branch, the top-of-loop pending-write resolution (Task 2), and the
    end-of-service drain branch (Task 4) -- never a second, parallel reconnect path.

    The offset is left exactly where the caller has it (frozen, D-04) -- this function
    never advances or commits $LastAcceptedPositionValue; only a subsequent successful
    write does that.

    .OUTPUTS
    PSCustomObject: FfmpegHandle (the new handle from Start-FfmpegProcess),
    BackoffAttemptNumber (updated), ReconnectDelayMilliseconds (the delay just slept).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $ExitClassification,
        [Parameter(Mandatory)] [System.IO.FileStream] $FileStream,
        [Parameter(Mandatory)] [long] $UnsentChunkLengthBytes,
        [Parameter(Mandatory)] [double] $RawObservedBytesPerSecond,
        [Parameter(Mandatory)] [PSCustomObject] $FfmpegHandle,
        [Parameter(Mandatory)] [string[]] $FfmpegArgumentList,
        [Parameter(Mandatory)] [string] $FfmpegPathValue,
        [Parameter(Mandatory)] [int] $BackoffAttemptNumberValue,
        [Parameter(Mandatory)] [hashtable] $ResilienceState,
        [Parameter(Mandatory)] [double] $SecondsBehindLiveValue,
        [Parameter(Mandatory)] [int] $BackoffBaseMillisecondsValue,
        [Parameter(Mandatory)] [int] $BackoffCeilingMillisecondsValue,
        [Parameter(Mandatory)] [int] $FfmpegCrashRestartDelayMillisecondsValue,
        [Parameter(Mandatory)] [double] $ResumeMarginLatencySecondsValue,
        [Parameter(Mandatory)] [long] $ChunkSizeBytesValue,
        [Parameter(Mandatory)] [long] $ResumeMarginFloorBytesValue,
        [Parameter(Mandatory)] [long] $ResumeMarginCeilingBytesValue,
        [Parameter(Mandatory)] [long] $ColdStartResumeMarginBytesValue,
        [Parameter(Mandatory)] [string] $StatsFilePathValue,
        [Parameter(Mandatory)] [string] $PusherStateValue,
        [Parameter(Mandatory)] [string] $CurrentRecordingFilePathValue,
        [Parameter(Mandatory)] [long] $LastAcceptedPositionValue,
        [Parameter(Mandatory)] $SendRateWindowValue,
        [Parameter(Mandatory)] $GrowthRateWindowValue,
        [Nullable[double]] $LastSuccessfulSendEpochSecondsValue = $null,
        [Nullable[double]] $SessionStartEpochSecondsValue = $null
    )

    # Force-stop ffmpeg if it is still alive (T-j58-01): a 'Fault' outcome has already
    # been stopped inside FfmpegProcess.psm1 (Write-FfmpegStdin/
    # Wait-FfmpegStdinPendingWrite's own Fault path), so this is a safe no-op there --
    # but a stall-past-tolerance escalation reaches here with the OLD process STILL
    # ALIVE (deliberately never killed while merely held), and it is about to be
    # abandoned in favor of a fresh Start-FfmpegProcess below. Skipping this would leak
    # the old, permanently-stuck process (and, in tests, any of its own child processes)
    # instead of cleanly tearing it down.
    Stop-FfmpegProcess -ProcessHandle $FfmpegHandle -Force

    if (-not $ResilienceState.OutageActive) {
        Write-Log -Level Warning -Message "Outage start -- delay-behind-live is ${SecondsBehindLiveValue}s and growing (write failure detected, cause=$ExitClassification)"
        $ResilienceState.OutageActive = $true
    }

    $newBackoffAttemptNumber = $BackoffAttemptNumberValue
    if ($ExitClassification -eq 'NetworkDeath' -or $ExitClassification -eq 'RecordingEnded') {
        $newBackoffAttemptNumber++
        $ResilienceState.CumulativeReconnectCount++
        $reconnectDelayMilliseconds = Get-NextBackoffDelayMilliseconds -AttemptNumber $newBackoffAttemptNumber `
            -BaseMilliseconds $BackoffBaseMillisecondsValue -CeilingMilliseconds $BackoffCeilingMillisecondsValue
    } else {
        $reconnectDelayMilliseconds = $FfmpegCrashRestartDelayMillisecondsValue
    }
    $ResilienceState.BackoffAttemptNumber    = $newBackoffAttemptNumber
    $ResilienceState.LastClassificationCause = $ExitClassification

    # DELIBERATE (260718-h23/T-h23-I1): the RAW observed rate, never the smoothed one --
    # see pusher.ps1's own historical comment on this exact calculation for why.
    $dynamicResumeMarginBytes = Get-ResumeSafetyMarginBytes -SrtLatencySeconds $ResumeMarginLatencySecondsValue `
        -ObservedBytesPerSecond $RawObservedBytesPerSecond -ChunkSizeBytes $ChunkSizeBytesValue `
        -FloorBytes $ResumeMarginFloorBytesValue -CeilingBytes $ResumeMarginCeilingBytesValue `
        -ColdStartMarginBytes $ColdStartResumeMarginBytesValue
    $restartSeekPosition = [Math]::Max([long]0, $FileStream.Position - $UnsentChunkLengthBytes - $dynamicResumeMarginBytes)
    $restartSeekPosition -= ($restartSeekPosition % 188)
    $FileStream.Seek($restartSeekPosition, [System.IO.SeekOrigin]::Begin) | Out-Null

    Write-Log -Level Warning -Message "ffmpeg exit classified as $ExitClassification -- reconnecting in ${reconnectDelayMilliseconds}ms (attempt $newBackoffAttemptNumber), resuming from position $($FileStream.Position) (margin $dynamicResumeMarginBytes bytes), delay-behind-live ${SecondsBehindLiveValue}s"

    Publish-PusherStats -StatsFilePath $StatsFilePathValue -PusherState $PusherStateValue `
        -RecordingFilePath $CurrentRecordingFilePathValue -OffsetBytes $LastAcceptedPositionValue -FileLengthBytes $FileStream.Length `
        -SendBytesPerSecond (Get-StatsWindowAverageBytesPerSecond -Window $SendRateWindowValue -Smoothed) `
        -RecordBytesPerSecond (Get-StatsWindowAverageBytesPerSecond -Window $GrowthRateWindowValue -Smoothed) `
        -SecondsBehindLive $SecondsBehindLiveValue -BackoffAttemptNumber $newBackoffAttemptNumber `
        -CumulativeReconnectCount $ResilienceState.CumulativeReconnectCount -LastClassificationCause $ResilienceState.LastClassificationCause `
        -CatchUpCapUtilization $ResilienceState.CatchUpCapUtilization -OutageActive $ResilienceState.OutageActive `
        -StaleWithinSeconds ((($reconnectDelayMilliseconds / 1000.0)) + 3.0) `
        -LastSuccessfulSendEpochSeconds $LastSuccessfulSendEpochSecondsValue -SessionStartEpochSeconds $SessionStartEpochSecondsValue

    Start-Sleep -Milliseconds $reconnectDelayMilliseconds
    $newFfmpegHandle = Start-FfmpegProcess -ArgumentList $FfmpegArgumentList -FfmpegPath $FfmpegPathValue

    return [pscustomobject]@{
        FfmpegHandle              = $newFfmpegHandle
        BackoffAttemptNumber      = $newBackoffAttemptNumber
        ReconnectDelayMilliseconds = $reconnectDelayMilliseconds
    }
}

function Start-Pusher {
    <#
    .SYNOPSIS
    Wires OffsetStore -> Tailer -> Pacer -> FfmpegProcess -> OffsetStore.Commit into
    one sequential paced tail -> stdin -> SRT loop (D-16). Runs until the process is
    stopped externally (Ctrl+C, Stop-Process, or a hard kill for the resume tests).
    #>
    [CmdletBinding()]
    param()

    Write-Log -Level Info -Message "Pusher starting ($(Get-ProcessIdentityLogText)) -- recordingFolder='$recordingFolderPath' filenameGlob='$recordingFilenameGlob' relay=$relayHost`:$relayPort streamId=$streamId"

    # 260718-epo/FEAT-B: captured ONCE at Start-Pusher entry (system-wide monotonic,
    # comparable across the supervisor/dashboard process, D-A3) and threaded through
    # every Publish-PusherStats call site this session so the dashboard can derive
    # LiveUptimeSeconds (now - this) while streaming and SessionDurationSeconds
    # (updatedEpochSeconds - this) on the finished screen -- never re-captured mid-loop.
    $sessionStartEpochSeconds = Get-MonotonicSeconds

    $restoredState = Restore-PusherOffset -StateFilePath $stateFilePath
    Write-Log -Level Info -Message "Restored offset: $($restoredState.byteOffset) bytes"

    # Reconcile the restored offset against the persisted file itself (D-14): a
    # persisted file differing from "the newest file in the folder" is the EXPECTED
    # post-rotation-resume case, not corruption -- only a missing file or an offset
    # past that file's own length resets to 0 (re-send bias, D-05). This replaces
    # Phase 1/2's same-path/oversize-only guard (CR-06).
    $resolvedResumeState = Resolve-ResumeOffset -RestoredState $restoredState -RecordingFolderPath $recordingFolderPath

    # SESS-01 session-freshness check (D-01/D-02): a resolved resume file whose
    # LastWriteTime is older than $sessionResumeStaleAfterSeconds is a FINISHED PRIOR
    # SESSION, not this one -- Start must follow today's newest recording at offset 0
    # instead of trusting a stale file. This only ever nulls $resolvedResumeState.file;
    # the existing null-file branch below (already correct, D-14) re-resolves via
    # Get-NewestMatchingRecordingFile -- Resolve-ResumeOffset itself is NEVER edited to
    # add this comparison (Pitfall 2, would break the locked D-14 rotation-resume
    # regression test). Get-Item is wrapped in try/catch so a TOCTOU delete of the
    # resolved file between Resolve-ResumeOffset and here degrades to "not same
    # session, start fresh" rather than crashing Start-Pusher under
    # $ErrorActionPreference = 'Stop' (T-05.1-04).
    if ($resolvedResumeState.file) {
        $resolvedFileLastWriteTimeUtc = $null
        try {
            $resolvedFileLastWriteTimeUtc = (Get-Item -LiteralPath $resolvedResumeState.file).LastWriteTimeUtc
        } catch {
            Write-Log -Level Warning -Message "SESS-01: could not read LastWriteTimeUtc for resolved resume file '$($resolvedResumeState.file)' -- treating as not-same-session, starting fresh: $($_.Exception.Message)"
        }

        # $null LastWriteTimeUtc (the Get-Item TOCTOU-delete catch above) always means
        # "not same session" -- Test-ResumeStateSameSession is a pure function and is
        # never called with a $null DateTime (T-05.1-04).
        $isResumeStateSameSession = ($null -ne $resolvedFileLastWriteTimeUtc) -and (Test-ResumeStateSameSession `
            -ResolvedFileLastWriteTimeUtc $resolvedFileLastWriteTimeUtc -NowUtc ([DateTime]::UtcNow) `
            -SessionStaleAfterSeconds $sessionResumeStaleAfterSeconds)

        if (-not $isResumeStateSameSession) {
            $resumeFileAgeDescription = if ($null -ne $resolvedFileLastWriteTimeUtc) {
                "$([Math]::Round((([DateTime]::UtcNow) - $resolvedFileLastWriteTimeUtc).TotalSeconds))s ago"
            } else {
                'unknown (file unreadable)'
            }
            Write-Log -Level Warning -Message "Persisted file '$($resolvedResumeState.file)' last written $resumeFileAgeDescription -- treating as a prior session, starting fresh on today's newest recording (SESS-01)"
            $resolvedResumeState = @{ file = $null; byteOffset = 0 }
        }
    }

    if ($null -eq $resolvedResumeState.file) {
        # START-STALE-01 (260809-ow9): this bounded wait loop SUPERSEDES the former
        # WR-05 behavior of falling through to Open-TailerFileStream on a folder+glob
        # path when no file matched yet (a loud FileNotFound error when OBS had not
        # started). The loud signal is now the throttled waiting warning below plus the
        # published WaitingForRecording state, which the operator can actually see on
        # the dashboard instead of a crash-and-relaunch cycle. No trustworthy persisted
        # file -- resolve the current file via the Rotation Detector (D-01), but refuse
        # to latch onto a newest-matching file that is not currently growing: the
        # 2026-08-09 incident this guard exists to prevent was the pusher pushing a
        # week-old finished recording onto a live channel because it was merely "the
        # newest file in the folder", not because it was actually being recorded to.
        $startGuardPreviousObservedPath         = $null
        $startGuardPreviousObservedLengthBytes  = $null
        $startGuardFirstIterationLogged         = $false
        $startGuardLastLogEpochSeconds          = 0.0
        $startGuardLastStatsPublishEpochSeconds = 0.0
        $startGuardLogIntervalSeconds           = 30
        $startGuardStatsPublishIntervalSeconds  = 1

        while ($true) {
            $startGuardNowEpochSeconds = Get-MonotonicSeconds
            $startGuardNowUtc = [DateTime]::UtcNow

            $candidateFile = $null
            $candidateEnumerationErrorMessage = $null
            try {
                $candidateFile = Get-NewestMatchingRecordingFile -RecordingFolderPath $recordingFolderPath -RecordingFilenameGlob $recordingFilenameGlob
            } catch {
                # A throw here (folder vanished, transient access denial) resolves to
                # "no file yet" plus the same throttled warning below -- never a crash
                # out of Start-Pusher under $ErrorActionPreference = 'Stop'.
                $candidateEnumerationErrorMessage = $_.Exception.Message
                $candidateFile = $null
            }

            $candidateFilePath = if ($null -eq $candidateFile) { $null } else { $candidateFile.FullName }

            # START-STALE-02 (260816-g70): the directory entry Get-ChildItem just served
            # (candidateFile) can be a STALE cache while OBS holds the file open -- length
            # frozen, mtime frozen at creation time, for as long as 8 minutes, measured
            # live on this machine. A handle-based read sees the truth. Degrade to the
            # FileInfo's own directory-entry values (never block) only when the live read
            # itself fails (vanished file, exclusive lock elsewhere) -- Rule 2/3.
            $liveMetadata = if ($null -eq $candidateFile) { $null } else { Get-RecordingFileLiveMetadata -FilePath $candidateFilePath }
            $liveReadDegraded = ($null -ne $candidateFile) -and ($null -eq $liveMetadata)
            $effectiveLastWriteTimeUtc = if ($null -ne $liveMetadata) { $liveMetadata.LastWriteTimeUtc } elseif ($null -ne $candidateFile) { $candidateFile.LastWriteTimeUtc } else { $null }
            $effectiveLengthBytes = if ($null -ne $liveMetadata) { $liveMetadata.LengthBytes } elseif ($null -ne $candidateFile) { [long] $candidateFile.Length } else { $null }

            $candidateAgeSeconds = if ($null -eq $effectiveLastWriteTimeUtc) { $null } else { [Math]::Round(($startGuardNowUtc - $effectiveLastWriteTimeUtc).TotalSeconds) }

            # Never compare a length observation across two different files (Rule 2 --
            # a correctness requirement, not tidiness): a fresh candidate's length must
            # never be judged "growing" against a DIFFERENT file's last-seen length.
            $effectivePreviousLengthBytes = if ($candidateFilePath -eq $startGuardPreviousObservedPath) { $startGuardPreviousObservedLengthBytes } else { $null }

            $isCandidateFresh = ($null -ne $candidateFile) -and (Test-RecordingFileFresh `
                -FileLastWriteTimeUtc $effectiveLastWriteTimeUtc -NowUtc $startGuardNowUtc `
                -StaleAfterSeconds $recordingStartStaleAfterSeconds `
                -PreviousLengthBytes $effectivePreviousLengthBytes -CurrentLengthBytes $effectiveLengthBytes)

            if ($isCandidateFresh) {
                $currentRecordingFilePath = $candidateFile.FullName
                $resumeByteOffset = 0
                Write-Log -Level Info -Message "START-STALE-01: latched onto '$currentRecordingFilePath' (age ${candidateAgeSeconds}s) -- releasing the stale-file Start guard"
                break
            }

            # Not fresh, or no matching file at all -- log once on entry, then throttle
            # to at most once per $startGuardLogIntervalSeconds (T-ow9-03): a per-poll
            # log at a 250ms poll would emit ~350k lines/day and rotate real diagnostics
            # off disk, the identical failure mode StatsStore.psm1's header documents.
            $candidateDescription = if ($null -ne $candidateEnumerationErrorMessage) {
                "could not enumerate '$recordingFolderPath' for '$recordingFilenameGlob' ($candidateEnumerationErrorMessage)"
            } elseif ($null -eq $candidateFile) {
                "no file matching '$recordingFilenameGlob' in '$recordingFolderPath' yet"
            } elseif ($liveReadDegraded) {
                "'$candidateFilePath' (age ${candidateAgeSeconds}s, degraded read -- live metadata unavailable, using directory-entry values)"
            } else {
                "'$candidateFilePath' (age ${candidateAgeSeconds}s)"
            }
            if ((-not $startGuardFirstIterationLogged) -or (($startGuardNowEpochSeconds - $startGuardLastLogEpochSeconds) -ge $startGuardLogIntervalSeconds)) {
                Write-Log -Level Warning -Message "START-STALE-01: holding -- newest candidate is $candidateDescription, threshold ${recordingStartStaleAfterSeconds}s -- waiting for a fresh recording or growth before latching"
                $startGuardFirstIterationLogged = $true
                $startGuardLastLogEpochSeconds = $startGuardNowEpochSeconds
            }

            # Publish the waiting state at most once per second (T-ow9-06 DoS mitigation
            # via bounded I/O): every zero below is structurally true, not fabricated --
            # nothing is open, nothing is pending, nothing is behind.
            if (($startGuardNowEpochSeconds - $startGuardLastStatsPublishEpochSeconds) -ge $startGuardStatsPublishIntervalSeconds) {
                Publish-PusherStats -StatsFilePath $statsFilePath -PusherState 'WaitingForRecording' `
                    -RecordingFilePath ($(if ($null -eq $candidateFilePath) { '' } else { $candidateFilePath })) `
                    -OffsetBytes 0 -FileLengthBytes 0 -SendBytesPerSecond 0.0 -RecordBytesPerSecond 0.0 `
                    -SecondsBehindLive 0.0 -BackoffAttemptNumber 0 -CumulativeReconnectCount 0 `
                    -CatchUpCapUtilization 0.0 -OutageActive $false -SessionStartEpochSeconds $sessionStartEpochSeconds
                $startGuardLastStatsPublishEpochSeconds = $startGuardNowEpochSeconds
            }

            # Consulted every iteration (T-ow9-02): an unbounded wait must never make
            # the pusher unstoppable. The return below is BEFORE the try/finally further
            # down this function, so no FileStream/ffmpeg teardown is involved and the
            # terminal exit code stays 0 -- a clean end-of-service, which is what the
            # supervisor should record for an operator stop while waiting.
            if (Get-ResolvedExplicitStopRequest) {
                Write-Log -Level Warning -Message "START-STALE-01: operator stop requested while waiting -- no recording file was ever opened, exiting cleanly"
                Publish-PusherStats -StatsFilePath $statsFilePath -PusherState 'Stopped' `
                    -RecordingFilePath ($(if ($null -eq $candidateFilePath) { '' } else { $candidateFilePath })) `
                    -OffsetBytes 0 -FileLengthBytes 0 -SendBytesPerSecond 0.0 -RecordBytesPerSecond 0.0 `
                    -SecondsBehindLive 0.0 -BackoffAttemptNumber 0 -CumulativeReconnectCount 0 `
                    -CatchUpCapUtilization 0.0 -OutageActive $false -SessionStartEpochSeconds $sessionStartEpochSeconds
                return
            }

            # Store the effective LIVE length, never the FileInfo's directory-entry
            # length (260816-g70): the growth arm compares this poll's value to last
            # poll's, so both observations must come from the same source or the
            # comparison is meaningless.
            $startGuardPreviousObservedPath        = $candidateFilePath
            $startGuardPreviousObservedLengthBytes = $effectiveLengthBytes

            Start-Sleep -Milliseconds $pollIntervalMilliseconds
        }
    } else {
        $currentRecordingFilePath = $resolvedResumeState.file
        $resumeByteOffset = $resolvedResumeState.byteOffset
    }

    $fileStream = Open-TailerFileStream -FilePath $currentRecordingFilePath
    Write-Log -Level Info -Message "Following recording file: $currentRecordingFilePath"

    # D-04's commit boundary is "accepted by ffmpeg stdin", not "confirmed sent over
    # SRT" -- ffmpeg itself can still be holding the tail of the last committed chunk
    # internally (demux/mux pipeline) at the instant of a crash. Resuming exactly at
    # the persisted offset would risk permanently losing that unconfirmed tail. D-05
    # explicitly allows a bounded re-send overlap to cover this, so resume rewinds by
    # a dynamic margin (D-12) rather than trusting the offset literally. No growth rate
    # has been observed yet at startup, so this always takes the cold-start fallback.
    $startupResumeMarginBytes = Get-ResumeSafetyMarginBytes -SrtLatencySeconds $resumeMarginLatencySeconds `
        -ObservedBytesPerSecond 0 -ChunkSizeBytes $chunkSizeBytes -FloorBytes $resumeMarginFloorBytes `
        -CeilingBytes $resumeMarginCeilingBytes -ColdStartMarginBytes $coldStartResumeMarginBytes
    # [long] arg1 forces the (Int64,Int64) Max overload: $resumeByteOffset is [long] and a
    # resume from a >2GB persisted offset would otherwise coerce arg2 to Int32 and crash
    # (int32-overflow-large-backlog).
    $resumeSeekPosition = [Math]::Max([long]0, $resumeByteOffset - $startupResumeMarginBytes)
    $resumeSeekPosition -= ($resumeSeekPosition % 188)
    if ($resumeSeekPosition -ne $resumeByteOffset) {
        Write-Log -Level Info -Message "Resume safety margin: seeking to $resumeSeekPosition (re-sending up to $($resumeByteOffset - $resumeSeekPosition) bytes as a bounded overlap, D-05/D-12)"
    }

    $fileStream.Seek($resumeSeekPosition, [System.IO.SeekOrigin]::Begin) | Out-Null

    $ffmpegArguments = Build-FfmpegArguments -RelayHost $relayHost -RelayPort $relayPort -StreamId $streamId `
        -Protocol $relayProtocol `
        -LatencyMicroseconds $latencyMicroseconds -PacketSizeBytes $packetSizeBytes -LingerSeconds $lingerSeconds `
        -ConnectionTimeoutMicroseconds $srtConnectionTimeoutMicroseconds `
        -MaxBandwidthBytesPerSecond $srtMaxBandwidthBytesPerSecond `
        -SendBufferBytes $srtSendBufferBytes -FlightFlagSizeBytes $srtFlightFlagSizeBytes `
        -LossMaxTtl $srtLossMaxTtl -NakReport $srtNakReport
    $ffmpegHandle = Start-FfmpegProcess -ArgumentList $ffmpegArguments -FfmpegPath $ffmpegPath

    $lastObservedLength     = $fileStream.Length
    $growthRateWindow       = @()
    # SEND-rate window (05-06/DASH-02): a second, independent Update-GrowthRateWindow
    # instance fed $lastAcceptedPosition (bytes ffmpeg's stdin ACCEPTED), never
    # $fileStream.Position -- Position has already advanced past a chunk ffmpeg may
    # never have accepted (see $lastAcceptedPosition's own comment below), so a send
    # rate derived from it would over-report during exactly the failures the operator
    # is watching. $growthRateWindow above stays the RECORD rate (file growth); kept
    # as two separate variables, never conflated into one hashtable, since
    # Update-GrowthRateWindow threads its own opaque state per call site.
    $sendRateWindow         = @()
    $bytesSinceLastCommit   = 0
    $lastCommitEpochSeconds = Get-MonotonicSeconds
    # The offset must only ever cover bytes ffmpeg's stdin actually ACCEPTED (D-04).
    # Read-StableChunk advances $fileStream.Position the instant it reads, BEFORE the
    # write is attempted, so committing raw Position (in-loop or from finally on a
    # crash) would persist bytes a failed/faulted write never handed to ffmpeg -- a
    # permanent gap after a crash-during-write. Track the last accepted position
    # separately and commit only that (CR-02).
    $lastAcceptedPosition   = $fileStream.Position

    # Rotation/end-of-service loop-local state (D-01/D-07/D-12): $pusherState models
    # the minimal Streaming -> (Rotating | Draining) -> Stopped lifecycle Phase 3 adds
    # around the unchanged Phase 1/2 hot path (YAGNI -- no heavier FSM than this).
    $pusherState              = 'Streaming'
    $pendingRotationFilePath  = $null
    $growthStallStartEpoch    = Get-MonotonicSeconds
    $previousObservedLength   = $fileStream.Length

    # CHUR-01 (15-01, Task 1): the frozen last-known-good record rate that replaces
    # the decaying EWMA as Get-SecondsBehindLive's divisor once growth stops (root
    # fix for the 2026-07-26 "30 min -> 8h21m in one minute" display-inflation
    # incident). Lives in the SAME scope as $growthRateWindow so it survives across
    # ticks and stays in scope inside the Draining block (Task 2's frozen ceiling
    # divisor). Updated via Get-LastKnownGoodRecordRate (lib/Pacer.psm1) every tick.
    $lastKnownGoodRecordBytesPerSecond = 0.0

    # Backoff attempt tracking (D-02/Pitfall 4): increments on each classified
    # NetworkDeath/RecordingEnded failure, resets to 0 only after a sustained-healthy
    # send window meaningfully longer than the backoff ceiling -- never after a single
    # success, which would let a flapping connection oscillate forever.
    $backoffAttemptNumber   = 0
    $lastFailureEpochSeconds = $null

    # Small in-memory state surface (D-15, superseded -- see below). CumulativeReconnectCount
    # (05-06/DASH-02) is a THIRD counter alongside BackoffAttemptNumber: it increments at the
    # same NetworkDeath/RecordingEnded site as BackoffAttemptNumber but is NEVER reset, so it
    # answers "how rough was tonight" (the whole-session reconnect total) while
    # BackoffAttemptNumber answers "is it flapping right now" (resets after a sustained-healthy
    # window, Pitfall 4) -- the reset behavior that makes BackoffAttemptNumber useless as the
    # session total DASH-02 asks for (RESEARCH.md Open Question 1).
    $resilienceState = @{
        SecondsBehindLive        = 0.0
        BackoffAttemptNumber     = 0
        CumulativeReconnectCount = 0
        LastClassificationCause  = $null
        CatchUpCapUtilization    = 0.0
        OutageActive             = $false
        WasBehindBand            = $false
        CatchUpLogEpochSeconds   = 0.0
        # Front A (260718-j58): distinct from OutageActive -- the session is UP, just
        # throttled by transient SRT flow-control backpressure. Kept separate so the
        # dashboard's ConnectionState resolution (which keys off OutageActive) does not
        # flip to Reconnecting for normal bond jitter (T-j58-01).
        BackpressureActive      = $false
        # DIAL-01 (14.5-08): throttle-gate for the cross-process live dial repoll,
        # same shape/initial-value as CatchUpLogEpochSeconds above (0.0 so the very
        # first hot-loop tick always repolls once, matching that field's own
        # fires-immediately-on-first-tick behavior).
        LiveTunableRepollEpochSeconds = 0.0
    }
    $catchUpLogIntervalSeconds = 5   # rate-limit the periodic catch-up log so it does not spam every poll
    # DIAL-01 (14.5-08): ~1s cadence for the live dial repoll -- the dashboard/pusher
    # cross-process channel is .env only (Read-LiveTunableOverrides, 14.5-07), and this
    # bounds how much I/O the repoll adds to the hot loop while still landing a dial
    # change within roughly one pacing tick of the operator moving the slider.
    $liveTunableRepollIntervalSeconds = 1

    # Front A stall-hold state (260718-j58): tracks a Write-FfmpegStdin 'Stalled'
    # outcome across polls so the SAME pending WriteAsync task is re-awaited (never a
    # new write, never a skip) until it resolves or the bounded
    # SRT_STALL_TOLERANCE_SECONDS ceiling is exceeded.
    $pendingWriteInFlight    = $false
    $stallStartEpochSeconds  = $null
    $stalledChunkLengthBytes = 0

    # Front C drain-local state (260718-j58/Task 4): captured once, the FIRST time
    # Draining is entered (persists across outer-loop iterations via the $null guard at
    # the top of the Draining branch below). $drainGaveUp is what the terminal decision
    # after the drain loop is keyed on -- NEVER (Length - offset) alone (a legitimate
    # sub-188-byte trailing remainder is not a give-up).
    $drainStartEpochSeconds = $null
    $drainAttemptCount      = 0
    $drainGaveUp            = $false

    # Catch-up pacing schedule (260726): absolute schedule so blocking stdin-write time
    # counts against the pacing quota -- per-chunk sleep alone made the ceiling
    # unreachable (send degenerated to the harmonic mean of ceiling and SRT rate).
    $catchUpNextSendEpochSeconds = $null

    # Stats publish state (05-06, the D-15 rework): this hashtable used to be the
    # dashboard's whole "no rework" promise (D-15's original comment, superseded --
    # Phase 4's supervisor.ps1 made pusher.ps1 a process that exists only while
    # streaming, so the dashboard cannot live here). Publish-PusherStats now writes
    # this state to state/stats.json (Save-PusherStats, lib/StatsStore.psm1) for
    # supervisor.ps1's dashboard to read across that process boundary.
    # $lastStatsPublishEpochSeconds/$secondsBehindLive are pre-initialized here (not
    # just inside the loop) so the finally block below can always safely reference
    # them even if the try body's while loop throws before its first iteration
    # completes (StrictMode would otherwise throw on an undefined-variable read at
    # exactly the moment a stats write must not be allowed to fail, D-05/T-05-11).
    $lastStatsPublishEpochSeconds = Get-MonotonicSeconds
    $secondsBehindLive            = 0.0

    # Last-successful-send wallclock (DASH-08): $null until the very first successful
    # ffmpeg-stdin write this session -- never a fabricated 0 rendered as "just sent"
    # (D-13). Set to $nowEpochSeconds at each site below where $lastAcceptedPosition
    # advances after a genuinely successful write, both the normal streaming path and
    # the end-of-service drain loop.
    $lastSuccessfulSendEpochSeconds = $null

    try {
        while ($true) {
            $nowEpochSeconds = Get-MonotonicSeconds

            # DIAL-01 (14.5-08): throttled live dial repoll -- the SEPARATE dashboard
            # process writes CATCH_UP_MULTIPLIER / SEND_CEILING_BYTES_PER_SECOND to
            # .env (Write-DotEnvFile), and this hot loop polls them back on the ~1s
            # LiveTunableRepollEpochSeconds gate via Read-LiveTunableOverrides
            # (lib/Config.psm1, 14.5-07's scope-fenced two-key reader -- never a full
            # Read-PusherConfig reload, T-14.5-08-01). Update-LiveTunableDialValues
            # (lib/Pacer.psm1) is the pure compare-and-apply seam: a $null override
            # (missing key, torn read, out-of-bounds value) always resolves to "keep
            # the current value" (T-14.5-08-02 safe default), and a log fires ONLY on
            # an actual value change (T-14.5-08-03 -- silent on the steady-state poll
            # path, avoiding the ~86k-lines/day log-spam failure mode
            # ControlFlag.psm1's header warns about). The Get-CatchUpSendCeiling call
            # site further down is left completely unchanged -- it simply reads these
            # module-scope variables, now possibly fresher.
            if (($nowEpochSeconds - $resilienceState.LiveTunableRepollEpochSeconds) -ge $liveTunableRepollIntervalSeconds) {
                $liveTunableOverrides = Read-LiveTunableOverrides -Path $envPath
                $liveTunableDialResult = Update-LiveTunableDialValues -CurrentCatchUpMultiplier $catchUpMultiplier `
                    -CurrentAbsoluteSendCeilingBytesPerSecond $absoluteSendCeilingBytesPerSecond -Overrides $liveTunableOverrides
                if ($liveTunableDialResult.CatchUpMultiplierChanged) {
                    Write-Log -Level Info -Message "Live dial change (DIAL-01): CatchUpMultiplier $($liveTunableDialResult.PreviousCatchUpMultiplier) -> $($liveTunableDialResult.CatchUpMultiplier)"
                }
                if ($liveTunableDialResult.AbsoluteSendCeilingBytesPerSecondChanged) {
                    Write-Log -Level Info -Message "Live dial change (DIAL-01): SendCeilingBytesPerSecond $($liveTunableDialResult.PreviousAbsoluteSendCeilingBytesPerSecond) -> $($liveTunableDialResult.AbsoluteSendCeilingBytesPerSecond)"
                }
                $catchUpMultiplier = $liveTunableDialResult.CatchUpMultiplier
                $absoluteSendCeilingBytesPerSecond = $liveTunableDialResult.AbsoluteSendCeilingBytesPerSecond
                $resilienceState.LiveTunableRepollEpochSeconds = $nowEpochSeconds
            }

            # Rotation is a positive signal only (D-02): a newer matching file appearing
            # in the folder means "keep going, redirect" -- never gated on any
            # stall/timeout, and only checked while Streaming (a rotation already
            # pending, or a drain/stop already underway, is not re-detected).
            if ($pusherState -eq 'Streaming') {
                $newestRecordingFile = Get-NewestMatchingRecordingFile -RecordingFolderPath $recordingFolderPath -RecordingFilenameGlob $recordingFilenameGlob
                if ($null -ne $newestRecordingFile -and (Test-RotationDetected -NewestFile $newestRecordingFile -CurrentFilePath $currentRecordingFilePath)) {
                    $pendingRotationFilePath = $newestRecordingFile.FullName
                    $pusherState = 'Rotating'
                    Write-Log -Level Warning -Message "Rotation detected: draining '$currentRecordingFilePath' before switching to '$pendingRotationFilePath' (D-02/D-04)"
                }
            }

            # Backlog is measured against the current position (bytes already read),
            # independent of Read-StableChunk's own 2-poll stability gate -- this is a
            # pacing signal, not a read-safety boundary (D-11).
            $currentLength     = $fileStream.Length

            # Growth-stall tracking (D-08): a growing file (network outage in a quiet
            # stretch) resets the timer every iteration, so a quiet-stretch outage can
            # never accumulate stall time and can never reach end-of-service -- the
            # pusher never stops mid-service. Rotating counts as activity too (D-02),
            # never stall.
            #
            # CHUR-01 (15-01, Task 1): $recordingFileGrew is captured here, BEFORE
            # $previousObservedLength is reassigned below, and reused both in the
            # stall-reset condition (no repeated comparison) and as the
            # Get-LastKnownGoodRecordRate freeze-on-stall signal further down.
            $recordingFileGrew = $currentLength -gt $previousObservedLength
            if ($recordingFileGrew -or $pusherState -eq 'Rotating') {
                $growthStallStartEpoch = $nowEpochSeconds
            }
            $growthStalledSeconds   = $nowEpochSeconds - $growthStallStartEpoch
            $previousObservedLength = $currentLength

            # Explicit operator stop (locked extension item 6), evaluated EVERY tick.
            # This site is not a convenience -- it is the only one that can see the
            # case the signal exists for. Both Phase 3 call sites below are idle-path
            # only (the Wait-pacing branch and the no-stable-chunk branch), so while
            # the pusher is in sustained ReadFast catch-up WITH stable data available,
            # NEITHER is reached and the gate is never evaluated at all. That is
            # exactly the operator's load-bearing case: 7689s behind live in the
            # phase-4 outage test. A stop wired only into the two existing sites would
            # pass every unit test and still be ignored for as long as the catch-up
            # lasts -- potentially hours of a service that was told to stop.
            # -ExplicitSignalOnly keeps the automatic heuristics (and their per-tick
            # process-table read) out of this hot path; see the gate's own header.
            Update-PusherStateForEndOfService -GrowthStalledSeconds $growthStalledSeconds `
                -SustainedWindowSeconds $growthStallSustainedWindowSeconds -DegradedWindowSeconds $growthStallDegradedWindowSeconds `
                -PusherState ([ref] $pusherState) -ExplicitSignalOnly

            $bytesBehindLive   = $currentLength - $fileStream.Position
            $growthRateWindow  = Update-GrowthRateWindow -Window $growthRateWindow -BytesTotal $currentLength -TimestampEpochSeconds $nowEpochSeconds -SmoothingSeconds $growthRateSmoothingSeconds
            # SEND-rate window (05-06/DASH-02): fed $lastAcceptedPosition (accepted-by-stdin),
            # never $currentLength/$fileStream.Position -- see $sendRateWindow's own declaration
            # comment above for why.
            $sendRateWindow    = Update-GrowthRateWindow -Window $sendRateWindow -BytesTotal $lastAcceptedPosition -TimestampEpochSeconds $nowEpochSeconds -SmoothingSeconds $growthRateSmoothingSeconds

            # CHUR-01 (15-01, Task 1): freeze-on-stall record rate, updated every tick
            # BEFORE the delay divisor below consumes it. Not gated on $pusherState --
            # the verified 2026-07-26 incident evidence shows the display-inflation
            # bug starts up to 30-90s BEFORE the formal Draining transition fires
            # (D-05 "delay must mirror reality at all times"), so this display fix
            # must run on every tick, not just during Draining. D-03's Draining-only
            # rate freeze governs the send CEILING (Task 2), a separate call site.
            $lastKnownGoodRecordBytesPerSecond = Get-LastKnownGoodRecordRate `
                -CurrentLastKnownGoodBytesPerSecond $lastKnownGoodRecordBytesPerSecond `
                -ObservedBytesPerSecond $growthRateWindow.SmoothedBytesPerSecond -RecordingFileGrew $recordingFileGrew

            # Pacing/display consume the frozen last-known-good rate (CHUR-01) -- the
            # decaying-EWMA divisor that used to inflate the displayed delay/ETA once
            # the recording stopped growing is replaced by a rate that can only ever
            # be updated from a genuine growth tick, never decay toward zero on its
            # own (260718-h23/DASH-BRIEF-1/2's divisor-jitter fix is preserved: the
            # frozen rate is itself seeded from the SAME smoothed estimate).
            $secondsBehindLive = Get-SecondsBehindLive -BytesBehind $bytesBehindLive -BytesPerSecond $lastKnownGoodRecordBytesPerSecond
            $pacingDecision    = Get-PacingDecision -SecondsBehindLive $secondsBehindLive -TargetLowSeconds $targetLowSeconds -TargetHighSeconds $targetHighSeconds
            $resilienceState.SecondsBehindLive = $secondsBehindLive

            # Stats publish site 1 (05-06/D-05/D-06/T-05-24) -- TOP OF THE LOOP, reached on
            # EVERY tick including the write-failure branch's `continue` (unlike the offset
            # commit gate at the bottom of this loop, which sits on the success path only and
            # is deliberately FROZEN during an outage/backoff). Rate-limited to the SAME
            # $persistIntervalMilliseconds cadence the offset commit gate uses -- no second
            # timer (D-05's letter) -- but reached here, not only at the four
            # Save-PusherOffset call sites, so stats.json keeps flowing through an entire
            # outage instead of going stale/blank exactly when the operator needs
            # delay-behind-live and the Reconnecting state the most (this is the deliberate,
            # documented deviation from D-05's letter that honors its intent; T-05-24).
            $millisecondsSinceLastStatsPublish = ($nowEpochSeconds - $lastStatsPublishEpochSeconds) * 1000
            if ($millisecondsSinceLastStatsPublish -ge $persistIntervalMilliseconds) {
                Publish-PusherStats -StatsFilePath $statsFilePath -PusherState $pusherState `
                    -RecordingFilePath $currentRecordingFilePath -OffsetBytes $lastAcceptedPosition -FileLengthBytes $currentLength `
                    -SendBytesPerSecond (Get-StatsWindowAverageBytesPerSecond -Window $sendRateWindow -Smoothed) `
                    -RecordBytesPerSecond (Get-StatsWindowAverageBytesPerSecond -Window $growthRateWindow -Smoothed) `
                    -SecondsBehindLive $secondsBehindLive -BackoffAttemptNumber $backoffAttemptNumber `
                    -CumulativeReconnectCount $resilienceState.CumulativeReconnectCount -LastClassificationCause $resilienceState.LastClassificationCause `
                    -CatchUpCapUtilization $resilienceState.CatchUpCapUtilization -OutageActive $resilienceState.OutageActive `
                    -LastSuccessfulSendEpochSeconds $lastSuccessfulSendEpochSeconds -SessionStartEpochSeconds $sessionStartEpochSeconds
                $lastStatsPublishEpochSeconds = $nowEpochSeconds
            }

            # Front A stall-hold resolution (260718-j58): short-circuits BEFORE the
            # normal read/pace/write whenever a prior Write-FfmpegStdin call left a
            # pending WriteAsync task in flight (its 'Stalled' outcome). Re-awaits the
            # SAME task (never a new write, never a skip/re-read of these bytes,
            # D-04/D-05) so the pusher holds ONE SRT session through transient bond
            # backpressure. Draining has its own, separate stall-hold handling (Task 4)
            # so this only ever runs while Streaming/Rotating.
            if ($pusherState -ne 'Draining' -and $pendingWriteInFlight) {
                $pendingWriteResult = Wait-FfmpegStdinPendingWrite -ProcessHandle $ffmpegHandle -TimeoutMilliseconds $watchdogTimeoutMilliseconds

                if ($pendingWriteResult.Success) {
                    # The frozen bytes were finally accepted -- advance exactly as the
                    # normal success path (D-04), clear all stall-local state, and
                    # resume the normal loop next tick.
                    $lastAcceptedPosition = $fileStream.Position
                    $lastSuccessfulSendEpochSeconds = $nowEpochSeconds
                    if ($resilienceState.OutageActive) {
                        Write-Log -Level Info -Message "Write succeeded after outage -- resuming send, delay-behind-live is ${secondsBehindLive}s"
                        $resilienceState.OutageActive = $false
                    }
                    if ($backoffAttemptNumber -gt 0 -and $lastFailureEpochSeconds -and (($nowEpochSeconds - $lastFailureEpochSeconds) -ge $sustainedHealthyWindowSeconds)) {
                        Write-Log -Level Info -Message "Sustained healthy send window (${sustainedHealthyWindowSeconds}s) exceeded -- resetting backoff attempt counter from $backoffAttemptNumber to 0"
                        $backoffAttemptNumber = 0
                        $lastFailureEpochSeconds = $null
                    }
                    $bytesSinceLastCommit += $stalledChunkLengthBytes
                    $millisecondsSinceLastCommit = ($nowEpochSeconds - $lastCommitEpochSeconds) * 1000
                    if ($bytesSinceLastCommit -ge $persistIntervalBytes -or $millisecondsSinceLastCommit -ge $persistIntervalMilliseconds) {
                        Save-PusherOffset -StateFilePath $stateFilePath -RecordingFilePath $currentRecordingFilePath -ByteOffset $lastAcceptedPosition
                        $bytesSinceLastCommit   = 0
                        $lastCommitEpochSeconds = $nowEpochSeconds
                    }
                    $pendingWriteInFlight    = $false
                    $stallStartEpochSeconds  = $null
                    $stalledChunkLengthBytes = 0
                    $resilienceState.BackpressureActive = $false
                    Write-Log -Level Info -Message "Held SRT session resumed -- transient backpressure cleared, no reconnect was needed"
                    continue
                }

                $stallElapsedSeconds = $nowEpochSeconds - $stallStartEpochSeconds
                $stallToleranceExceeded = ($pendingWriteResult.FailureReason -eq 'Stalled') -and ($stallElapsedSeconds -ge $srtStallToleranceSeconds)

                if ($pendingWriteResult.FailureReason -eq 'Stalled' -and -not $stallToleranceExceeded) {
                    # Still within the bounded tolerance -- keep holding, no reconnect.
                    Start-Sleep -Milliseconds $pollIntervalMilliseconds
                    continue
                }

                # Either the process is genuinely gone (Fault) or the stall has
                # exceeded the bounded ceiling (T-j58-01) -- escalate through the
                # EXISTING NetworkDeath reconnect machinery, never a parallel path.
                $escalationClassification = if ($pendingWriteResult.FailureReason -eq 'Fault') {
                    Get-FfmpegExitClassification -FailureReason 'Fault' -ExitCode $ffmpegHandle.Process.ExitCode `
                        -StderrTailLines $ffmpegHandle.StderrTailLines -RecordingFileStillGrowing ($fileStream.Length -gt $lastAcceptedPosition)
                } else {
                    # Synthesized 'Hang' -> NetworkDeath (Get-FfmpegExitClassification's
                    # existing short-circuit) -- a stall past the bounded tolerance is a
                    # network/relay-side symptom, exactly like the pre-Front-A hang path.
                    Get-FfmpegExitClassification -FailureReason 'Hang' -ExitCode 0 -StderrTailLines @() -RecordingFileStillGrowing $true
                }

                $escalation = Invoke-PusherReconnectEscalation -ExitClassification $escalationClassification `
                    -FileStream $fileStream -UnsentChunkLengthBytes $stalledChunkLengthBytes `
                    -RawObservedBytesPerSecond $growthRateWindow.AverageBytesPerSecond -FfmpegHandle $ffmpegHandle `
                    -FfmpegArgumentList $ffmpegArguments -FfmpegPathValue $ffmpegPath -BackoffAttemptNumberValue $backoffAttemptNumber `
                    -ResilienceState $resilienceState -SecondsBehindLiveValue $secondsBehindLive `
                    -BackoffBaseMillisecondsValue $backoffBaseMilliseconds -BackoffCeilingMillisecondsValue $backoffCeilingMilliseconds `
                    -FfmpegCrashRestartDelayMillisecondsValue $ffmpegCrashRestartDelayMilliseconds `
                    -ResumeMarginLatencySecondsValue $resumeMarginLatencySeconds -ChunkSizeBytesValue $chunkSizeBytes `
                    -ResumeMarginFloorBytesValue $resumeMarginFloorBytes -ResumeMarginCeilingBytesValue $resumeMarginCeilingBytes `
                    -ColdStartResumeMarginBytesValue $coldStartResumeMarginBytes -StatsFilePathValue $statsFilePath `
                    -PusherStateValue $pusherState -CurrentRecordingFilePathValue $currentRecordingFilePath `
                    -LastAcceptedPositionValue $lastAcceptedPosition -SendRateWindowValue $sendRateWindow -GrowthRateWindowValue $growthRateWindow `
                    -LastSuccessfulSendEpochSecondsValue $lastSuccessfulSendEpochSeconds -SessionStartEpochSecondsValue $sessionStartEpochSeconds

                $ffmpegHandle          = $escalation.FfmpegHandle
                $backoffAttemptNumber  = $escalation.BackoffAttemptNumber
                $lastFailureEpochSeconds = $nowEpochSeconds
                $pendingWriteInFlight    = $false
                $stallStartEpochSeconds  = $null
                $stalledChunkLengthBytes = 0
                $resilienceState.BackpressureActive = $false
                continue
            }

            # Delay-behind-live structured logging (D-15/SC #4): log the transition into the
            # catch-up band and, on the way back out, the return-to-band -- not every poll, so
            # this stays loud without spamming. The periodic in-catch-up log lives in the
            # ReadFast branch below (rate-limited).
            if ($pacingDecision -eq 'ReadFast') {
                if (-not $resilienceState.WasBehindBand) {
                    Write-Log -Level Warning -Message "Delay-behind-live entering catch-up band: ${secondsBehindLive}s behind live (ReadFast) -- draining backlog"
                    $resilienceState.WasBehindBand = $true
                    $resilienceState.CatchUpLogEpochSeconds = 0.0
                }
            } elseif ($resilienceState.WasBehindBand) {
                Write-Log -Level Info -Message "Delay-behind-live returned to band: ${secondsBehindLive}s behind live (pacing=$pacingDecision) -- catch-up complete"
                $resilienceState.WasBehindBand = $false
            }

            if ($pacingDecision -eq 'Wait') {
                # Two-signal end-of-service gate (D-07/Pitfall 1/WR-03): evaluated here
                # too, not only inside the write-failure branch, so a clean OBS stop over
                # a healthy SRT link is detected even though this branch never reaches
                # Write-FfmpegStdin at all. Extracted into Update-PusherStateForEndOfService
                # (WR-03) so this call site and the no-stable-chunk branch below can never
                # drift out of sync.
                Update-PusherStateForEndOfService -GrowthStalledSeconds $growthStalledSeconds `
                    -SustainedWindowSeconds $growthStallSustainedWindowSeconds -DegradedWindowSeconds $growthStallDegradedWindowSeconds `
                    -PusherState ([ref] $pusherState)

                # Rotating is ALSO exempt from the Wait band's sleep/continue (bug fix,
                # 03-05 integration testing): once the OLD file's backlog is fully
                # drained, bytesBehindLive settles to exactly 0, which Get-PacingDecision
                # always reports as 'Wait' (0 is always below TargetLowSeconds) -- without
                # this exemption the Rotating-state drain-complete check below (the only
                # place that detects "no stable data left + Position>=Length" and performs
                # the switch) would never be reached again once the backlog is drained,
                # permanently starving every rotation's switch-complete detection, not
                # just an edge case. The old file is about to be abandoned, so draining it
                # promptly rather than pacing it behind a live-buffering band is always
                # correct (D-02/D-13).
                if ($pusherState -ne 'Draining' -and $pusherState -ne 'Rotating') {
                    # Too close to live (or growth rate not yet observed) -- don't race the
                    # writer's tail; let backlog build toward the healthy band (D-12).
                    Start-Sleep -Milliseconds $pollIntervalMilliseconds
                    continue
                }
                # A Draining transition just fired from this idle path, or the state is
                # Rotating -- fall through to the shared chunk-read/drain-complete
                # handling below with NO intervening Start-Sleep/continue (D-11/D-13).
            }

            if ($pusherState -ne 'Draining') {
                $chunkResult = Read-StableChunk -FileStream $fileStream -LastObservedLength $lastObservedLength -ChunkSizeBytes $chunkSizeBytes
                $lastObservedLength = $chunkResult.NewObservedLength

                if (-not $chunkResult.HasStableData) {
                    # CR-01 fix: switch-complete must NOT require Position to reach an
                    # exact (possibly non-188-aligned) Length. Read-StableChunk only ever
                    # advances Position in whole 188-byte increments (D-15) -- if the OLD
                    # file's true final length is not a multiple of 188 (OBS crashed/was
                    # killed mid-flush of a TS packet, or any other partial write), Position
                    # can never equal Length, and the previous "Position -ge Length" check
                    # would hang Rotating forever (permanent frozen livestream, no
                    # auto-recovery). Once the old file is confirmed done growing (stable
                    # across 2 polls -- the same "no more stable data" signal the Draining
                    # final-tail loop trusts), the only bytes that can still be unread are a
                    # trailing remainder smaller than one whole TS packet (< 188 bytes). That
                    # remainder can never become a deliverable whole packet because the file
                    # has stopped growing -- it is not a "skippable" TS packet, so completing
                    # the switch now does not violate the never-skip-bytes rule (D-04/D-05):
                    # every WHOLE packet of the old file was already fully drained by the
                    # normal chunk-read path before HasStableData ever went false here.
                    if ($pusherState -eq 'Rotating' -and $currentLength -eq $lastObservedLength -and ($fileStream.Length - $fileStream.Position) -lt 188) {
                        # Old file confirmed fully drained: stable across the 2-poll gate AND
                        # every byte read (D-04). Switch in commit-then-identity order so a
                        # mid-rotation crash re-resumes the OLD file, never the new one
                        # (D-05/D-13) -- old and new bytes are never interleaved (D-06).
                        Save-PusherOffset -StateFilePath $stateFilePath -RecordingFilePath $currentRecordingFilePath -ByteOffset $lastAcceptedPosition
                        Stop-FfmpegProcess -ProcessHandle $ffmpegHandle
                        Close-Tailer -FileStream $fileStream

                        $currentRecordingFilePath = $pendingRotationFilePath
                        Save-PusherOffset -StateFilePath $stateFilePath -RecordingFilePath $currentRecordingFilePath -ByteOffset 0

                        $fileStream   = Open-TailerFileStream -FilePath $currentRecordingFilePath
                        $ffmpegHandle = Start-FfmpegProcess -ArgumentList $ffmpegArguments -FfmpegPath $ffmpegPath

                        $lastObservedLength     = $fileStream.Length
                        $lastAcceptedPosition   = $fileStream.Position
                        $growthRateWindow       = @()
                        # Reset alongside $growthRateWindow (Rule 1, 05-06): the old file's
                        # accepted-position samples are meaningless against the new file's
                        # counter, which restarts at 0 -- an unreset window would compute a
                        # bogus (likely negative) send rate until it fully cycled out.
                        $sendRateWindow         = @()
                        $bytesSinceLastCommit   = 0
                        $growthStallStartEpoch  = $nowEpochSeconds
                        $pusherState            = 'Streaming'

                        Write-Log -Level Info -Message "Rotation switch complete: now following '$currentRecordingFilePath' from byte 0"
                        continue
                    }

                    # Two-signal end-of-service gate (D-07/Pitfall 1/WR-03): this is the
                    # branch that would otherwise loop forever once OBS has genuinely
                    # stopped and there is simply no more data to become stable -- the
                    # exact "zombie loop" this gate exists to close. Shares
                    # Update-PusherStateForEndOfService (WR-03) with the Wait-pacing idle
                    # branch above so the two call sites can never drift out of sync.
                    Update-PusherStateForEndOfService -GrowthStalledSeconds $growthStalledSeconds `
                        -SustainedWindowSeconds $growthStallSustainedWindowSeconds -DegradedWindowSeconds $growthStallDegradedWindowSeconds `
                        -PusherState ([ref] $pusherState)

                    if ($pusherState -ne 'Draining') {
                        Start-Sleep -Milliseconds $pollIntervalMilliseconds
                        continue
                    }
                    # A Draining transition just fired from this idle path -- fall through
                    # to the shared Draining handling below with NO intervening
                    # Start-Sleep/continue (D-11).
                }
            }

            if ($pusherState -eq 'Draining') {
                # Final-tail drain (D-02/D-11): paced to the SAME ceiling dials as live
                # streaming -- SEND_CEILING_BYTES_PER_SECOND if > 0, else
                # CatchUpMultiplier x the frozen last-known-good record rate
                # ($lastKnownGoodRecordBytesPerSecond, Task 1) -- reusing
                # Get-CatchUpSendCeiling unchanged (never a second ceiling formula) and
                # the SAME ahead-of-schedule sleep gate idiom the ReadFast branch below
                # uses, enforced via its own drain-local schedule variable
                # ($drainCatchUpNextSendEpochSeconds) so it can never interfere with
                # $catchUpNextSendEpochSeconds from the streaming path. This is the D-03
                # rate freeze's ONE engagement point: the official Draining state, never
                # a transient mid-stream stall.
                #
                # Front C (260718-j58/Task 4): a write failure during drain no longer
                # unconditionally abandons the backlog. A 'Stalled' outcome HOLDS exactly
                # like the mid-stream path (transient backpressure, not death); a genuine
                # 'Fault' -- or a stall that has run the WHOLE drain past the bounded
                # $endOfServiceReconnectMaxDurationSeconds/$endOfServiceReconnectMaxAttempts
                # ceiling -- reconnects through the SAME shared Invoke-PusherReconnectEscalation
                # action the mid-stream path uses, up to that bound; only once the bound is
                # genuinely exceeded does the drain give up, honestly, with the exact
                # recoverable offset already persisted. The pacing gate below sits ONLY on
                # the successful-write paths -- the stall-hold, Fault-escalation and
                # bounded-give-up branches carrying that content-loss guarantee are left
                # byte-for-byte unchanged in behaviour.
                if ($null -eq $drainStartEpochSeconds) {
                    $drainStartEpochSeconds = Get-MonotonicSeconds
                    $drainCatchUpNextSendEpochSeconds = $null
                    # Task 3 (CHUR-03): drain-local time-based publish cadence, alongside
                    # (never replacing) the existing bytes-based one below -- reuses
                    # $persistIntervalMilliseconds, no new interval constant. 0.0 so the
                    # very first drain iteration always publishes once immediately,
                    # matching the streaming loop's own stats publish site 1 precedent.
                    $drainLastStatsPublishEpochSeconds = 0.0
                }

                while (($fileStream.Position -lt $fileStream.Length) -or $pendingWriteInFlight) {
                    $drainNowEpochSeconds = Get-MonotonicSeconds

                    # Task 3 (CHUR-03): live drain telemetry, recomputed on EVERY
                    # iteration -- including while a write is stalled and no bytes are
                    # being committed -- so the dashboard's drain rate, remaining bytes
                    # and ETA never go stale mid-drain. $sendRateWindow is fed
                    # $lastAcceptedPosition, the identical accepted-by-stdin input the
                    # streaming loop uses (05-06/DASH-02), so "drain rate" is literally
                    # derived from the offset delta, same as always. $growthRateWindow
                    # (record rate) is deliberately left untouched here: OBS has
                    # genuinely stopped recording, so the record bitrate the dashboard
                    # shows stays honestly whatever the last live window held -- no
                    # fabrication either way.
                    $sendRateWindow = Update-GrowthRateWindow -Window $sendRateWindow -BytesTotal $lastAcceptedPosition -TimestampEpochSeconds $drainNowEpochSeconds -SmoothingSeconds $growthRateSmoothingSeconds
                    $secondsBehindLive = Get-SecondsBehindLive -BytesBehind ($fileStream.Length - $lastAcceptedPosition) -BytesPerSecond $lastKnownGoodRecordBytesPerSecond
                    $resilienceState.SecondsBehindLive = $secondsBehindLive

                    # Time-based publish cadence, ALONGSIDE (never replacing) the
                    # existing bytes-based Publish-PusherStats calls below -- without
                    # this, a drain-time stall-hold freezes stats.json and the
                    # dashboard flips to stale/lost-contact, directly contradicting
                    # CHUR-03's "the hero chart keeps charting" (D-11).
                    $millisecondsSinceLastDrainStatsPublish = ($drainNowEpochSeconds - $drainLastStatsPublishEpochSeconds) * 1000
                    if ($millisecondsSinceLastDrainStatsPublish -ge $persistIntervalMilliseconds) {
                        Publish-PusherStats -StatsFilePath $statsFilePath -PusherState $pusherState `
                            -RecordingFilePath $currentRecordingFilePath -OffsetBytes $lastAcceptedPosition -FileLengthBytes $fileStream.Length `
                            -SendBytesPerSecond (Get-StatsWindowAverageBytesPerSecond -Window $sendRateWindow -Smoothed) `
                            -RecordBytesPerSecond (Get-StatsWindowAverageBytesPerSecond -Window $growthRateWindow -Smoothed) `
                            -SecondsBehindLive $secondsBehindLive -BackoffAttemptNumber $backoffAttemptNumber `
                            -CumulativeReconnectCount $resilienceState.CumulativeReconnectCount -LastClassificationCause $resilienceState.LastClassificationCause `
                            -CatchUpCapUtilization $resilienceState.CatchUpCapUtilization -OutageActive $resilienceState.OutageActive `
                            -LastSuccessfulSendEpochSeconds $lastSuccessfulSendEpochSeconds -SessionStartEpochSeconds $sessionStartEpochSeconds
                        $drainLastStatsPublishEpochSeconds = $drainNowEpochSeconds
                    }

                    if ($pendingWriteInFlight) {
                        $pendingWriteResult = Wait-FfmpegStdinPendingWrite -ProcessHandle $ffmpegHandle -TimeoutMilliseconds $watchdogTimeoutMilliseconds

                        if ($pendingWriteResult.Success) {
                            $lastAcceptedPosition = $fileStream.Position
                            $lastSuccessfulSendEpochSeconds = $drainNowEpochSeconds

                            # Task 2 (CHUR-01/D-02): ceiling-respecting pacing on the
                            # successful-write path only -- see this block's twin at the
                            # direct-write success site below for the full rationale.
                            $drainSendCeilingBytesPerSecond = Get-CatchUpSendCeiling -CatchUpMultiplier $catchUpMultiplier `
                                -ObservedBytesPerSecond $lastKnownGoodRecordBytesPerSecond `
                                -ColdStartCeilingBytesPerSecond $coldStartCatchUpCeilingBytesPerSecond `
                                -AbsoluteCeilingBytesPerSecond $absoluteSendCeilingBytesPerSecond
                            $drainExpectedSecondsForThisChunk = $stalledChunkLengthBytes / $drainSendCeilingBytesPerSecond

                            $drainNowForPacingEpochSeconds = Get-MonotonicSeconds
                            if ($null -eq $drainCatchUpNextSendEpochSeconds -or $drainCatchUpNextSendEpochSeconds -lt ($drainNowForPacingEpochSeconds - 1.0)) {
                                $drainCatchUpNextSendEpochSeconds = $drainNowForPacingEpochSeconds
                            }
                            $drainAheadOfScheduleSeconds = $drainCatchUpNextSendEpochSeconds - $drainNowForPacingEpochSeconds
                            if ($drainAheadOfScheduleSeconds -gt 0) {
                                Start-Sleep -Milliseconds ([int]($drainAheadOfScheduleSeconds * 1000))
                            }
                            $drainCatchUpNextSendEpochSeconds = [Math]::Max($drainNowForPacingEpochSeconds, $drainCatchUpNextSendEpochSeconds) + $drainExpectedSecondsForThisChunk

                            $drainSmoothedSendBytesPerSecond = Get-StatsWindowAverageBytesPerSecond -Window $sendRateWindow -Smoothed
                            $resilienceState.CatchUpCapUtilization = if ($drainSendCeilingBytesPerSecond -gt 0) {
                                [Math]::Min(1.0, $drainSmoothedSendBytesPerSecond / $drainSendCeilingBytesPerSecond)
                            } else {
                                1.0
                            }

                            if ($resilienceState.OutageActive) {
                                Write-Log -Level Info -Message "Drain write succeeded after outage -- resuming backlog delivery"
                                $resilienceState.OutageActive = $false
                            }
                            $bytesSinceLastCommit += $stalledChunkLengthBytes
                            if ($bytesSinceLastCommit -ge $persistIntervalBytes) {
                                Save-PusherOffset -StateFilePath $stateFilePath -RecordingFilePath $currentRecordingFilePath -ByteOffset $lastAcceptedPosition
                                Publish-PusherStats -StatsFilePath $statsFilePath -PusherState $pusherState `
                                    -RecordingFilePath $currentRecordingFilePath -OffsetBytes $lastAcceptedPosition -FileLengthBytes $fileStream.Length `
                                    -SendBytesPerSecond (Get-StatsWindowAverageBytesPerSecond -Window $sendRateWindow -Smoothed) `
                                    -RecordBytesPerSecond (Get-StatsWindowAverageBytesPerSecond -Window $growthRateWindow -Smoothed) `
                                    -SecondsBehindLive $secondsBehindLive -BackoffAttemptNumber $backoffAttemptNumber `
                                    -CumulativeReconnectCount $resilienceState.CumulativeReconnectCount -LastClassificationCause $resilienceState.LastClassificationCause `
                                    -CatchUpCapUtilization $resilienceState.CatchUpCapUtilization -OutageActive $resilienceState.OutageActive `
                                    -LastSuccessfulSendEpochSeconds $lastSuccessfulSendEpochSeconds -SessionStartEpochSeconds $sessionStartEpochSeconds
                                $bytesSinceLastCommit = 0
                            }
                            $pendingWriteInFlight    = $false
                            $stallStartEpochSeconds  = $null
                            $stalledChunkLengthBytes = 0
                            $resilienceState.BackpressureActive = $false
                            continue
                        }

                        $drainStallElapsedSeconds = $drainNowEpochSeconds - $stallStartEpochSeconds
                        $drainElapsedSeconds      = $drainNowEpochSeconds - $drainStartEpochSeconds
                        $drainStallExceededBound  = ($pendingWriteResult.FailureReason -eq 'Stalled') -and ($drainStallElapsedSeconds -ge $endOfServiceReconnectMaxDurationSeconds)

                        if ($pendingWriteResult.FailureReason -eq 'Stalled' -and -not $drainStallExceededBound) {
                            # Still within the hold window -- keep holding, no reconnect,
                            # no give-up evaluation yet (a drain-time stall is backpressure,
                            # not death).
                            Start-Sleep -Milliseconds $pollIntervalMilliseconds
                            continue
                        }

                        $drainClassification = if ($pendingWriteResult.FailureReason -eq 'Fault') {
                            Get-FfmpegExitClassification -FailureReason 'Fault' -ExitCode $ffmpegHandle.Process.ExitCode `
                                -StderrTailLines $ffmpegHandle.StderrTailLines -RecordingFileStillGrowing ($fileStream.Length -gt $lastAcceptedPosition)
                        } else {
                            Get-FfmpegExitClassification -FailureReason 'Hang' -ExitCode 0 -StderrTailLines @() -RecordingFileStillGrowing $true
                        }

                        $drainAttemptCount++
                        if ($drainAttemptCount -gt $endOfServiceReconnectMaxAttempts -or $drainElapsedSeconds -ge $endOfServiceReconnectMaxDurationSeconds) {
                            $undeliveredBacklogBytes = $fileStream.Length - $lastAcceptedPosition
                            Write-Log -Level Error -Message "End-of-service drain giving up after $drainAttemptCount attempt(s) / ${drainElapsedSeconds}s -- $undeliveredBacklogBytes bytes remain UNDELIVERED and recoverable from the exact persisted offset (D-05 margin only, never a gap)"
                            $drainGaveUp = $true
                            $pendingWriteInFlight    = $false
                            $stallStartEpochSeconds  = $null
                            $stalledChunkLengthBytes = 0
                            break
                        }

                        $escalation = Invoke-PusherReconnectEscalation -ExitClassification $drainClassification `
                            -FileStream $fileStream -UnsentChunkLengthBytes $stalledChunkLengthBytes `
                            -RawObservedBytesPerSecond $growthRateWindow.AverageBytesPerSecond -FfmpegHandle $ffmpegHandle `
                            -FfmpegArgumentList $ffmpegArguments -FfmpegPathValue $ffmpegPath -BackoffAttemptNumberValue ($drainAttemptCount - 1) `
                            -ResilienceState $resilienceState -SecondsBehindLiveValue $secondsBehindLive `
                            -BackoffBaseMillisecondsValue $backoffBaseMilliseconds -BackoffCeilingMillisecondsValue $backoffCeilingMilliseconds `
                            -FfmpegCrashRestartDelayMillisecondsValue $ffmpegCrashRestartDelayMilliseconds `
                            -ResumeMarginLatencySecondsValue $resumeMarginLatencySeconds -ChunkSizeBytesValue $chunkSizeBytes `
                            -ResumeMarginFloorBytesValue $resumeMarginFloorBytes -ResumeMarginCeilingBytesValue $resumeMarginCeilingBytes `
                            -ColdStartResumeMarginBytesValue $coldStartResumeMarginBytes -StatsFilePathValue $statsFilePath `
                            -PusherStateValue $pusherState -CurrentRecordingFilePathValue $currentRecordingFilePath `
                            -LastAcceptedPositionValue $lastAcceptedPosition -SendRateWindowValue $sendRateWindow -GrowthRateWindowValue $growthRateWindow `
                            -LastSuccessfulSendEpochSecondsValue $lastSuccessfulSendEpochSeconds -SessionStartEpochSecondsValue $sessionStartEpochSeconds

                        $ffmpegHandle = $escalation.FfmpegHandle
                        $pendingWriteInFlight    = $false
                        $stallStartEpochSeconds  = $null
                        $stalledChunkLengthBytes = 0
                        $resilienceState.BackpressureActive = $false
                        continue
                    }

                    $finalChunkResult = Read-StableChunk -FileStream $fileStream -LastObservedLength $fileStream.Length -ChunkSizeBytes $chunkSizeBytes
                    if (-not $finalChunkResult.HasStableData) {
                        # A legitimate sub-188-byte trailing remainder can never become a
                        # deliverable whole packet (same never-skip reasoning the rotation
                        # switch documents) -- this is a clean, non-give-up exit.
                        break
                    }

                    $finalWriteResult = Write-FfmpegStdin -ProcessHandle $ffmpegHandle -Bytes $finalChunkResult.Bytes -TimeoutMilliseconds $watchdogTimeoutMilliseconds

                    if (-not $finalWriteResult.Success -and $finalWriteResult.FailureReason -eq 'Stalled') {
                        # Transient backpressure during drain -- HOLD exactly like the
                        # mid-stream path (Front A): no reconnect, offset frozen, resolved
                        # by the pending-write check at the top of this same loop.
                        $pendingWriteInFlight = $true
                        if ($null -eq $stallStartEpochSeconds) { $stallStartEpochSeconds = $drainNowEpochSeconds }
                        $stalledChunkLengthBytes = $finalChunkResult.Bytes.Length
                        $resilienceState.LastClassificationCause = 'Backpressure'
                        $resilienceState.BackpressureActive = $true
                        continue
                    }

                    if (-not $finalWriteResult.Success) {
                        # 'Fault' -- ffmpeg genuinely died mid-drain. Evaluate the bounded
                        # give-up before reconnecting (same discipline as the pending-write
                        # resolution branch above).
                        $drainFileLengthBeforeGrowthCheck = $fileStream.Length
                        Start-Sleep -Milliseconds ($pollIntervalMilliseconds * 2)
                        $drainRecordingFileStillGrowing = $fileStream.Length -gt $drainFileLengthBeforeGrowthCheck

                        $drainClassification = Get-FfmpegExitClassification -FailureReason 'Fault' -ExitCode $ffmpegHandle.Process.ExitCode `
                            -StderrTailLines $ffmpegHandle.StderrTailLines -RecordingFileStillGrowing $drainRecordingFileStillGrowing

                        $drainElapsedSeconds = $drainNowEpochSeconds - $drainStartEpochSeconds
                        $drainAttemptCount++
                        if ($drainAttemptCount -gt $endOfServiceReconnectMaxAttempts -or $drainElapsedSeconds -ge $endOfServiceReconnectMaxDurationSeconds) {
                            $undeliveredBacklogBytes = $fileStream.Length - $lastAcceptedPosition
                            Write-Log -Level Error -Message "End-of-service drain giving up after $drainAttemptCount attempt(s) / ${drainElapsedSeconds}s -- $undeliveredBacklogBytes bytes remain UNDELIVERED and recoverable from the exact persisted offset (D-05 margin only, never a gap)"
                            $drainGaveUp = $true
                            break
                        }

                        $escalation = Invoke-PusherReconnectEscalation -ExitClassification $drainClassification `
                            -FileStream $fileStream -UnsentChunkLengthBytes $finalChunkResult.Bytes.Length `
                            -RawObservedBytesPerSecond $growthRateWindow.AverageBytesPerSecond -FfmpegHandle $ffmpegHandle `
                            -FfmpegArgumentList $ffmpegArguments -FfmpegPathValue $ffmpegPath -BackoffAttemptNumberValue ($drainAttemptCount - 1) `
                            -ResilienceState $resilienceState -SecondsBehindLiveValue $secondsBehindLive `
                            -BackoffBaseMillisecondsValue $backoffBaseMilliseconds -BackoffCeilingMillisecondsValue $backoffCeilingMilliseconds `
                            -FfmpegCrashRestartDelayMillisecondsValue $ffmpegCrashRestartDelayMilliseconds `
                            -ResumeMarginLatencySecondsValue $resumeMarginLatencySeconds -ChunkSizeBytesValue $chunkSizeBytes `
                            -ResumeMarginFloorBytesValue $resumeMarginFloorBytes -ResumeMarginCeilingBytesValue $resumeMarginCeilingBytes `
                            -ColdStartResumeMarginBytesValue $coldStartResumeMarginBytes -StatsFilePathValue $statsFilePath `
                            -PusherStateValue $pusherState -CurrentRecordingFilePathValue $currentRecordingFilePath `
                            -LastAcceptedPositionValue $lastAcceptedPosition -SendRateWindowValue $sendRateWindow -GrowthRateWindowValue $growthRateWindow `
                            -LastSuccessfulSendEpochSecondsValue $lastSuccessfulSendEpochSeconds -SessionStartEpochSecondsValue $sessionStartEpochSeconds

                        $ffmpegHandle = $escalation.FfmpegHandle
                        continue
                    }

                    # Advance/commit exactly as the normal success path (D-04): the offset
                    # only ever covers bytes ffmpeg's stdin actually accepted.
                    $lastAcceptedPosition  = $fileStream.Position
                    # DASH-08: this final-tail write just succeeded, so it IS a real
                    # last-successful-send moment -- mirrors the identical assignment on
                    # the normal streaming success path below.
                    $lastSuccessfulSendEpochSeconds = $drainNowEpochSeconds

                    # Task 2 (CHUR-01/D-02): ceiling-respecting pacing, successful-write
                    # path only -- mirrors the ReadFast branch's Get-CatchUpSendCeiling
                    # call and ahead-of-schedule sleep gate exactly (this block's own
                    # $drainCatchUpNextSendEpochSeconds is drain-local, never shared with
                    # $catchUpNextSendEpochSeconds), fed the frozen last-known-good record
                    # rate (Task 1) instead of the live decaying rate -- the D-03 freeze
                    # engaging here, in the official Draining state.
                    $drainSendCeilingBytesPerSecond = Get-CatchUpSendCeiling -CatchUpMultiplier $catchUpMultiplier `
                        -ObservedBytesPerSecond $lastKnownGoodRecordBytesPerSecond `
                        -ColdStartCeilingBytesPerSecond $coldStartCatchUpCeilingBytesPerSecond `
                        -AbsoluteCeilingBytesPerSecond $absoluteSendCeilingBytesPerSecond
                    $drainExpectedSecondsForThisChunk = $finalChunkResult.Bytes.Length / $drainSendCeilingBytesPerSecond

                    $drainNowForPacingEpochSeconds = Get-MonotonicSeconds
                    if ($null -eq $drainCatchUpNextSendEpochSeconds -or $drainCatchUpNextSendEpochSeconds -lt ($drainNowForPacingEpochSeconds - 1.0)) {
                        $drainCatchUpNextSendEpochSeconds = $drainNowForPacingEpochSeconds
                    }
                    $drainAheadOfScheduleSeconds = $drainCatchUpNextSendEpochSeconds - $drainNowForPacingEpochSeconds
                    if ($drainAheadOfScheduleSeconds -gt 0) {
                        Start-Sleep -Milliseconds ([int]($drainAheadOfScheduleSeconds * 1000))
                    }
                    $drainCatchUpNextSendEpochSeconds = [Math]::Max($drainNowForPacingEpochSeconds, $drainCatchUpNextSendEpochSeconds) + $drainExpectedSecondsForThisChunk

                    # Utilization = achieved smoothed send rate vs ceiling (mirrors the
                    # ReadFast branch's identical computation) -- the observable that
                    # proves the ceiling is actually being applied during drain, not just
                    # computed and ignored.
                    $drainSmoothedSendBytesPerSecond = Get-StatsWindowAverageBytesPerSecond -Window $sendRateWindow -Smoothed
                    $resilienceState.CatchUpCapUtilization = if ($drainSendCeilingBytesPerSecond -gt 0) {
                        [Math]::Min(1.0, $drainSmoothedSendBytesPerSecond / $drainSendCeilingBytesPerSecond)
                    } else {
                        1.0
                    }

                    if ($resilienceState.OutageActive) {
                        Write-Log -Level Info -Message "Drain write succeeded after outage -- resuming backlog delivery"
                        $resilienceState.OutageActive = $false
                    }
                    $bytesSinceLastCommit += $finalChunkResult.Bytes.Length
                    if ($bytesSinceLastCommit -ge $persistIntervalBytes) {
                        Save-PusherOffset -StateFilePath $stateFilePath -RecordingFilePath $currentRecordingFilePath -ByteOffset $lastAcceptedPosition
                        # Stats publish site 3 (05-06/D-11) -- beside the drain loop's existing
                        # Save-PusherOffset call, same $persistIntervalBytes cadence, no new
                        # interval constant. This is the window D-11 exists for: the operator
                        # watching pending bytes fall toward zero after pressing Stop -- the
                        # timeline bar and drain ETA keep moving while the backlog drains.
                        Publish-PusherStats -StatsFilePath $statsFilePath -PusherState $pusherState `
                            -RecordingFilePath $currentRecordingFilePath -OffsetBytes $lastAcceptedPosition -FileLengthBytes $fileStream.Length `
                            -SendBytesPerSecond (Get-StatsWindowAverageBytesPerSecond -Window $sendRateWindow -Smoothed) `
                            -RecordBytesPerSecond (Get-StatsWindowAverageBytesPerSecond -Window $growthRateWindow -Smoothed) `
                            -SecondsBehindLive $secondsBehindLive -BackoffAttemptNumber $backoffAttemptNumber `
                            -CumulativeReconnectCount $resilienceState.CumulativeReconnectCount -LastClassificationCause $resilienceState.LastClassificationCause `
                            -CatchUpCapUtilization $resilienceState.CatchUpCapUtilization -OutageActive $resilienceState.OutageActive `
                            -LastSuccessfulSendEpochSeconds $lastSuccessfulSendEpochSeconds -SessionStartEpochSeconds $sessionStartEpochSeconds
                        $bytesSinceLastCommit = 0
                    }
                }

                if ($drainGaveUp) {
                    # Bounded, honest give-up (Task 4/EOS-DRAIN-01): the recording is
                    # intact on disk and the exact byte offset is persisted -- starting
                    # the pusher again delivers the remainder, byte-exact (D-05 margin
                    # only). This terminal decision is driven by the gave-up flag, NEVER
                    # by (Length - offset) alone.
                    Save-PusherOffset -StateFilePath $stateFilePath -RecordingFilePath $currentRecordingFilePath -ByteOffset $lastAcceptedPosition
                    $undeliveredBacklogBytesAtExit = $fileStream.Length - $lastAcceptedPosition
                    Write-Log -Level Warning -Message "End-of-service ended with $undeliveredBacklogBytesAtExit bytes of UNDELIVERED backlog -- recoverable by starting the pusher again (byte-exact, D-05 margin only)"
                    $script:pusherTerminalExitCode = $script:ExitCodeUndeliveredBacklog
                } else {
                    Write-Log -Level Info -Message "End-of-service drain complete -- stopping cleanly (D-11/D-12)"
                }
                $pusherState = 'Stopped'
                break
            }

            if ($pacingDecision -eq 'Throttle') {
                # Inside the healthy band -- pace at roughly realtime rather than
                # bursting every chunk out back-to-back (D-12).
                Start-Sleep -Milliseconds $pollIntervalMilliseconds
            } elseif ($pacingDecision -eq 'ReadFast') {
                # Catch-up cap enforcement (RES-02/D-05/D-08): ReadFast drains backlog but must
                # never exceed catchUpMultiplier x observed growth rate (or the cold-start
                # ceiling before a rate is observed). Get-CatchUpSendCeiling only returns the
                # ceiling number (pure, Pacer.psm1) -- the sleep that actually enforces it lives
                # here in the wrapper, never inside the Pacer (D-08).
                # Fed the SMOOTHED rate (260718-h23/DASH-BRIEF-1/2): a burst-driven raw
                # divisor spike could otherwise momentarily widen the cap; the smoothed
                # rate tracks the true mean and can only make the cap MORE stable, never
                # less conservative (T-h23-D1).
                $sendCeilingBytesPerSecond = Get-CatchUpSendCeiling -CatchUpMultiplier $catchUpMultiplier `
                    -ObservedBytesPerSecond $growthRateWindow.SmoothedBytesPerSecond `
                    -ColdStartCeilingBytesPerSecond $coldStartCatchUpCeilingBytesPerSecond `
                    -AbsoluteCeilingBytesPerSecond $absoluteSendCeilingBytesPerSecond
                $expectedSecondsForThisChunk = $chunkResult.Bytes.Length / $sendCeilingBytesPerSecond

                # Sleep only when ahead of schedule; a stale schedule (>1s behind) resets
                # so a stall or Throttle interlude never produces a compensating burst.
                $nowForPacingEpochSeconds = Get-MonotonicSeconds
                if ($null -eq $catchUpNextSendEpochSeconds -or $catchUpNextSendEpochSeconds -lt ($nowForPacingEpochSeconds - 1.0)) {
                    $catchUpNextSendEpochSeconds = $nowForPacingEpochSeconds
                }
                $aheadOfScheduleSeconds = $catchUpNextSendEpochSeconds - $nowForPacingEpochSeconds
                if ($aheadOfScheduleSeconds -gt 0) {
                    Start-Sleep -Milliseconds ([int]($aheadOfScheduleSeconds * 1000))
                }
                $catchUpNextSendEpochSeconds = [Math]::Max($nowForPacingEpochSeconds, $catchUpNextSendEpochSeconds) + $expectedSecondsForThisChunk

                # Utilization = achieved send rate vs ceiling: 1.0 means the cap is the
                # limiter, below 1.0 means SRT/tunnel is.
                $smoothedSendBytesPerSecond = Get-StatsWindowAverageBytesPerSecond -Window $sendRateWindow -Smoothed
                $catchUpCapUtilization = if ($sendCeilingBytesPerSecond -gt 0) {
                    [Math]::Min(1.0, $smoothedSendBytesPerSecond / $sendCeilingBytesPerSecond)
                } else {
                    1.0
                }
                $resilienceState.CatchUpCapUtilization = $catchUpCapUtilization

                # Periodic delay-behind-live + cap-utilization log during catch-up (D-15/SC #4),
                # rate-limited so it does not spam every poll.
                if (($nowEpochSeconds - $resilienceState.CatchUpLogEpochSeconds) -ge $catchUpLogIntervalSeconds) {
                    Write-Log -Level Info -Message "Catch-up in progress: ${secondsBehindLive}s behind live, cap=$([Math]::Round($sendCeilingBytesPerSecond))B/s, utilization=$([Math]::Round($catchUpCapUtilization * 100))%"
                    $resilienceState.CatchUpLogEpochSeconds = $nowEpochSeconds
                }
            }
            # ReadFast: excess backlog is drained above, capped to sendCeilingBytesPerSecond (D-12).

            $writeResult = Write-FfmpegStdin -ProcessHandle $ffmpegHandle -Bytes $chunkResult.Bytes -TimeoutMilliseconds $watchdogTimeoutMilliseconds

            if (-not $writeResult.Success -and $writeResult.FailureReason -eq 'Stalled') {
                # Front A (260718-j58): transient SRT flow-control backpressure -- ffmpeg
                # is still alive, the send buffer is just full. HOLD the one session: do
                # NOT reconnect, do NOT kill, do NOT advance/commit the offset (it stays
                # frozen at $lastAcceptedPosition, D-04). The top-of-loop short-circuit
                # above re-awaits this SAME pending WriteAsync task next tick.
                $pendingWriteInFlight = $true
                if ($null -eq $stallStartEpochSeconds) { $stallStartEpochSeconds = Get-MonotonicSeconds }
                $stalledChunkLengthBytes = $chunkResult.Bytes.Length
                $resilienceState.LastClassificationCause = 'Backpressure'
                $resilienceState.BackpressureActive = $true
                Write-Log -Level Warning -Message "SRT send buffer backpressure -- holding the session (no reconnect), tolerance ${srtStallToleranceSeconds}s"
                continue
            }

            if (-not $writeResult.Success) {
                # 'Fault': ffmpeg hung/died and was already killed by Write-FfmpegStdin
                # (D-18/CR-01). Classify WHY before deciding the reconnect delay (RES-04):
                # NetworkDeath and RecordingEnded take the identical reconnect+resume
                # action (D-11) but get a full-jitter exponential backoff (D-02), while
                # FfmpegCrash -- a local process fault, not a bonded-WAN-congestion
                # concern -- gets a short fixed delay instead (Anti-Patterns note, never
                # the exponential schedule). This ESCALATES through the ONE shared
                # reconnect action (Invoke-PusherReconnectEscalation) -- never a parallel
                # reconnect path (Front A).
                $fileLengthBeforeGrowthCheck = $fileStream.Length
                Start-Sleep -Milliseconds ($pollIntervalMilliseconds * 2)
                $recordingFileStillGrowing = $fileStream.Length -gt $fileLengthBeforeGrowthCheck

                $exitClassification = Get-FfmpegExitClassification -FailureReason $writeResult.FailureReason `
                    -ExitCode $ffmpegHandle.Process.ExitCode -StderrTailLines $ffmpegHandle.StderrTailLines `
                    -RecordingFileStillGrowing $recordingFileStillGrowing

                $escalation = Invoke-PusherReconnectEscalation -ExitClassification $exitClassification `
                    -FileStream $fileStream -UnsentChunkLengthBytes $chunkResult.Bytes.Length `
                    -RawObservedBytesPerSecond $growthRateWindow.AverageBytesPerSecond -FfmpegHandle $ffmpegHandle `
                    -FfmpegArgumentList $ffmpegArguments -FfmpegPathValue $ffmpegPath -BackoffAttemptNumberValue $backoffAttemptNumber `
                    -ResilienceState $resilienceState -SecondsBehindLiveValue $secondsBehindLive `
                    -BackoffBaseMillisecondsValue $backoffBaseMilliseconds -BackoffCeilingMillisecondsValue $backoffCeilingMilliseconds `
                    -FfmpegCrashRestartDelayMillisecondsValue $ffmpegCrashRestartDelayMilliseconds `
                    -ResumeMarginLatencySecondsValue $resumeMarginLatencySeconds -ChunkSizeBytesValue $chunkSizeBytes `
                    -ResumeMarginFloorBytesValue $resumeMarginFloorBytes -ResumeMarginCeilingBytesValue $resumeMarginCeilingBytes `
                    -ColdStartResumeMarginBytesValue $coldStartResumeMarginBytes -StatsFilePathValue $statsFilePath `
                    -PusherStateValue $pusherState -CurrentRecordingFilePathValue $currentRecordingFilePath `
                    -LastAcceptedPositionValue $lastAcceptedPosition -SendRateWindowValue $sendRateWindow -GrowthRateWindowValue $growthRateWindow `
                    -LastSuccessfulSendEpochSecondsValue $lastSuccessfulSendEpochSeconds -SessionStartEpochSecondsValue $sessionStartEpochSeconds

                $ffmpegHandle           = $escalation.FfmpegHandle
                $backoffAttemptNumber   = $escalation.BackoffAttemptNumber
                $lastFailureEpochSeconds = $nowEpochSeconds
                continue
            }

            # The write returned successfully -- these bytes are now accepted by ffmpeg
            # stdin (D-04), so this is the furthest position it is safe to commit.
            $lastAcceptedPosition = $fileStream.Position
            # DASH-08: a real successful send just happened -- record the moment (never
            # fabricated, D-13) so the dashboard can render "last send Ns ago".
            $lastSuccessfulSendEpochSeconds = $nowEpochSeconds

            if ($resilienceState.OutageActive) {
                Write-Log -Level Info -Message "Write succeeded after outage -- resuming send, delay-behind-live is ${secondsBehindLive}s"
                $resilienceState.OutageActive = $false
            }

            # Reset the backoff attempt counter only after a sustained-healthy send window
            # meaningfully longer than the backoff ceiling (~30-60s) -- resetting after a
            # single success would let a flapping connection oscillate between attempt 0/1
            # forever, defeating the reconnect-storm protection D-02 exists for (Pitfall 4).
            if ($backoffAttemptNumber -gt 0 -and $lastFailureEpochSeconds -and (($nowEpochSeconds - $lastFailureEpochSeconds) -ge $sustainedHealthyWindowSeconds)) {
                Write-Log -Level Info -Message "Sustained healthy send window (${sustainedHealthyWindowSeconds}s) exceeded -- resetting backoff attempt counter from $backoffAttemptNumber to 0"
                $backoffAttemptNumber = 0
                $lastFailureEpochSeconds = $null
            }

            # Offset advances and commits only AFTER ffmpeg's stdin Write() returned
            # (D-04), at the bounded cadence of 250 ms or 256 KB, whichever first (D-07).
            $bytesSinceLastCommit += $chunkResult.Bytes.Length
            $millisecondsSinceLastCommit = ($nowEpochSeconds - $lastCommitEpochSeconds) * 1000
            if ($bytesSinceLastCommit -ge $persistIntervalBytes -or $millisecondsSinceLastCommit -ge $persistIntervalMilliseconds) {
                Save-PusherOffset -StateFilePath $stateFilePath -RecordingFilePath $currentRecordingFilePath -ByteOffset $lastAcceptedPosition
                $bytesSinceLastCommit   = 0
                $lastCommitEpochSeconds = $nowEpochSeconds
            }
        }
    } finally {
        if ($bytesSinceLastCommit -gt 0) {
            # Commit the last ACCEPTED position, never raw $fileStream.Position -- on a
            # crash mid-write, Position has already advanced past a chunk ffmpeg never
            # accepted (CR-02, D-04).
            Save-PusherOffset -StateFilePath $stateFilePath -RecordingFilePath $currentRecordingFilePath -ByteOffset $lastAcceptedPosition
        }
        # Stats publish site 4 (05-06) -- the TERMINAL record, published once more with
        # PusherState='Stopped' regardless of whether anything was pending above (this call
        # sits as the `if` guard's SIBLING, not inside it -- a clean exit with nothing
        # pending still needs the terminal state written). This flips the dashboard to Idle
        # promptly rather than leaving a stale 'Streaming' payload on disk that looks briefly
        # alive after the process has already exited. Belt-and-braces with 05-05's
        # PusherProcessAlive check (which already forces Idle on its own), but the label
        # should not lie for even one poll. $fileStream is still open here (Close-Tailer runs
        # after this call), so .Length is safe to read.
        Publish-PusherStats -StatsFilePath $statsFilePath -PusherState 'Stopped' `
            -RecordingFilePath $currentRecordingFilePath -OffsetBytes $lastAcceptedPosition -FileLengthBytes $fileStream.Length `
            -SendBytesPerSecond (Get-StatsWindowAverageBytesPerSecond -Window $sendRateWindow -Smoothed) `
            -RecordBytesPerSecond (Get-StatsWindowAverageBytesPerSecond -Window $growthRateWindow -Smoothed) `
            -SecondsBehindLive $secondsBehindLive -BackoffAttemptNumber $backoffAttemptNumber `
            -CumulativeReconnectCount $resilienceState.CumulativeReconnectCount -LastClassificationCause $resilienceState.LastClassificationCause `
            -CatchUpCapUtilization $resilienceState.CatchUpCapUtilization -OutageActive $resilienceState.OutageActive `
            -LastSuccessfulSendEpochSeconds $lastSuccessfulSendEpochSeconds -SessionStartEpochSeconds $sessionStartEpochSeconds
        Stop-FfmpegProcess -ProcessHandle $ffmpegHandle
        Close-Tailer -FileStream $fileStream
        Write-Log -Level Info -Message "Pusher stopped."
    }
}

try {
    Start-Pusher
} finally {
    # A crash still exits non-zero and a hard kill skips this on purpose: the mutex is then
    # abandoned, which the next pusher and the supervisor's probe both count as free.
    Exit-SupervisorSingleInstance -Mutex $script:PusherSingleInstanceMutex
}
# Front C (260718-j58/Task 3/Task 4): a fully-drained finish leaves the holder at its
# initialized 0 (unchanged pre-existing contract); a bounded end-of-service give-up with
# undelivered backlog (Task 4) sets it to $script:ExitCodeUndeliveredBacklog (3) before
# Start-Pusher returns. A crash still terminates non-zero before this line is ever
# reached; the exit-2 config-validation path (near the top of this file) is untouched.
exit $script:pusherTerminalExitCode

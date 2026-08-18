# Pacer.psm1
# Pure, I/O-free pacing decision component (D-11/D-12; ARCHITECTURE.md Pattern 3).
# "Delay behind live" is bytes-behind-stable-EOF converted to seconds via an observed
# rolling-average growth rate -- no TS timestamp parsing (D-11). Below the 5-10s band:
# Wait. Inside the band: Throttle. Above the band: ReadFast. Get-CatchUpSendCeiling
# fills the Phase-2 D-12 seam: the max send rate during ReadFast, expressed relative
# to the observed growth rate (catchUpMultiplier x observedBytesPerSecond, D-06/D-07)
# with a cold-start absolute fallback -- still just a number, no cap enforcement here.
# No file/process access, no sleeping -- every function here is a pure function of its
# inputs (CLAUDE.md functional-style requirement).
#
# SmoothedBytesPerSecond (260718-h23, DASH-BRIEF-1/2): Update-GrowthRateWindow's bounded
# 20-sample/~5s window is far shorter than OBS's bursty file flushes, so its
# AverageBytesPerSecond divisor swings wildly poll-to-poll -- and that swinging divisor
# used to feed BOTH the displayed delay/bitrate AND the pacing decision, ricocheting the
# dashboard and the pacing logic together. SmoothedBytesPerSecond is a single-pole IIR
# (EWMA, time-constant GrowthRateSmoothingSeconds) computed alongside the raw average,
# now consumed by pacing/cap/display so the operator's number and the pacing number are
# always the same, stable value. AverageBytesPerSecond (raw) is deliberately PRESERVED,
# byte-for-byte unchanged, because the crash-safe resume margin
# (Get-ResumeSafetyMarginBytes, lib/OffsetStore.psm1) is intentionally fed the RAW rate,
# never the smoothed one -- a lagging smoothed rate could theoretically shrink the one
# content-loss-critical safety window this codebase has.
#
# Update-LiveTunableDialValues (DIAL-01, 14.5-08): the pure compare-and-apply core of
# the cross-process live dial repoll. pusher.ps1 and the dashboard are separate OS
# processes -- .env is the only channel (14.5-07's Read-LiveTunableOverrides is the
# read half; Write-DotEnvFile is the write half). This function takes the CURRENT
# in-memory dial values plus a Read-LiveTunableOverrides result and decides the
# (possibly updated) working values, with a per-dial Changed flag so the hot loop logs
# the old->new transition ONLY on an actual change (T-14.5-08-03: a per-tick log would
# rotate real diagnostic history off disk within hours, mirroring ControlFlag.psm1's
# log-on-transition-only discipline). No .env I/O and no Write-Log call live here --
# kept pure so this seam is Pester-testable independent of the hot loop, same as every
# other function in this module (D-08).
#
# Get-LastKnownGoodRecordRate (CHUR-01, 15-01): the frozen-divisor fix for the
# 2026-07-26 "30 min -> 8h21m in one minute" incident. Get-SecondsBehindLive's
# BytesPerSecond divisor used to be fed growthRateWindow.SmoothedBytesPerSecond
# directly -- a valid live-rate ESTIMATOR (EWMA) but an invalid DIVISOR once the
# recording file stops growing, because it decays toward zero the instant OBS
# stops writing, inflating the displayed delay far faster than the backlog is
# actually shrinking. This function carries a "last known good" rate forward
# across non-growth ticks (mirrors Update-GrowthRateWindow's own carry-forward
# idiom, lines 196-198/202-204 above) so the caller always has an honest,
# non-decaying divisor: adopted only from a tick where the file genuinely grew
# AND the observed rate was itself meaningfully positive (D-01/D-05).
#
# Exports: Get-PacingDecision, Get-SecondsBehindLive, Update-GrowthRateWindow, Get-CatchUpSendCeiling, Update-LiveTunableDialValues, Get-LastKnownGoodRecordRate

Set-StrictMode -Version Latest

$script:DefaultGrowthRateWindowMaxSamples = 20

function Get-PacingDecision {
    <#
    .SYNOPSIS
    Pure band decision: Wait below TargetLowSeconds, ReadFast above TargetHighSeconds,
    Throttle everywhere in between -- including both boundaries themselves, so a
    reading of exactly the low or high bound falls inside the safe Throttle band
    rather than flapping to Wait/ReadFast on a boundary value (PUSH-04).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [double] $SecondsBehindLive,
        [Parameter(Mandatory)] [double] $TargetLowSeconds,
        [Parameter(Mandatory)] [double] $TargetHighSeconds
    )

    if ($SecondsBehindLive -lt $TargetLowSeconds) {
        return 'Wait'
    }
    if ($SecondsBehindLive -gt $TargetHighSeconds) {
        return 'ReadFast'
    }
    return 'Throttle'
}

function Get-SecondsBehindLive {
    <#
    .SYNOPSIS
    Converts bytes-behind-stable-EOF to seconds using the observed growth rate.
    Guards BytesPerSecond <= 0 (no growth observed yet, e.g. at startup) by returning
    the safe sentinel 0 rather than dividing by zero (T-01-DIV mitigation).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [long] $BytesBehind,
        [Parameter(Mandatory)] [double] $BytesPerSecond
    )

    if ($BytesPerSecond -le 0) {
        return 0
    }
    return $BytesBehind / $BytesPerSecond
}

function Get-CatchUpSendCeiling {
    <#
    .SYNOPSIS
    Pure catch-up cap: the maximum allowed send rate (bytes/sec) while ReadFast is
    active, expressed as CatchUpMultiplier x ObservedBytesPerSecond (default 2.0x,
    D-05/D-06) -- relative to the observed recording growth rate, never an absolute
    bitrate, so it self-adjusts to any church's OBS bitrate without retuning (D-07).
    Guards ObservedBytesPerSecond <= 0 (cold window -- growth rate not yet observed,
    e.g. right after startup) the same way Get-SecondsBehindLive guards its divisor:
    falls back to ColdStartCeilingBytesPerSecond, a conservative absolute ceiling, so
    a cold catch-up cannot burst uncapped onto the bonded WAN (D-07). Returns a number
    only -- no sleep, no I/O; the throttle sleep this ceiling feeds is enforced by the
    wrapper (pusher.ps1, Wave 3 / 02-06), keeping this module 100% pure (D-08).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [double] $CatchUpMultiplier,
        [Parameter(Mandatory)] [double] $ObservedBytesPerSecond,
        [Parameter(Mandatory)] [double] $ColdStartCeilingBytesPerSecond,
        # SEND_CEILING_BYTES_PER_SECOND (2026-07-26): when > 0, an absolute cap that fully
        # replaces the multiplier-of-record-rate ceiling -- send rate decoupled from what
        # OBS encodes at, bounded only by this operator-set value.
        [double] $AbsoluteCeilingBytesPerSecond = 0
    )

    if ($AbsoluteCeilingBytesPerSecond -gt 0) {
        return $AbsoluteCeilingBytesPerSecond
    }
    if ($ObservedBytesPerSecond -le 0) {
        # CR-01 defense-in-depth: Test-PusherConfig rejects a <= 0
        # ColdStartCeilingBytesPerSecond before it reaches here, but this floor protects
        # any future caller that skips config validation (a test fixture, a new config
        # source) from reintroducing the same division-by-zero / uncapped-burst bug.
        return [Math]::Max($ColdStartCeilingBytesPerSecond, 1)
    }
    return $CatchUpMultiplier * $ObservedBytesPerSecond
}

function Update-GrowthRateWindow {
    <#
    .SYNOPSIS
    Maintains a bounded rolling window of (bytes, timestamp) samples and returns the
    average bytes/sec across the window, alongside an EWMA-smoothed rate estimate.
    Accepts either an empty/plain array of prior samples or a previously returned
    window object (its .Samples/.SmoothedBytesPerSecond are reused) so callers can
    thread the return value straight back in on the next poll.
    .OUTPUTS
    Hashtable with keys: Samples (array of @{ Bytes; TimestampEpochSeconds }),
    AverageBytesPerSecond (double; 0 when fewer than 2 samples or the window spans
    zero elapsed time, guarding divide-by-zero the same way Get-SecondsBehindLive does
    -- byte-for-byte unchanged behavior, feeds the resume-safety-margin path only),
    SmoothedBytesPerSecond (double; a single-pole IIR filter over the per-poll
    instantaneous rate, time-constant $SmoothingSeconds -- kills the divisor jitter
    that used to ricochet the displayed delay/bitrate and the pacing decision
    together, see the module header for the full rationale). Seeded from
    AverageBytesPerSecond on the first update that establishes a rate (no
    ramp-from-zero). When $SmoothingSeconds <= 0 (or omitted), SmoothedBytesPerSecond
    is an EXACT passthrough of AverageBytesPerSecond -- the resilience escape hatch
    that restores the prior raw behavior with zero smoothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Window,
        [Parameter(Mandatory)] [long] $BytesTotal,
        [Parameter(Mandatory)] [double] $TimestampEpochSeconds,
        [int] $MaxSamples = $script:DefaultGrowthRateWindowMaxSamples,
        [double] $SmoothingSeconds = 0
    )

    $existingSamples = @(
        if ($Window -is [hashtable] -and $Window.ContainsKey('Samples')) {
            $Window.Samples
        } else {
            $Window
        }
    )
    $priorSmoothedBytesPerSecond = $null
    if ($Window -is [hashtable] -and $Window.ContainsKey('SmoothedBytesPerSecond')) {
        $priorSmoothedBytesPerSecond = $Window.SmoothedBytesPerSecond
    }
    # Captured BEFORE the new sample is appended below -- the immediately-previous
    # poll's own sample, used ONLY to derive the per-poll instantaneous rate for the
    # EWMA. The window-average divisor computed further down is left completely
    # untouched (still oldest-vs-newest across the whole bounded window, D-11).
    $immediatelyPreviousSample = if ($existingSamples.Count -ge 1) { $existingSamples[-1] } else { $null }
    $newestSample = @{ Bytes = $BytesTotal; TimestampEpochSeconds = $TimestampEpochSeconds }

    $samples = @($existingSamples) + @($newestSample)
    if ($samples.Count -gt $MaxSamples) {
        $samples = $samples[($samples.Count - $MaxSamples)..($samples.Count - 1)]
    }

    $averageBytesPerSecond = 0
    if ($samples.Count -ge 2) {
        $oldestSample = $samples[0]
        $newestWindowSample = $samples[-1]
        $elapsedSeconds = $newestWindowSample.TimestampEpochSeconds - $oldestSample.TimestampEpochSeconds
        if ($elapsedSeconds -gt 0) {
            $averageBytesPerSecond = ($newestWindowSample.Bytes - $oldestSample.Bytes) / $elapsedSeconds
        }
    }

    # SmoothedBytesPerSecond defaults to the raw window average -- this IS the
    # SmoothingSeconds<=0 passthrough (disabled smoothing, the resilience escape
    # hatch) and the safe fallback whenever there is not yet enough history to
    # compute a per-poll instantaneous rate.
    $smoothedBytesPerSecond = $averageBytesPerSecond

    if ($SmoothingSeconds -gt 0 -and $null -ne $immediatelyPreviousSample) {
        $instantDeltaSeconds = $newestSample.TimestampEpochSeconds - $immediatelyPreviousSample.TimestampEpochSeconds
        if ($instantDeltaSeconds -le 0) {
            # No forward progress between polls (or a clock glitch) -- carry the
            # prior smoothed value rather than dividing by a zero/negative span.
            $smoothedBytesPerSecond = if ($null -ne $priorSmoothedBytesPerSecond) { $priorSmoothedBytesPerSecond } else { 0.0 }
        } else {
            $instantBytesPerSecond = ($newestSample.Bytes - $immediatelyPreviousSample.Bytes) / $instantDeltaSeconds
            if ($instantBytesPerSecond -lt 0) {
                # Bytes went backwards (a rotation/truncation glitch) -- skip this
                # update defensively and carry the prior smoothed value.
                $smoothedBytesPerSecond = if ($null -ne $priorSmoothedBytesPerSecond) { $priorSmoothedBytesPerSecond } else { 0.0 }
            } elseif ($existingSamples.Count -lt 2) {
                # The FIRST update that establishes a rate: seed from the stable
                # multi-sample window average rather than a single noisy per-poll
                # delta, so there is no long ramp-from-zero.
                $smoothedBytesPerSecond = $averageBytesPerSecond
            } else {
                # Single-pole IIR filter (EWMA): alpha derived from dt/tau.
                $priorSmoothedForFilter = if ($null -ne $priorSmoothedBytesPerSecond) { $priorSmoothedBytesPerSecond } else { $averageBytesPerSecond }
                $alpha = 1 - [Math]::Exp(-$instantDeltaSeconds / $SmoothingSeconds)
                $smoothedBytesPerSecond = ($alpha * $instantBytesPerSecond) + ((1 - $alpha) * $priorSmoothedForFilter)
            }
        }
    }

    return @{ Samples = $samples; AverageBytesPerSecond = $averageBytesPerSecond; SmoothedBytesPerSecond = $smoothedBytesPerSecond }
}

function Update-LiveTunableDialValues {
    <#
    .SYNOPSIS
    DIAL-01's pure repoll-and-apply seam. Given the CALLER's current in-memory
    CatchUpMultiplier / AbsoluteSendCeilingBytesPerSecond and an Overrides object
    shaped like Read-LiveTunableOverrides' return value (lib/Config.psm1, 14.5-07 --
    each property $null-or-a-validated-value, $null meaning "no override signal"),
    returns the working values the caller should now use plus a per-dial Changed
    flag. A $null override property ALWAYS resolves to "keep the current value,
    unchanged" -- this is the same safe-default resolution a torn/locked .env read
    produces (Read-LiveTunableOverrides returns both properties $null on any read
    failure), so a transient read race during the hot loop's ~1s poll never mutates
    the running pacer (T-14.5-08-02). An override that is present but numerically
    EQUAL to the current value is also reported unchanged, so the caller does not
    log a no-op transition.

    .OUTPUTS
    Hashtable: CatchUpMultiplier, CatchUpMultiplierChanged, PreviousCatchUpMultiplier,
    AbsoluteSendCeilingBytesPerSecond, AbsoluteSendCeilingBytesPerSecondChanged,
    PreviousAbsoluteSendCeilingBytesPerSecond.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [double] $CurrentCatchUpMultiplier,
        [Parameter(Mandatory)] [double] $CurrentAbsoluteSendCeilingBytesPerSecond,
        [Parameter(Mandatory)] $Overrides
    )

    $newCatchUpMultiplier = $CurrentCatchUpMultiplier
    $catchUpMultiplierChanged = $false
    if ($null -ne $Overrides.CatchUpMultiplier -and $Overrides.CatchUpMultiplier -ne $CurrentCatchUpMultiplier) {
        $newCatchUpMultiplier = $Overrides.CatchUpMultiplier
        $catchUpMultiplierChanged = $true
    }

    $newAbsoluteSendCeilingBytesPerSecond = $CurrentAbsoluteSendCeilingBytesPerSecond
    $sendCeilingChanged = $false
    if ($null -ne $Overrides.SendCeilingBytesPerSecond -and $Overrides.SendCeilingBytesPerSecond -ne $CurrentAbsoluteSendCeilingBytesPerSecond) {
        $newAbsoluteSendCeilingBytesPerSecond = $Overrides.SendCeilingBytesPerSecond
        $sendCeilingChanged = $true
    }

    return @{
        CatchUpMultiplier                         = $newCatchUpMultiplier
        CatchUpMultiplierChanged                  = $catchUpMultiplierChanged
        PreviousCatchUpMultiplier                 = $CurrentCatchUpMultiplier
        AbsoluteSendCeilingBytesPerSecond          = $newAbsoluteSendCeilingBytesPerSecond
        AbsoluteSendCeilingBytesPerSecondChanged   = $sendCeilingChanged
        PreviousAbsoluteSendCeilingBytesPerSecond  = $CurrentAbsoluteSendCeilingBytesPerSecond
    }
}

function Get-LastKnownGoodRecordRate {
    <#
    .SYNOPSIS
    Freeze-on-stall carry-forward for the record-rate divisor (CHUR-01, 15-01):
    an EWMA record rate (growthRateWindow.SmoothedBytesPerSecond) decays toward
    zero the moment OBS stops writing -- a valid live-rate ESTIMATOR, but an
    invalid DIVISOR once growth stops, since dividing a shrinking backlog by an
    ever-shrinking rate inflates the displayed delay/ETA far faster than the
    backlog is actually draining (the 2026-07-26 "30 min -> 8h21m in one
    minute" incident). This function is the pure decision of WHICH rate the
    caller should now treat as "last known good": adopt the observed rate only
    on a tick where the recording file genuinely grew AND the observed rate is
    itself meaningfully positive; otherwise carry the prior value forward
    unchanged -- mirroring Update-GrowthRateWindow's own carry-forward idiom
    (this file, "carry the prior smoothed value rather than dividing by a
    zero/negative span"). This is a freeze-on-STALL, never a high-water mark:
    an honest lower live rate on a genuine growth tick IS adopted.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [double] $CurrentLastKnownGoodBytesPerSecond,
        [Parameter(Mandatory)] [double] $ObservedBytesPerSecond,
        [Parameter(Mandatory)] [bool] $RecordingFileGrew
    )

    if (-not $RecordingFileGrew) {
        return $CurrentLastKnownGoodBytesPerSecond
    }
    if ($ObservedBytesPerSecond -le 0) {
        return $CurrentLastKnownGoodBytesPerSecond
    }
    return $ObservedBytesPerSecond
}

Export-ModuleMember -Function Get-PacingDecision, Get-SecondsBehindLive, Update-GrowthRateWindow, Get-CatchUpSendCeiling, Update-LiveTunableDialValues, Get-LastKnownGoodRecordRate

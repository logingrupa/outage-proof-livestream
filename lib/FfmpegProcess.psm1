# FfmpegProcess.psm1
# ffmpeg subprocess lifecycle (D-23, PUSH-02/PUSH-04): builds the D-19 stdin->SRT
# argument shape, drains stderr via an async event reader started BEFORE any stdin
# write (D-17, Pitfall 5 deadlock avoidance), feeds stdin, and distinguishes transient
# SRT flow-control backpressure from a genuinely dead peer on stdin writes (Front A,
# 260718-j58) -- a soft-timeout stall while ffmpeg is still alive is HELD (never
# killed); only a truly gone process/pipe is killed and signaled for restart (D-18).
# ffmpeg is stateless/disposable (ARCHITECTURE.md Anti-Pattern 2) -- this module owns
# only the OS process boundary, never resume/offset state.
#
# Exports: Build-FfmpegArguments, Start-FfmpegProcess, Write-FfmpegStdin,
#          Wait-FfmpegStdinPendingWrite, Stop-FfmpegProcess

Set-StrictMode -Version Latest

$script:DefaultSrtLatencyMicroseconds = 500000
$script:DefaultSrtPacketSizeBytes = 1316
# SRT_MAXBW (.planning/debug/srt-throughput-degraded-today.md): the hard ceiling, in
# BYTES/sec, on TOTAL SRT send bandwidth -- original packets AND retransmissions combined.
# Default 0 = maxbw OMITTED (libsrt unlimited). The capped direction was tried against the
# uncapped-ARQ congestion collapse (measured 78 Mbit offered for 21 Mbit goodput) and
# FALSIFIED in the same debug cycle: a cap starves the retransmits a lossy bonded path
# needs (see the Tier-1 block below), and it also rate-limits the close-time linger flush,
# discarding the stream's tail at every clean finish -- the D-20 byte-match test measures a
# deterministic 564-byte shortfall with maxbw on, which is content the church loses at the
# end of every service. Backlog-drain rate limiting belongs to the pusher's own pacer
# (SEND_CEILING_BYTES_PER_SECOND), not to libsrt. A positive value here is opt-in via .env
# (SRT_MAXBW_BYTES_PER_SECOND) for differential testing only.
$script:DefaultSrtMaxBandwidthBytesPerSecond = 0
# TIER 1 sender-side SRT buffer/window tuning
# (.planning/debug/srt-throughput-degraded-today.md, Tier 1 cycle). These four knobs do
# NOT cap bandwidth (the maxbw direction above was FALSIFIED -- it starved the retransmits
# a lossy or bandwidth-constrained upstream path needs and collapsed goodput). They ENLARGE
# the sender's buffering and reorder tolerance so a loss burst on that kind of path is ridden
# out rather than stalling the stdin feed, and mirror the relay listener's receiver-side sizing
# (relay runs ffs=65536, rcvbuf=64MB, lossmaxttl=4096). Each defaults to 0 / '' meaning the
# option is OMITTED entirely (libsrt default = exact pre-Tier-1 behaviour), so the shipped
# default changes nothing; an operator opts in per-knob via .env and the one-line
# revert is setting the key back to 0 / blank. All are verified present in a modern
# ffmpeg 7.1 build's `-h protocol=srt` surface (sndbuf, ffs, lossmaxttl, nakreport):
#   * sndbuf (SendBufferBytes): a bigger send buffer holds more unacked data in flight
#     through a loss burst before stdin backpressure ('Stalled') kicks in.
#   * ffs (FlightFlagSizeBytes): the SRT flow-control window (SRTO_FC, in packets). Sized to
#     match the relay's 65536 so the 8s-latency x ~26 Mbit in-flight set is not window-capped.
#   * lossmaxttl (LossMaxTtl): packet-reorder tolerance -- light reorder on a multipath bond
#     is not mistaken for loss (and a needless retransmit), mirroring the relay's 4096.
#   * nakreport (NakReport): '' omits (libsrt 'auto'); 'true'/'false' sets it explicitly to
#     mirror the relay's loss-signalling behaviour on the sender's reverse channel.
$script:DefaultSrtSendBufferBytes = 0
$script:DefaultSrtFlightFlagSizeBytes = 0
$script:DefaultSrtLossMaxTtl = 0
$script:DefaultSrtNakReport = ''
# THE transport mode, and the fix for the clean-finish tail loss
# (.planning/debug/ffmpeg-tail-flush-on-stop.md). Leaving this unset is NOT neutral:
# ffmpeg's -transtype default is 2, outside its own live=0/file=1 range, so libsrt
# applies SRTT_LIVE. Live mode is DEFINED to sacrifice late data to protect realtime
# playout -- it buffers an in-flight window sized by `latency=` and discards whatever has
# not been played out when the connection closes. That trade is the exact INVERSE of this
# project's core value: here the disk file is the buffer, catch-up deliberately runs
# faster than realtime, and late data is not stale -- it IS the product.
#
# Measured, quiet box, 3/3 each (no CPU load, no pusher.ps1 in the loop):
#     live, latency=4s -> receiver delivered ZERO bytes; file -> full 356824 baseline.
# Under CPU load at the production latency=500000, live lost 19176-37976 bytes 6/6 while
# the SENDER reported a complete clean exit (frame=783, Lsize=348KiB) -- the bytes left
# ffmpeg and died in the transport, which is why every sender-side knob failed:
#   * linger=20 (5x)      -> still lost 37976. `linger` waits for UNSENT data; data the
#                            transport is holding or has discarded is not "unsent".
#   * tlpktdrop=0         -> still lost 37976, 3/3. Sender-side late-drop is NOT the path.
#   * raising latency=    -> STRICTLY WORSE; the loss IS the in-flight window.
#   * latency=0           -> green 3/3 and REJECTED: on loopback the window costs nothing,
#                            but on a real bonded WAN that window IS the retransmission
#                            budget. It would pass the suite while destroying the outage
#                            resilience this product exists for.
# file mode keeps full ARQ retransmission (it is reliable, TCP-like) and removes only the
# playout DEADLINE -- so it is more resilient on a lossy WAN, not less. Pacing is
# unaffected: the pusher owns pacing at the stdin feed (D-03), never ffmpeg.
#
# HARD REQUIREMENT: the relay must set transtype=file too. A file-mode caller against a
# live-mode listener is REJECTED at handshake -- SRT's own words, captured from the
# sender's stderr: "REJECT reported from HS processing: MessageAPI/StreamAPI collision".
# That is a loud, immediate, impossible-to-miss failure rather than silent byte loss, so a
# mismatched deployment cannot quietly corrupt a service -- but it does mean pusher and
# relay must be switched together (or the relay must expose a file-mode listener on a
# second port to migrate without downtime).
$script:DefaultSrtTransmissionType = 'file'
# Wave 1 spike deviation (01-01-SUMMARY.md): the SRT socket can hard-close before the
# send buffer drains unless an explicit linger value is set on the caller URL -- bake
# it into every built URL rather than relying on callers to remember it.
$script:DefaultSrtLingerSeconds = 4
# RES-01 investigation (02-07): the CALLER URL previously had no explicit `timeout=`
# at all, unlike the test listener helper (which always sets one). Setting it here is
# still a reasonable, harmless explicit bound on SRT connection ESTABLISHMENT (rather
# than leaving that implicit), but a direct integration-test repro (02-07) CONFIRMED
# this option has NO measurable effect on how long ffmpeg silently tolerates an
# ALREADY-CONNECTED peer going dead (identical ~5.4-5.5s detection delay measured with
# timeout=3000000 and timeout=1000000 alike) -- ffmpeg's SRT protocol handler does not
# expose that specific liveness knob here (CLAUDE.md's own caveat: "SRT connection
# health: ffmpeg does NOT give you this -- plan around it"). Do NOT assume this value
# bounds real-world outage-detection latency; see pusher.ps1's
# $networkDeathDetectionDelaySeconds for the actual (empirically-measured, not
# configured) constant the resume margin is sized against.
$script:DefaultSrtConnectionTimeoutMicroseconds = 3000000
$script:DefaultStdinWriteTimeoutMilliseconds = 5000
# Pitfall 1 / T-02-BUF: bound the retained stderr-tail buffer so a long outage
# (chatty/looping ffmpeg) cannot grow process memory without limit.
$script:DefaultMaxStderrTailLines = 20

function Build-FfmpegArguments {
    <#
    .SYNOPSIS
    Builds the D-19 stdin->SRT argument array:
    -f mpegts -i pipe:0 -c copy -f mpegts "srt://<host>:<port>?mode=caller&transtype=file&latency=...&pkt_size=...&streamid=...&linger=...&timeout=...".
    Built from explicit tokens so ffmpeg's native realtime input pacing flag (forbidden
    by D-03) can never be introduced -- that literal token is never written in this
    module's source. `timeout=` is an explicit bound on connection establishment only --
    it does NOT bound post-connection dead-peer detection latency (confirmed empirically,
    02-07; see $script:DefaultSrtConnectionTimeoutMicroseconds above).

    `transtype=file` is load-bearing and the relay MUST match it -- see
    $script:DefaultSrtTransmissionType above for the full measurement trail and the
    handshake-rejection consequence of a mismatch.

    `latency=` is retained and still emitted, but note that SRT applies the playout delay
    it configures only in LIVE mode; in file mode there is no playout deadline for it to
    set. It is kept explicit (rather than dropped) because it is the one knob that must be
    re-tuned if the transport mode is ever moved back to live, and because -TransmissionType
    'live' remains selectable for differential testing of exactly this defect.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $RelayHost,
        [Parameter(Mandatory)] [int] $RelayPort,
        [Parameter(Mandatory)] [string] $StreamId,
        # RELAY_PROTOCOL (2026-07-26 incident): 'tcp' emits a plain tcp://host:port output
        # URL (raw mpegts over TCP to a tcp-relay listener) and ignores every SRT knob below.
        # TCP's own congestion control replaces SRT file-mode ARQ; outage detection is
        # unchanged -- the pusher's stdin stall/backpressure machinery is transport-agnostic.
        # No timeout= on the tcp URL: ffmpeg's tcp timeout bounds EVERY socket op, and a
        # congested-but-alive path can legitimately block a write longer than any sane
        # connect bound -- the stall tolerance in pusher.ps1 owns dead-peer escalation.
        [ValidateSet('srt', 'tcp')] [string] $Protocol = 'srt',
        [int] $LatencyMicroseconds = $script:DefaultSrtLatencyMicroseconds,
        [int] $PacketSizeBytes = $script:DefaultSrtPacketSizeBytes,
        [int] $LingerSeconds = $script:DefaultSrtLingerSeconds,
        [int] $ConnectionTimeoutMicroseconds = $script:DefaultSrtConnectionTimeoutMicroseconds,
        [ValidateSet('file', 'live')] [string] $TransmissionType = $script:DefaultSrtTransmissionType,
        [int] $MaxBandwidthBytesPerSecond = $script:DefaultSrtMaxBandwidthBytesPerSecond,
        [int] $SendBufferBytes = $script:DefaultSrtSendBufferBytes,
        [int] $FlightFlagSizeBytes = $script:DefaultSrtFlightFlagSizeBytes,
        [int] $LossMaxTtl = $script:DefaultSrtLossMaxTtl,
        [ValidateSet('', 'true', 'false')] [string] $NakReport = $script:DefaultSrtNakReport
    )

    if ($Protocol -eq 'tcp') {
        return @(
            '-f', 'mpegts',
            '-i', 'pipe:0',
            '-c', 'copy',
            '-f', 'mpegts',
            "tcp://${RelayHost}:${RelayPort}"
        )
    }

    $srtUrl = "srt://${RelayHost}:${RelayPort}?mode=caller&transtype=$TransmissionType&latency=$LatencyMicroseconds&pkt_size=$PacketSizeBytes&streamid=$StreamId&linger=$LingerSeconds&timeout=$ConnectionTimeoutMicroseconds"

    # A positive maxbw caps aggregate send bandwidth (originals + retransmits) to prevent the
    # uncapped-ARQ congestion collapse documented above; 0 omits it (libsrt default unlimited).
    if ($MaxBandwidthBytesPerSecond -gt 0) {
        $srtUrl += "&maxbw=$MaxBandwidthBytesPerSecond"
    }

    # TIER 1 sender-side buffer/window tuning: each option is appended only when opted in
    # (positive value / non-blank), otherwise omitted so the URL is byte-identical to the
    # pre-Tier-1 shape. See $script:DefaultSrt* comments above for the mechanism of each.
    if ($SendBufferBytes -gt 0) {
        $srtUrl += "&sndbuf=$SendBufferBytes"
    }
    if ($FlightFlagSizeBytes -gt 0) {
        $srtUrl += "&ffs=$FlightFlagSizeBytes"
    }
    if ($LossMaxTtl -gt 0) {
        $srtUrl += "&lossmaxttl=$LossMaxTtl"
    }
    if ($NakReport -ne '') {
        $srtUrl += "&nakreport=$NakReport"
    }

    return @(
        '-f', 'mpegts',
        '-i', 'pipe:0',
        '-c', 'copy',
        '-f', 'mpegts',
        $srtUrl
    )
}

function Start-FfmpegProcess {
    <#
    .SYNOPSIS
    Spawns ffmpeg (or an FfmpegPath override, for testing without a real SRT chain)
    with stdin+stderr redirected, and calls BeginErrorReadLine BEFORE returning --
    async stderr drain is active before any caller can possibly write to stdin (D-17,
    Pitfall 5 deadlock avoidance). ffmpeg stderr lines are routed to Write-Log Debug
    AND retained in a bounded, thread-safe tail buffer (last ~20 lines) on the
    returned handle so Get-FfmpegExitClassification (RES-04) has real stderr text to
    inspect after ffmpeg exits -- previously the lines were logged and discarded
    (Pitfall 1). The buffer is ring-trimmed to MaxStderrTailLines so a long outage
    cannot grow it unbounded (T-02-BUF).

    .OUTPUTS
    A handle object (Process, ErrorSubscriptionId, StderrTailLines) to pass to
    Write-FfmpegStdin, Stop-FfmpegProcess, and Get-FfmpegExitClassification.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [string] $FfmpegPath = 'ffmpeg',
        [int] $MaxStderrTailLines = $script:DefaultMaxStderrTailLines
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FfmpegPath
    foreach ($argumentValue in $ArgumentList) { $startInfo.ArgumentList.Add($argumentValue) }
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false

    $ffmpegProcess = [System.Diagnostics.Process]::new()
    $ffmpegProcess.StartInfo = $startInfo

    # Synchronized wrapper is required: the ErrorDataReceived event fires on a
    # different thread than the main loop that will later read StderrTailLines
    # (RESEARCH.md "Reading ffmpeg's stderr into a retained tail buffer").
    $stderrTailBuffer = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

    $errorSubscription = Register-ObjectEvent -InputObject $ffmpegProcess -EventName ErrorDataReceived -Action {
        if ($EventArgs.Data) {
            Write-Log -Level Debug -Message "ffmpeg stderr: $($EventArgs.Data)"
            $null = $Event.MessageData.Buffer.Add($EventArgs.Data)
            while ($Event.MessageData.Buffer.Count -gt $Event.MessageData.MaxLines) {
                $Event.MessageData.Buffer.RemoveAt(0)
            }
        }
    } -MessageData ([PSCustomObject]@{ Buffer = $stderrTailBuffer; MaxLines = $MaxStderrTailLines })

    $ffmpegProcess.Start() | Out-Null
    $ffmpegProcess.BeginErrorReadLine()   # MUST be before any stdin write (D-17)

    return [PSCustomObject]@{
        Process             = $ffmpegProcess
        ErrorSubscriptionId = $errorSubscription.Id
        StderrTailLines     = $stderrTailBuffer
        # Front A (260718-j58): holds the in-flight WriteAsync task across a transient
        # SRT flow-control stall (Write-FfmpegStdin's 'Stalled' outcome) so
        # Wait-FfmpegStdinPendingWrite can re-await the SAME task next poll -- the exact
        # bytes already handed to ffmpeg's stdin are never re-read or skipped. $null
        # whenever no write is currently stalled.
        PendingWriteTask    = $null
    }
}

function Write-FfmpegStdin {
    <#
    .SYNOPSIS
    Writes Bytes to the ffmpeg process's stdin BaseStream. A write that does not
    complete within TimeoutMilliseconds is no longer automatically treated as a hang
    (Front A, 260718-j58, T-j58-01/T-j58-02): under bond congestion ffmpeg's own SRT
    send buffer filling is NORMAL, TCP-like flow-control backpressure in file mode --
    killing the process on that first soft timeout is the exact defect this rework
    fixes (it made the relay see input EOF and cascade into a reconnect storm every
    ~8-10s). The process's own HasExited decides which of the two genuinely different
    outcomes this is:
      - still alive  -> 'Stalled': the peer/pipe is fine, just backed up. The process
        is NOT killed; the SAME pending WriteAsync task is stashed on
        $ProcessHandle.PendingWriteTask so Wait-FfmpegStdinPendingWrite can re-await
        it later -- these exact bytes are never re-read or skipped (D-04/D-05).
      - already exited -> 'Fault': the peer/pipe is genuinely gone. Unchanged from the
        prior behavior -- kill (already dead, this is a formality) and signal restart.

    The write can also FAULT immediately (not merely time out) when ffmpeg has already
    exited and the pipe is closed -- the single most likely production failure
    (relay/network drop, SRT handshake failure, demux error). $writeTask.Wait()
    rethrows that as an AggregateException, a .NET exception that ignores
    $ErrorActionPreference and would otherwise unwind the whole pusher loop and exit
    the process. Catch it here and signal restart instead (D-18, CR-01) -- this path
    is unchanged by the Front A rework.

    .OUTPUTS
    Hashtable: Success (bool), RestartNeeded (bool), FailureReason ('Stalled' | 'Fault' | $null).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $ProcessHandle,
        [Parameter(Mandatory)] [byte[]] $Bytes,
        [int] $TimeoutMilliseconds = $script:DefaultStdinWriteTimeoutMilliseconds
    )

    $stdinStream = $ProcessHandle.Process.StandardInput.BaseStream

    try {
        $writeTask = $stdinStream.WriteAsync($Bytes, 0, $Bytes.Length)
        $completedInTime = $writeTask.Wait($TimeoutMilliseconds)
    } catch {
        Write-Log -Level Error -Message "Write-FfmpegStdin: stdin write failed (ffmpeg exited/pipe closed) -- killing and signaling restart: $($_.Exception.Message)"
        Stop-FfmpegProcess -ProcessHandle $ProcessHandle -Force
        $ProcessHandle.PendingWriteTask = $null
        return @{ Success = $false; RestartNeeded = $true; FailureReason = 'Fault' }
    }

    if (-not $completedInTime) {
        # TOCTOU-guarded HasExited read (mirrors Stop-FfmpegProcess's own discipline,
        # see its header) -- a genuine race exists between the Wait() timing out and
        # ffmpeg exiting on its own in that same window.
        $processHasExited = $true
        try { $processHasExited = $ProcessHandle.Process.HasExited } catch { $processHasExited = $true }

        if ($processHasExited) {
            Write-Log -Level Error -Message "Write-FfmpegStdin: stdin write blocked beyond ${TimeoutMilliseconds}ms and ffmpeg has already exited -- killing and signaling restart"
            Stop-FfmpegProcess -ProcessHandle $ProcessHandle -Force
            $ProcessHandle.PendingWriteTask = $null
            return @{ Success = $false; RestartNeeded = $true; FailureReason = 'Fault' }
        }

        # The process is genuinely still alive: this is transient SRT flow-control
        # backpressure (the send buffer is full), not a hang. Do NOT kill -- hold the
        # SAME pending WriteAsync task so the caller can re-await it next poll rather
        # than re-reading or skipping these bytes (Front A byte-exact hold, D-04/D-05).
        Write-Log -Level Warning -Message "Write-FfmpegStdin: stdin write has not completed within ${TimeoutMilliseconds}ms but ffmpeg is still alive -- holding as transient backpressure (Stalled), not killing"
        $ProcessHandle.PendingWriteTask = $writeTask
        return @{ Success = $false; RestartNeeded = $false; FailureReason = 'Stalled' }
    }

    $ProcessHandle.PendingWriteTask = $null
    return @{ Success = $true; RestartNeeded = $false; FailureReason = $null }
}

function Wait-FfmpegStdinPendingWrite {
    <#
    .SYNOPSIS
    Re-awaits the SAME in-flight WriteAsync task a prior Write-FfmpegStdin call left on
    $ProcessHandle.PendingWriteTask (its 'Stalled' outcome) for another soft window
    (Front A, 260718-j58). This is what lets the pusher hold ONE SRT session through
    transient bond backpressure instead of re-reading, skipping, or duplicating bytes:
    the exact same task object -- not a new write of the same bytes -- is what gets
    re-awaited here.

      - task completes successfully within the window -> 'Success': clears
        PendingWriteTask, the caller advances its accepted-position exactly as any
        other successful write.
      - task faults, OR the process has exited -> 'Fault': force-stops the process
        (mirrors Write-FfmpegStdin's own Fault path) and signals restart -- the hold
        is over because the peer/pipe is genuinely gone.
      - still pending AND the process is alive -> 'Stalled': PendingWriteTask is left
        in place for the caller to poll again; the caller decides (against its own
        bounded SRT_STALL_TOLERANCE_SECONDS ceiling) whether to keep holding or
        escalate to a reconnect.

    Guarded the same TOCTOU-safe way Stop-FfmpegProcess/Write-FfmpegStdin already are:
    every Process/Task read that could race a genuine mid-check exit is wrapped so it
    can never escape this function as an uncaught throw (the never-throw contract,
    D-10).

    .OUTPUTS
    Hashtable: Success (bool), RestartNeeded (bool), FailureReason ('Stalled' | 'Fault' | $null).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $ProcessHandle,
        [int] $TimeoutMilliseconds = $script:DefaultStdinWriteTimeoutMilliseconds
    )

    $pendingTask = $ProcessHandle.PendingWriteTask
    if ($null -eq $pendingTask) {
        # Defensive: a caller should only reach here when a prior Stalled outcome left
        # a task in place. Nothing pending is trivially "already done".
        return @{ Success = $true; RestartNeeded = $false; FailureReason = $null }
    }

    $completedInTime = $false
    $waitFaulted = $false
    try {
        $completedInTime = $pendingTask.Wait($TimeoutMilliseconds)
    } catch {
        $waitFaulted = $true
    }

    if ($completedInTime -and -not $waitFaulted) {
        $ProcessHandle.PendingWriteTask = $null
        return @{ Success = $true; RestartNeeded = $false; FailureReason = $null }
    }

    if ($waitFaulted) {
        Write-Log -Level Error -Message "Wait-FfmpegStdinPendingWrite: pending stdin write faulted (ffmpeg exited/pipe closed) -- killing and signaling restart"
        Stop-FfmpegProcess -ProcessHandle $ProcessHandle -Force
        $ProcessHandle.PendingWriteTask = $null
        return @{ Success = $false; RestartNeeded = $true; FailureReason = 'Fault' }
    }

    # Not completed and the Wait() itself did not throw -- check for a TOCTOU exit the
    # same way Write-FfmpegStdin does before deciding this is still a live hold.
    $processHasExited = $true
    try { $processHasExited = $ProcessHandle.Process.HasExited } catch { $processHasExited = $true }

    if ($processHasExited) {
        Write-Log -Level Error -Message "Wait-FfmpegStdinPendingWrite: ffmpeg exited while a stdin write was still pending -- killing and signaling restart"
        Stop-FfmpegProcess -ProcessHandle $ProcessHandle -Force
        $ProcessHandle.PendingWriteTask = $null
        return @{ Success = $false; RestartNeeded = $true; FailureReason = 'Fault' }
    }

    # Still pending, process still alive -- keep holding (PendingWriteTask left in
    # place for the caller's next poll).
    return @{ Success = $false; RestartNeeded = $false; FailureReason = 'Stalled' }
}

function Stop-FfmpegProcess {
    <#
    .SYNOPSIS
    Closes stdin (letting ffmpeg drain/exit gracefully) and kills the process if it has
    not exited within a bounded wait, or immediately when -Force is set (the D-18 hang
    path). Always unregisters the stderr event subscription registered by
    Start-FfmpegProcess.

    Kill()/WaitForExit() are wrapped in their own try/catch (RES-01 bug fix, 02-07):
    HasExited is read once, then acted on -- a genuine TOCTOU race exists between that
    check and the Kill() call, and it is not theoretical: a real mid-push SRT-listener
    death is exactly the case where ffmpeg can exit ON ITS OWN (from its own "I/O error"
    -> process exit) in the brief window between the check and the call. When that
    happens, Kill() throws InvalidOperationException("...the process has exited") --
    and since this is called from Write-FfmpegStdin's Fault-path catch block under
    Set-StrictMode/$ErrorActionPreference='Stop', an uncaught throw here unwinds the
    ENTIRE pusher.ps1 main loop and exits the whole process, directly violating D-10
    ("the pusher must never exit on a network outage") -- the process being already
    dead is exactly the outcome this call was trying to achieve, so that specific
    exception is expected/benign here and must never escape.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $ProcessHandle,
        [int] $GracefulExitTimeoutMilliseconds = 5000,
        [switch] $Force
    )

    $ffmpegProcess = $ProcessHandle.Process

    try {
        if (-not $ffmpegProcess.HasExited) {
            if ($Force) {
                try { $ffmpegProcess.Kill($true) } catch { }
            } else {
                try { $ffmpegProcess.StandardInput.Close() } catch { }
                $alreadyExited = $false
                try { $alreadyExited = $ffmpegProcess.WaitForExit($GracefulExitTimeoutMilliseconds) } catch { }
                if (-not $alreadyExited) {
                    try { $ffmpegProcess.Kill($true) } catch { }
                }
            }
            try { $ffmpegProcess.WaitForExit(5000) | Out-Null } catch { }
        }
    } finally {
        if ($ProcessHandle.ErrorSubscriptionId) {
            Unregister-Event -SubscriptionId $ProcessHandle.ErrorSubscriptionId -ErrorAction SilentlyContinue
        }
    }
}

function Get-FfmpegExitClassification {
    <#
    .SYNOPSIS
    Pure classifier (RES-04, D-09): maps the three failure signals Write-FfmpegStdin
    and Start-FfmpegProcess now expose -- FailureReason, ffmpeg's own ExitCode, the
    retained StderrTailLines, and whether the recording file is still growing -- to
    one of NetworkDeath / FfmpegCrash / RecordingEnded. This decides which backoff
    policy applies (D-10: NetworkDeath/RecordingEnded get exponential full-jitter
    backoff; FfmpegCrash gets a short/no delay) and what gets logged; it never itself
    stops the pusher -- RecordingEnded is a log/metrics-only label in Phase 2, the
    identical reconnect+resume action as NetworkDeath (D-11). A stop-on-RecordingEnded
    control path is explicitly out of scope until Phase 3 (D-10, Pitfall 3).

    FailureReason='Hang' short-circuits straight to NetworkDeath: severe stdin
    backpressure with the process still alive (forcibly killed by the watchdog, never
    self-reporting anything) is a network/relay-side symptom, not an internal ffmpeg
    fault (Anti-Patterns note, RESEARCH.md).

    Otherwise StderrTailLines is scanned against $networkDeathPatterns -- fixed,
    reviewed, non-backtracking substrings grounded in tests/fixtures/ffmpeg-srt-failure-stderr.txt,
    this project's own real captured mid-push SRT-listener-kill output on its gyan.dev
    ffmpeg 7.1 build (02-01-SUMMARY.md ground truth), NOT the original RESEARCH.md
    web-search guesses -- only "I/O error" was actually observed verbatim. Patterns
    are never constructed dynamically and stderr text is never passed to
    Invoke-Expression (ASVS V5, T-02-REDOS).

    ExitCode is treated as a weak tie-breaker only: Assumption A1 (RESEARCH.md) notes
    this ffmpeg/Windows build likely returns a generic non-zero code for most
    failures, so a clean ExitCode=0 combined with a non-growing recording file is the
    RecordingEnded signal; anything else that doesn't match Hang or a NetworkDeath
    pattern falls through to FfmpegCrash.

    .OUTPUTS
    String: 'NetworkDeath' | 'FfmpegCrash' | 'RecordingEnded'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateSet('Hang', 'Fault')] [string] $FailureReason,
        [int] $ExitCode,
        [string[]] $StderrTailLines = @(),
        [Parameter(Mandatory)] [bool] $RecordingFileStillGrowing
    )

    if ($FailureReason -eq 'Hang') {
        return 'NetworkDeath'
    }

    # Grounded in tests/fixtures/ffmpeg-srt-failure-stderr.txt (02-01-SUMMARY.md ground
    # truth) -- "I/O error" is the one substring from RESEARCH.md's original
    # LOW-confidence candidate list that was actually observed verbatim, present in
    # both the mid-push and pre-connect failure shapes on this build.
    $networkDeathPatterns = @(
        'I/O error'
    )
    foreach ($pattern in $networkDeathPatterns) {
        foreach ($line in $StderrTailLines) {
            if ($line -match $pattern) { return 'NetworkDeath' }
        }
    }

    if (-not $RecordingFileStillGrowing -and $ExitCode -eq 0) {
        return 'RecordingEnded'
    }

    return 'FfmpegCrash'
}

Export-ModuleMember -Function Build-FfmpegArguments, Start-FfmpegProcess, Write-FfmpegStdin, Wait-FfmpegStdinPendingWrite, Stop-FfmpegProcess, Get-FfmpegExitClassification

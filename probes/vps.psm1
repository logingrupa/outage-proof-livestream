# probes/vps.psm1
# The one shipped plugin (MON-03) and the first real implementation of the phase's
# plugin contract (MON-01/D-01): a single PowerShell module exporting exactly one
# function, Invoke-Probe -Config, returning the D-02 normalized schema WITHOUT
# timestamps -- the HOST (lib/ProbeStore.psm1's Save-ProbeResult, via lib/ProbeHost.psm1)
# stamps updatedEpochSeconds/staleAfterEpochSeconds at persist time, mirroring why
# Save-PusherStats -- not its caller -- owns the identical staleness math (D-07).
#
# Three legs measure the path that is ACTUALLY in production (D-07/CHUR-02), selected and
# combined by Invoke-Probe -- none of them ever mutates the VPS, the OMR router, or the
# tunnel (read-only observation only, per this plan's own threat register):
#
# 1. Reachability/Port leg -- branches on Config.RelayProtocol (D-07/D-10):
#    'srt' is the BREAK-GLASS branch, unchanged since 06-01: Test-SrtInductionReachability-
#    WithRetry sends ONLY the SRT handshake INDUCTION request over a raw UdpClient, NEVER
#    the Conclusion phase, so it cannot establish or interfere with the pusher's own live
#    SRT connection (A2) -- this is a stateless UDP probe that never touches ffmpeg's TCP
#    listener, so it carries none of the risk described below.
#    'tcp' (production since the 2026-07-26 cutover) is now ENTIRELY PASSIVE (260809-oc4,
#    third-round live finding): there is no active TCP connect anywhere in this module
#    against the relay port. A prior design (Test-TcpRelayPortReachable, deleted) opened a
#    real TcpClient connection through the ssh -L forward to the VPS's ffmpeg
#    tcp://127.0.0.1:<port>?listen input -- ffmpeg's TCP listen is SINGLE-ACCEPT, so every
#    probe poll's empty connect was itself accepted, ffmpeg then read EOF and exited
#    ("Invalid data found when processing input"), and systemd auto-restarted it: 576
#    ingest restarts in one day on the VPS, NRestarts=1584. It was ALSO a false-negative
#    generator the other direction -- during a real live stream the listener is already
#    busy (one session accepted), so the probe's own connect was refused and the leg
#    reported 'closed' exactly when a real session was healthy. The tcp path's Port state
#    is now read PASSIVELY, piggybacked onto the SAME single SSH round trip as the unit-
#    health leg below (`ss` against the VPS's own loopback socket table), never a network
#    connection this process initiates against the relay port.
# 2. Tunnel leg (tcp path only) -- Test-LocalTunnelProcessAlive, a purely LOCAL
#    (church-PC-side) check with no SSH round trip: is the GaplessTcpRelayTunnel Scheduled
#    Task actually Running. Not applicable on the srt path (no ssh -L forward exists there).
# 3. The OPTIONAL SSH unit-health-and-port leg (15-02/D-07/D-09, extended 260809-oc4) runs
#    ssh.exe as a plain external process (never PowerShell SSH Remoting -- see
#    06-RESEARCH.md) via -ArgumentList as an ARRAY, never a concatenated string -- the ASVS
#    V5/Tampering control (T-06-02/T-15-02-01) that keeps an attacker-influenced .env SSH
#    host/user/keypath/port value from injecting extra ssh flags or a second command. ONE
#    remote command (`systemctl is-active <3 units>`, and on the tcp path ONLY, a trailing
#    `; echo ---; ss -Htan '( sport = :<port> )'` section, THEN (260830-ffp, D-01) a second
#    `echo ---` plus a per-channel egress loop) covers unit health, Port state, AND the two
#    YouTube egress rows in the SAME SSH round trip -- Test-SmoothRelayHealth replaces the old ambiguous
#    `pgrep -f 'ffmpeg.*-c copy'` leg, which matched all three of the current architecture's
#    processes indistinguishably. It degrades gracefully (never a hard failure) when SSH is
#    unconfigured, when ssh.exe is absent from PATH (Pitfall 3), or when the ssh invocation
#    itself times out (Pitfall 2's outer WaitForExit+Kill hard ceiling, mirroring
#    lib/FfmpegProcess.psm1's Stop-FfmpegProcess TOCTOU-safe idiom). A reply that cannot be
#    cleanly aligned (missing section separator, or the wrong number of systemctl status
#    lines -- a truncated write from the hard-timeout kill) is retried EXACTLY ONCE with no
#    sleep, before falling back to all-unknown (260809-oc4); Invoke-SshCommand itself always
#    spawns ssh.exe with CreateNoWindow=$true so an unattended poll never flashes a console
#    window at the operator, and reads its full stdout via ReadToEndAsync (never the earlier
#    Register-ObjectEvent design, which lost the tail line under a real async-drain race --
#    see Invoke-SshCommand's own header). Invoke-Probe reaches this leg only through the
#    60-second-throttled Get-ThrottledSmoothRelayUnitStates seam (Task 2), never a per-poll
#    SSH round trip -- which ALSO means, since 260809-oc4, the tcp path's Port state now
#    refreshes at the SAME 60-second cadence as unit health, not every poll: a real down
#    event on the tcp path can take up to 60s to surface, a deliberate tradeoff against the
#    restart-storm the removed active connect was causing.
#
# Exports: Invoke-Probe

Set-StrictMode -Version Latest

# 260809-oc4: Clock.psm1 is this repo's single shared clock -- explicitly documented to
# import nothing and have zero import side effects (safe inside the probe host's
# throwaway child runspace, ProbeHost.psm1's Invoke-ProbeWithTimeout), and it is the SAME
# clock lib/ProbeStore.psm1's Save-ProbeResult stamps updatedEpochSeconds/
# staleAfterEpochSeconds with -- using it here for the SSH-leg cache's own timestamps
# means a cache age and the probe's own staleness math can never drift onto two
# independent clock origins. Never re-implement the Stopwatch math locally.
Import-Module (Join-Path $PSScriptRoot '../lib/Clock.psm1')

$script:ProbeName = 'vps-relay'
$script:ProbeTitle = 'VPS Relay'
$script:DefaultReachabilityTimeoutMilliseconds = 2000
# DASH-03: a single dropped UDP induction packet under a saturated bond must never
# misreport the relay as down (confirmed live, 2026-07-18 shakeout, brief #3) -- see
# Test-SrtInductionReachabilityWithRetry's own header for the retry contract this
# attempt budget bounds.
$script:DefaultReachabilityAttemptCount = 3
$script:DefaultSshConnectTimeoutSeconds = 5
$script:DefaultSshHardTimeoutMilliseconds = 8000
# 16-byte control header + 48-byte handshake CIF, per 06-01-SUMMARY.md's CONFIRMED
# byte layout (spike/Confirm-SrtInductionProbe.ps1, run 3x consecutively, PASS every
# time against a real ffmpeg/libsrt listener). Copied verbatim -- see that file's
# New-SrtInductionPacketBytes for the byte-by-byte commentary this mirrors.
$script:MinimumHandshakeResponseBytes = 48
# D-07 (superseded 2026-08-09, quick task 260809-oc4): the three production smooth-relay
# units, hardcoded literals never assembled from any .env value (T-15-02-01/ASVS V5) -- a
# malformed or hostile .env host/user/keypath/port cannot reach these names. One SSH round
# trip via `systemctl is-active <unit1> <unit2> <unit3>` covers all three (RESEARCH.md
# "Don't Hand-Roll": systemctl already accepts multiple unit names and prints one status
# line per unit, in request order). The two YouTube channel units are spelled as the
# systemd TEMPLATE INSTANCE form (`smooth-youtube@lv.service` / `smooth-youtube@ru.service`)
# -- confirmed live on 2026-08-09 via `systemctl list-units --state=running` on the VPS,
# matching the relay-side systemd unit templates that the deployment installs. This
# supersedes 15-02's earlier planned hyphen-before-channel spelling
# (`smooth-youtube-lv.service` / `smooth-youtube-ru.service`), which systemd never
# actually instantiates -- that spelling left the dashboard's YouTube LV/RU rows
# permanently reporting unknown/inactive.
$script:SmoothRelayUnitNames = @(
    'smooth-ingest-tcp.service',
    'smooth-youtube@lv.service',
    'smooth-youtube@ru.service'
)
# Maps each hardcoded unit name to its operator-facing metric label (D-07/UI-SPEC "VPS
# Health Pill" 5 fixed check rows) -- the dashboard consumes exactly these three labels
# plus Tunnel/Port (added in Task 2/3).
$script:SmoothRelayUnitMetricLabels = @{
    'smooth-ingest-tcp.service' = 'Ingest'
    'smooth-youtube@lv.service' = 'YouTube LV'
    'smooth-youtube@ru.service' = 'YouTube RU'
}
# The Task Scheduler task registered by install.ps1's Register-TunnelScheduledTask
# ($script:TunnelTaskName = 'GaplessTcpRelayTunnel') -- a hardcoded literal matching
# install.ps1 exactly, never .env-sourced, since the tunnel leg is a purely local
# (church-PC-side) check with no SSH round trip.
$script:TunnelScheduledTaskName = 'GaplessTcpRelayTunnel'
# 260809-oc4 (live 2026-08-09 observation): a fresh ssh.exe round trip roughly every ~20s
# (lib/ProbeHost.psm1's $script:DefaultPollIntervalSeconds) is hotter than a health pill
# needs -- the SSH leg only answers "is a unit active"/"is the relay port in use", facts
# that do not meaningfully change tick-to-tick. The local Scheduled-Task leg
# (Test-LocalTunnelProcessAlive) deliberately keeps the fast per-poll cadence (it is purely
# local, no network round trip). The tcp path's Port state, since the third-round
# 260809-oc4 redesign, is now READ FROM this same throttled leg (an active TCP connect
# against the relay port was removed entirely -- see the module header) -- so down-
# detection on the tcp path is now bounded by this 60-second cadence, not the old ~20s
# poll interval. That tradeoff is deliberate: the removed active connect was causing a
# real restart storm (576 ingest restarts/day on the VPS) precisely BECAUSE it ran every
# poll.
$script:SshLegMinimumIntervalSeconds = 60
# Bumped whenever the cache payload's own shape changes incompatibly -- 2 as of 260809-oc4
# (added the portState field alongside unitStates), 3 as of 260830-ffp (added the
# egressStates field alongside unitStates/portState, D-06); a stored schemaVersion
# mismatch (or its absence) makes Read-SshLegCache discard the file exactly like a
# corrupt one, never a StrictMode surprise on a stale-shaped payload. This also means a
# cache file written by ANY pre-260830-ffp module version (schemaVersion 1 or 2, missing
# egressStates entirely) is automatically discarded on the first poll after a bounce,
# rather than silently missing EgressStates. 4 as of 260906-i2k (added the readerHealth
# field, D-11): every schemaVersion-3 payload predates the reader-health counters, so
# bumping is what forces the SSH leg to re-run once and populate them instead of the
# Rotations/Discontinuities rows reading 'unknown' for up to a full throttle interval.
$script:SshLegCacheSchemaVersion = 4
$script:SshLegCacheFileName = 'vps-probe-ssh-cache.json'
# 260809-oc4: the deterministic alignment marker printed BETWEEN the `systemctl is-active`
# section and the `ss` section of the single combined SSH remote command (tcp path only) --
# the ONE literal both Test-SmoothRelayHealth's remote-command builder and
# Invoke-SmoothRelayStatusCheck's parser share, so they can never drift apart. A reply
# missing this exact line (a truncated write, or ssh itself mangling something) cannot be
# aligned at all and is treated as fully unknown (both unit states AND Port state), never a
# guessed split.
$script:SmoothRelaySshSectionSeparator = '---'
# 260830-ffp (D-04): a channel is reported 'sending' when its ffmpeg child's lastsnd
# (milliseconds since the kernel last sent data on that TCP socket) is below this
# threshold, else 'stalled Ns'. Set comfortably above the 60s SSH-leg throttle
# ($script:SshLegMinimumIntervalSeconds) divided by 6 -- a sample this stale already
# tolerates multi-second gaps between polls, so 10s of no send activity is a real,
# actionable stall signal, not throttle-interval jitter.
$script:VpsEgressStalledThresholdMilliseconds = 10000
# 260906-i2k (D-09): the VPS-side path smooth-watchdog-ingest.sh publishes its two
# reader-health counters to, once per 1-minute watchdog tick. Hardcoded as a module-scope
# literal rather than read from any env var, because the remote command runs in a
# NON-LOGIN shell over ssh where the watchdog's own WATCHDOG_STATE_DIR does not exist --
# an env read there would silently resolve to nothing and cat a bare '/reader-health'.
# Must stay in step with $READER_HEALTH_FILE's default in
# tools/smooth-relay/smooth-watchdog-ingest.sh.
$script:VpsReaderHealthRemotePath = '/run/smooth-watchdog/reader-health'

function New-SrtInductionPacketBytes {
    <#
    .SYNOPSIS
    Builds the 64-byte SRT handshake INDUCTION request packet, byte-for-byte identical
    to spike/Confirm-SrtInductionProbe.ps1's New-SrtInductionPacketBytes (06-01's
    CONFIRMED, empirically-proven-safe layout). Never builds a Conclusion packet (A2).

    .OUTPUTS
    byte[] -- the 64-byte induction request payload.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [uint32] $OwnSocketId = 0x1234ABCD,
        [uint32] $InitialPacketSequenceNumber = 0
    )

    $packet = New-Object byte[] 64

    function Set-UInt32BigEndian {
        param([byte[]] $Buffer, [int] $Offset, [uint32] $Value)
        $Buffer[$Offset]     = [byte](($Value -shr 24) -band 0xFF)
        $Buffer[$Offset + 1] = [byte](($Value -shr 16) -band 0xFF)
        $Buffer[$Offset + 2] = [byte](($Value -shr 8)  -band 0xFF)
        $Buffer[$Offset + 3] = [byte]($Value -band 0xFF)
    }

    # bytes 0-3: top bit=1 (control packet) | control type 0x0000 (handshake) | reserved=0.
    # Set directly rather than via Set-UInt32BigEndian -Value 0x80000000 -- PowerShell
    # parses that hex literal as a negative Int32 first, which fails UInt32 parameter
    # binding (06-01's Deviation 1, reproduced here deliberately).
    $packet[0] = 0x80
    $packet[1] = 0x00
    $packet[2] = 0x00
    $packet[3] = 0x00
    # bytes 4-7: type-specific info (unused for handshake) = 0
    # bytes 8-11: timestamp (32-bit, microseconds since socket start) = 0, acceptable for an induction probe
    # bytes 12-15: destination SRT socket id = 0 (first induction request)

    Set-UInt32BigEndian -Buffer $packet -Offset 16 -Value 4     # HS Version = 4 (legacy/induction)
    Set-UInt32BigEndian -Buffer $packet -Offset 20 -Value 0     # bytes 20-21 Encryption Field=0, 22-23 Extension Field=0
    Set-UInt32BigEndian -Buffer $packet -Offset 24 -Value $InitialPacketSequenceNumber
    Set-UInt32BigEndian -Buffer $packet -Offset 28 -Value 1500  # Maximum Transmission Unit size
    Set-UInt32BigEndian -Buffer $packet -Offset 32 -Value 8192  # Maximum Flow Window Size
    Set-UInt32BigEndian -Buffer $packet -Offset 36 -Value 1     # Handshake Type = 1 (INDUCTION)
    Set-UInt32BigEndian -Buffer $packet -Offset 40 -Value $OwnSocketId
    Set-UInt32BigEndian -Buffer $packet -Offset 44 -Value 0     # SYN Cookie = 0 on the initial induction request
    # bytes 48-63: Peer IP Address (128 bits) -- left zero-filled; never claims a real
    # routable peer address, matching the "never send Conclusion" minimalism (A2).

    return , $packet
}

function Test-LooksLikeSrtHandshakeResponse {
    <#
    .SYNOPSIS
    Best-effort sanity check that a UDP reply looks like a plausible SRT/UDT
    control-packet handshake response: minimum length and the control-packet top bit.
    Mirrors spike/Confirm-SrtInductionProbe.ps1's identical helper verbatim.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([byte[]] $Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -lt $script:MinimumHandshakeResponseBytes) {
        return $false
    }
    return (($Bytes[0] -band 0x80) -eq 0x80)
}

function Test-SrtInductionReachability {
    <#
    .SYNOPSIS
    Sends ONLY the SRT handshake INDUCTION request via a raw UdpClient and waits for a
    reply -- NEVER the Conclusion phase (A2), so this exchange cannot establish or
    interfere with the pusher's own live SRT connection to the same relay (06-01's
    spike proved this empirically: a concurrent real push completed byte-identical
    while this probe ran against the same listener port). A SocketException (timeout,
    or the WSAECONNRESET-on-UDP ICMP-port-unreachable quirk on some Windows stacks)
    always yields a FAIL verdict, never an unhandled exception (Pitfall 1: ReceiveTimeout
    is always set before Receive() -- a UdpClient blocks forever otherwise).

    .OUTPUTS
    PSCustomObject: Reachable (bool), LatencyMilliseconds (double or $null),
    Detail (string).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $RelayHost,
        [Parameter(Mandatory)] [int] $RelayPort,
        [int] $TimeoutMilliseconds = $script:DefaultReachabilityTimeoutMilliseconds
    )

    $result = [ordered]@{
        Reachable           = $false
        LatencyMilliseconds = $null
        Detail              = $null
    }

    $udpClient = [System.Net.Sockets.UdpClient]::new()
    try {
        $udpClient.Client.ReceiveTimeout = $TimeoutMilliseconds
        $udpClient.Connect($RelayHost, $RelayPort)

        $inductionPacket = New-SrtInductionPacketBytes
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        [void] $udpClient.Send($inductionPacket, $inductionPacket.Length)

        $remoteEndpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $responseBytes = $udpClient.Receive([ref] $remoteEndpoint)   # throws SocketException on timeout
        $stopwatch.Stop()

        if (-not (Test-LooksLikeSrtHandshakeResponse -Bytes $responseBytes)) {
            $result.Detail = "unexpected reply ($($responseBytes.Length) bytes) -- does not look like an SRT handshake response"
            return [pscustomobject] $result
        }

        $result.Reachable = $true
        $result.LatencyMilliseconds = $stopwatch.Elapsed.TotalMilliseconds
        $result.Detail = "induction response received ($($responseBytes.Length) bytes) in $([math]::Round($stopwatch.Elapsed.TotalMilliseconds, 2))ms"
    } catch [System.Net.Sockets.SocketException] {
        $result.Detail = "no response within ${TimeoutMilliseconds}ms (SocketException: $($_.Exception.Message))"
    } catch {
        # Any other unexpected failure (e.g. a malformed RelayHost) still yields a FAIL
        # verdict, never an unhandled exception out of a probe module (MON-05's
        # isolation still applies, but a probe should never need the outer runspace
        # timeout to survive its own I/O errors).
        $result.Detail = "reachability probe failed: $($_.Exception.Message)"
    } finally {
        $udpClient.Close()
    }

    return [pscustomobject] $result
}

function Test-SrtInductionReachabilityWithRetry {
    <#
    .SYNOPSIS
    Private (never exported): protects against a single dropped UDP induction packet
    misreporting the relay as down under a saturated bond (brief #3, DASH-03 --
    confirmed live during the 2026-07-18 shakeout). Retries the existing single-shot
    Test-SrtInductionReachability sequentially, up to a small bounded attempt budget
    (default 3, $script:DefaultReachabilityAttemptCount), returning Reachable=$true
    IMMEDIATELY on the first attempt that succeeds -- a healthy relay never wastes a
    second or third probe (short-circuit). Only when EVERY attempt in the budget fails
    is Reachable=$false returned, carrying the LAST failing attempt's own Detail (the
    most recent evidence, not the first).

    On success, this returns THAT succeeding attempt's own LatencyMilliseconds
    verbatim -- never averaged across attempts -- consistent with the existing
    single-shot probe's semantics (a retry changes WHETHER the relay is reported
    reachable, never HOW the reported latency is computed).

    Purely sequential, with NO sleep between attempts: a dropped UDP packet is an
    already-timed-out event by the time Test-SrtInductionReachability's own
    TimeoutMilliseconds returns -- inserting a fixed inter-attempt delay would only
    inflate the down-detection latency this fix exists to protect, for zero benefit
    (there is nothing to wait for between attempts). Bounded worst case: this adds at
    most (AttemptCount - 1) x TimeoutMilliseconds versus the old single-shot probe on a
    genuinely down relay (default 3 attempts x 2000ms timeout = up to 4000ms added),
    all sequential, never overlapping.

    .OUTPUTS
    PSCustomObject: Reachable (bool), LatencyMilliseconds (double or $null), Detail (string).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $RelayHost,
        [Parameter(Mandatory)] [int] $RelayPort,
        [int] $TimeoutMilliseconds = $script:DefaultReachabilityTimeoutMilliseconds,
        [int] $AttemptCount = $script:DefaultReachabilityAttemptCount
    )

    $lastResult = $null
    for ($attemptNumber = 1; $attemptNumber -le $AttemptCount; $attemptNumber++) {
        $lastResult = Test-SrtInductionReachability -RelayHost $RelayHost -RelayPort $RelayPort -TimeoutMilliseconds $TimeoutMilliseconds
        if ($lastResult.Reachable) {
            return $lastResult
        }
    }

    return $lastResult
}

function Test-VpsSshLegConfigured {
    <#
    .SYNOPSIS
    Private (never exported): true only when all three SSH-leg settings
    (ProbeVpsSshHost/ProbeVpsSshUser/ProbeVpsSshKeyPath) are non-blank. D-09's SSH leg
    is entirely optional -- any one missing value means "not configured", never a
    partial/broken attempt.

    .OUTPUTS
    Bool.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Config
    )

    return (-not [string]::IsNullOrWhiteSpace($Config.ProbeVpsSshHost)) `
        -and (-not [string]::IsNullOrWhiteSpace($Config.ProbeVpsSshUser)) `
        -and (-not [string]::IsNullOrWhiteSpace($Config.ProbeVpsSshKeyPath))
}

function Test-LocalTunnelProcessAlive {
    <#
    .SYNOPSIS
    Purely LOCAL (church-PC-side) tunnel-alive leg (D-07), no SSH round trip: checks
    whether the GaplessTcpRelayTunnel Scheduled Task (install.ps1's
    Register-TunnelScheduledTask) is actually Running. Never throws -- an absent task, an
    absent ScheduledTasks module/cmdlet, or any other Get-ScheduledTask failure all
    resolve to a genuinely unknown ($null) verdict, never a fabricated "not running": a
    live process with a dead forward is a real, distinguishable failure this leg exists to
    catch, but "the task couldn't even be queried" is not evidence of either state.

    .OUTPUTS
    PSCustomObject: Running ($true|$false|$null -- $null means genuinely unknown), Detail
    (string or $null).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $ScheduledTaskName = $script:TunnelScheduledTaskName
    )

    try {
        $task = Get-ScheduledTask -TaskName $ScheduledTaskName -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            return [pscustomobject]@{ Running = $null; Detail = "Scheduled Task '$ScheduledTaskName' not found" }
        }
        if ($task.State -eq 'Running') {
            return [pscustomobject]@{ Running = $true; Detail = $null }
        }
        return [pscustomobject]@{ Running = $false; Detail = "Scheduled Task '$ScheduledTaskName' state is '$($task.State)'" }
    } catch {
        return [pscustomobject]@{ Running = $null; Detail = "could not read Scheduled Task '$ScheduledTaskName': $($_.Exception.Message)" }
    }
}

function Invoke-SshCommand {
    <#
    .SYNOPSIS
    Private (never exported) process-invocation seam (CR-02): spawns ssh.exe as a plain
    external process via [System.Diagnostics.Process] + ProcessStartInfo.ArgumentList --
    a real Collection<string>, each element preserved byte-for-byte with no shell-style
    re-joining -- NEVER Start-Process's -ArgumentList, which silently flattens an array
    into one space-joined string with no quoting (a long-standing, documented PowerShell
    behavior: https://github.com/PowerShell/PowerShell/issues/5576), mirroring
    lib/FfmpegProcess.psm1's Start-FfmpegProcess argument-construction discipline exactly.
    The caller (Test-SmoothRelayHealth) is REQUIRED to place a '--' end-of-options
    separator before any positional/attacker-influenceable argument -- this function does
    not add one itself, since it has no opinion on which elements are positional.

    Stdout drain (260809-oc4, replacing an earlier BeginOutputReadLine + Register-
    ObjectEvent design): StandardOutput.ReadToEndAsync() is started immediately after
    Start(), BEFORE the timed WaitForExit(HardTimeoutMilliseconds) below -- a real
    Task[string] driven entirely by .NET's own I/O completion, reading until the child's
    stdout pipe reaches EOF (i.e. the child has exited and its stdout handle is closed).
    This is deliberately NOT a blocking ReadToEnd() call made BEFORE the timed wait (that
    would defeat the hard-timeout kill below, since it has no bound of its own) -- it is
    an ASYNC read raced against the SAME outer timeout via the Task's own bounded .Wait()
    after the process has already exited. This replaced the original
    BeginOutputReadLine()/Register-ObjectEvent(OutputDataReceived) design (still the
    right idiom for a LIVE stderr tail buffer read continuously while a long-running
    process is alive, e.g. lib/FfmpegProcess.psm1's stderr tail) because a live 2026-08-09
    post-bounce finding proved TWO independent races stack on top of each other for a
    short-lived, read-once-after-exit command like this one: (1) the documented .NET
    contract that a timed WaitForExit(ms) returning true does NOT guarantee the redirected
    -output events have finished delivering (Microsoft requires a follow-up parameterless
    WaitForExit() to force that drain) and (2) PowerShell's OWN Register-ObjectEvent
    subscription mechanism queues the .NET event onto the engine's separate PSEventManager
    queue, which is drained on its own schedule -- a SECOND, PowerShell-specific source of
    lag the .NET-level fix alone does not close. ReadToEndAsync() sidesteps both: there is
    no incremental per-line event delivery to race at all, only one Task whose completion
    IS "the entire stream has been read", confirmed empirically deterministic (this
    function's own async-drain test in tests/ProbeVps.Tests.ps1 flaked ~1-in-20 with the
    Register-ObjectEvent design even after the WaitForExit()-after-WaitForExit(ms) fix,
    and is 20-for-20 with this design).

    ConnectTimeout (an -o option the caller supplies inside ArgumentList) bounds the
    TCP-connect phase only (Pitfall 2 -- a documented Win32-OpenSSH quirk means it is not
    a guaranteed hard ceiling on the whole invocation), so the OUTER
    WaitForExit(HardTimeoutMilliseconds) + Kill($true) here is the real safety net,
    mirroring lib/FfmpegProcess.psm1's Stop-FfmpegProcess TOCTOU-safe try/catch-every-call
    idiom -- the child can also finish or fault in the brief window between the check and
    the kill.

    ExecutableFileName defaults to 'ssh.exe' for every real caller -- it exists as a
    parameter (260809-oc4) purely as a test seam, so tests/ProbeVps.Tests.ps1 can point a
    REAL [System.Diagnostics.Process] at pwsh.exe (a short stub script printing N lines)
    to exercise the actual stdout-drain behavior below with a real process, rather than
    only ever mocking this function.

    .OUTPUTS
    PSCustomObject: TimedOut (bool), OutputLines (string[], trimmed non-blank stdout
    lines), Detail (string or $null -- non-null only when the process itself failed to
    start/run, distinct from a clean timeout or a clean exit with unexpected output).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [Parameter(Mandatory)] [int] $HardTimeoutMilliseconds,
        [string] $ExecutableFileName = 'ssh.exe'
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExecutableFileName
    foreach ($argumentValue in $ArgumentList) { $startInfo.ArgumentList.Add($argumentValue) }
    $startInfo.RedirectStandardOutput = $true
    $startInfo.UseShellExecute = $false
    # The supervisor runs headless (a Scheduled Task, no interactive desktop session an
    # operator is expected to watch) -- a per-poll console window would steal operator
    # focus mid-service every time this leg fires (found live, 2026-08-09).
    $startInfo.CreateNoWindow = $true

    $sshProcess = [System.Diagnostics.Process]::new()
    $sshProcess.StartInfo = $startInfo

    try {
        $sshProcess.Start() | Out-Null

        # Started BEFORE the timed wait below -- see .SYNOPSIS. This Task completes once
        # the child's stdout reaches EOF; it is not bounded here, only raced via the
        # bounded .Wait() call below, AFTER the process itself has already been confirmed
        # exited (or killed) by the outer hard timeout.
        $outputReadTask = $sshProcess.StandardOutput.ReadToEndAsync()

        $exitedInTime = $false
        try { $exitedInTime = $sshProcess.WaitForExit($HardTimeoutMilliseconds) } catch { }

        if (-not $exitedInTime) {
            try { $sshProcess.Kill($true) } catch { }
            return [pscustomobject]@{ TimedOut = $true; OutputLines = @(); Detail = $null }
        }

        # The process has exited, so its stdout handle is closed and $outputReadTask
        # should already be complete or complete within microseconds -- this bounded
        # .Wait() is defensive (never block the probe forever on a read task that, for
        # some unforeseen reason, never completes), not an expected-to-actually-wait
        # step. A task that fails to complete in time degrades to zero captured lines
        # (the existing line-count-mismatch retry path already treats that safely),
        # never a thrown exception out of this function.
        $rawOutput = ''
        try {
            if ($outputReadTask.Wait($HardTimeoutMilliseconds)) {
                $rawOutput = $outputReadTask.Result
            }
        } catch { }

        $outputLines = @(($rawOutput -split "`r?`n") | Where-Object { $null -ne $_ -and $_.Trim().Length -gt 0 })
        return [pscustomobject]@{ TimedOut = $false; OutputLines = $outputLines; Detail = $null }
    } catch {
        return [pscustomobject]@{ TimedOut = $false; OutputLines = @(); Detail = "ssh probe failed to start: $($_.Exception.Message)" }
    } finally {
        $sshProcess.Dispose()
    }
}

function Get-VpsEgressChannelIds {
    <#
    .SYNOPSIS
    Private (never exported), 260830-ffp/D-02: derives the ordered egress channel ids
    from $script:SmoothRelayUnitNames by matching the systemd template-instance pattern
    ^smooth-youtube@(?<channel>[a-z]+)\.service$ -- NEVER a second hardcoded list, never
    anything .env-sourced. The unit list stays the single source of truth for which
    egress channels exist: a future rename or addition there is the only edit needed to
    change the egress rows too.

    .OUTPUTS
    string[] -- ordered lowercase channel ids (e.g. 'lv', 'ru'), in
    $script:SmoothRelayUnitNames order.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $channelIds = [System.Collections.Generic.List[string]]::new()
    foreach ($unitName in $script:SmoothRelayUnitNames) {
        if ($unitName -match '^smooth-youtube@(?<channel>[a-z]+)\.service$') {
            $channelIds.Add($Matches['channel'])
        }
    }
    return , $channelIds.ToArray()
}

function New-VpsEgressRemoteCommandSection {
    <#
    .SYNOPSIS
    Private (never exported), 260830-ffp/D-01/D-07: builds the third `;`-chained
    remote-command section (the egress loop), appended after a second section separator
    on the tcp path only. ChannelIds are interpolated via plain string concatenation
    (D-02); EVERYTHING from '; do' onward is a SINGLE-quoted PowerShell literal, copied
    byte-for-byte from the plan's verified reference command, so the shell's own
    ${mp:-0} default-value expression, the "$fp," comma fragment, and every other
    dollar-sign token reach the remote bash verbatim -- a double-quoted PowerShell
    string would silently interpolate (and blank) each of them before ssh ever sees the
    command.

    The `printf "%s " "$c"` prefix (the one addition to the verified form) is load-
    bearing: Invoke-SshCommand drops blank stdout lines, so a channel with no ffmpeg
    child would otherwise vanish and silently break line-for-line channel alignment; the
    prefix also makes each line self-identifying, which ConvertTo-VpsEgressStates relies
    on as an independent cross-check against the expected channel-id order (D-03).

    Known limitation (by design, not a bug): this reads only bytes_sent/lastsnd tokens
    from `ss -p` -- the RTMPS stream key is never in `ss` output (process NAME only,
    never a command line) and is never transmitted back. A VPS missing `pgrep` reads as
    'no connection' rather than 'unknown'; acceptable since the value is indicator-only
    (D-05).

    .OUTPUTS
    String -- the loop section only (no leading/trailing separator or `;`).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string[]] $ChannelIds
    )

    return "for c in $($ChannelIds -join ' '); " + 'do mp=$(systemctl show -p MainPID --value smooth-youtube@$c.service); fp=$(pgrep -P ${mp:-0} -x ffmpeg | head -1); printf "%s " "$c"; if [ -n "$fp" ]; then ss -Htinp state established "( dport = :443 )" | grep -A1 "pid=$fp," | grep -o -e "bytes_sent:[0-9]*" -e "lastsnd:[0-9]*" | tr "\n" " "; fi; echo; done'
}

function New-VpsReaderHealthRemoteCommandSection {
    <#
    .SYNOPSIS
    Private (never exported), 260906-i2k/D-09: builds the FOURTH `;`-chained remote-command
    section -- a plain `cat` of $script:VpsReaderHealthRemotePath with stderr discarded --
    appended after a THIRD section separator on the tcp path only. stderr is discarded and
    no `|| true` is needed because the whole remote command is a `;`-chained list, not a
    `&&` chain: a missing file simply contributes zero lines, which
    ConvertTo-VpsReaderHealthState resolves to $null (D-10), exactly like a watchdog that
    has not ticked yet.

    .OUTPUTS
    String -- the cat section only (no leading/trailing separator or `;`).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return "cat $script:VpsReaderHealthRemotePath 2>/dev/null"
}

function ConvertTo-VpsReaderHealthState {
    <#
    .SYNOPSIS
    Private (never exported), 260906-i2k/D-10: parses the fourth reader-health section's
    lines into {Discontinuities; Rotations} as [int64], or $null when the section cannot
    be trusted -- zero lines (no file, watchdog not ticked yet, or no third separator in
    the reply), either key missing, or either value not a plain integer.

    Parses BY KEY, never by line position, so a future key-order change in
    write_reader_health cannot silently swap the two counts. Each key is matched with an
    ANCHORED regex that tolerates surrounding whitespace and accepts DIGITS ONLY
    (T-i2k-01): the payload crosses a trust boundary from the VPS onto the church PC and
    into the dashboard, so nothing from it is ever rendered verbatim -- the row value
    comes from a fixed vocabulary and the unit is a re-formatted integer.

    Per D-10 the caller treats a $null here as "these two rows are unknown" and NOTHING
    else: never a retry, never a change to unit/Port/egress state, never an input to the
    ok/degraded/down fold.

    .OUTPUTS
    PSCustomObject{Discontinuities; Rotations} ([int64] each), or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [array] $ReaderHealthLines
    )

    if ($ReaderHealthLines.Count -eq 0) {
        return $null
    }

    $parsedCounts = @{}
    foreach ($readerHealthLine in $ReaderHealthLines) {
        $keyValueMatch = [regex]::Match($readerHealthLine, '^\s*(?<key>discontinuities|rotations)\s*=\s*(?<value>\d+)\s*$')
        if ($keyValueMatch.Success) {
            $parsedCounts[$keyValueMatch.Groups['key'].Value] = [int64] $keyValueMatch.Groups['value'].Value
        }
    }

    if (-not $parsedCounts.ContainsKey('discontinuities') -or -not $parsedCounts.ContainsKey('rotations')) {
        return $null
    }

    return [pscustomobject]@{
        Discontinuities = $parsedCounts['discontinuities']
        Rotations       = $parsedCounts['rotations']
    }
}

function ConvertTo-VpsEgressStates {
    <#
    .SYNOPSIS
    Private (never exported), 260830-ffp/D-03/D-04: parses the third egress section's
    lines into an ordered array of {ChannelId; HasConnection; LastSendMilliseconds;
    BytesSent}, one entry per expected channel id, IN THE EXPECTED ORDER -- or $null
    when the section cannot be cleanly aligned to that order: a line-count mismatch, or
    a channel-id prefix that does not match the expected id at that position. An
    unalignable egress section is ALWAYS a $null result and NOTHING else (the caller
    never retries or touches unit/port state because of it) -- the whole feature is
    indicator-only (D-05), so a cosmetic parsing failure here must never degrade a
    healthy probe.

    Each line is expected to start with "<channelId> " (the New-VpsEgressRemoteCommand
    Section printf prefix), optionally followed by "bytes_sent:<N>" and/or
    "lastsnd:<M>" tokens -- neither present means no established socket for that
    channel (HasConnection=$false).

    .OUTPUTS
    Array of PSCustomObject{ChannelId;HasConnection;LastSendMilliseconds;BytesSent}, or
    $null.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [array] $EgressLines,
        [Parameter(Mandatory)] [string[]] $ExpectedChannelIds
    )

    if ($EgressLines.Count -ne $ExpectedChannelIds.Count) {
        return $null
    }

    $egressStates = [System.Collections.Generic.List[object]]::new()
    for ($channelIndex = 0; $channelIndex -lt $ExpectedChannelIds.Count; $channelIndex++) {
        $expectedChannelId = $ExpectedChannelIds[$channelIndex]
        $egressLine = $EgressLines[$channelIndex]

        if ($egressLine -notmatch "^$([regex]::Escape($expectedChannelId))(\s|$)") {
            return $null
        }

        $bytesSentMatch = [regex]::Match($egressLine, 'bytes_sent:(\d+)')
        $lastSendMatch = [regex]::Match($egressLine, 'lastsnd:(\d+)')

        $egressStates.Add([pscustomobject]@{
                ChannelId            = $expectedChannelId
                HasConnection        = $bytesSentMatch.Success -or $lastSendMatch.Success
                LastSendMilliseconds = if ($lastSendMatch.Success) { [int64] $lastSendMatch.Groups[1].Value } else { $null }
                BytesSent            = if ($bytesSentMatch.Success) { [int64] $bytesSentMatch.Groups[1].Value } else { $null }
            })
    }

    return , $egressStates.ToArray()
}

function Invoke-SmoothRelayStatusCheck {
    <#
    .SYNOPSIS
    Private (never exported): the single Invoke-SshCommand call plus its result checks
    (process failed to start, timed out, section-alignment failure, line-count mismatch),
    extracted out of Test-SmoothRelayHealth so its one-retry-on-truncated-reply behavior is
    a second call to this same helper, never a copy-pasted block (DRY/SRP). Renamed from
    Invoke-SmoothRelayUnitStatusCheck (260809-oc4, third round): it now ALSO parses the
    passive `ss`-derived Port section on the tcp path (-ExpectPortSection), piggybacked
    onto the SAME single SSH round trip -- see the module header for why an active TCP
    connect against the relay port was removed entirely. 260830-ffp extends this again
    with an optional THIRD section (-ExpectEgressSection, D-01) carrying per-channel
    YouTube egress observations, after a SECOND section separator.

    260906-i2k extends it once more with an optional FOURTH section
    (-ExpectReaderHealthSection, D-09) carrying the watchdog's two reader-health counters,
    after a THIRD section separator.

    Combined-reply parsing (-ExpectPortSection):
      1. Collect EVERY $script:SmoothRelaySshSectionSeparator line's index in
         OutputLines, in order. None found -> the reply cannot be aligned (a truncated
         write, or something mangled the ssh session) -- UnitStates, PortState, AND
         EgressStates all resolve to unknown, ShouldRetry=$true (same truncated-reply
         retry contract as a line-count mismatch).
      2. Everything before the FIRST separator is the systemctl section; if its line
         count does not match UnitNames.Count, same treatment as case 1
         (ShouldRetry=$true). This is the pre-existing contract and is UNCHANGED by the
         260830-ffp egress extension -- a malformed egress section can never widen or
         narrow it (D-03).
      3. Everything between the FIRST and SECOND separator (or to the end of the reply,
         when there is no second separator) is the `ss` section -- ZERO OR MORE lines is
         a perfectly valid, ALIGNED result (a quiet port genuinely prints nothing), never
         a retry trigger by itself: any line starting with 'LISTEN' -> PortState='open';
         else any line starting with 'ESTAB' -> PortState='in use'; else ->
         PortState='closed' (a REAL, observed negative -- D-09 still lets this outrank
         down, not merely degraded).
      4. Only when -ExpectEgressSection was requested AND a second separator is present:
         everything after the SECOND separator is handed to ConvertTo-VpsEgressStates
         against the D-02-derived expected channel-id order. Per D-03, ANY alignment
         failure here (no second separator, wrong line count, out-of-order channel-id
         prefix) resolves EgressStates to $null and NOTHING else -- it never sets
         ShouldRetry and never blanks UnitStates or PortState, both of which are already
         fully resolved above by the time this step runs.
      5. Only when -ExpectReaderHealthSection was requested AND a THIRD separator is
         present: everything after it is handed to ConvertTo-VpsReaderHealthState. Adding
         this third separator necessarily SHORTENS the egress slice in step 4, which
         previously ran to end-of-reply -- when no third separator is present the egress
         slice still runs to end-of-reply, byte-identical to before this feature. Per
         D-10, any misalignment here resolves ReaderHealth to $null and NOTHING else: no
         ShouldRetry, no change to unit/Port/egress state.

    Without -ExpectPortSection (the srt break-glass path's SSH leg, or any caller that
    passes no RelayPort), OutputLines is parsed exactly as before this redesign: no
    separator is expected, and the whole reply must equal UnitNames.Count. EgressStates
    is always $null on this path.

    ShouldRetry is $true on EXACTLY the alignment-failure branches above -- the process-
    start-failure branch and the TimedOut branch both fail fast with ShouldRetry=$false:
    neither has anything a same-arguments retry could recover (a process that could not
    start will not start on a second attempt either, and a hard timeout already waited the
    full budget).

    .OUTPUTS
    PSCustomObject: UnitStates (ordered array of {UnitName; State}), PortState
    ('open'|'in use'|'closed'|$null -- $null only when -ExpectPortSection was never
    requested, or the reply could not be aligned), EgressStates (ordered array of
    {ChannelId; HasConnection; LastSendMilliseconds; BytesSent}, or $null -- see D-03
    above), ReaderHealth ({Discontinuities; Rotations} or $null -- see D-10 above),
    Detail (string or $null), ShouldRetry (bool).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string[]] $SshArguments,
        [Parameter(Mandatory)] [int] $HardTimeoutMilliseconds,
        [Parameter(Mandatory)] [array] $UnitNames,
        [bool] $ExpectPortSection = $false,
        [bool] $ExpectEgressSection = $false,
        [bool] $ExpectReaderHealthSection = $false
    )

    $unitStates = [System.Collections.Generic.List[object]]::new()
    foreach ($unitName in $UnitNames) {
        $unitStates.Add([pscustomobject]@{ UnitName = $unitName; State = $null })
    }

    $sshResult = Invoke-SshCommand -ArgumentList $SshArguments -HardTimeoutMilliseconds $HardTimeoutMilliseconds

    if ($null -ne $sshResult.Detail) {
        return [pscustomobject]@{ UnitStates = $unitStates.ToArray(); PortState = $null; EgressStates = $null; ReaderHealth = $null; Detail = $sshResult.Detail; ShouldRetry = $false }
    }

    if ($sshResult.TimedOut) {
        return [pscustomobject]@{ UnitStates = $unitStates.ToArray(); PortState = $null; EgressStates = $null; ReaderHealth = $null; Detail = 'ssh probe timed out'; ShouldRetry = $false }
    }

    $outputLines = $sshResult.OutputLines

    if (-not $ExpectPortSection) {
        if ($outputLines.Count -ne $UnitNames.Count) {
            return [pscustomobject]@{
                UnitStates   = $unitStates.ToArray()
                PortState    = $null
                EgressStates = $null
                ReaderHealth = $null
                Detail       = "systemctl is-active returned $($outputLines.Count) status line(s), expected $($UnitNames.Count) -- cannot align, treating all units unknown"
                ShouldRetry  = $true
            }
        }
        for ($unitIndex = 0; $unitIndex -lt $unitStates.Count; $unitIndex++) {
            $unitStates[$unitIndex].State = $outputLines[$unitIndex].Trim()
        }
        return [pscustomobject]@{ UnitStates = $unitStates.ToArray(); PortState = $null; EgressStates = $null; ReaderHealth = $null; Detail = $null; ShouldRetry = $false }
    }

    # 260830-ffp: collect ALL separator indices (not just the first) so a third section
    # (egress) can be sliced out after the second separator without disturbing the
    # first separator's existing systemctl/ss alignment contract at all (D-03).
    $separatorIndices = [System.Collections.Generic.List[int]]::new()
    for ($lineIndex = 0; $lineIndex -lt $outputLines.Count; $lineIndex++) {
        if ($outputLines[$lineIndex] -eq $script:SmoothRelaySshSectionSeparator) {
            $separatorIndices.Add($lineIndex)
        }
    }

    if ($separatorIndices.Count -eq 0) {
        return [pscustomobject]@{
            UnitStates   = $unitStates.ToArray()
            PortState    = $null
            EgressStates = $null
            ReaderHealth = $null
            Detail       = "ssh reply is missing the '$($script:SmoothRelaySshSectionSeparator)' section separator -- cannot align systemctl/ss output, treating all checks unknown"
            ShouldRetry  = $true
        }
    }

    $firstSeparatorIndex = $separatorIndices[0]
    $systemctlLines = if ($firstSeparatorIndex -gt 0) { @($outputLines[0..($firstSeparatorIndex - 1)]) } else { @() }

    if ($systemctlLines.Count -ne $UnitNames.Count) {
        return [pscustomobject]@{
            UnitStates   = $unitStates.ToArray()
            PortState    = $null
            EgressStates = $null
            ReaderHealth = $null
            Detail       = "systemctl is-active returned $($systemctlLines.Count) status line(s), expected $($UnitNames.Count) -- cannot align, treating all units unknown"
            ShouldRetry  = $true
        }
    }

    for ($unitIndex = 0; $unitIndex -lt $unitStates.Count; $unitIndex++) {
        $unitStates[$unitIndex].State = $systemctlLines[$unitIndex].Trim()
    }

    # D-03: a second separator is present only when the caller also asked for an egress
    # section (tcp path) AND the reply actually contains one -- its ABSENCE here is not
    # an alignment failure of the FIRST separator's own contract (unchanged above), so
    # the port section still runs all the way to the end of the reply exactly like it
    # did before this feature existed.
    $secondSeparatorIndex = if ($separatorIndices.Count -ge 2) { $separatorIndices[1] } else { $null }

    $portLines = if ($null -ne $secondSeparatorIndex) {
        if ($secondSeparatorIndex -gt $firstSeparatorIndex + 1) { @($outputLines[($firstSeparatorIndex + 1)..($secondSeparatorIndex - 1)]) } else { @() }
    } elseif ($firstSeparatorIndex -lt $outputLines.Count - 1) {
        @($outputLines[($firstSeparatorIndex + 1)..($outputLines.Count - 1)])
    } else {
        @()
    }

    $portState = 'closed'
    if (@($portLines | Where-Object { $_ -match '^LISTEN\b' }).Count -gt 0) {
        $portState = 'open'
    } elseif (@($portLines | Where-Object { $_ -match '^ESTAB\b' }).Count -gt 0) {
        $portState = 'in use'
    }

    # D-03: egress resolves to $null and NOTHING else when it cannot be aligned -- no
    # second separator, a line-count mismatch, or an out-of-order channel-id prefix.
    # UnitStates and PortState above are already fully resolved by this point and are
    # NEVER touched by anything below.
    # 260906-i2k/D-09: the THIRD separator, when present, BOUNDS the egress slice below --
    # which before this feature always ran to end-of-reply. Its ABSENCE is not an
    # alignment failure of anything: the egress slice then runs to end-of-reply exactly
    # as it did, byte-identical, so a VPS running a pre-260906-i2k watchdog (or none at
    # all) parses precisely as before.
    $thirdSeparatorIndex = if ($separatorIndices.Count -ge 3) { $separatorIndices[2] } else { $null }

    # Both slices below are built by DIRECT ASSIGNMENT of `@()` first, then conditionally
    # overwritten -- never as `$x = if (...) {...} else { @() }`. PowerShell unrolls an
    # empty array returned from an if-expression into $null, which then fails the
    # [array]-typed Mandatory parameter binding on the converters. Caught live by this
    # change's own "empty reader-health section" test (260906-i2k).
    $egressStates = $null
    if ($ExpectEgressSection -and $null -ne $secondSeparatorIndex) {
        $egressSliceEndIndex = if ($null -ne $thirdSeparatorIndex) { $thirdSeparatorIndex - 1 } else { $outputLines.Count - 1 }
        $egressLines = @()
        if ($egressSliceEndIndex -ge $secondSeparatorIndex + 1) {
            $egressLines = @($outputLines[($secondSeparatorIndex + 1)..$egressSliceEndIndex])
        }
        $egressStates = ConvertTo-VpsEgressStates -EgressLines $egressLines -ExpectedChannelIds (Get-VpsEgressChannelIds)
    }

    # D-10: reader health resolves to $null and NOTHING else on ANY misalignment -- no
    # third separator, a missing key, a non-integer value, or an absent remote file
    # (zero lines). UnitStates, PortState and EgressStates above are already fully
    # resolved by this point and are NEVER touched by anything below, and ShouldRetry is
    # never set from here: the two rows this feeds are indicator-only, and a genuinely
    # dead reader already surfaces on its own unit row.
    $readerHealth = $null
    if ($ExpectReaderHealthSection -and $null -ne $thirdSeparatorIndex) {
        $readerHealthLines = @()
        if ($thirdSeparatorIndex -lt $outputLines.Count - 1) {
            $readerHealthLines = @($outputLines[($thirdSeparatorIndex + 1)..($outputLines.Count - 1)])
        }
        $readerHealth = ConvertTo-VpsReaderHealthState -ReaderHealthLines $readerHealthLines
    }

    return [pscustomobject]@{ UnitStates = $unitStates.ToArray(); PortState = $portState; EgressStates = $egressStates; ReaderHealth = $readerHealth; Detail = $null; ShouldRetry = $false }
}

function Test-SmoothRelayHealth {
    <#
    .SYNOPSIS
    Optional SSH unit-health-AND-port leg (D-07/D-09, CHUR-02; extended 260809-oc4, third
    round). Renamed from Test-SmoothRelayUnitsActive: it invokes ssh.exe as a plain
    external process (never PowerShell SSH Remoting -- that would require the VPS to run a
    pwsh -sshs subsystem, an assumption this repo should not make about a church's own VPS)
    to check `systemctl is-active` on the three production smooth-relay units, and -- ONLY
    when RelayPort is supplied (the tcp path) -- ALSO reads the VPS's own loopback socket
    table for that port via `ss`, ALL in the SAME ONE SSH round trip. This replaces the old
    ambiguous `pgrep -f 'ffmpeg.*-c copy'` leg (which matched all three of the new
    architecture's processes indistinguishably) AND the separate active-TCP-connect Port
    leg (Test-TcpRelayPortReachable, deleted -- see the module header for why: it forced a
    real restart storm against ffmpeg's single-accept listener).

    ArgumentList is ALWAYS an array with host/user/keypath/port as distinct elements,
    handed to Invoke-SshCommand's ProcessStartInfo.ArgumentList (a true argv Collection,
    no shell-style re-joining) -- NEVER a concatenated command string (T-06-02/ASVS
    V5/T-15-02-01): a malformed or malicious .env value cannot inject additional ssh
    flags or a second command this way. A '--' end-of-options separator precedes the
    positional "user@host" argument (CR-02) so a `.env`-sourced host beginning with '-'
    cannot be parsed by ssh's own getopt as an option flag (e.g. a fake
    `-oProxyCommand=...`). The three unit names are $script:SmoothRelayUnitNames
    module-scope literals -- never built from any .env value (T-15-02-02, read-only
    against the VPS: a fixed `systemctl is-active`/`ss` query issues no
    restart/enable/disable/write/transport change -- `ss` reads the kernel's own socket
    table, it never touches the relay port itself). -o BatchMode=yes means a probe
    running unattended fails fast rather than hanging on an interactive prompt.

    When RelayPort -gt 0, the remote command becomes FIVE `;`-chained sections
    (260830-ffp adds the last two): `systemctl is-active <unit1> <unit2> <unit3>`, then
    `echo ---` (the exact $script:SmoothRelaySshSectionSeparator literal), then
    `ss -Htan '( sport = :<RelayPort> )'`, then a SECOND `echo ---`, then the D-01/D-02
    egress loop built by New-VpsEgressRemoteCommandSection over Get-VpsEgressChannelIds'
    derived channel ids -- see Invoke-SmoothRelayStatusCheck for the alignment-safe
    parsing contract this produces. When RelayPort is 0 or omitted (the srt break-glass
    path's SSH leg), the remote command is UNCHANGED from before this redesign: plain
    `systemctl is-active <unit1> <unit2> <unit3>`, no separator, no `ss`, no egress loop
    (a TCP-only `ss`/egress query against the srt path's UDP port would be meaningless).

    `systemctl is-active <unit1> <unit2> <unit3>` prints exactly one status line per
    requested unit, IN REQUEST ORDER (the documented systemctl contract this leg relies
    on). A reply that cannot be cleanly aligned (missing section separator, or the wrong
    number of systemctl status lines -- a truncated write from the hard-timeout kill) is
    retried EXACTLY ONCE, with no sleep between attempts (nothing to wait for). A healthy
    poll that returns a clean, aligned reply on the first try never pays for the second
    round trip. Only when the retry's reply ALSO fails to align does every unit resolve to
    unknown ($null) and PortState resolve to $null too, with Detail naming the RETRY's own
    failure -- a genuinely unknown state is always safer than a mis-aligned fabricated one.

    .OUTPUTS
    PSCustomObject: UnitStates (ordered array of {UnitName; State} -- State is
    'active'/'inactive'/etc. as reported by systemd, or $null meaning genuinely unknown,
    e.g. a timeout or an unparseable response, never a fabricated 'inactive'), PortState
    ('open'|'in use'|'closed'|$null -- $null when RelayPort was 0/omitted, or the reply
    could not be aligned), EgressStates (260830-ffp: ordered array of {ChannelId;
    HasConnection; LastSendMilliseconds; BytesSent}, or $null when RelayPort was
    0/omitted, or the egress section could not be aligned -- D-03), Detail (string or
    $null).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $SshHost,
        [Parameter(Mandatory)] [string] $SshUser,
        [Parameter(Mandatory)] [string] $SshKeyPath,
        [Parameter(Mandatory)] [int] $SshPort,
        [int] $RelayPort = 0,
        [int] $ConnectTimeoutSeconds = $script:DefaultSshConnectTimeoutSeconds,
        [int] $HardTimeoutMilliseconds = $script:DefaultSshHardTimeoutMilliseconds
    )

    $includesPortCheck = $RelayPort -gt 0

    $remoteCommandSections = [System.Collections.Generic.List[string]]::new()
    $remoteCommandSections.Add("systemctl is-active $($script:SmoothRelayUnitNames -join ' ')")
    if ($includesPortCheck) {
        $remoteCommandSections.Add("echo $script:SmoothRelaySshSectionSeparator")
        $remoteCommandSections.Add("ss -Htan '( sport = :$RelayPort )'")
        # 260830-ffp/D-01: the egress section is appended ONLY on the tcp path, as a
        # THIRD section after a SECOND separator -- the srt break-glass path's remote
        # command (the 'else' branch, i.e. $includesPortCheck stays $false) is
        # byte-identical to today's.
        $remoteCommandSections.Add("echo $script:SmoothRelaySshSectionSeparator")
        $remoteCommandSections.Add((New-VpsEgressRemoteCommandSection -ChannelIds (Get-VpsEgressChannelIds)))
        # 260906-i2k/D-09: the reader-health section, likewise tcp-path only, as a FOURTH
        # section after a THIRD separator. The srt break-glass path's remote command
        # (this whole branch skipped) stays byte-identical to today's.
        $remoteCommandSections.Add("echo $script:SmoothRelaySshSectionSeparator")
        $remoteCommandSections.Add((New-VpsReaderHealthRemoteCommandSection))
    }

    $sshArguments = @(
        '-o', 'BatchMode=yes',
        '-o', "ConnectTimeout=$ConnectTimeoutSeconds",
        '-o', 'StrictHostKeyChecking=accept-new',
        '-i', $SshKeyPath,
        '-p', "$SshPort",
        '--',
        "$SshUser@$SshHost",
        ($remoteCommandSections -join '; ')
    )

    $checkResult = Invoke-SmoothRelayStatusCheck -SshArguments $sshArguments `
        -HardTimeoutMilliseconds $HardTimeoutMilliseconds -UnitNames $script:SmoothRelayUnitNames `
        -ExpectPortSection $includesPortCheck -ExpectEgressSection $includesPortCheck `
        -ExpectReaderHealthSection $includesPortCheck

    if ($checkResult.ShouldRetry) {
        $checkResult = Invoke-SmoothRelayStatusCheck -SshArguments $sshArguments `
            -HardTimeoutMilliseconds $HardTimeoutMilliseconds -UnitNames $script:SmoothRelayUnitNames `
            -ExpectPortSection $includesPortCheck -ExpectEgressSection $includesPortCheck `
            -ExpectReaderHealthSection $includesPortCheck
    }

    return [pscustomobject]@{ UnitStates = $checkResult.UnitStates; PortState = $checkResult.PortState; EgressStates = $checkResult.EgressStates; ReaderHealth = $checkResult.ReaderHealth; Detail = $checkResult.Detail }
}

function Get-SshLegCacheFilePath {
    <#
    .SYNOPSIS
    Private (never exported), 260809-oc4: derives the SSH-leg throttle cache's on-disk
    path from Config.StateFilePath's own parent directory -- explicitly NOT inside
    state/probes/, because lib/Dashboard.psm1's Get-ProbeResultsForDashboard folds EVERY
    *.json file in that directory into a dashboard panel; a cache file dropped there would
    render as a bogus extra probe. Sits beside state/offset.json instead, using the same
    state/ directory the pusher's own offset/stats files already live in.

    Uses the same PSObject property-existence guard Test-VpsSshLegConfigured's
    ProbeVpsSshHost/User/KeyPath reads already use (StrictMode-safe): a Config fixture
    that omits StateFilePath entirely, or carries a blank one, degrades to $null -- the
    current unthrottled per-poll behavior -- rather than crashing or guessing a path.

    .OUTPUTS
    String (the cache file's full path) or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Config
    )

    $stateFilePathProperty = $Config.PSObject.Properties['StateFilePath']
    if ($null -eq $stateFilePathProperty -or [string]::IsNullOrWhiteSpace($stateFilePathProperty.Value)) {
        return $null
    }

    $stateDirectory = Split-Path -Parent $stateFilePathProperty.Value
    if ([string]::IsNullOrWhiteSpace($stateDirectory)) {
        return $null
    }

    return Join-Path $stateDirectory $script:SshLegCacheFileName
}

function Read-SshLegCache {
    <#
    .SYNOPSIS
    Private (never exported), 260809-oc4: loads the SSH-leg cache payload from
    CacheFilePath, or $null when there is nothing trustworthy to reuse -- missing, empty,
    corrupt JSON, a schemaVersion mismatch, or a stored unitNames set that no longer
    matches $script:SmoothRelayUnitNames (T-oc4-02: a cache written before a unit-name
    rename can never resurrect the wrong names). Mirrors lib/ProbeStore.psm1's
    Read-ProbeResult silent-safe-default contract exactly: never throws, never logs (this
    reader runs on every probe tick).

    .OUTPUTS
    PSCustomObject (the parsed payload) or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $CacheFilePath
    )

    if (-not (Test-Path -LiteralPath $CacheFilePath)) {
        return $null
    }

    try {
        $rawCacheJson = [System.IO.File]::ReadAllText($CacheFilePath)
        if ([string]::IsNullOrWhiteSpace($rawCacheJson)) {
            return $null
        }

        $cachedPayload = $rawCacheJson | ConvertFrom-Json
        if ($null -eq $cachedPayload) {
            return $null
        }

        $requiredPropertyNames = @('schemaVersion', 'observedAtMonotonicSeconds', 'unitNames', 'unitStates')
        foreach ($requiredPropertyName in $requiredPropertyNames) {
            if ($cachedPayload.PSObject.Properties.Name -notcontains $requiredPropertyName) {
                return $null
            }
        }
        if ($cachedPayload.schemaVersion -ne $script:SshLegCacheSchemaVersion) {
            return $null
        }

        $cachedUnitNames = @($cachedPayload.unitNames)
        $currentUnitNames = @($script:SmoothRelayUnitNames)
        if ($cachedUnitNames.Count -ne $currentUnitNames.Count) {
            return $null
        }
        for ($unitNameIndex = 0; $unitNameIndex -lt $currentUnitNames.Count; $unitNameIndex++) {
            if ($cachedUnitNames[$unitNameIndex] -ne $currentUnitNames[$unitNameIndex]) {
                return $null
            }
        }

        return $cachedPayload
    } catch {
        # Corrupt/truncated JSON == "no trustworthy cache" (mirrors Read-ProbeResult's
        # identical bias): never a fabricated value rendered as fact, the caller simply
        # re-runs the SSH leg.
        return $null
    }
}

function Save-SshLegCache {
    <#
    .SYNOPSIS
    Private (never exported), 260809-oc4 (extended third round for PortState; extended
    260830-ffp for EgressStates, D-06): writes the SSH-leg cache payload (schemaVersion,
    the monotonic moment it was observed, the unit-name set it was captured with -- so a
    future rename can never be resurrected under the wrong names -- the observed
    unit/state pairs, the observed Port state, the observed per-channel egress states,
    and Detail) to CacheFilePath. The whole body is wrapped so ANY write failure
    (permissions, disk full, a concurrent delete of the parent directory) is swallowed
    rather than thrown: the SSH-leg cache is a best-effort optimization, never a
    correctness dependency, so the next poll simply re-runs the SSH leg unthrottled
    instead of the probe crashing.

    A $null EgressStates is written as JSON null, NEVER as an empty array (D-06) -- an
    empty array on read-back would mean "aligned, zero channels", a fabricated fact this
    module must never claim. 260906-i2k/D-11 adds readerHealth on the same terms: a $null
    ReaderHealth is written as JSON null, never as a fabricated zero pair -- "the watchdog
    has not published counters" and "the watchdog published two zeroes" are different
    facts, and only the second one may render as an 'ok' row.

    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CacheFilePath,
        [Parameter(Mandatory)] [double] $ObservedAtMonotonicSeconds,
        [Parameter(Mandatory)] [array] $UnitStates,
        [AllowNull()] [string] $PortState,
        [AllowNull()] [array] $EgressStates,
        [AllowNull()] $ReaderHealth,
        [string] $Detail
    )

    try {
        $cacheDirectory = Split-Path -Parent $CacheFilePath
        if ($cacheDirectory -and -not (Test-Path -LiteralPath $cacheDirectory)) {
            New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
        }

        $egressStatesForCache = if ($null -eq $EgressStates) {
            $null
        } else {
            @($EgressStates | ForEach-Object {
                    [ordered]@{
                        channelId            = $_.ChannelId
                        hasConnection        = $_.HasConnection
                        lastSendMilliseconds = $_.LastSendMilliseconds
                        bytesSent            = $_.BytesSent
                    }
                })
        }

        $readerHealthForCache = if ($null -eq $ReaderHealth) {
            $null
        } else {
            [ordered]@{
                discontinuities = $ReaderHealth.Discontinuities
                rotations       = $ReaderHealth.Rotations
            }
        }

        $cachePayloadObject = [ordered]@{
            schemaVersion              = $script:SshLegCacheSchemaVersion
            observedAtMonotonicSeconds = $ObservedAtMonotonicSeconds
            unitNames                  = @($script:SmoothRelayUnitNames)
            unitStates                 = @($UnitStates | ForEach-Object { [ordered]@{ unitName = $_.UnitName; state = $_.State } })
            portState                  = $PortState
            egressStates               = $egressStatesForCache
            readerHealth               = $readerHealthForCache
            detail                     = $Detail
        }
        $cachePayload = $cachePayloadObject | ConvertTo-Json -Compress -Depth 4
        [System.IO.File]::WriteAllText($CacheFilePath, $cachePayload)
    } catch {
        # Never throws out of the probe (see .SYNOPSIS) -- the next poll re-runs SSH.
    }
}

function Get-ThrottledSmoothRelayUnitStates {
    <#
    .SYNOPSIS
    260809-oc4 (extended third round for PortState): the ONE seam Invoke-Probe uses to
    reach the SSH unit-health-and-port leg -- no future call site can bypass the throttle,
    since Test-SmoothRelayHealth itself stays a plain, directly-unit-testable function.
    -RelayPort threads through to Test-SmoothRelayHealth verbatim: 0/omitted on the srt
    path (no port check in the remote command at all), Config.RelayPort on the tcp path.

    No cache-capable path (Get-SshLegCacheFilePath returned $null, e.g. a partial Config
    fixture with no StateFilePath) -> always runs the SSH leg fresh, exactly today's
    unthrottled behavior.

    A cache-capable path with a valid, unit-name-matching, non-negative-age cache younger
    than $script:SshLegMinimumIntervalSeconds -> reused verbatim, INCLUDING its cached
    PortState (ObservedAgeSeconds carries how long ago it was actually observed, for
    Invoke-Probe's D-13 honesty note -- now covering the Port metric too on the tcp path).
    A negative age (the Stopwatch tick origin resets on reboot, so a pre-reboot cache
    would otherwise look impossibly fresh) is treated exactly like an expired cache, never
    reused.

    Every other case -- no cache file yet, expired, future-dated, name-mismatched, or
    corrupt/unparseable (including a cache written by the PRE-260809-oc4-third-round
    module version, which the schemaVersion bump to 2 discards automatically) -- runs the
    SSH leg fresh and (best-effort) persists the new result via Save-SshLegCache,
    INCLUDING an all-unknown/timed-out result: caching a failure is what stops a sustained
    SSH outage from silently restoring the old hot per-poll cadence (T-oc4-04).

    .OUTPUTS
    PSCustomObject: UnitStates, PortState ('open'|'in use'|'closed'|$null), EgressStates
    (260830-ffp: ordered array of {ChannelId; HasConnection; LastSendMilliseconds;
    BytesSent}, or $null -- D-03/D-06), ReaderHealth (260906-i2k: {Discontinuities;
    Rotations} or $null -- D-10/D-11), Detail, ObservedAgeSeconds (double, seconds, or
    $null when this call ran the SSH leg fresh).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Config,
        [int] $RelayPort = 0
    )

    $cacheFilePath = Get-SshLegCacheFilePath -Config $Config

    if ($null -ne $cacheFilePath) {
        $cachedPayload = Read-SshLegCache -CacheFilePath $cacheFilePath
        if ($null -ne $cachedPayload) {
            $observedAgeSeconds = (Get-MonotonicSeconds) - $cachedPayload.observedAtMonotonicSeconds
            if ($observedAgeSeconds -ge 0 -and $observedAgeSeconds -lt $script:SshLegMinimumIntervalSeconds) {
                $cachedUnitStates = @($cachedPayload.unitStates | ForEach-Object {
                        [pscustomobject]@{ UnitName = $_.unitName; State = $_.state }
                    })
                $cachedPortState = if ($cachedPayload.PSObject.Properties.Name -contains 'portState') { $cachedPayload.portState } else { $null }
                # 260830-ffp/D-06: the SAME property-existence guard the portState
                # restore above already uses (StrictMode-safe against an older-shaped
                # payload), PLUS an explicit null guard -- a null egressStates value
                # restores as $null, never as an empty array (an empty array would mean
                # "aligned, zero channels", a fabricated fact).
                $cachedEgressStates = $null
                if (($cachedPayload.PSObject.Properties.Name -contains 'egressStates') -and ($null -ne $cachedPayload.egressStates)) {
                    $cachedEgressStates = @($cachedPayload.egressStates | ForEach-Object {
                            [pscustomobject]@{
                                ChannelId            = $_.channelId
                                HasConnection        = $_.hasConnection
                                LastSendMilliseconds = $_.lastSendMilliseconds
                                BytesSent            = $_.bytesSent
                            }
                        })
                }
                # 260906-i2k/D-11: same property-existence-plus-null guard as the
                # egressStates restore above. A null readerHealth restores as $null
                # (rows read 'unknown'), never as a fabricated {0;0} pair, which would
                # render two reassuring 'ok' rows for a watchdog that never reported.
                $cachedReaderHealth = $null
                if (($cachedPayload.PSObject.Properties.Name -contains 'readerHealth') -and ($null -ne $cachedPayload.readerHealth)) {
                    $cachedReaderHealth = [pscustomobject]@{
                        Discontinuities = $cachedPayload.readerHealth.discontinuities
                        Rotations       = $cachedPayload.readerHealth.rotations
                    }
                }
                return [pscustomobject]@{
                    UnitStates         = $cachedUnitStates
                    PortState          = $cachedPortState
                    EgressStates       = $cachedEgressStates
                    ReaderHealth       = $cachedReaderHealth
                    Detail             = $cachedPayload.detail
                    ObservedAgeSeconds = $observedAgeSeconds
                }
            }
        }
    }

    $freshResult = Test-SmoothRelayHealth -SshHost $Config.ProbeVpsSshHost -SshUser $Config.ProbeVpsSshUser `
        -SshKeyPath $Config.ProbeVpsSshKeyPath -SshPort $Config.ProbeVpsSshPort -RelayPort $RelayPort

    # 260830-ffp: a property-existence guard against $freshResult (StrictMode-safe) --
    # many existing test fixtures mock Test-SmoothRelayHealth with a pscustomobject that
    # predates EgressStates entirely; treating an absent property as $null (unresolved)
    # rather than a StrictMode error keeps every such fixture's existing behavior intact.
    $freshEgressStates = if ($freshResult.PSObject.Properties.Name -contains 'EgressStates') { $freshResult.EgressStates } else { $null }
    # 260906-i2k: the SAME StrictMode-safe guard, for the same reason -- existing test
    # fixtures mock Test-SmoothRelayHealth with objects that predate ReaderHealth, and an
    # absent property must read as "unresolved", never as a StrictMode error.
    $freshReaderHealth = if ($freshResult.PSObject.Properties.Name -contains 'ReaderHealth') { $freshResult.ReaderHealth } else { $null }

    if ($null -ne $cacheFilePath) {
        Save-SshLegCache -CacheFilePath $cacheFilePath -ObservedAtMonotonicSeconds (Get-MonotonicSeconds) `
            -UnitStates $freshResult.UnitStates -PortState $freshResult.PortState -EgressStates $freshEgressStates `
            -ReaderHealth $freshReaderHealth -Detail $freshResult.Detail
    }

    return [pscustomobject]@{
        UnitStates         = $freshResult.UnitStates
        PortState          = $freshResult.PortState
        EgressStates       = $freshEgressStates
        ReaderHealth       = $freshReaderHealth
        Detail             = $freshResult.Detail
        ObservedAgeSeconds = $null
    }
}

function Add-SshLegObservationAgeNote {
    <#
    .SYNOPSIS
    260809-oc4 (D-13 honesty requirement): a pure composer -- takes a status-fold Detail
    string and an observation age and returns Detail with a trailing note naming the age
    in whole seconds and the throttle interval, or Detail UNCHANGED when ObservedAgeSeconds
    is $null (the SSH leg ran fresh this tick, nothing to disclose). Appends rather than
    replaces so every existing `Should -Match` assertion on these details keeps passing.

    .OUTPUTS
    String or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] [string] $Detail,
        [AllowNull()] [System.Nullable[double]] $ObservedAgeSeconds
    )

    if ($null -eq $ObservedAgeSeconds) {
        return $Detail
    }

    $observationAgeNote = "observed $([math]::Round($ObservedAgeSeconds))s ago (SSH leg refreshes at most once per ${script:SshLegMinimumIntervalSeconds}s)"

    if ([string]::IsNullOrWhiteSpace($Detail)) {
        return $observationAgeNote
    }
    return "$Detail -- $observationAgeNote"
}

function Resolve-VpsEgressRowValue {
    <#
    .SYNOPSIS
    Private (never exported), 260830-ffp/D-04: pure resolver for one egress channel's
    metric row VALUE, in this exact order (never reordered -- each earlier branch
    outranks every later one): srt path -> 'not applicable'; SSH leg not configured ->
    'not configured'; ssh.exe absent, egress unresolved, or no observation for this
    channel -> 'unknown'; no established socket for the channel -> 'no connection';
    lastsnd absent -> 'unknown'; lastsnd below $script:VpsEgressStalledThresholdMilliseconds
    -> 'sending'; otherwise -> 'stalled Ns' (whole seconds, floored). Takes plain values
    only, never the Config object, so it stays directly unit-testable (D-04).

    .OUTPUTS
    String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [bool] $IsTcpPath,
        [Parameter(Mandatory)] [bool] $SshConfigured,
        [Parameter(Mandatory)] [bool] $SshExecutableAvailable,
        [AllowNull()] $EgressState
    )

    if (-not $IsTcpPath) {
        return 'not applicable'
    }
    if (-not $SshConfigured) {
        return 'not configured'
    }
    if ((-not $SshExecutableAvailable) -or ($null -eq $EgressState)) {
        return 'unknown'
    }
    if (-not $EgressState.HasConnection) {
        return 'no connection'
    }
    if ($null -eq $EgressState.LastSendMilliseconds) {
        return 'unknown'
    }
    if ($EgressState.LastSendMilliseconds -lt $script:VpsEgressStalledThresholdMilliseconds) {
        return 'sending'
    }
    return "stalled $([math]::Floor($EgressState.LastSendMilliseconds / 1000))s"
}

function Resolve-VpsReaderHealthRowValue {
    <#
    .SYNOPSIS
    Private (never exported), 260906-i2k/D-11: pure resolver for ONE reader-health row's
    VALUE, in this exact order (never reordered -- each earlier branch outranks every
    later one): srt path -> 'not applicable'; SSH leg not configured -> 'not configured';
    ssh.exe absent or the reader-health state unresolved -> 'unknown'; count of zero ->
    'ok'; any count above zero -> 'warn'. Takes plain values only (never the Config
    object, never the whole state), so it stays directly unit-testable -- same shape and
    same rationale as Resolve-VpsEgressRowValue.

    'warn' rather than a number is deliberate: the COUNT belongs in the row's unit field,
    where Invoke-Probe puts it. The value field is a fixed vocabulary the dashboard maps
    to a status dot, and nothing from the remote payload is ever rendered into it
    verbatim (T-i2k-01).

    .OUTPUTS
    String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [bool] $IsTcpPath,
        [Parameter(Mandatory)] [bool] $SshConfigured,
        [Parameter(Mandatory)] [bool] $SshExecutableAvailable,
        [AllowNull()] $Count
    )

    if (-not $IsTcpPath) {
        return 'not applicable'
    }
    if (-not $SshConfigured) {
        return 'not configured'
    }
    if ((-not $SshExecutableAvailable) -or ($null -eq $Count)) {
        return 'unknown'
    }
    if ($Count -eq 0) {
        return 'ok'
    }
    return 'warn'
}

function Format-VpsEgressByteTotal {
    <#
    .SYNOPSIS
    Private (never exported), 260830-ffp/D-04: pure byte-total formatter for the egress
    row's `unit` field -- whole MB below 1 GB, one-decimal GB at or above 1 GB, ALWAYS
    rendered via [cultureinfo]::InvariantCulture so a non-English church PC locale can
    never format the decimal point as a comma (D-07: ASCII only, no locale surprises).
    $null (no byte total known) formats as '' -- never a fabricated zero.

    .OUTPUTS
    String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] $BytesSent
    )

    if ($null -eq $BytesSent) {
        return ''
    }

    if ($BytesSent -ge 1GB) {
        $gigabytes = [double] $BytesSent / 1GB
        return "$($gigabytes.ToString('0.0', [cultureinfo]::InvariantCulture)) GB"
    }

    $megabytes = [math]::Round([double] $BytesSent / 1MB)
    return "$($megabytes.ToString([cultureinfo]::InvariantCulture)) MB"
}

function New-VpsProbeResult {
    <#
    .SYNOPSIS
    Private (never exported): builds the D-02 domain subset (name/title/status/
    metrics/detail) WITHOUT any timestamp field -- the host stamps
    updatedEpochSeconds/staleAfterEpochSeconds at persist time (D-07).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateSet('ok', 'degraded', 'down', 'unknown')] [string] $Status,
        [array] $Metrics = @(),
        [string] $Detail
    )

    return [pscustomobject]@{
        name    = $script:ProbeName
        title   = $script:ProbeTitle
        status  = $Status
        metrics = $Metrics
        detail  = $Detail
    }
}

function Invoke-Probe {
    <#
    .SYNOPSIS
    Contract entry point (D-01/MON-01) -- the ONE function this module exports, always
    under this exact name. Runs all three legs -- Port, the optional SSH unit-health-and-
    port leg (Ingest/YouTube LV/YouTube RU/Port-on-tcp-path), and the local Tunnel leg --
    then folds them into a D-09 three-level status. Never throws: every helper this
    function calls already returns a normalized result rather than propagating an
    exception, and every branch below returns via New-VpsProbeResult.

    PORT LEG IS PATH-DEPENDENT (260809-oc4, third round -- see the module header for the
    live incident that forced this): on the srt break-glass path, Port is still driven by
    Test-SrtInductionReachabilityWithRetry, unchanged. On the tcp path, there is NO active
    network leg at all anymore -- Port is read PASSIVELY from the SAME SSH round trip as
    the unit-health leg (Test-SmoothRelayHealth's `ss`-derived PortState), so it is only
    ever populated when the SSH leg actually ran (sshExecutableAvailable).

    D-09 PRECEDENCE (why this fold is shaped as it is): Port is the leg that observes the
    actual data path -- the SRT induction handshake on the srt path, or the VPS's own
    kernel socket table (via `ss`, over SSH) on the tcp path. Because of that, no other
    SSH-derived signal (a dead YouTube reader unit, a failing/unknown SSH check, a
    not-running tunnel) can EVER downgrade the probe below 'degraded' once Port proves
    healthy -- checked FIRST. Only a definitively broken Port ('closed'/unreachable), or a
    definitively-dead Ingest unit (the far end of the stream path itself), can ever report
    'down'. On the tcp path, an UNRESOLVED Port (SSH not configured, ssh.exe absent, or a
    garbled/misaligned reply) is intentionally NOT treated as proof of 'down' -- absence of
    evidence is not evidence of absence; it falls through to the same graceful-degradation
    paths the unit-health signals already use.

    The fold, in order (guard clauses, no nested if/else):
      1. Port leg proves the path broken (srt: induction unreachable; tcp: the `ss`
         section resolved and found neither LISTEN nor ESTABLISHED)        -> 'down'
      2. Ingest unit definitively not active (a real, non-null state
         that isn't 'active')                                             -> 'down'
      (SSH-not-configured / ssh.exe-absent short-circuit to 'ok' here -- an operator who
      has deliberately not set up SSH is not degraded; a configured-but-failing check is.
      On the tcp path this also means Port itself could not be observed this tick.)
      3. A YouTube reader unit definitively not active, OR the SSH leg
         is configured but returned unknown/timed out (which, on the tcp
         path, also means Port itself is unresolved), OR the tunnel leg
         reports not-running                                              -> 'degraded'
      4. Otherwise                                                        -> 'ok'

    METRIC CONTRACT: the fixed five-row array (Ingest, YouTube LV, YouTube RU, Tunnel,
    Port -- plus a Latency row on the srt path only, appended when a latency value was
    actually measured; the tcp path no longer measures a connect latency at all, since
    there is no more active connect -- YAGNI, this was never one of the five fixed rows)
    is built UNCONDITIONALLY, from whatever each leg returned, BEFORE the status decision
    above runs. Every return path -- including the 'down' path -- carries all five rows,
    so the dashboard never has to hide a check row depending on status. 260830-ffp appends
    TWO MORE rows after those, unconditionally on every path and every status: 'YT LV out'
    and 'YT RU out' (D-02's derived channel ids), each resolved per D-04 from the SAME SSH
    round trip's egress section. These two rows are INDICATOR-ONLY -- see D-05 at their
    build site below -- they never influence the status fold and the dashboard renderer
    needs no schema change to display them (plain {label,value,unit} rows, same as every
    other metric).

    .OUTPUTS
    PSCustomObject: name, title, status ('ok'|'degraded'|'down'|'unknown'), metrics
    (array of {label,value,unit}), detail (string or $null). Deliberately WITHOUT
    updatedEpochSeconds/staleAfterEpochSeconds (D-07, host-owned).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Config
    )

    # --- Leg 1 (srt break-glass path only): SRT induction reachability -- unchanged by
    # 260809-oc4's redesign, since UDP induction never touches ffmpeg's TCP listener and
    # carries none of the single-accept restart-storm risk that forced the tcp-path
    # redesign. Property-existence guard (mirrors lib/Config.psm1's Test-PusherConfig
    # convention): a Config object that omits RelayProtocol entirely (e.g. a partial
    # fixture) means "schema default", i.e. the srt path, never a hard failure.
    $relayProtocolProperty = $Config.PSObject.Properties['RelayProtocol']
    $isTcpPath = ($null -ne $relayProtocolProperty) -and ($relayProtocolProperty.Value -eq 'tcp')
    if ($isTcpPath) {
        # 260809-oc4: NO active-connect leg on the tcp path anymore -- Port is read
        # passively below, piggybacked on the SSH leg. See the module header.
        $reachability = $null
    } else {
        $reachability = Test-SrtInductionReachabilityWithRetry -RelayHost $Config.RelayHost -RelayPort $Config.RelayPort
    }

    # --- Leg 2: local tunnel-alive (tcp path only -- not applicable on the srt
    # break-glass path, since the ssh -L forward it checks has no equivalent there).
    if ($isTcpPath) {
        $tunnelResult = Test-LocalTunnelProcessAlive
    } else {
        $tunnelResult = [pscustomobject]@{ Running = $null; Detail = $null }
    }

    # --- Leg 3: SSH unit-health-and-port (optional, D-09). Pitfall 3: ssh.exe is an
    # optional Windows Feature-on-Demand, checked at poll time (not install time, since
    # the SSH leg is optional and must never block install.ps1). 260809-oc4: reached ONLY
    # through Get-ThrottledSmoothRelayUnitStates (the 60-second-throttled, cache-backed
    # seam) -- never Test-SmoothRelayHealth directly -- so no future call site can bypass
    # the throttle. On the tcp path this SAME round trip ALSO carries Port state (the
    # `ss`-derived PortState) -- passed -RelayPort only on the tcp path, since a TCP-only
    # `ss` query against the srt path's UDP port would be meaningless.
    $sshConfigured = Test-VpsSshLegConfigured -Config $Config
    $sshExecutableAvailable = $sshConfigured -and [bool] (Get-Command 'ssh.exe' -ErrorAction SilentlyContinue)
    $unitsResult = $null
    $tcpPortState = $null
    $egressStates = $null
    $readerHealth = $null
    $sshLegObservedAgeSeconds = $null
    if ($sshExecutableAvailable) {
        $sshLegRelayPort = if ($isTcpPath) { $Config.RelayPort } else { 0 }
        $throttledResult = Get-ThrottledSmoothRelayUnitStates -Config $Config -RelayPort $sshLegRelayPort
        $unitsResult = [pscustomobject]@{ UnitStates = $throttledResult.UnitStates; Detail = $throttledResult.Detail }
        $tcpPortState = $throttledResult.PortState
        $egressStates = $throttledResult.EgressStates
        $readerHealth = $throttledResult.ReaderHealth
        $sshLegObservedAgeSeconds = $throttledResult.ObservedAgeSeconds
    }

    # --- Build the fixed 5-row metric array UNCONDITIONALLY, before any status decision.
    $metrics = [System.Collections.Generic.List[object]]::new()

    foreach ($unitName in $script:SmoothRelayUnitNames) {
        $metricLabel = $script:SmoothRelayUnitMetricLabels[$unitName]
        $unitMetricValue = 'unknown'
        if (-not $sshConfigured) {
            $unitMetricValue = 'not configured'
        } elseif ($sshExecutableAvailable) {
            $unitState = ($unitsResult.UnitStates | Where-Object { $_.UnitName -eq $unitName }).State
            if ($unitState -eq 'active') {
                $unitMetricValue = 'active'
            } elseif ($null -ne $unitState) {
                $unitMetricValue = 'inactive'
            }
        }
        $metrics.Add(@{ label = $metricLabel; value = $unitMetricValue; unit = '' })
    }

    if (-not $isTcpPath) {
        $metrics.Add(@{ label = 'Tunnel'; value = 'not applicable'; unit = '' })
    } elseif ($null -eq $tunnelResult.Running) {
        $metrics.Add(@{ label = 'Tunnel'; value = 'unknown'; unit = '' })
    } elseif ($tunnelResult.Running) {
        $metrics.Add(@{ label = 'Tunnel'; value = 'running'; unit = '' })
    } else {
        $metrics.Add(@{ label = 'Tunnel'; value = 'not running'; unit = '' })
    }

    # Port metric value -- path-dependent (260809-oc4). tcp path mirrors the exact
    # not-configured/unknown/real-value resolution the per-unit metrics loop above
    # already uses, since Port is now sourced from the identical SSH leg.
    if ($isTcpPath) {
        $portMetricValue = 'unknown'
        if (-not $sshConfigured) {
            $portMetricValue = 'not configured'
        } elseif ($sshExecutableAvailable -and $null -ne $tcpPortState) {
            $portMetricValue = $tcpPortState
        }
        $metrics.Add(@{ label = 'Port'; value = $portMetricValue; unit = '' })
    } else {
        $portMetricValue = if ($reachability.Reachable) { 'open' } else { 'closed' }
        $metrics.Add(@{ label = 'Port'; value = $portMetricValue; unit = '' })

        if ($null -ne $reachability.LatencyMilliseconds) {
            $metrics.Add(@{ label = 'Latency'; value = [math]::Round($reachability.LatencyMilliseconds, 2); unit = 'ms' })
        }
    }

    # 260830-ffp/D-05: two egress indicator rows, appended after EVERY existing row on
    # both paths ('YT LV out' / 'YT RU out'). These are INDICATOR-ONLY -- they never
    # feed the D-09 fold below (no new branch, no changed condition anywhere in that
    # fold) because (a) YAGNI: a genuinely dead reader unit already surfaces through its
    # own row and the existing degraded branch, and (b) the sample can be up to 60s old
    # (the SSH-leg throttle), so folding it would raise false alarms from stale evidence
    # during a normal catch-up burst.
    foreach ($egressChannelId in (Get-VpsEgressChannelIds)) {
        $matchingEgressState = if ($null -ne $egressStates) { $egressStates | Where-Object { $_.ChannelId -eq $egressChannelId } } else { $null }
        $egressRowValue = Resolve-VpsEgressRowValue -IsTcpPath $isTcpPath -SshConfigured $sshConfigured `
            -SshExecutableAvailable $sshExecutableAvailable -EgressState $matchingEgressState
        $egressRowUnit = if ($null -ne $matchingEgressState) { Format-VpsEgressByteTotal -BytesSent $matchingEgressState.BytesSent } else { '' }
        $metrics.Add(@{ label = "YT $($egressChannelId.ToUpperInvariant()) out"; value = $egressRowValue; unit = $egressRowUnit })
    }

    # 260906-i2k/D-10/D-11: two reader-health indicator rows, appended AFTER the egress
    # rows, 'Rotations' first then 'Discontinuities'. Like the egress rows they never
    # enter the D-09 fold below -- no new branch, no changed condition anywhere in it --
    # for the same two reasons: a genuinely dead reader already surfaces through its own
    # unit row and the existing degraded branch, and the sample can be up to 60s stale
    # (the SSH-leg throttle), so folding it would raise false alarms from old evidence.
    # The count rides in the row's unit field as an invariant-culture string, or '' when
    # the state is unresolved -- never a fabricated zero.
    foreach ($readerHealthRow in @(
            @{ Label = 'Rotations'; PropertyName = 'Rotations' },
            @{ Label = 'Discontinuities'; PropertyName = 'Discontinuities' })) {
        $readerHealthCount = if ($null -ne $readerHealth) { $readerHealth.($readerHealthRow.PropertyName) } else { $null }
        $readerHealthRowValue = Resolve-VpsReaderHealthRowValue -IsTcpPath $isTcpPath -SshConfigured $sshConfigured `
            -SshExecutableAvailable $sshExecutableAvailable -Count $readerHealthCount
        $readerHealthRowUnit = if ($null -ne $readerHealthCount) { ([int64] $readerHealthCount).ToString([cultureinfo]::InvariantCulture) } else { '' }
        $metrics.Add(@{ label = $readerHealthRow.Label; value = $readerHealthRowValue; unit = $readerHealthRowUnit })
    }

    $metricsArray = $metrics.ToArray()

    # --- D-09 three-level fold ---

    # Step 1: Port leg proves the path broken -> down, unconditionally. This is the whole
    # point of D-09's precedence -- checked before any other SSH-derived signal.
    #   srt path: unchanged, Reachable == false.
    #   tcp path: the ss section resolved cleanly (PortState is a REAL, non-null
    #   observation) and found neither LISTEN nor ESTABLISHED -- 'closed' outranks down
    #   exactly like the old active-connect leg did, but an UNRESOLVED tcpPortState
    #   ($null -- SSH not configured/available, or a garbled reply) never forces 'down'.
    $portProvesDown = if ($isTcpPath) {
        $sshExecutableAvailable -and ($tcpPortState -eq 'closed')
    } else {
        -not $reachability.Reachable
    }
    if ($portProvesDown) {
        $portDownDetail = if ($isTcpPath) {
            Add-SshLegObservationAgeNote -Detail "no LISTEN or ESTABLISHED socket found for port $($Config.RelayPort) on the VPS -- the relay's TCP ingest listener is not reachable" -ObservedAgeSeconds $sshLegObservedAgeSeconds
        } else {
            $reachability.Detail
        }
        return New-VpsProbeResult -Status 'down' -Metrics $metricsArray -Detail $portDownDetail
    }

    # Step 2: Ingest unit definitively not active -> down (the far end of the stream path
    # is dead). Only fires on a REAL, non-null state -- an unresolved/unknown SSH check
    # never fabricates a 'down'.
    $ingestUnitState = $null
    if ($sshExecutableAvailable) {
        $ingestUnitState = ($unitsResult.UnitStates | Where-Object { $_.UnitName -eq 'smooth-ingest-tcp.service' }).State
    }
    if ($null -ne $ingestUnitState -and $ingestUnitState -ne 'active') {
        $ingestDownDetail = Add-SshLegObservationAgeNote -Detail 'smooth-ingest-tcp.service is not active -- the stream path itself is broken' -ObservedAgeSeconds $sshLegObservedAgeSeconds
        return New-VpsProbeResult -Status 'down' -Metrics $metricsArray -Detail $ingestDownDetail
    }

    # SSH-not-configured / ssh.exe-absent short-circuit to 'ok' BEFORE step 3: an operator
    # who has deliberately not set up SSH is not degraded; a configured-but-failing check
    # is (existing documented graceful-degradation contract). On the tcp path this also
    # means Port itself was never observed this tick -- deliberately not treated as a
    # failure (D-13/D-09: absence of evidence is not evidence of absence).
    if (-not $sshConfigured) {
        return New-VpsProbeResult -Status 'ok' -Metrics $metricsArray -Detail 'SSH not configured'
    }
    if (-not $sshExecutableAvailable) {
        return New-VpsProbeResult -Status 'ok' -Metrics $metricsArray -Detail 'ssh.exe not found on PATH'
    }

    # Step 3: a YouTube reader unit definitively not active, OR the SSH leg is configured
    # but returned unknown/timed out (which, on the tcp path, also leaves Port unresolved
    # -- the SAME combined reply drives both), OR the tunnel leg reports not-running ->
    # degraded. Never 'down' -- Step 1 already proved the data path itself is open (D-09).
    $youtubeReaderUnitDead = @($unitsResult.UnitStates | Where-Object {
            $_.UnitName -ne 'smooth-ingest-tcp.service' -and $null -ne $_.State -and $_.State -ne 'active'
        }).Count -gt 0
    if ($youtubeReaderUnitDead) {
        $youtubeDeadDetail = Add-SshLegObservationAgeNote -Detail 'A YouTube reader unit is not active' -ObservedAgeSeconds $sshLegObservedAgeSeconds
        return New-VpsProbeResult -Status 'degraded' -Metrics $metricsArray -Detail $youtubeDeadDetail
    }

    $sshCheckUnresolved = @($unitsResult.UnitStates | Where-Object { $null -eq $_.State }).Count -gt 0
    if ($sshCheckUnresolved) {
        $unresolvedDetail = if ($unitsResult.Detail) { $unitsResult.Detail } else { 'SSH unit-health check returned an unresolved result' }
        $unresolvedDetail = Add-SshLegObservationAgeNote -Detail $unresolvedDetail -ObservedAgeSeconds $sshLegObservedAgeSeconds
        return New-VpsProbeResult -Status 'degraded' -Metrics $metricsArray -Detail $unresolvedDetail
    }

    $tunnelNotRunning = $isTcpPath -and ($null -ne $tunnelResult.Running) -and (-not $tunnelResult.Running)
    if ($tunnelNotRunning) {
        return New-VpsProbeResult -Status 'degraded' -Metrics $metricsArray -Detail 'GaplessTcpRelayTunnel Scheduled Task is not running'
    }

    # Step 4: otherwise -> ok.
    $okDetail = Add-SshLegObservationAgeNote -Detail $null -ObservedAgeSeconds $sshLegObservedAgeSeconds
    return New-VpsProbeResult -Status 'ok' -Metrics $metricsArray -Detail $okDetail
}

Export-ModuleMember -Function Invoke-Probe

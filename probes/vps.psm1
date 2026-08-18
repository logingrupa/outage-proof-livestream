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
#    `; echo ---; ss -Htan '( sport = :<port> )'` section) covers unit health AND Port state
#    in the SAME SSH round trip -- Test-SmoothRelayHealth replaces the old ambiguous
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
# (added the portState field alongside unitStates); a stored schemaVersion mismatch (or its
# absence) makes Read-SshLegCache discard the file exactly like a corrupt one, never a
# StrictMode surprise on a stale-shaped payload. This also means a cache file written by
# the PRE-redesign module version is automatically discarded on the first poll after a
# bounce, rather than silently missing PortState.
$script:SshLegCacheSchemaVersion = 2
$script:SshLegCacheFileName = 'vps-probe-ssh-cache.json'
# 260809-oc4: the deterministic alignment marker printed BETWEEN the `systemctl is-active`
# section and the `ss` section of the single combined SSH remote command (tcp path only) --
# the ONE literal both Test-SmoothRelayHealth's remote-command builder and
# Invoke-SmoothRelayStatusCheck's parser share, so they can never drift apart. A reply
# missing this exact line (a truncated write, or ssh itself mangling something) cannot be
# aligned at all and is treated as fully unknown (both unit states AND Port state), never a
# guessed split.
$script:SmoothRelaySshSectionSeparator = '---'

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
    connect against the relay port was removed entirely.

    Combined-reply parsing (-ExpectPortSection):
      1. Find $script:SmoothRelaySshSectionSeparator's exact line in OutputLines. Not
         found at all -> the reply cannot be aligned (a truncated write, or something
         mangled the ssh session) -- BOTH UnitStates and PortState resolve to unknown,
         ShouldRetry=$true (same truncated-reply retry contract as a line-count mismatch).
      2. Everything before the separator is the systemctl section; if its line count does
         not match UnitNames.Count, same treatment as case 1 (ShouldRetry=$true).
      3. Everything after the separator is the `ss` section -- ZERO OR MORE lines is a
         perfectly valid, ALIGNED result (a quiet port genuinely prints nothing), never a
         retry trigger by itself: any line starting with 'LISTEN' -> PortState='open'; else
         any line starting with 'ESTAB' -> PortState='in use'; else -> PortState='closed'
         (a REAL, observed negative -- D-09 still lets this outrank down, not merely
         degraded).

    Without -ExpectPortSection (the srt break-glass path's SSH leg, or any caller that
    passes no RelayPort), OutputLines is parsed exactly as before this redesign: no
    separator is expected, and the whole reply must equal UnitNames.Count.

    ShouldRetry is $true on EXACTLY the alignment-failure branches above -- the process-
    start-failure branch and the TimedOut branch both fail fast with ShouldRetry=$false:
    neither has anything a same-arguments retry could recover (a process that could not
    start will not start on a second attempt either, and a hard timeout already waited the
    full budget).

    .OUTPUTS
    PSCustomObject: UnitStates (ordered array of {UnitName; State}), PortState
    ('open'|'in use'|'closed'|$null -- $null only when -ExpectPortSection was never
    requested, or the reply could not be aligned), Detail (string or $null), ShouldRetry
    (bool).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string[]] $SshArguments,
        [Parameter(Mandatory)] [int] $HardTimeoutMilliseconds,
        [Parameter(Mandatory)] [array] $UnitNames,
        [bool] $ExpectPortSection = $false
    )

    $unitStates = [System.Collections.Generic.List[object]]::new()
    foreach ($unitName in $UnitNames) {
        $unitStates.Add([pscustomobject]@{ UnitName = $unitName; State = $null })
    }

    $sshResult = Invoke-SshCommand -ArgumentList $SshArguments -HardTimeoutMilliseconds $HardTimeoutMilliseconds

    if ($null -ne $sshResult.Detail) {
        return [pscustomobject]@{ UnitStates = $unitStates.ToArray(); PortState = $null; Detail = $sshResult.Detail; ShouldRetry = $false }
    }

    if ($sshResult.TimedOut) {
        return [pscustomobject]@{ UnitStates = $unitStates.ToArray(); PortState = $null; Detail = 'ssh probe timed out'; ShouldRetry = $false }
    }

    $outputLines = $sshResult.OutputLines

    if (-not $ExpectPortSection) {
        if ($outputLines.Count -ne $UnitNames.Count) {
            return [pscustomobject]@{
                UnitStates  = $unitStates.ToArray()
                PortState   = $null
                Detail      = "systemctl is-active returned $($outputLines.Count) status line(s), expected $($UnitNames.Count) -- cannot align, treating all units unknown"
                ShouldRetry = $true
            }
        }
        for ($unitIndex = 0; $unitIndex -lt $unitStates.Count; $unitIndex++) {
            $unitStates[$unitIndex].State = $outputLines[$unitIndex].Trim()
        }
        return [pscustomobject]@{ UnitStates = $unitStates.ToArray(); PortState = $null; Detail = $null; ShouldRetry = $false }
    }

    $separatorIndex = [array]::IndexOf($outputLines, $script:SmoothRelaySshSectionSeparator)
    if ($separatorIndex -lt 0) {
        return [pscustomobject]@{
            UnitStates  = $unitStates.ToArray()
            PortState   = $null
            Detail      = "ssh reply is missing the '$($script:SmoothRelaySshSectionSeparator)' section separator -- cannot align systemctl/ss output, treating all checks unknown"
            ShouldRetry = $true
        }
    }

    $systemctlLines = if ($separatorIndex -gt 0) { @($outputLines[0..($separatorIndex - 1)]) } else { @() }
    $portLines = if ($separatorIndex -lt $outputLines.Count - 1) { @($outputLines[($separatorIndex + 1)..($outputLines.Count - 1)]) } else { @() }

    if ($systemctlLines.Count -ne $UnitNames.Count) {
        return [pscustomobject]@{
            UnitStates  = $unitStates.ToArray()
            PortState   = $null
            Detail      = "systemctl is-active returned $($systemctlLines.Count) status line(s), expected $($UnitNames.Count) -- cannot align, treating all units unknown"
            ShouldRetry = $true
        }
    }

    for ($unitIndex = 0; $unitIndex -lt $unitStates.Count; $unitIndex++) {
        $unitStates[$unitIndex].State = $systemctlLines[$unitIndex].Trim()
    }

    $portState = 'closed'
    if (@($portLines | Where-Object { $_ -match '^LISTEN\b' }).Count -gt 0) {
        $portState = 'open'
    } elseif (@($portLines | Where-Object { $_ -match '^ESTAB\b' }).Count -gt 0) {
        $portState = 'in use'
    }

    return [pscustomobject]@{ UnitStates = $unitStates.ToArray(); PortState = $portState; Detail = $null; ShouldRetry = $false }
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

    When RelayPort -gt 0, the remote command becomes THREE `;`-chained sections:
    `systemctl is-active <unit1> <unit2> <unit3>`, then `echo ---` (the exact
    $script:SmoothRelaySshSectionSeparator literal), then
    `ss -Htan '( sport = :<RelayPort> )'` -- see Invoke-SmoothRelayStatusCheck for the
    alignment-safe parsing contract this produces. When RelayPort is 0 or omitted (the
    srt break-glass path's SSH leg), the remote command is UNCHANGED from before this
    redesign: plain `systemctl is-active <unit1> <unit2> <unit3>`, no separator, no `ss`
    (a TCP-only `ss` query against the srt path's UDP port would be meaningless).

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
    could not be aligned), Detail (string or $null).
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
        -HardTimeoutMilliseconds $HardTimeoutMilliseconds -UnitNames $script:SmoothRelayUnitNames -ExpectPortSection $includesPortCheck

    if ($checkResult.ShouldRetry) {
        $checkResult = Invoke-SmoothRelayStatusCheck -SshArguments $sshArguments `
            -HardTimeoutMilliseconds $HardTimeoutMilliseconds -UnitNames $script:SmoothRelayUnitNames -ExpectPortSection $includesPortCheck
    }

    return [pscustomobject]@{ UnitStates = $checkResult.UnitStates; PortState = $checkResult.PortState; Detail = $checkResult.Detail }
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
    Private (never exported), 260809-oc4 (extended third round for PortState): writes the
    SSH-leg cache payload (schemaVersion, the monotonic moment it was observed, the
    unit-name set it was captured with -- so a future rename can never be resurrected
    under the wrong names -- the observed unit/state pairs, the observed Port state, and
    Detail) to CacheFilePath. The whole body is wrapped so ANY write failure (permissions,
    disk full, a concurrent delete of the parent directory) is swallowed rather than
    thrown: the SSH-leg cache is a best-effort optimization, never a correctness
    dependency, so the next poll simply re-runs the SSH leg unthrottled instead of the
    probe crashing.

    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CacheFilePath,
        [Parameter(Mandatory)] [double] $ObservedAtMonotonicSeconds,
        [Parameter(Mandatory)] [array] $UnitStates,
        [AllowNull()] [string] $PortState,
        [string] $Detail
    )

    try {
        $cacheDirectory = Split-Path -Parent $CacheFilePath
        if ($cacheDirectory -and -not (Test-Path -LiteralPath $cacheDirectory)) {
            New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
        }

        $cachePayloadObject = [ordered]@{
            schemaVersion              = $script:SshLegCacheSchemaVersion
            observedAtMonotonicSeconds = $ObservedAtMonotonicSeconds
            unitNames                  = @($script:SmoothRelayUnitNames)
            unitStates                 = @($UnitStates | ForEach-Object { [ordered]@{ unitName = $_.UnitName; state = $_.State } })
            portState                  = $PortState
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
    PSCustomObject: UnitStates, PortState ('open'|'in use'|'closed'|$null), Detail,
    ObservedAgeSeconds (double, seconds, or $null when this call ran the SSH leg fresh).
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
                return [pscustomobject]@{
                    UnitStates         = $cachedUnitStates
                    PortState          = $cachedPortState
                    Detail             = $cachedPayload.detail
                    ObservedAgeSeconds = $observedAgeSeconds
                }
            }
        }
    }

    $freshResult = Test-SmoothRelayHealth -SshHost $Config.ProbeVpsSshHost -SshUser $Config.ProbeVpsSshUser `
        -SshKeyPath $Config.ProbeVpsSshKeyPath -SshPort $Config.ProbeVpsSshPort -RelayPort $RelayPort

    if ($null -ne $cacheFilePath) {
        Save-SshLegCache -CacheFilePath $cacheFilePath -ObservedAtMonotonicSeconds (Get-MonotonicSeconds) `
            -UnitStates $freshResult.UnitStates -PortState $freshResult.PortState -Detail $freshResult.Detail
    }

    return [pscustomobject]@{
        UnitStates         = $freshResult.UnitStates
        PortState          = $freshResult.PortState
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
    so the dashboard never has to hide a check row depending on status.

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
    $sshLegObservedAgeSeconds = $null
    if ($sshExecutableAvailable) {
        $sshLegRelayPort = if ($isTcpPath) { $Config.RelayPort } else { 0 }
        $throttledResult = Get-ThrottledSmoothRelayUnitStates -Config $Config -RelayPort $sshLegRelayPort
        $unitsResult = [pscustomobject]@{ UnitStates = $throttledResult.UnitStates; Detail = $throttledResult.Detail }
        $tcpPortState = $throttledResult.PortState
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

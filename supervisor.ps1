<#
.SYNOPSIS
The process-death mechanism for the pusher, and the owner of "am I supposed to be
streaming right now?".

WHY THIS SCRIPT EXISTS: install.ps1 registers the Scheduled Task with RestartCount
999 / RestartInterval 1 minute, and the whole system was documented as if those
settings restarted the pusher after a crash. They do not. Task Scheduler's
RestartOnFailure fires only on ABNORMAL TASK termination -- never on the action
process exiting with a non-zero code. An isolated probe against real Task Scheduler
(`pwsh -Command "exit 1"`, install.ps1's exact settings) left lastRun FROZEN and
rerun False across 160 seconds: zero relaunches where 2-3 were expected. A pusher
crash mid-service therefore left the stream DOWN until the next reboot. Crash
restart now lives here, in code that can actually be tested
(tests/Supervisor.Tests.ps1), instead of in a task setting that was never true.

BOOT IS IDLE, DELIBERATELY. The Scheduled Task launches THIS script at boot, and it
starts no ffmpeg, opens no recording file, pushes no bytes. Streaming to a LIVE
YouTube audience must never begin unattended -- it begins only when an operator
explicitly says so by flipping the control flag (start.ps1, or Phase 5's dashboard
Start button, which writes the same flag). That flag is the seam; this loop just
obeys it. The idle gate is also what stops a boot with no recording file present
from crash-looping on Open-TailerFileStream's FileNotFoundException (lib/Tailer.psm1).

THE EXIT-CODE CONTRACT (pusher.ps1, D-12) is the other half of the design:
  exit 0 -- clean end-of-service (pusher.ps1:669, after Start-Pusher returns)
  exit 2 -- config validation failure (pusher.ps1:68)
  anything else -- an uncaught throw under $ErrorActionPreference = 'Stop', a crash
Both documented exits STAY DOWN, and stay down by SETTING desired=stopped rather
than by merely not relaunching this tick. That distinction is load-bearing: after a
clean exit 0 the drained .ts file is still sitting on disk, so any later relaunch
re-opens it, spawns ffmpeg, connects SRT and re-sends the 2 MB D-05 resume margin --
duplicate bytes to a live YouTube audience, on every tick. Writing the flag makes
the stay-down survive a supervisor restart, a reboot, and anything else.

Functions are defined at top level (not wrapped in a module) so
tests/Supervisor.Tests.ps1 can dot-source this file and Mock Start-PusherProcess /
Start-Sleep without ever spawning a real pusher or burning real wall-clock backoff --
the same convention install.ps1 already uses. Invoke-Supervisor (the main loop) only
runs when this script is executed directly, never when dot-sourced: see the guard at
the bottom of this file.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Deliberately NOT -Force (unlike pusher.ps1/install.ps1's own imports): dot-sourcing
# this file must not reset an already-configured Logging module back to its default
# log directory. Plain Import-Module is a no-op when the module is already loaded.
Import-Module (Join-Path $PSScriptRoot 'lib/Logging.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/ControlFlag.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/Backoff.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/Dashboard.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/StatsStore.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/PusherProcess.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/Clock.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/Config.psm1')
# 260718-epo: Rotation.psm1 (Get-NewestMatchingRecordingFile) and SessionState.psm1
# (Save-SessionState/Read-SessionState/Get-NewRecordingPickupDecision) are needed in
# THIS process's own scope -- Invoke-AutoPickupTick runs on the main tick loop, never
# inside the dashboard's separate runspace (which already imports Rotation.psm1 for
# its own ApiRecordings route, and now also imports SessionState.psm1 as
# defense-in-depth, see Start-DashboardHost below).
Import-Module (Join-Path $PSScriptRoot 'lib/Rotation.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/SessionState.psm1')
# 260722-xbr/NIC-TELEMETRY-01: Resolve-SrtNicName is called once, in THIS process's own
# scope, at dashboard-start time (Start-DashboardHost below) -- never per-poll, and
# never inside the dashboard's own runspace (which reads the already-resolved name
# via a threaded param, mirroring how RecordingFolderPath/StateFilePath are resolved
# here and threaded, not re-resolved runspace-side).
Import-Module (Join-Path $PSScriptRoot 'lib/NicTelemetry.psm1')
# 261011-ugi/SUP-SINGLE-01: the per-install Global\ mutex, taken by
# Invoke-SupervisorEntryPoint below -- never inside Invoke-Supervisor.
Import-Module (Join-Path $PSScriptRoot 'lib/SupervisorSingleInstance.psm1')

# Stop-PusherProcesses (cut.ps1, never a module) is what the dashboard's /api/control
# 'cut' action needs (D-08 -- the SAME control seam cut.ps1 itself uses, never a
# second one). Dot-sourcing here defines every function in cut.ps1 without running
# anything (its own bottom guard, matching install.ps1/supervisor.ps1's convention).
# This is deliberately NOT copied into the dashboard's own runspace-hosted script
# block below as its only home: a command called from inside an imported module
# (Dashboard.psm1's Invoke-DashboardRequestHandler) only resolves against the
# CALLER's truly GLOBAL functions, never a nested scriptblock's local ones
# (05-07-SUMMARY.md's confirmed finding) -- so Start-DashboardHost's own runspace
# script block dot-sources cut.ps1 again, at THAT runspace's own top level, which is
# the scope that actually matters for the dashboard's cut action to resolve.
. (Join-Path $PSScriptRoot 'cut.ps1')

# pusher.ps1's exit-code contract (D-12), named once here rather than as bare
# magic numbers inside the branching below.
$script:PusherExitCodeCleanEndOfService = 0
$script:PusherExitCodeConfigError = 2
# Front C (260718-j58/Task 3/EOS-DRAIN-01): a bounded end-of-service give-up with
# undelivered backlog still on disk -- distinct from both a clean finish (0) and a
# config error (2). Like both of those, this StayDown -- an already-down/never-connecting
# relay does not fix itself by relaunching immediately into another reconnect storm; the
# recording is intact and the exact byte offset is persisted, so an operator-initiated
# restart later delivers the remainder byte-exact (D-05 margin only).
$script:PusherExitCodeUndeliveredBacklog = 3
# 261018 (B6): another pusher for this install already holds the per-install Pusher mutex,
# so this launch stood down before touching anything. Neither a crash nor a finish.
$script:PusherExitCodeAnotherPusherRunning = 4

$script:IdlePollIntervalMilliseconds = 1000

# Timeout of each wait on a streaming pusher before one round of dashboard maintenance
# (261018). WaitForExit(ms) is a kernel wait that returns the instant the pusher exits, so
# this sets how OFTEN maintenance runs, never how LATE an exit is noticed. Same cadence as
# the idle tick.
$script:PusherExitPollIntervalMilliseconds = 1000

# How long a second supervisor for the same install waits for the first to let go of the
# single-instance mutex before it logs one line and exits 0 (261011-ugi). Long enough that
# a kill-and-restart or a shutting-down predecessor never leaves zero supervisors; short
# enough that a duplicate launch does not linger. Code-only, like the constants around it.
$script:SupervisorSingleInstanceWaitSeconds = 15

# Where a supervisor that is dying writes its last line when Write-Log itself fails
# (261018). The fallback exists because the failure being reported may BE a log-write
# failure; relative to the script root, like state/control.json.
$script:SupervisorLastGaspLogRelativePath = 'state/logs/supervisor-last-gasp.log'

# Dashboard restart schedule (261011-ugi). Fast retries come 2, 4, 8, 16, 32, then 60 s
# apart, about 6 minutes for the default 10 attempts. After that the supervisor retries
# silently every 10 minutes for the rest of the run and never gives up for good: on
# 2026-10-04 a duplicate supervisor held the dashboard address for much longer than any
# fixed burst would have covered. The slow interval doubles as the stable window -- a
# restarted dashboard that cannot stay up for one slow interval belongs to the same
# outage. Both phases count ATTEMPTS, not elapsed time: the schedule advances only when a
# maintenance step actually runs (once per idle tick, once per pusher-exit poll while
# streaming), so a stretch where no step runs (the crash-backoff sleep, up to 30 s; a slow
# start attempt) cannot use up the budget. Code-only, not read from .env, like the probe
# timeout constant above.
$script:DashboardRestartBaseDelayMilliseconds = 2000
$script:DashboardRestartCeilingDelayMilliseconds = 60000
$script:DashboardRestartMaximumAttempts = 10
$script:DashboardRestartSlowIntervalSeconds = 600

# Per-probe hard-timeout ceiling threaded into Invoke-ProbeHostLoop (D-05):
# generous enough to cover the shipped VPS probe's own worst-case internal
# budget (2000ms reachability timeout + 8000ms SSH hard timeout, per
# probes/vps.psm1's own defaults) plus runspace/process spawn overhead,
# without being so long that a genuinely hung probe stalls its own panel for
# an operator-noticeable window. Code-only for v1 (mirrors ProbeHost.psm1's
# own $script:DefaultPollIntervalSeconds convention, RESEARCH.md Open
# Question 2, YAGNI) -- not .env-configurable this phase.
$script:ProbeHostHardTimeoutMilliseconds = 15000

# The reassurance a volunteer needs when a crash restart is genuinely under way, and
# the reason it lives HERE rather than in Get-SupervisorExitDecision's Reason: it is a
# CLAIM about what happens next, not a FACT about what just happened. The exit code is
# known the instant the pusher dies; whether a relaunch follows is not decided until
# the flag is re-read at the top of the next tick. So the decision function states the
# fact and this string is emitted only at the point the relaunch is actually about to
# happen -- which is exactly where it is true.
$script:RelaunchReassurance = 'the recording file on disk is the buffer, so the stream catches back up from the persisted byte offset.'

function Get-SupervisorExitDecision {
    <#
    .SYNOPSIS
    Maps a pusher exit code to what the supervisor does next: StayDown or Relaunch.
    Pure -- no file access, no process access, no sleeping, no wall-clock reads -- so
    the branching that actually keeps a church's stream alive is unit-testable with
    no real Task Scheduler, no real pusher, and no real Sunday anywhere in the loop.

    Reason is not decoration: it is the line a church volunteer reads in the log at
    10:55 on a Sunday morning while the stream is down, so every branch carries one.

    Reason states only what HAS happened, never what will. This function sees an exit
    code and nothing else -- it cannot see the control flag (staying pure is what makes
    it testable), so it cannot know whether a Relaunch it returns will actually be
    carried out. cut.ps1 sets desired=stopped and then kills the pusher; the kill looks
    exactly like a crash from here, so Relaunch is the correct decision, and the next
    tick's flag re-read correctly discards it. A Reason that ASSERTED "relaunching after
    a backoff" was therefore a lie in precisely the case a volunteer most needs the
    truth -- observed live after a real cut. The relaunch CLAIM belongs to the caller,
    at the point the flag has confirmed it: see $script:RelaunchReassurance.

    .OUTPUTS
    PSCustomObject: Action ('StayDown', 'Relaunch' or 'WaitForRunningPusher' -- exit 4,
    261018: another pusher already runs; no flag write, no crash count), Reason (string),
    ExitReasonToken
    ('clean-end-of-service' | 'config-fail' | 'crash' -- 260718-epo: the SAME token
    Invoke-Supervisor persists to state/session.json via Save-SessionState, so a
    Dashboard.psm1 reader can distinguish a clean finish from a crash/lost-contact
    without re-deriving the exit-code mapping a second time).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [int] $ExitCode
    )

    if ($ExitCode -eq $script:PusherExitCodeCleanEndOfService) {
        return [pscustomobject]@{
            Action          = 'StayDown'
            Reason          = 'clean end-of-service -- the service finished normally and the recording was fully drained. Relaunching would re-send the already-sent resume margin as duplicate bytes, so the pusher stays down until an operator starts the next service.'
            ExitReasonToken = 'clean-end-of-service'
        }
    }

    if ($ExitCode -eq $script:PusherExitCodeConfigError) {
        return [pscustomobject]@{
            Action          = 'StayDown'
            Reason          = 'config validation failed -- a bad .env cannot fix itself, so retrying would only be a restart storm. Fix the reported problem in .env, then start the pusher again.'
            ExitReasonToken = 'config-fail'
        }
    }

    if ($ExitCode -eq $script:PusherExitCodeUndeliveredBacklog) {
        return [pscustomobject]@{
            Action          = 'StayDown'
            Reason          = 'the relay was persistently unreachable at end-of-service, so some already-recorded bytes never reached it -- the recording is intact on disk and the exact byte offset is persisted. Starting the pusher again delivers the remainder from that offset (only the small D-05 margin re-sent). Staying down avoids a reconnect storm against a still-down relay.'
            ExitReasonToken = 'finished-with-undelivered-backlog'
        }
    }

    if ($ExitCode -eq $script:PusherExitCodeAnotherPusherRunning) {
        return [pscustomobject]@{
            Action          = 'WaitForRunningPusher'
            Reason          = 'another pusher for this install is already running, and this launch stood down without touching the offset or the control flag.'
            ExitReasonToken = 'another-pusher-running'
        }
    }

    return [pscustomobject]@{
        Action          = 'Relaunch'
        Reason          = "unexpected exit code $ExitCode -- the pusher crashed rather than finishing or rejecting its config."
        ExitReasonToken = 'crash'
    }
}

function Start-PusherProcess {
    <#
    .SYNOPSIS
    Starts pusher.ps1 in its own pwsh process and returns the running Process; it does
    not wait. Waiting is Wait-PusherProcessExit's job, so the supervisor's main thread
    stays free to keep the dashboard healthy while the pusher streams (261018).
    Isolated into its own function as the testability seam: Pester mocks this to return
    a fake process (tests/TestHelpers.psm1 New-FakePusherProcess), so every branch of
    Invoke-Supervisor can be driven without spawning a real pusher, a real ffmpeg, or a
    real SRT connection. tools/portable-launch.ps1 refers to this function by name.

    The child pwsh gets the same Session-0 hardening install.ps1 applies to the task
    itself (PITFALLS.md Pitfall 10): an absolute pwsh.exe path, explicit
    -ExecutionPolicy Bypass -NoProfile, and an explicit WorkingDirectory -- this
    supervisor runs under Task Scheduler as the operator account (S4U) with
    CWD = %windir%\system32 and cannot assume it inherits an execution policy, a PATH,
    or a sane working directory.

    ExitCode must stay readable after the timed polls in Wait-PusherProcessExit. That
    needs the process handle cached before the child can exit: Start-Process caches it
    itself only on PowerShell 7.4.1+ (PR #20749), and README allows 7.4+, so the handle
    is read explicitly below (the documented #20400 workaround; a no-op on 7.4.1+).
    #>
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param(
        [Parameter(Mandatory)] [string] $ScriptRoot
    )

    $pusherScriptPath = Join-Path $ScriptRoot 'pusher.ps1'
    $pwshPath = (Get-Command -Name 'pwsh.exe' -ErrorAction Stop).Source

    # -PassThru without -Wait: -Wait does not reliably populate ExitCode on the returned
    # object, and the caller must keep its thread free while the pusher runs.
    $pusherProcess = Start-Process -FilePath $pwshPath `
        -ArgumentList @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', $pusherScriptPath) `
        -WorkingDirectory $ScriptRoot -NoNewWindow -PassThru
    $null = $pusherProcess.Handle
    return $pusherProcess
}

function Wait-PusherProcessExit {
    <#
    .SYNOPSIS
    Waits for a running pusher to exit, in timed polls, and runs one round of dashboard
    maintenance between polls. Returns the pusher's exit code and the dashboard state.

    WHY: on 2026-10-04 the dashboard was dead for 14 days because its retry ran only in
    the supervisor's tick loop, and the tick loop is blocked for the whole service while
    a pusher streams. WaitForExit(ms) is a kernel wait that returns the instant the
    pusher exits, so a pusher exit is noticed at once; the poll interval only sets how
    often maintenance runs.

    - Maintenance runs only after a poll that timed out with the pusher alive, never
      after the poll that saw the exit.
    - The steady-state round costs microseconds (one clock read and a state check). A
      due restart attempt costs one Start-DashboardHost call.
    - The only calls on the process are WaitForExit, ExitCode and Dispose. There is no
      Kill: nothing on this path can affect the pusher.
    - An exception from WaitForExit itself propagates exactly as it did from the old
      blocking wait.
    - State in, state out: a dashboard restarted mid-service reaches Invoke-Supervisor's
      final cleanup.

    .OUTPUTS
    PSCustomObject with ExitCode (int) and DashboardHostState.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $PusherProcess,
        [Parameter(Mandatory)] $DashboardHostState,
        [Parameter(Mandatory)] [hashtable] $DashboardRecoveryParameters,
        [int] $PollIntervalMilliseconds = $script:PusherExitPollIntervalMilliseconds
    )

    $currentDashboardHostState = $DashboardHostState
    try {
        while (-not $PusherProcess.WaitForExit($PollIntervalMilliseconds)) {
            $currentDashboardHostState = Invoke-DashboardHostMaintenance `
                -DashboardHostState $currentDashboardHostState `
                -DashboardRecoveryParameters $DashboardRecoveryParameters
        }
        # The documented follow-up after a timed wait (probes/vps.psm1 precedent).
        $null = $PusherProcess.WaitForExit()
        $pusherExitCode = $PusherProcess.ExitCode
    } finally {
        # Closes OUR handle only; the pusher process is unaffected.
        try { $PusherProcess.Dispose() } catch { }
    }

    return [pscustomobject]@{
        ExitCode           = $pusherExitCode
        DashboardHostState = $currentDashboardHostState
    }
}

function Invoke-AutoPickupTick {
    <#
    .SYNOPSIS
    Config-gated auto-pickup (260718-epo/FEAT-C, T-epo-01): on every idle tick, checks
    whether the last pusher run ended cleanly and, if so, whether a strictly-newer
    recording has since appeared. Detection ALWAYS runs and is recorded to
    session.json (so the dashboard can surface a one-click Start notice); auto-START
    additionally requires AutoPickupEnabled (AUTO_PICKUP, default OFF).

    Top-level and dot-sourceable (matches this file's own convention, see the header)
    so tests/Supervisor.Tests.ps1 can Mock Get-NewestMatchingRecordingFile and drive
    every branch without a real recording folder. A no-op (returns immediately) when
    RecordingFolderPath/RecordingFilenameGlob/SessionStateFilePath are not threaded --
    the same "degrade to inert, never crash" contract Start-DashboardHost/Start-ProbeHost
    already use for a config-read failure.

    NEVER THROWS INTO THE SUPERVISOR LOOP: the whole body is wrapped in try/catch,
    logging at Error and returning on any fault -- auto-pickup is a nice-to-have, never
    worth risking the process that owns crash restart (mirrors Publish-PusherStats's
    own guard, 05-06).

    SAFETY (T-epo-01, locked): this function NEVER calls Set-PusherDesiredState
    'streaming' unless Get-NewRecordingPickupDecision's own ShouldAutoStart is $true --
    which itself requires AutoPickupEnabled AND a strictly-newer file (the pure
    function's own conservative-by-default bias, lib/SessionState.psm1). Before that
    call, state/offset.json is removed (Remove-Item -Force -ErrorAction SilentlyContinue)
    so the pusher resolves the NEW file at offset 0 -- the just-finished (older) file is
    never re-opened, closing the D-11/D-12 duplicate-byte hazard.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ControlFilePath,
        [string] $RecordingFolderPath = $null,
        [string] $RecordingFilenameGlob = $null,
        [string] $StateFilePath = $null,
        [string] $SessionStateFilePath = $null,
        [bool] $AutoPickupEnabled = $false
    )

    if ([string]::IsNullOrEmpty($RecordingFolderPath) -or [string]::IsNullOrEmpty($RecordingFilenameGlob) -or [string]::IsNullOrEmpty($SessionStateFilePath)) {
        return
    }

    try {
        $sessionState = Read-SessionState -SessionStateFilePath $SessionStateFilePath
        if ($null -eq $sessionState) {
            return
        }

        $lastExitReasonProperty = $sessionState.PSObject.Properties['lastExitReason']
        if (-not $lastExitReasonProperty -or $lastExitReasonProperty.Value -ne 'clean-end-of-service') {
            return
        }

        $finishedRecordingFilePathProperty = $sessionState.PSObject.Properties['finishedRecordingFilePath']
        $finishedRecordingFilePath = if ($finishedRecordingFilePathProperty) { $finishedRecordingFilePathProperty.Value } else { $null }
        if ([string]::IsNullOrEmpty($finishedRecordingFilePath)) {
            return
        }

        $finishedRecordingLastWriteUtcProperty = $sessionState.PSObject.Properties['finishedRecordingLastWriteUtc']
        $finishedRecordingLastWriteUtcRaw = if ($finishedRecordingLastWriteUtcProperty) { $finishedRecordingLastWriteUtcProperty.Value } else { $null }
        # PowerShell 7's ConvertFrom-Json auto-detects an ISO 8601 ('o'-format) string
        # and deserialises it straight to a real [datetime] -- so the round-tripped
        # value may ALREADY be a DateTime (the common case) rather than the string
        # Save-SessionState wrote. Coercing it through [datetime]::Parse() unconditionally
        # would force an implicit ToString() using the CURRENT CULTURE first (seconds
        # precision only, fractional-second data silently lost) -- exactly the kind of
        # false-equal/false-negative mtime comparison T-epo-01 exists to prevent. Use the
        # already-typed value directly when present; only parse when it truly is a string.
        $finishedRecordingLastWriteUtc = $null
        if ($finishedRecordingLastWriteUtcRaw -is [datetime]) {
            $finishedRecordingLastWriteUtc = $finishedRecordingLastWriteUtcRaw
        } elseif (-not [string]::IsNullOrEmpty($finishedRecordingLastWriteUtcRaw)) {
            try {
                $finishedRecordingLastWriteUtc = [datetime]::Parse([string] $finishedRecordingLastWriteUtcRaw, `
                    [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            } catch {
                $finishedRecordingLastWriteUtc = $null
            }
        }

        $newestRecordingFile = $null
        try {
            $newestRecordingFile = Get-NewestMatchingRecordingFile -RecordingFolderPath $RecordingFolderPath -RecordingFilenameGlob $RecordingFilenameGlob
        } catch {
            Write-Log -Level Warning -Message "Invoke-AutoPickupTick: could not enumerate recording folder '$RecordingFolderPath' -- degrading to no-op this tick: $($_.Exception.Message)"
            return
        }

        $newestRecordingFilePath = if ($newestRecordingFile) { $newestRecordingFile.FullName } else { $null }
        $newestRecordingLastWriteUtc = if ($newestRecordingFile) { $newestRecordingFile.LastWriteTimeUtc } else { $null }

        $decision = Get-NewRecordingPickupDecision -FinishedRecordingFilePath $finishedRecordingFilePath `
            -FinishedRecordingLastWriteUtc $finishedRecordingLastWriteUtc `
            -NewestRecordingFilePath $newestRecordingFilePath -NewestRecordingLastWriteUtc $newestRecordingLastWriteUtc `
            -AutoPickupEnabled $AutoPickupEnabled

        if (-not $decision.NewRecordingDetected) {
            return
        }

        # Re-save only when the detected file actually changed, to avoid a 1/second
        # rewrite of session.json for the entire idle window after a finish.
        $currentlyRecordedFilePathProperty = $sessionState.PSObject.Properties['newRecordingDetectedFilePath']
        $currentlyRecordedFilePath = if ($currentlyRecordedFilePathProperty) { $currentlyRecordedFilePathProperty.Value } else { $null }
        if ($currentlyRecordedFilePath -ne $decision.NewRecordingFilePath) {
            Save-SessionState -SessionStateFilePath $SessionStateFilePath -LastExitReason 'clean-end-of-service' `
                -LastExitEpochSeconds $sessionState.lastExitEpochSeconds `
                -FinishedRecordingFilePath $finishedRecordingFilePath -FinishedRecordingLastWriteUtc $finishedRecordingLastWriteUtc `
                -NewRecordingDetectedFilePath $decision.NewRecordingFilePath
        }

        if ($decision.ShouldAutoStart) {
            # Reset-resume idiom (SESS-03/D-05 precedent, ApiControl's own reset-resume
            # arm): removing state/offset.json guarantees the pusher resolves the
            # strictly-newer file at offset 0 on its next Start -- the just-finished
            # (older) file is never re-opened, closing the D-11/D-12 duplicate-byte
            # hazard this whole feature exists to avoid (T-epo-01).
            if (-not [string]::IsNullOrEmpty($StateFilePath)) {
                Remove-Item -LiteralPath $StateFilePath -Force -ErrorAction SilentlyContinue
            }
            Set-PusherDesiredState -ControlFilePath $ControlFilePath -DesiredState 'streaming'
            # Clear lastExitReason so this pickup fires exactly once -- the very next
            # tick's Read-SessionState sees no 'clean-end-of-service' record and this
            # function returns at its second guard clause above.
            Save-SessionState -SessionStateFilePath $SessionStateFilePath -LastExitReason $null `
                -LastExitEpochSeconds $null -FinishedRecordingFilePath $null `
                -FinishedRecordingLastWriteUtc $null -NewRecordingDetectedFilePath $null
            Write-Log -Level Warning -Message "AUTO_PICKUP: strictly-newer recording '$($decision.NewRecordingFilePath)' detected after a clean finish -- auto-starting streaming (state/offset.json cleared, resuming from byte 0, the just-finished file is never re-picked)"
        }
    } catch {
        Write-Log -Level Error -Message "Invoke-AutoPickupTick faulted -- auto-pickup is inert this tick, supervision and streaming continue unaffected: $($_.Exception.Message)"
    }
}

function Start-DashboardHost {
    <#
    .SYNOPSIS
    Starts the dashboard per 05-01's HOST DECISION (05-SPIKE-FINDINGS.md): a
    runspace-hosted HttpListener, not the main-loop Task.WaitAny interleave --
    the supervisor's main thread only checks in once a second (idle ticks, then
    Wait-PusherProcessExit's polls while a pusher streams, which is the window the
    dashboard matters most), so the listener's accept loop needs its OWN execution
    context to answer requests immediately. The listener object itself is created and Start()ed on THIS thread
    (fast, non-blocking -- only GetContext() blocks) via the existing
    Start-DashboardListener, then handed by reference into a fresh [powershell]
    instance whose script block runs Invoke-DashboardListenerLoop, started via
    BeginInvoke() -- a thread inside this same process, never a second pwsh.exe
    (D-02's hard limit). This mirrors spike/Confirm-DashboardHost.ps1's
    Invoke-Q1RunspaceListenerSpike structure exactly, minus the throwaway
    probe/fault-injection scaffolding.

    NEVER THROWS (D-03's first line): the whole body is wrapped in try/catch. A
    dashboard that cannot start (most commonly: DASHBOARD_PORT already bound by
    another process) must degrade to "no dashboard", never to "no supervisor" -- a
    church whose port is taken still needs a working stream. On failure, logs at
    Error naming the port and DASHBOARD_PORT, and returns $null. The supervisor's
    automatic retry attempts pass -SuppressFailureLog, so a dashboard that stays
    unavailable writes that detailed line once (from the first start) instead of once
    per attempt.

    A fresh runspace does not inherit this process's already-imported modules or
    Logging's configured directory (D-15's Session-0 lesson, again) -- the script
    block below imports everything Invoke-DashboardListenerLoop's call chain needs
    and re-points Logging at the same directory this supervisor process uses, before
    the accept loop starts. Every path is resolved from the -ScriptRoot parameter,
    never from this process's own script-root variable or its current directory --
    this supervisor runs under Task Scheduler as the operator account (S4U) with
    CWD = %windir%\system32 and a Scheduled Task launch cannot be trusted to inherit a
    sane working directory (PITFALLS.md Pitfall 10).

    .OUTPUTS
    PSCustomObject: @{ Listener = <started HttpListener>; PowerShell = <[powershell]
    instance running the accept loop>; AsyncResult = <IAsyncResult> }, or $null on
    any failure to start.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [string] $ScriptRoot,
        [Parameter(Mandatory)] [int] $DashboardPort,
        [Parameter(Mandatory)] [string] $ControlFilePath,
        [switch] $SuppressFailureLog
    )

    try {
        $listener = Start-DashboardListener -DashboardPort $DashboardPort

        $dashboardRootPath = Join-Path $ScriptRoot 'dashboard'
        $envFilePath = Join-Path $ScriptRoot '.env'
        $statsFilePath = Join-Path $ScriptRoot 'state/stats.json'
        $logDirectoryPath = Join-Path $ScriptRoot 'state/logs'

        # SESS-03/SESS-04 (05.1-05, Pitfall 5/6): the recordings-list, delete-guard
        # and reset-resume routes need RecordingFolderPath/RecordingFilenameGlob/
        # StateFilePath resolved the exact same way pusher.ps1:53-61 resolves its own
        # copy -- read + anchor to -ScriptRoot BEFORE threading into the runspace, so
        # a relative .env value can never resolve against a Scheduled Task's System32
        # CWD (Pitfall 6). This read is inside Start-DashboardHost's own never-throw
        # try/catch (D-03): a config-read failure here still degrades to "no
        # dashboard, supervision continues", never crashes the supervisor.
        $dashboardConfig = Read-PusherConfig -Path $envFilePath
        $dashboardConfig = Resolve-PusherConfigPaths -Config $dashboardConfig -ScriptRoot $ScriptRoot
        $recordingFolderPath = $dashboardConfig.RecordingFolderPath
        $recordingFilenameGlob = $dashboardConfig.RecordingFilenameGlob
        $stateFilePath = $dashboardConfig.StateFilePath

        # 260722-xbr/NIC-TELEMETRY-01: resolve the SRT-path NIC name ONCE here, never
        # per-poll -- a resolution failure (no route, adapter vanished) leaves
        # $srtNicName $null, which simply disables NIC telemetry for this run (the
        # ApiStats branch's own SrtNicName guard); it never blocks the dashboard from
        # starting (D-03, this whole function is already wrapped in try/catch).
        $srtNicName = Resolve-SrtNicName -RelayHost $dashboardConfig.RelayHost -OverrideNicName $dashboardConfig.SrtNicName
        $nicUploadLogPath = Join-Path $ScriptRoot 'logs/nic-upload.jsonl'

        $listenerLoopScriptBlock = {
            param(
                $ScriptRoot, $ControlFilePath, $StatsFilePath, $DashboardRootPath,
                $EnvFilePath, $DashboardPort, $Listener, $LogDirectoryPath,
                $RecordingFolderPath, $RecordingFilenameGlob, $StateFilePath,
                $SrtNicName, $NicUploadLogPath
            )

            Import-Module (Join-Path $ScriptRoot 'lib/Logging.psm1')
            Set-LogDirectory -Path $LogDirectoryPath
            Import-Module (Join-Path $ScriptRoot 'lib/ControlFlag.psm1')
            Import-Module (Join-Path $ScriptRoot 'lib/PusherProcess.psm1')
            Import-Module (Join-Path $ScriptRoot 'lib/StatsStore.psm1')
            Import-Module (Join-Path $ScriptRoot 'lib/Clock.psm1')
            Import-Module (Join-Path $ScriptRoot 'lib/Config.psm1')
            Import-Module (Join-Path $ScriptRoot 'lib/Rotation.psm1')
            # 260718-epo: defense-in-depth only -- the ApiStats route's own read of
            # state/session.json resolves via Dashboard.psm1's own SessionState.psm1
            # import (Task 3), so this runspace does not strictly need its own copy
            # today, but importing it here keeps this script block self-sufficient for
            # any future in-runspace read, mirroring how Rotation.psm1 is imported here.
            Import-Module (Join-Path $ScriptRoot 'lib/SessionState.psm1')
            # 260722-xbr/NIC-TELEMETRY-01: the ApiStats route's own NIC block resolves
            # via Dashboard.psm1's own NicTelemetry.psm1 import, same reason as
            # SessionState.psm1 above -- imported here too so this script block stays
            # self-sufficient.
            Import-Module (Join-Path $ScriptRoot 'lib/NicTelemetry.psm1')
            Import-Module (Join-Path $ScriptRoot 'lib/Dashboard.psm1')

            # Stop-PusherProcesses only resolves against THIS runspace's own truly
            # global functions when called from inside Dashboard.psm1's
            # Invoke-DashboardRequestHandler (05-07-SUMMARY.md's confirmed finding)
            # -- dot-sourcing here, at this script block's own top level, is that
            # scope for this runspace, mirroring how supervisor.ps1 dot-sources
            # cut.ps1 at its own top level for a script run directly by pwsh.
            . (Join-Path $ScriptRoot 'cut.ps1')

            Invoke-DashboardListenerLoop -Listener $Listener -ScriptRoot $ScriptRoot `
                -ControlFilePath $ControlFilePath -StatsFilePath $StatsFilePath `
                -DashboardRootPath $DashboardRootPath -EnvFilePath $EnvFilePath `
                -DashboardPort $DashboardPort -RecordingFolderPath $RecordingFolderPath `
                -RecordingFilenameGlob $RecordingFilenameGlob -StateFilePath $StateFilePath `
                -SrtNicName $SrtNicName -NicUploadLogPath $NicUploadLogPath `
                -MaxRequests 0
        }

        $powershell = [powershell]::Create()
        [void] $powershell.AddScript($listenerLoopScriptBlock).
            AddArgument($ScriptRoot).AddArgument($ControlFilePath).AddArgument($statsFilePath).
            AddArgument($dashboardRootPath).AddArgument($envFilePath).AddArgument($DashboardPort).
            AddArgument($listener).AddArgument($logDirectoryPath).
            AddArgument($recordingFolderPath).AddArgument($recordingFilenameGlob).AddArgument($stateFilePath).
            AddArgument($srtNicName).AddArgument($nicUploadLogPath)

        $asyncResult = $powershell.BeginInvoke()

        return [pscustomobject]@{
            Listener    = $listener
            PowerShell  = $powershell
            AsyncResult = $asyncResult
        }
    } catch {
        if ($SuppressFailureLog) { return $null }
        Write-Log -Level Error -Message "Dashboard host failed to start on port $DashboardPort -- check DASHBOARD_PORT in .env if another process already owns this port. The pusher and supervisor are unaffected. ($($_.Exception.Message))"
        return $null
    }
}

function Test-DashboardHostFaulted {
    <#
    .SYNOPSIS
    Reports whether the dashboard's runspace-hosted execution context has died or
    faulted, per 05-01's HOST DECISION fault-detection mechanism: Invoke-
    DashboardListenerLoop's own GetContext() try/catch (05-07) means a
    stopped/faulted listener breaks its own accept loop and reaches a terminal
    PowerShell invocation state, rather than spinning forever writing
    non-terminating errors under a runspace's default ErrorActionPreference =
    'Continue' (the exact failure mode the spike's Q1 fault probe surfaced). Only
    'Running' (the accept loop is still executing) and 'NotStarted' (BeginInvoke()
    was just called and has not yet transitioned) count as healthy.

    Never throws -- a $null handle (Start-DashboardHost already failed to start) is
    already dead, and any other unreadable handle degrades to "faulted" rather than
    risking a caller crash on this read.

    .OUTPUTS
    Bool.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()] $DashboardHandle
    )

    if ($null -eq $DashboardHandle) { return $true }

    try {
        $state = $DashboardHandle.PowerShell.InvocationStateInfo.State
        return $state -notin @('Running', 'NotStarted')
    } catch {
        return $true
    }
}

function Get-DashboardRestartSchedule {
    <#
    .SYNOPSIS
    Pure: how long to wait before the next dashboard restart attempt, given how many
    attempts this outage has already made. Below MaximumFastAttempts the delay is the
    un-jittered exponential from lib/Backoff.psm1 (2, 4, 8, 16, 32, then the 60 s
    ceiling); from MaximumFastAttempts on it is SlowIntervalSeconds, forever.

    EntersSlowRetry is true only when RetryAttemptCount equals MaximumFastAttempts.
    Within one outage the count only grows, so that is exactly once -- it is what makes
    the "fast retries exhausted" line a one-time event.

    No jitter: there is one client and no herd of clients to spread out, and a fixed
    schedule keeps the timing predictable for the operator reading the log.

    .OUTPUTS
    PSCustomObject: @{ DelaySeconds = <double>; EntersSlowRetry = <bool> }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [int] $RetryAttemptCount,
        [Parameter(Mandatory)] [int] $MaximumFastAttempts,
        [Parameter(Mandatory)] [int] $SlowIntervalSeconds
    )

    $entersSlowRetry = $RetryAttemptCount -eq $MaximumFastAttempts

    if ($RetryAttemptCount -ge $MaximumFastAttempts) {
        return [pscustomobject]@{ DelaySeconds = [double] $SlowIntervalSeconds; EntersSlowRetry = $entersSlowRetry }
    }

    $fastDelayMilliseconds = Get-NextBackoffDelayMilliseconds -AttemptNumber $RetryAttemptCount `
        -BaseMilliseconds $script:DashboardRestartBaseDelayMilliseconds `
        -CeilingMilliseconds $script:DashboardRestartCeilingDelayMilliseconds -RandomValue 1.0
    return [pscustomobject]@{ DelaySeconds = $fastDelayMilliseconds / 1000.0; EntersSlowRetry = $entersSlowRetry }
}

function Test-DashboardRestartDue {
    <#
    .SYNOPSIS
    Pure: is a scheduled dashboard restart attempt due? $null means nothing is
    scheduled (a dashboard is running, or recovery has not been armed), never due.

    .OUTPUTS
    Bool.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [Nullable[double]] $NextAttemptAtSeconds,
        [Parameter(Mandatory)] [double] $NowSeconds
    )

    if ($null -eq $NextAttemptAtSeconds) { return $false }
    return $NowSeconds -ge $NextAttemptAtSeconds
}

function Test-DashboardRecoveryConfirmed {
    <#
    .SYNOPSIS
    Pure: has a restarted dashboard earned the "recovered" log line? Only when an
    outage is open (FaultLogged) AND the new handle has stayed up for one full stable
    window. That window is what keeps a dashboard that flaps on every slow cycle from
    writing a fault/recovery pair each time -- a start that dies inside the window
    belongs to the same outage.

    .OUTPUTS
    Bool.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [bool] $FaultLogged,
        [Parameter(Mandatory)] [double] $HandleUptimeSeconds,
        [Parameter(Mandatory)] [double] $StableUptimeSeconds
    )

    return $FaultLogged -and ($HandleUptimeSeconds -ge $StableUptimeSeconds)
}

function Get-DashboardFaultOutcome {
    <#
    .SYNOPSIS
    Pure: what a dashboard fault means for the log and the retry count. A dashboard that
    survived the stable window and then faulted starts a NEW outage (log the fault line,
    retry count back to 0). A dashboard that faults inside the window while an outage is
    already open is a flap in that same outage: silent, and the attempt count carries
    over so the schedule keeps growing instead of restarting at 2 s. A first fault of a
    healthy dashboard (no outage open) is logged.

    .OUTPUTS
    PSCustomObject: @{ LogFaultLine = <bool>; RetryAttemptCount = <int> }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [bool] $FaultLogged,
        [Parameter(Mandatory)] [double] $HandleUptimeSeconds,
        [Parameter(Mandatory)] [double] $StableUptimeSeconds,
        [Parameter(Mandatory)] [int] $RetryAttemptCount
    )

    if ($HandleUptimeSeconds -ge $StableUptimeSeconds) {
        return [pscustomobject]@{ LogFaultLine = $true; RetryAttemptCount = 0 }
    }
    return [pscustomobject]@{ LogFaultLine = -not $FaultLogged; RetryAttemptCount = $RetryAttemptCount }
}

function New-DashboardHostState {
    <#
    .SYNOPSIS
    Constructor for the dashboard recovery state that Invoke-Supervisor carries from
    tick to tick. Every field defaults to inert (no handle, no outage, nothing
    scheduled). Handle and FaultLogged carry the meaning of the old $dashboardHandle and
    $dashboardHostFaultLogged locals; FaultLogged now means "an outage is open and has
    been reported". Every state change returns a NEW object built here -- the input
    object is never modified.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] $Handle = $null,
        [bool] $FaultLogged = $false,
        [int] $RetryAttemptCount = 0,
        [AllowNull()] [Nullable[double]] $NextAttemptAtSeconds = $null,
        [AllowNull()] [Nullable[double]] $HandleStartedAtSeconds = $null,
        [bool] $RecoveryDisabled = $false
    )

    return [pscustomobject]@{
        Handle                 = $Handle
        FaultLogged            = $FaultLogged
        RetryAttemptCount      = $RetryAttemptCount
        NextAttemptAtSeconds   = $NextAttemptAtSeconds
        HandleStartedAtSeconds = $HandleStartedAtSeconds
        RecoveryDisabled       = $RecoveryDisabled
    }
}

function Copy-DashboardHostState {
    <#
    .SYNOPSIS
    A new dashboard recovery state equal to DashboardHostState except for the fields
    named in Changes (a hashtable keyed by New-DashboardHostState parameter name). Keeps
    every state transition to the one constructor without repeating all six fields at
    each call site. An unknown key throws, which the recovery tick's never-throw catch
    turns into "recovery off, logged once".
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $DashboardHostState,
        [Parameter(Mandatory)] [hashtable] $Changes
    )

    $fields = @{
        Handle                 = $DashboardHostState.Handle
        FaultLogged            = $DashboardHostState.FaultLogged
        RetryAttemptCount      = $DashboardHostState.RetryAttemptCount
        NextAttemptAtSeconds   = $DashboardHostState.NextAttemptAtSeconds
        HandleStartedAtSeconds = $DashboardHostState.HandleStartedAtSeconds
        RecoveryDisabled       = $DashboardHostState.RecoveryDisabled
    }
    foreach ($fieldName in $Changes.Keys) { $fields[$fieldName] = $Changes[$fieldName] }
    return New-DashboardHostState @fields
}

function Format-DashboardSlowInterval {
    <#
    .SYNOPSIS
    Pure: the slow retry interval as an operator-readable number of minutes ("10"), for
    the transition log lines.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [int] $SlowIntervalSeconds
    )

    return ([Math]::Round($SlowIntervalSeconds / 60.0, 1)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Resolve-DashboardNextAttemptSeconds {
    <#
    .SYNOPSIS
    The shared "schedule the next dashboard restart" step used by both the failed-attempt
    path and the fault path: returns when (monotonic seconds) the next attempt falls due,
    and writes the one-time "fast retries exhausted" Error line on the call that enters
    the slow tail. Nothing is written for any other call, so the slow tail is silent.

    .OUTPUTS
    Double: NowSeconds plus the schedule's delay.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [int] $RetryAttemptCount,
        [Parameter(Mandatory)] [int] $MaximumRetryAttempts,
        [Parameter(Mandatory)] [int] $SlowIntervalSeconds,
        [Parameter(Mandatory)] [int] $DashboardPort,
        [Parameter(Mandatory)] [double] $NowSeconds
    )

    $schedule = Get-DashboardRestartSchedule -RetryAttemptCount $RetryAttemptCount -MaximumFastAttempts $MaximumRetryAttempts -SlowIntervalSeconds $SlowIntervalSeconds
    if ($schedule.EntersSlowRetry) {
        $slowIntervalMinutes = Format-DashboardSlowInterval -SlowIntervalSeconds $SlowIntervalSeconds
        Write-Log -Level Error -Message "Dashboard host fast retries exhausted after $MaximumRetryAttempts attempts on port $DashboardPort -- will keep retrying silently every $slowIntervalMinutes minutes. Supervision and streaming continue unaffected."
    }
    return $NowSeconds + $schedule.DelaySeconds
}

function Stop-DashboardHostHandle {
    <#
    .SYNOPSIS
    Releases everything a dashboard handle holds: the HttpListener (and with it the
    localhost address claim), then the runspace-hosted PowerShell instance. Used both
    for a faulted dashboard before a retry and by Invoke-Supervisor's shutdown cleanup.
    A $null handle is a no-op. Never throws.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] $DashboardHandle
    )

    if (-not $DashboardHandle) { return }

    # Every call is guarded individually: Stop-DashboardListener's own contract is to
    # never throw, but the parameter bind itself (a $null Listener on a fake/mocked
    # handle in tests) can raise before that contract ever applies, and
    # PowerShell.Stop()/Dispose() are not guaranteed to exist on a test double standing
    # in for the real runspace handle.
    try { Stop-DashboardListener -Listener $DashboardHandle.Listener } catch { }
    try { $DashboardHandle.PowerShell.Stop() } catch { }
    try { $DashboardHandle.PowerShell.Dispose() } catch { }
}

function Invoke-DashboardHostStartAttempt {
    <#
    .SYNOPSIS
    One dashboard start attempt, guarded a second time. Start-DashboardHost's own body
    already never throws by contract, but the process that owns crash restart must
    survive a dashboard failure even if that contract is ever broken by a future edit
    (D-03) -- so every start, the first one and every retry, goes through this wrapper
    rather than trusting the callee alone. Returns the handle, or $null on any failure.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [string] $ScriptRoot,
        [Parameter(Mandatory)] [int] $DashboardPort,
        [Parameter(Mandatory)] [string] $ControlFilePath,
        [switch] $SuppressFailureLog
    )

    try {
        return Start-DashboardHost -ScriptRoot $ScriptRoot -DashboardPort $DashboardPort `
            -ControlFilePath $ControlFilePath -SuppressFailureLog:$SuppressFailureLog
    } catch {
        if ($SuppressFailureLog) { return $null }
        Write-Log -Level Error -Message "Dashboard host start raised an unexpected exception -- it will be retried automatically. Supervision and streaming continue unaffected. ($($_.Exception.Message))"
        return $null
    }
}

function Initialize-DashboardHostState {
    <#
    .SYNOPSIS
    The one start before the tick loop. DashboardPort 0 is genuinely inert (no clock
    read, no start). A failed start opens an outage: one Warning line, then the retry
    path in Invoke-DashboardHostRecoveryTick takes over. This is the only unsuppressed
    start in the whole run, so the detailed address error is still logged exactly once,
    as it always was.

    .OUTPUTS
    PSCustomObject: the dashboard recovery state (see New-DashboardHostState).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $ScriptRoot,
        [Parameter(Mandatory)] [int] $DashboardPort,
        [Parameter(Mandatory)] [string] $ControlFilePath,
        [Parameter(Mandatory)] [int] $MaximumRetryAttempts,
        [Parameter(Mandatory)] [int] $SlowIntervalSeconds
    )

    if ($DashboardPort -eq 0) { return New-DashboardHostState }

    try {
        $nowSeconds = Get-MonotonicSeconds
        $dashboardHandle = Invoke-DashboardHostStartAttempt -ScriptRoot $ScriptRoot -DashboardPort $DashboardPort -ControlFilePath $ControlFilePath
        if ($null -ne $dashboardHandle) {
            return New-DashboardHostState -Handle $dashboardHandle -HandleStartedAtSeconds $nowSeconds
        }

        $fastBaseSeconds = $script:DashboardRestartBaseDelayMilliseconds / 1000
        $fastCeilingSeconds = $script:DashboardRestartCeilingDelayMilliseconds / 1000
        $slowIntervalMinutes = Format-DashboardSlowInterval -SlowIntervalSeconds $SlowIntervalSeconds
        Write-Log -Level Warning -Message "Dashboard host is unavailable on port $DashboardPort -- retrying automatically (fast retries ${fastBaseSeconds}s growing to ${fastCeilingSeconds}s apart, up to $MaximumRetryAttempts attempts, then every $slowIntervalMinutes minutes). Supervision and streaming continue unaffected."
        $nextAttemptAtSeconds = Resolve-DashboardNextAttemptSeconds -RetryAttemptCount 0 -MaximumRetryAttempts $MaximumRetryAttempts `
            -SlowIntervalSeconds $SlowIntervalSeconds -DashboardPort $DashboardPort -NowSeconds $nowSeconds
        return New-DashboardHostState -FaultLogged $true -NextAttemptAtSeconds $nextAttemptAtSeconds
    } catch {
        Write-Log -Level Error -Message "Dashboard host initial step raised an unexpected exception -- automatic dashboard recovery is off for the rest of this run. Supervision and streaming continue unaffected. ($($_.Exception.Message))"
        return New-DashboardHostState -RecoveryDisabled $true
    }
}

function Invoke-DashboardHostRecoveryTick {
    <#
    .SYNOPSIS
    One per-tick step of dashboard self-healing. Pure in shape like
    Invoke-AutoPickupTick: it takes the current recovery state and returns the next
    one; the only side effects are the transition log lines and the restart attempt
    itself. DashboardPort 0 returns the state untouched without reading the clock.

    Reads the monotonic clock exactly once per tick, then decides in order: recovery
    switched off for the run (after an unexpected exception) changes nothing; a faulted
    dashboard is stopped (releasing its address claim), cleared and scheduled for a
    retry, never retried in the same tick; a restarted dashboard that has stayed up for
    the stable window is a confirmed recovery (one Info line, fault logging re-armed); a
    running dashboard is left alone; a restart that is not yet due is left alone;
    otherwise one silent restart attempt is made. Never throws: an unexpected exception
    is logged once and switches recovery off, keeping the handle for the final cleanup.

    .OUTPUTS
    PSCustomObject: the next dashboard recovery state.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $DashboardHostState,
        [Parameter(Mandatory)] [string] $ScriptRoot,
        [Parameter(Mandatory)] [int] $DashboardPort,
        [Parameter(Mandatory)] [string] $ControlFilePath,
        [Parameter(Mandatory)] [int] $MaximumRetryAttempts,
        [Parameter(Mandatory)] [int] $SlowIntervalSeconds
    )

    if ($DashboardPort -eq 0) { return $DashboardHostState }
    if ($DashboardHostState.RecoveryDisabled) { return $DashboardHostState }

    try {
        $nowSeconds = Get-MonotonicSeconds
        $hasHandle = $null -ne $DashboardHostState.Handle
        $handleUptimeSeconds = if ($hasHandle) { $nowSeconds - $DashboardHostState.HandleStartedAtSeconds } else { 0.0 }

        if ($hasHandle -and (Test-DashboardHostFaulted -DashboardHandle $DashboardHostState.Handle)) {
            $faultOutcome = Get-DashboardFaultOutcome -FaultLogged $DashboardHostState.FaultLogged -HandleUptimeSeconds $handleUptimeSeconds `
                -StableUptimeSeconds $SlowIntervalSeconds -RetryAttemptCount $DashboardHostState.RetryAttemptCount
            if ($faultOutcome.LogFaultLine) {
                Write-Log -Level Error -Message 'Dashboard host has faulted or stopped -- the dashboard is unavailable and will be restarted automatically. Supervision and streaming continue unaffected.'
            }
            # Stopped BEFORE it is cleared and before a retry is scheduled: a dead
            # handle's listener can still hold the address, and a retry would then
            # collide with our own leftover claim.
            Stop-DashboardHostHandle -DashboardHandle $DashboardHostState.Handle
            $nextAttemptAtSeconds = Resolve-DashboardNextAttemptSeconds -RetryAttemptCount $faultOutcome.RetryAttemptCount `
                -MaximumRetryAttempts $MaximumRetryAttempts -SlowIntervalSeconds $SlowIntervalSeconds `
                -DashboardPort $DashboardPort -NowSeconds $nowSeconds
            # Never retried in the same tick: the retry waits for its scheduled time.
            return Copy-DashboardHostState -DashboardHostState $DashboardHostState -Changes @{
                Handle = $null; FaultLogged = $true
                RetryAttemptCount = $faultOutcome.RetryAttemptCount; NextAttemptAtSeconds = $nextAttemptAtSeconds
            }
        }

        if ($hasHandle -and (Test-DashboardRecoveryConfirmed -FaultLogged $DashboardHostState.FaultLogged -HandleUptimeSeconds $handleUptimeSeconds -StableUptimeSeconds $SlowIntervalSeconds)) {
            Write-Log -Level Info -Message "Dashboard host recovered on port $DashboardPort after $($DashboardHostState.RetryAttemptCount) restart attempt(s) and has stayed up for $($SlowIntervalSeconds)s -- the dashboard is available again."
            return Copy-DashboardHostState -DashboardHostState $DashboardHostState -Changes @{
                FaultLogged = $false; RetryAttemptCount = 0; NextAttemptAtSeconds = $null
            }
        }

        if ($hasHandle) { return $DashboardHostState }

        if (-not (Test-DashboardRestartDue -NextAttemptAtSeconds $DashboardHostState.NextAttemptAtSeconds -NowSeconds $nowSeconds)) {
            return $DashboardHostState
        }

        $retryAttemptCount = $DashboardHostState.RetryAttemptCount + 1
        $restartedHandle = Invoke-DashboardHostStartAttempt -ScriptRoot $ScriptRoot -DashboardPort $DashboardPort `
            -ControlFilePath $ControlFilePath -SuppressFailureLog

        if ($null -eq $restartedHandle) {
            $nextAttemptAtSeconds = Resolve-DashboardNextAttemptSeconds -RetryAttemptCount $retryAttemptCount `
                -MaximumRetryAttempts $MaximumRetryAttempts -SlowIntervalSeconds $SlowIntervalSeconds `
                -DashboardPort $DashboardPort -NowSeconds $nowSeconds
            return Copy-DashboardHostState -DashboardHostState $DashboardHostState -Changes @{
                RetryAttemptCount = $retryAttemptCount; NextAttemptAtSeconds = $nextAttemptAtSeconds
            }
        }

        # Not a confirmed recovery yet -- the new dashboard must stay up for the stable
        # window first, so nothing is logged here.
        return Copy-DashboardHostState -DashboardHostState $DashboardHostState -Changes @{
            Handle = $restartedHandle; HandleStartedAtSeconds = $nowSeconds
            NextAttemptAtSeconds = $null; RetryAttemptCount = $retryAttemptCount
        }
    } catch {
        Write-Log -Level Error -Message "Dashboard host recovery step raised an unexpected exception -- automatic dashboard recovery is off for the rest of this run. Supervision and streaming continue unaffected. ($($_.Exception.Message))"
        # Keeps the existing Handle so the finally cleanup still releases it.
        return Copy-DashboardHostState -DashboardHostState $DashboardHostState -Changes @{ RecoveryDisabled = $true }
    }
}

function Invoke-DashboardHostMaintenance {
    <#
    .SYNOPSIS
    The one dashboard-maintenance step both wait sites call: the idle tick in
    Invoke-Supervisor and every poll in Wait-PusherProcessExit while a pusher streams
    (261018). It runs Invoke-DashboardHostRecoveryTick (unchanged: same schedule, flap
    guard and transition-only log lines) and returns the next recovery state.

    WHY a second guard on top of the tick's own catch: that catch cannot catch a
    parameter-bind failure, because the exception is raised at the call site before the
    tick's body runs. During streaming an escaping exception would end the supervisor
    while its pusher keeps running unsupervised. So an exception here is logged once,
    switches maintenance off for the rest of the run (the state's RecoveryDisabled flag,
    after which this function is never entered again, so a repeating failure logs once
    instead of once a second) and keeps the Handle for the final cleanup.

    Never throws. Never touches the pusher process or the probe host.

    .OUTPUTS
    PSCustomObject: the next dashboard recovery state.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $DashboardHostState,
        [Parameter(Mandatory)] [hashtable] $DashboardRecoveryParameters
    )

    try {
        if ($DashboardHostState.RecoveryDisabled) { return $DashboardHostState }
        return Invoke-DashboardHostRecoveryTick -DashboardHostState $DashboardHostState @DashboardRecoveryParameters
    } catch {
        try {
            Write-Log -Level Error -Message "Dashboard host recovery step raised an unexpected exception -- automatic dashboard recovery is off for the rest of this run. Supervision and streaming continue unaffected. ($($_.Exception.Message))"
        } catch { }
        # Keeps the existing Handle so the finally cleanup still releases it.
        return Copy-DashboardHostState -DashboardHostState $DashboardHostState -Changes @{ RecoveryDisabled = $true }
    }
}

function Start-ProbeHost {
    <#
    .SYNOPSIS
    Starts the probe host per MON-05/D-04: a SECOND runspace-hosted background
    worker, structurally separate from BOTH the pacing loop (pusher.ps1, never
    touched by this function at all) AND the dashboard request loop
    (Start-DashboardHost above) -- this is that exact live-proven pattern,
    mirrored a second time (06-PATTERNS.md's "Runspace-hosted background
    worker, never a second pwsh.exe"). The listener-equivalent step
    (Start-DashboardListener's synchronous, fast, non-blocking setup) has no
    analog here -- there is no socket to bind up front -- so this function's
    own work before BeginInvoke() is just resolving paths and ensuring the
    state/probes output directory exists.

    NEVER THROWS (mirrors Start-DashboardHost's own contract verbatim): the
    whole body is wrapped in try/catch. A probe host that cannot start must
    degrade to "no probes", never to "no supervisor" -- MON-05's isolation
    guarantee extends to the host's own startup failure, not merely to a
    single hung probe once running. On failure, logs at Error and returns
    $null.

    A fresh runspace does not inherit this process's already-imported modules
    or Logging's configured directory (D-15's Session-0 lesson, same as
    Start-DashboardHost) -- the script block below imports everything
    Invoke-ProbeHostLoop's call chain needs and re-points Logging at the same
    directory this supervisor process uses, before the scheduler loop starts.
    Every path is resolved from the -ScriptRoot parameter, never from this
    process's own script-root variable or its current directory -- this
    supervisor runs under Task Scheduler as the operator account (S4U) with
    CWD = %windir%\system32 and a Scheduled Task launch cannot be trusted to
    inherit a sane working directory (PITFALLS.md Pitfall 10).

    .OUTPUTS
    PSCustomObject: @{ PowerShell = <[powershell] instance running the
    scheduler loop>; AsyncResult = <IAsyncResult> }, or $null on any failure
    to start.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [string] $ScriptRoot
    )

    try {
        $probesDirectoryPath = Join-Path $ScriptRoot 'probes'
        $stateProbesDirectoryPath = Join-Path $ScriptRoot 'state/probes'
        $logDirectoryPath = Join-Path $ScriptRoot 'state/logs'
        $envFilePath = Join-Path $ScriptRoot '.env'

        if (-not (Test-Path -LiteralPath $stateProbesDirectoryPath)) {
            New-Item -ItemType Directory -Path $stateProbesDirectoryPath -Force | Out-Null
        }

        # Read + anchor config via -ScriptRoot BEFORE threading into the
        # runspace, mirroring Start-DashboardHost's identical config-read step
        # (a relative .env value must never resolve against a Scheduled
        # Task's System32 CWD). This read is inside Start-ProbeHost's own
        # never-throw try/catch: a config-read failure here still degrades to
        # "no probes, supervision continues", never crashes the supervisor.
        $probeConfig = Read-PusherConfig -Path $envFilePath
        $probeConfig = Resolve-PusherConfigPaths -Config $probeConfig -ScriptRoot $ScriptRoot

        $probeHostLoopScriptBlock = {
            param(
                $ScriptRoot, $ProbesDirectoryPath, $ProbeConfig,
                $HardTimeoutMilliseconds, $StateProbesDirectoryPath, $LogDirectoryPath
            )

            Import-Module (Join-Path $ScriptRoot 'lib/Logging.psm1')
            Set-LogDirectory -Path $LogDirectoryPath
            Import-Module (Join-Path $ScriptRoot 'lib/Clock.psm1')
            Import-Module (Join-Path $ScriptRoot 'lib/Config.psm1')
            Import-Module (Join-Path $ScriptRoot 'lib/ProbeStore.psm1')
            Import-Module (Join-Path $ScriptRoot 'lib/ProbeHost.psm1')

            Invoke-ProbeHostLoop -ProbesDirectory $ProbesDirectoryPath -Config $ProbeConfig `
                -HardTimeoutMilliseconds $HardTimeoutMilliseconds `
                -StateProbesDirectory $StateProbesDirectoryPath
        }

        $powershell = [powershell]::Create()
        [void] $powershell.AddScript($probeHostLoopScriptBlock).
            AddArgument($ScriptRoot).AddArgument($probesDirectoryPath).AddArgument($probeConfig).
            AddArgument($script:ProbeHostHardTimeoutMilliseconds).AddArgument($stateProbesDirectoryPath).
            AddArgument($logDirectoryPath)

        $asyncResult = $powershell.BeginInvoke()

        return [pscustomobject]@{
            PowerShell  = $powershell
            AsyncResult = $asyncResult
        }
    } catch {
        Write-Log -Level Error -Message "Probe host failed to start -- probes are unavailable for this run, but supervision and streaming are unaffected. ($($_.Exception.Message))"
        return $null
    }
}

function Test-ProbeHostFaulted {
    <#
    .SYNOPSIS
    Reports whether the probe host's runspace-hosted execution context has
    died or faulted -- twin of Test-DashboardHostFaulted above (MON-05/D-04),
    copied verbatim against the probe host's own handle shape. Only 'Running'
    (the scheduler loop is still executing) and 'NotStarted' (BeginInvoke()
    was just called and has not yet transitioned) count as healthy.

    Never throws -- a $null handle (Start-ProbeHost already failed to start)
    is already dead, and any other unreadable handle degrades to "faulted"
    rather than risking a caller crash on this read.

    .OUTPUTS
    Bool.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()] $ProbeHostHandle
    )

    if ($null -eq $ProbeHostHandle) { return $true }

    try {
        $state = $ProbeHostHandle.PowerShell.InvocationStateInfo.State
        return $state -notin @('Running', 'NotStarted')
    } catch {
        return $true
    }
}

function Invoke-Supervisor {
    <#
    .SYNOPSIS
    The main loop. Each tick: read the operator's desired state; if it is not
    'streaming', sleep and poll again (this is the idle boot state); if it is, run
    the pusher to completion and branch on its exit code -- stay down (setting
    desired=stopped) on a documented clean/config exit, or relaunch after a
    full-jitter backoff on a crash.

    A crash NEVER touches the flag: a crash is not an operator stop, so desired stays
    'streaming' and the loop keeps bringing the stream back. Conversely the loop
    re-reads the flag every single tick, so an operator's stop.ps1 / cut.ps1 (or the
    dashboard's Stop and Cut buttons) interrupts even a crash loop on the very next
    tick, and an operator's start.ps1 picks the next service straight back up with no
    reboot. That re-read is what makes cut.ps1 safe: it sets desired=stopped BEFORE
    killing the pusher, so the crash-class exit its kill produces is classified as
    Relaunch and then never acted on.

    The crash backoff therefore waits at the TOP of the following tick -- after the
    flag re-read and immediately before the launch -- rather than at the end of the
    crashing tick. One tick still means at most one launch attempt; what changes is
    that nothing is announced or slept for until the flag has confirmed it will
    actually happen.

    Backoff reuses Get-NextBackoffDelayMilliseconds (lib/Backoff.psm1) rather than
    growing a second backoff implementation -- same full-jitter formula, same ceiling
    clamp (T-02-BOFLOOP), already unit-tested. The attempt counter advances only on
    consecutive crashes and resets whenever the loop reaches a non-crash state, so a
    single crash six hours into a service is not delayed by this morning's history.

    The dashboard heals itself (261011-ugi). A failed first start and a faulted dashboard
    are retried from the idle tick and, while a pusher streams, from
    Wait-PusherProcessExit's polls -- both through Invoke-DashboardHostMaintenance, the
    same state machine -- fast first (2 s doubling to 60 s apart, up to
    DashboardRestartMaximumAttempts attempts), then silently every
    DashboardRestartSlowIntervalSeconds for the rest of the run. Only state transitions
    are logged, so an outage writes a constant number of lines. Nothing in that path can
    throw out of this function, delay the pusher, or touch the probe host.

    Orphan-pusher guard (261018). The five-minute watchdog can start a new supervisor while
    a pusher of the dead one still streams. Before every launch the loop probes the
    per-install Pusher mutex (Test-SingleInstanceMutexHeld); while it is held nothing is
    launched, the control flag is not touched and no crash is counted. A pusher that loses
    the mutex race exits 4, which Get-SupervisorExitDecision maps to WaitForRunningPusher:
    no session.json write, no flag write. Exit 4 also covers a guard that failed with no
    holder, so the mutex is probed again after the exit: held means wait with no crash
    count; not held is paced like a crash (the existing backoff) so a failing guard can
    never become a tight relaunch loop. The warning is logged once per episode. When the
    orphan's mutex disappears the next launch is a normal decision from the flag re-read. Accepted
    residual: if the orphan finished end-of-service on its own, the flag still says
    'streaming', so the D-05 tail margin (up to 2 MB) is re-sent once.

    MaxTicks is the test seam and nothing else: production runs with the default 0
    (unbounded -- this is a boot-to-shutdown service), while tests bound the loop so
    it terminates.

    .OUTPUTS
    Int: the supervisor's own exit code (0 -- it exits only when its tick budget runs
    out, which in production never happens).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $ControlFilePath,
        [Parameter(Mandatory)] [string] $ScriptRoot,
        [int] $MaxTicks = 0,
        [int] $DashboardPort = 0,
        [string] $RecordingFolderPath = $null,
        [string] $RecordingFilenameGlob = $null,
        [string] $StateFilePath = $null,
        [string] $SessionStateFilePath = $null,
        [bool] $AutoPickupEnabled = $false,
        # Dashboard restart knobs (261011-ugi): code-level defaults, also the test hooks.
        # Deliberately not wired to .env.
        [int] $DashboardRestartMaximumAttempts = $script:DashboardRestartMaximumAttempts,
        [int] $DashboardRestartSlowIntervalSeconds = $script:DashboardRestartSlowIntervalSeconds
    )

    Write-Log -Level Info -Message "Supervisor starting ($(Get-ProcessIdentityLogText)) -- idle until an operator starts streaming; control flag '$ControlFilePath', script root '$ScriptRoot'"

    $consecutiveCrashCount = 0
    $lastLoggedDesiredState = $null
    $dashboardHostState = New-DashboardHostState
    $dashboardRecoveryParameters = @{
        ScriptRoot           = $ScriptRoot
        DashboardPort        = $DashboardPort
        ControlFilePath      = $ControlFilePath
        MaximumRetryAttempts = $DashboardRestartMaximumAttempts
        SlowIntervalSeconds  = $DashboardRestartSlowIntervalSeconds
    }
    $probeHostHandle = $null
    $probeHostFaultLogged = $false
    $pusherSingleInstanceMutexName = Get-SupervisorSingleInstanceMutexName -ScriptRoot $ScriptRoot -Role 'Pusher'
    $otherPusherWaitLogged = $false
    $exitFourWarningLogged = $false
    $stayDownFlagWritePending = $false

    try {
    # DashboardPort 0 (the default) is genuinely inert -- no listener is ever
    # started, so every pre-existing caller of Invoke-Supervisor that never passes
    # this parameter keeps the exact pre-05-09 behavior. The FIRST start happens ONCE,
    # before the tick loop begins (05-01's HOST DECISION: the tick loop body does not
    # run while a pusher is streaming -- only dashboard maintenance runs, inside
    # Wait-PusherProcessExit -- so the dashboard needs its own execution context
    # regardless of where in the loop this call sits). Any later start happens only
    # through the maintenance step (Invoke-DashboardHostMaintenance) below and in
    # Wait-PusherProcessExit. The start guards itself (D-03,
    # Invoke-DashboardHostStartAttempt): the callee never throws by contract, but this
    # process must survive a dashboard failure even if that contract is ever broken.
    $dashboardHostState = Initialize-DashboardHostState @dashboardRecoveryParameters

    # Never gated on DashboardPort (MON-05/D-04): probes are a wholly separate
    # concern from the dashboard and must run even when the dashboard is
    # disabled -- the only gate is each probe's own .env enable flag (D-03),
    # so a probe host with zero enabled probes still starts, cheaply, and is
    # the MON-04 baseline. Started ONCE, before the tick loop, not per-tick
    # (mirrors the dashboard's own start-once placement immediately above,
    # for the identical reason: the tick loop body does not run while a pusher
    # is streaming, so the probe host needs its own execution context
    # regardless of where in the loop this call sits). Defense in depth
    # (mirroring the dashboard call site immediately above): Start-ProbeHost's
    # own body already never throws by contract, but the process that owns
    # crash restart must survive a probe-host failure even if that contract
    # is ever broken by a future edit -- so this call site guards itself too,
    # rather than trusting the callee alone.
    try {
        $probeHostHandle = Start-ProbeHost -ScriptRoot $ScriptRoot
    } catch {
        Write-Log -Level Error -Message "Probe host start raised an unexpected exception -- probes are disabled for this run, but supervision and streaming continue unaffected. ($($_.Exception.Message))"
        $probeHostHandle = $null
    }

    for ($tick = 1; ($MaxTicks -le 0) -or ($tick -le $MaxTicks); $tick++) {
        $desiredState = Get-PusherDesiredState -ControlFilePath $ControlFilePath

        # Transition-only logging: Get-PusherDesiredState is polled once per second
        # for the whole idle week between services and is silent by design (see
        # lib/ControlFlag.psm1's header), so the operator-visible record of what the
        # flag said lives here, once per CHANGE.
        if ($desiredState -ne $lastLoggedDesiredState) {
            Write-Log -Level Info -Message "Desired state is now '$desiredState'"
            $lastLoggedDesiredState = $desiredState
        }

        # Dashboard recovery (D-03/05-01's HOST DECISION, rewritten 261011-ugi) runs on
        # EVERY tick regardless of desired state -- placed BEFORE the idle branch's
        # `continue` immediately below, because idle is most of the week and a step
        # placed after that continue would never run while idle.
        #
        # A failed first start and a faulted dashboard are retried the same way: fast
        # retries come 2 s doubling to 60 s apart, up to DashboardRestartMaximumAttempts
        # attempts, then the supervisor retries silently every
        # DashboardRestartSlowIntervalSeconds, forever. It never gives up for good
        # because on 2026-10-04 a duplicate supervisor held the dashboard address for
        # much longer than any fixed burst would have covered.
        #
        # Recovery is confirmed only after one slow interval of uptime. A dashboard that
        # faults sooner continues the same outage silently -- the flap guard.
        #
        # Logging happens only on transitions (outage opened, fast retries exhausted,
        # recovered), mirroring $lastLoggedDesiredState's convention and for the same
        # reason (SVC-03/D-14): this loop ticks once a second for the whole idle week.
        # Each outage therefore writes a constant number of lines; retries suppress their
        # own failure log via -SuppressFailureLog.
        #
        # The same step also runs once per second inside Wait-PusherProcessExit while a
        # pusher streams, so a fault or a due retry is handled mid-service. The remaining
        # gaps are the crash-backoff sleep (at most 30 s) and the length of a start
        # attempt; counting attempts instead of elapsed time keeps those gaps from
        # changing the schedule.
        $dashboardHostState = Invoke-DashboardHostMaintenance -DashboardHostState $dashboardHostState `
            -DashboardRecoveryParameters $dashboardRecoveryParameters

        # Probe host fault check -- twin of the dashboard recovery step immediately
        # above, same placement (BEFORE the idle branch's `continue` below, same
        # reason: idle is most of the week and a check placed after that continue
        # would never run while idle). The probe host is still never auto-restarted,
        # while the dashboard now retries (261011-ugi); it keeps the "log once per
        # fault via a flag" convention (MON-05/D-04: a faulted host is a
        # log-flood risk to retry automatically, and the recovery -- a supervisor
        # restart -- is already available to the operator). Unlike the dashboard step,
        # this check stays tick-only (261018): it is not part of the streaming-time
        # maintenance in Wait-PusherProcessExit.
        if ($probeHostHandle -and -not $probeHostFaultLogged -and (Test-ProbeHostFaulted -ProbeHostHandle $probeHostHandle)) {
            Write-Log -Level Error -Message 'Probe host has faulted or stopped -- probes are unavailable, but supervision and streaming continue unaffected. Restart the supervisor to recover probes.'
            $probeHostFaultLogged = $true
        }

        # Stay-down flag write retry (261018, B8). The pusher exited in a way that must
        # not be relaunched, but writing 'stopped' to the control flag failed (a transient
        # Defender or indexer lock). The flag still says 'streaming', so launching again
        # would re-send the resume margin as duplicate bytes. Until the write succeeds,
        # nothing is launched; the retry is silent on failure (the failure was logged once).
        if ($stayDownFlagWritePending) {
            try {
                Set-PusherDesiredState -ControlFilePath $ControlFilePath -DesiredState 'stopped'
                $stayDownFlagWritePending = $false
                Write-Log -Level Info -Message "Control flag set back to 'stopped' on retry."
            } catch { }
            Start-Sleep -Milliseconds $script:IdlePollIntervalMilliseconds
            continue
        }

        if ($desiredState -ne 'streaming') {
            $consecutiveCrashCount = 0
            # 260718-epo/FEAT-C: config-gated auto-pickup -- own never-throw contract
            # (Invoke-AutoPickupTick's whole body is try/catch-guarded), kept strictly
            # inside the idle branch, never reached while streaming.
            Invoke-AutoPickupTick -ControlFilePath $ControlFilePath -RecordingFolderPath $RecordingFolderPath `
                -RecordingFilenameGlob $RecordingFilenameGlob -StateFilePath $StateFilePath `
                -SessionStateFilePath $SessionStateFilePath -AutoPickupEnabled $AutoPickupEnabled
            Start-Sleep -Milliseconds $script:IdlePollIntervalMilliseconds
            continue
        }

        # Orphan-pusher guard (261018, B6). A supervisor that died mid-service can leave its
        # pusher running, and the watchdog starts a new supervisor next to it. While any
        # pusher of this install holds the Pusher mutex, nothing is launched: no second
        # pusher, no flag write, no crash count. The wait is announced once per transition
        # (this loop ticks once a second). When the mutex frees, the next launch is a
        # normal decision made from the flag re-read above. Accepted residual: if the
        # orphan finished end-of-service on its own, the flag still says 'streaming', so
        # the D-05 tail margin (up to 2 MB) is re-sent once.
        $pusherMutexHeld = Test-SingleInstanceMutexHeld -MutexName $pusherSingleInstanceMutexName
        if ($pusherMutexHeld -and -not $otherPusherWaitLogged) {
            Write-Log -Level Warning -Message 'Another pusher for this install is still running (left behind by an earlier supervisor) -- waiting for it to exit; no second pusher is started and the control flag is untouched.'
            $otherPusherWaitLogged = $true
        }
        if ($pusherMutexHeld) {
            # Waiting for a real holder is its own pacing; a count left by failed-guard
            # exit-4 launches must not add a backoff on top once the holder is gone.
            $consecutiveCrashCount = 0
            Start-Sleep -Milliseconds $script:IdlePollIntervalMilliseconds
            continue
        }
        if ($otherPusherWaitLogged) {
            Write-Log -Level Info -Message 'The earlier pusher has exited -- starting the pusher normally.'
            $otherPusherWaitLogged = $false
        }

        # The crash backoff waits HERE, after the flag re-read, rather than at the end
        # of the crashing tick -- so this log line is written only once the flag has
        # confirmed the relaunch will actually happen. Logged the other way round it
        # was a lie in the exact case that matters most: cut.ps1 sets desired=stopped
        # before killing the pusher, the kill reports a crash-class exit, and the log
        # then announced a relaunch that the very next tick cancelled. A church
        # volunteer reading "Relaunching the pusher in 853ms" at 10:55 on a Sunday
        # believes the stream is coming back. After a cut, it is not.
        #
        # This is also the ONLY place the relaunch is described, reassurance included.
        # The crash branch below states the exit as a fact and stops there, because at
        # that moment nothing has yet decided a relaunch will follow.
        if ($consecutiveCrashCount -gt 0) {
            $backoffDelayMilliseconds = Get-NextBackoffDelayMilliseconds -AttemptNumber ($consecutiveCrashCount - 1)
            Write-Log -Level Warning -Message "Relaunching the pusher in ${backoffDelayMilliseconds}ms (consecutive crashes: $consecutiveCrashCount) -- $script:RelaunchReassurance"
            Start-Sleep -Milliseconds $backoffDelayMilliseconds

            # Re-read once more after the wait, not only before it: the backoff window
            # is precisely when a human is most likely to stop or cut a crash loop by
            # hand, and without this the honest log above would be honest when written
            # and stale by the time the launch happened. This also preserves the
            # pre-existing guarantee that the flag is always the last thing consulted
            # before a pusher is spawned.
            if ((Get-PusherDesiredState -ControlFilePath $ControlFilePath) -ne 'streaming') {
                Write-Log -Level Info -Message 'Relaunch cancelled -- the operator stopped streaming during the backoff.'
                $consecutiveCrashCount = 0
                continue
            }
        }

        $pusherProcess = Start-PusherProcess -ScriptRoot $ScriptRoot
        $pusherWaitResult = Wait-PusherProcessExit -PusherProcess $pusherProcess `
            -DashboardHostState $dashboardHostState -DashboardRecoveryParameters $dashboardRecoveryParameters
        $dashboardHostState = $pusherWaitResult.DashboardHostState
        $pusherExitCode = $pusherWaitResult.ExitCode
        $decision = Get-SupervisorExitDecision -ExitCode $pusherExitCode

        # Exit 4 (261018, B6): this launch stood down, normally because another pusher holds
        # the Pusher mutex. Either way it ran nothing, so it records no session state and
        # writes no flag. Exit 4 also covers "the guard itself failed", so the mutex is
        # probed again to tell the two apart:
        #   held     -> a real holder: wait for it on the next ticks, no crash counted.
        #   not held -> nothing is holding it, so relaunching at once would loop tightly;
        #               it is paced like a crash (the backoff before the next launch).
        # The warning is written once per episode of consecutive exit-4 launches, never
        # per launch; any other exit re-arms it.
        if ($decision.Action -eq 'WaitForRunningPusher') {
            if (-not $exitFourWarningLogged) {
                Write-Log -Level Warning -Message "Pusher exited $pusherExitCode -- $($decision.Reason)"
                $exitFourWarningLogged = $true
            }
            if (Test-SingleInstanceMutexHeld -MutexName $pusherSingleInstanceMutexName) {
                $consecutiveCrashCount = 0
                Start-Sleep -Milliseconds $script:IdlePollIntervalMilliseconds
            } else {
                $consecutiveCrashCount++
            }
            continue
        }
        $exitFourWarningLogged = $false

        # 260718-epo: record the exit outcome for the dashboard's Finished-state
        # detection and FEAT-C's auto-pickup BEFORE branching on Action -- every
        # terminal path (StayDown OR Relaunch/crash) writes state/session.json exactly
        # once per pusher exit. Guarded in its own try/catch (mirrors
        # Publish-PusherStats's contract, 05-06): a session-state write is a
        # nice-to-have and must never take down the process that owns crash restart.
        if (-not [string]::IsNullOrEmpty($SessionStateFilePath)) {
            try {
                if ($decision.ExitReasonToken -eq 'clean-end-of-service') {
                    # Resolve the just-finished recording file (guarded -- a $null
                    # folder/glob or a Get-ChildItem throw degrades to "no finished
                    # file recorded", never crashes the supervisor).
                    $finishedRecordingFile = $null
                    if (-not [string]::IsNullOrEmpty($RecordingFolderPath) -and -not [string]::IsNullOrEmpty($RecordingFilenameGlob)) {
                        try {
                            $finishedRecordingFile = Get-NewestMatchingRecordingFile -RecordingFolderPath $RecordingFolderPath -RecordingFilenameGlob $RecordingFilenameGlob
                        } catch {
                            Write-Log -Level Warning -Message "Could not resolve the just-finished recording file for session state -- recording it as unknown: $($_.Exception.Message)"
                        }
                    }
                    $finishedRecordingFilePath = if ($finishedRecordingFile) { $finishedRecordingFile.FullName } else { $null }
                    $finishedRecordingLastWriteUtc = if ($finishedRecordingFile) { $finishedRecordingFile.LastWriteTimeUtc } else { $null }

                    Save-SessionState -SessionStateFilePath $SessionStateFilePath -LastExitReason $decision.ExitReasonToken `
                        -LastExitEpochSeconds (Get-MonotonicSeconds) -FinishedRecordingFilePath $finishedRecordingFilePath `
                        -FinishedRecordingLastWriteUtc $finishedRecordingLastWriteUtc -NewRecordingDetectedFilePath $null
                } else {
                    # config-fail (StayDown) and crash (Relaunch) both record the token
                    # with NO finished file -- a "Finished" screen is only ever earned
                    # by a genuine clean end-of-service (Dashboard.psm1's own gate).
                    Save-SessionState -SessionStateFilePath $SessionStateFilePath -LastExitReason $decision.ExitReasonToken `
                        -LastExitEpochSeconds (Get-MonotonicSeconds) -FinishedRecordingFilePath $null `
                        -FinishedRecordingLastWriteUtc $null -NewRecordingDetectedFilePath $null
                }
            } catch {
                Write-Log -Level Warning -Message "Session state write failed after pusher exit -- the dashboard's Finished screen/auto-pickup may lag this tick, streaming is unaffected: $($_.Exception.Message)"
            }
        }

        if ($decision.Action -eq 'StayDown') {
            Write-Log -Level Info -Message "Pusher exited $pusherExitCode -- $($decision.Reason)"
            # Setting the flag, not merely skipping the relaunch: the drained .ts file
            # is still on disk, so a later supervisor restart that found desired still
            # 'streaming' would re-send the resume margin as duplicate bytes.
            try {
                Set-PusherDesiredState -ControlFilePath $ControlFilePath -DesiredState 'stopped'
            } catch {
                # A throw here used to end the supervisor with exit 1 and no pusher
                # relaunched until the next watchdog. Hold instead and retry every tick.
                Write-Log -Level Error -Message "Could not set the control flag back to 'stopped' after the pusher stayed down -- no pusher will be relaunched; the write is retried every second until it succeeds. ($($_.Exception.Message))"
                $stayDownFlagWritePending = $true
            }
            $consecutiveCrashCount = 0
            continue
        }

        # A crash NEVER touches the flag (a crash is not an operator stop), so the loop
        # simply records it and goes round: the next tick re-reads the flag and, if it
        # still says streaming, waits out the backoff and relaunches above.
        #
        # This line reports the exit and NOTHING about what comes next -- $decision.Reason
        # is deliberately fact-only. After a cut, this is the last thing the log says
        # about the pusher, and it must still be true when read on its own.
        Write-Log -Level Error -Message "Pusher exited $pusherExitCode -- $($decision.Reason)"
        $consecutiveCrashCount++
    }

    return 0
    } finally {
        # A supervisor shutdown (MaxTicks exhausted in tests; never in production --
        # this loop is boot-to-shutdown) must not leak the dashboard's bound port,
        # or the very next start would greet the operator with exactly the
        # port-conflict error Start-DashboardListener exists to make readable.
        # Stop-DashboardHostHandle guards each release call individually.
        Stop-DashboardHostHandle -DashboardHandle $dashboardHostState.Handle

        # Same cleanup discipline for the probe host -- it has no bound port to
        # leak (unlike the dashboard's HttpListener), but its scheduler loop
        # runs Start-Sleep between cycles and must not keep spinning in the
        # background after the supervisor itself has shut down. Every call
        # guarded individually, same reasoning as the dashboard cleanup above:
        # PowerShell.Stop()/Dispose() are not guaranteed to exist on a test
        # double standing in for the real runspace handle.
        if ($probeHostHandle) {
            try { $probeHostHandle.PowerShell.Stop() } catch { }
            try { $probeHostHandle.PowerShell.Dispose() } catch { }
        }
    }
}

function Format-SupervisorTerminationMessage {
    <#
    .SYNOPSIS
    Pure: the one-line last-gasp text for a supervisor that is dying on an unhandled
    exception -- pid, exception type and message, and the first three stack lines.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $stackLines = @(([string] $ErrorRecord.ScriptStackTrace) -split "`r?`n" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -First 3 |
        ForEach-Object { $_.Trim() })
    $stackText = $stackLines -join ' <- '
    return "Supervisor terminating on unhandled exception (pid $PID): $($ErrorRecord.Exception.GetType().FullName): $($ErrorRecord.Exception.Message) | $stackText"
}

function Write-SupervisorLastGasp {
    <#
    .SYNOPSIS
    Records why the supervisor is dying: one Error line in the normal log AND, always, one
    line in state/logs/supervisor-last-gasp.log. The file is unconditional because
    Write-Log swallows its own log-file I/O failures (it cannot throw), so a try/catch
    fallback would never fire exactly when the failure being reported IS a log-write
    failure; the separate file is the copy that survives that. Never throws: this runs
    while the process is already going down, and a failure here must not hide the exit
    code or leave the single-instance mutex held.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ScriptRoot,
        [Parameter(Mandatory)] [string] $Message
    )

    try { Write-Log -Level Error -Message $Message } catch { }

    try {
        $lastGaspLogPath = Join-Path $ScriptRoot $script:SupervisorLastGaspLogRelativePath
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $lastGaspLogPath)) | Out-Null
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        [System.IO.File]::AppendAllText($lastGaspLogPath, "[$timestamp] [Error] $Message$([Environment]::NewLine)")
    } catch { }
}

function Invoke-SupervisorEntryPoint {
    <#
    .SYNOPSIS
    The script's process edge, minus the `exit`: takes the single-instance mutex FIRST,
    then reads config and runs Invoke-Supervisor. Returns the exit code for the bottom
    guard to hand to `exit`.

    WHY: on 2026-10-04 two supervisors ran side by side, each with its own tick loop and
    pusher. They were launched by two DIFFERENT scheduled tasks (the hand-made
    GaplessSupervisor and the installer's legacy SYSTEM task, retired 2026-10-18);
    MultipleInstances=IgnoreNew is per task and cannot see another task, so it worked as
    designed. On 2026-09-13 the same split put two pushers on the single-accept ingest and
    about 1 h 47 min of old content went to YouTube. With OBS recording, two pushers would
    push the same file at the same time and break the byte-order guarantee. This mutex is
    the cross-task guard. The losing instance waits up to SingleInstanceWaitSeconds (a
    predecessor that is shutting down gets time to let go), logs ONE line naming itself,
    and returns 0 without reading config or starting anything -- no dashboard, probe host,
    tick loop or pusher. Exit code 0 on purpose: a duplicate launch that correctly stood
    down is not a failure. (install.ps1's RestartCount does not fire on an action's
    non-zero exit anyway -- see its New-AlwaysOnTaskSettingSet probe note.)

    The mutex lives HERE and never inside Invoke-Supervisor, which Pester calls many times
    in one process. It is held in script scope for the life of the process, so garbage
    collection can never close it, and released in `finally` on this (the main) thread.
    A process kill skips the release; the mutex is then abandoned, which the next start
    counts as acquired.

    A supervisor never dies silently (261018). An unhandled exception is caught here,
    written as exactly one Error last-gasp line plus one line in
    state/logs/supervisor-last-gasp.log (always, because the log itself may be what
    failed), followed by a "Supervisor exiting (pid=... code=...)"
    line, exit code 1 and a released mutex. The exception is never rethrown out of this
    function.

    .OUTPUTS
    Int: the exit code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $ScriptRoot,
        [string] $SingleInstanceMutexName = (Get-SupervisorSingleInstanceMutexName -ScriptRoot $ScriptRoot),
        [int] $SingleInstanceWaitSeconds = $script:SupervisorSingleInstanceWaitSeconds
    )

    Set-LogDirectory -Path (Join-Path $ScriptRoot 'state/logs')

    $script:SupervisorSingleInstanceMutex = Enter-SupervisorSingleInstance -MutexName $SingleInstanceMutexName -WaitSeconds $SingleInstanceWaitSeconds
    if ($null -eq $script:SupervisorSingleInstanceMutex) {
        Write-Log -Level Warning -Message "Another supervisor instance is already running for this install ('$ScriptRoot') -- this instance exits without starting anything (no tick loop, dashboard, probe host or pusher). ($(Get-ProcessIdentityLogText))"
        return 0
    }

    $exitCode = 1
    try {
        # DASHBOARD_PORT (D-24) flows from .env through Config.psm1's schema (Default =
        # 8787) to the listener prefix -- named here, not a bare literal, so a church
        # with a port conflict can move it without editing code. If the config read
        # itself throws, the supervisor must still start (Phase 4's whole point) --
        # the dashboard degrades to disabled (0) for this run; pusher.ps1 owns its own
        # deployment-critical config validation (Test-PusherConfig, D-08) and that
        # contract does not belong here.
        $dashboardPort = 0
        $recordingFolderPath = $null
        $recordingFilenameGlob = $null
        $stateFilePath = $null
        $autoPickupEnabled = $false
        try {
            $config = Read-PusherConfig -Path (Join-Path $ScriptRoot '.env')
            $config = Resolve-PusherConfigPaths -Config $config -ScriptRoot $ScriptRoot
            $dashboardPort = $config.DashboardPort
            # 260718-epo: same resolved config, three more values threaded into
            # Invoke-AutoPickupTick -- a config-read failure below leaves all four at
            # their inert defaults (dashboard disabled, auto-pickup a no-op), never
            # blocking the supervisor itself from starting (D-03's own precedent).
            $recordingFolderPath = $config.RecordingFolderPath
            $recordingFilenameGlob = $config.RecordingFilenameGlob
            $stateFilePath = $config.StateFilePath
            $autoPickupEnabled = $config.AutoPickupEnabled
        } catch {
            Write-Log -Level Error -Message "Failed to read .env for DASHBOARD_PORT/AUTO_PICKUP -- the dashboard is disabled and auto-pickup stays inert for this run, but the supervisor still starts and streaming is unaffected. ($($_.Exception.Message))"
        }
        # state/session.json (260718-epo): a fixed script-root-relative location, like
        # state/stats.json and state/control.json -- never .env-configurable (D-06 parity).
        $sessionStateFilePath = Join-Path $ScriptRoot 'state/session.json'

        $exitCode = Invoke-Supervisor `
            -ControlFilePath (Get-PusherControlFilePath -ScriptRoot $ScriptRoot) `
            -ScriptRoot $ScriptRoot `
            -DashboardPort $dashboardPort `
            -RecordingFolderPath $recordingFolderPath `
            -RecordingFilenameGlob $recordingFilenameGlob `
            -StateFilePath $stateFilePath `
            -SessionStateFilePath $sessionStateFilePath `
            -AutoPickupEnabled $autoPickupEnabled
    } catch {
        $exitCode = 1
        try {
            Write-SupervisorLastGasp -ScriptRoot $ScriptRoot -Message (Format-SupervisorTerminationMessage -ErrorRecord $_)
        } catch { }
    } finally {
        try { Write-Log -Level Info -Message "Supervisor exiting (pid=$PID code=$exitCode)" } catch { }
        Exit-SupervisorSingleInstance -Mutex $script:SupervisorSingleInstanceMutex
        $script:SupervisorSingleInstanceMutex = $null
    }

    return $exitCode
}

# Only run the real loop when this script is invoked directly -- when dot-sourced
# (tests/Supervisor.Tests.ps1's `. $script:SupervisorScriptPath`), every function
# above is defined and mockable, but nothing runs, blocks, or exits. This guard is
# the supervisor's single process edge -- the one place `exit` belongs (Invoke-
# Supervisor itself returns its exit code so the loop stays testable), exactly as
# install.ps1's bottom guard does. The single-instance mutex is taken first, inside
# Invoke-SupervisorEntryPoint.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-SupervisorEntryPoint -ScriptRoot $PSScriptRoot)
}

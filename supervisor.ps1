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

$script:IdlePollIntervalMilliseconds = 1000

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
    PSCustomObject: Action ('StayDown' or 'Relaunch'), Reason (string), ExitReasonToken
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

    return [pscustomobject]@{
        Action          = 'Relaunch'
        Reason          = "unexpected exit code $ExitCode -- the pusher crashed rather than finishing or rejecting its config."
        ExitReasonToken = 'crash'
    }
}

function Start-PusherProcess {
    <#
    .SYNOPSIS
    Runs pusher.ps1 to completion in its own pwsh process and returns its exit code.
    Isolated into its own function purely as the testability seam: Pester mocks this
    to return an exit code directly, so every branch of Invoke-Supervisor can be
    driven without spawning a real pusher, a real ffmpeg, or a real SRT connection.

    The child pwsh gets the same Session-0 hardening install.ps1 applies to the task
    itself (PITFALLS.md Pitfall 10): an absolute pwsh.exe path, explicit
    -ExecutionPolicy Bypass -NoProfile, and an explicit WorkingDirectory -- this
    supervisor runs as SYSTEM with CWD = %windir%\system32 and cannot assume it
    inherits an execution policy, a PATH, or a sane working directory.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $ScriptRoot
    )

    $pusherScriptPath = Join-Path $ScriptRoot 'pusher.ps1'
    $pwshPath = (Get-Command -Name 'pwsh.exe' -ErrorAction Stop).Source

    # -PassThru without -Wait, then an explicit WaitForExit(): Start-Process -Wait
    # does not reliably populate ExitCode on the returned object, and the exit code
    # is the entire point of this call.
    $pusherProcess = Start-Process -FilePath $pwshPath `
        -ArgumentList @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', $pusherScriptPath) `
        -WorkingDirectory $ScriptRoot -NoNewWindow -PassThru
    $pusherProcess.WaitForExit()
    return $pusherProcess.ExitCode
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
    Invoke-Supervisor's tick loop does not tick while a pusher is streaming (blocked
    inside Start-PusherProcess's own WaitForExit()), which is exactly the window the
    dashboard matters most, so the listener's accept loop needs its OWN execution
    context. The listener object itself is created and Start()ed on THIS thread
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
    Error naming the port and DASHBOARD_PORT, and returns $null.

    A fresh runspace does not inherit this process's already-imported modules or
    Logging's configured directory (D-15's Session-0 lesson, again) -- the script
    block below imports everything Invoke-DashboardListenerLoop's call chain needs
    and re-points Logging at the same directory this supervisor process uses, before
    the accept loop starts. Every path is resolved from the -ScriptRoot parameter,
    never from this process's own script-root variable or its current directory --
    this supervisor runs as SYSTEM with CWD = %windir%\system32 and a Scheduled Task
    launch cannot be trusted to inherit a sane working directory (PITFALLS.md
    Pitfall 10).

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
        [Parameter(Mandatory)] [string] $ControlFilePath
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
        Write-Log -Level Error -Message "Dashboard host failed to start on port $DashboardPort -- check DASHBOARD_PORT in .env if another process already owns this port. The pusher and supervisor are unaffected; only the dashboard is unavailable this run. ($($_.Exception.Message))"
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
    supervisor runs as SYSTEM with CWD = %windir%\system32 and a Scheduled
    Task launch cannot be trusted to inherit a sane working directory
    (PITFALLS.md Pitfall 10).

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
        [bool] $AutoPickupEnabled = $false
    )

    Write-Log -Level Info -Message "Supervisor starting (idle until an operator starts streaming) -- control flag '$ControlFilePath', script root '$ScriptRoot'"

    $consecutiveCrashCount = 0
    $lastLoggedDesiredState = $null
    $dashboardHandle = $null
    $dashboardHostFaultLogged = $false
    $probeHostHandle = $null
    $probeHostFaultLogged = $false

    try {
    # DashboardPort 0 (the default) is genuinely inert -- no listener is ever
    # started, so every pre-existing caller of Invoke-Supervisor that never passes
    # this parameter keeps the exact pre-05-09 behavior. Started ONCE, before the
    # tick loop begins, not per-tick (05-01's HOST DECISION: the loop does not tick
    # while a pusher is streaming, so the dashboard needs its own execution context
    # regardless of where in the loop this call sits).
    if ($DashboardPort -ne 0) {
        # Defense in depth (D-03): Start-DashboardHost's own body already never
        # throws by contract, but the process that owns crash restart must survive
        # a dashboard failure even if that contract is ever broken by a future edit
        # -- so this call site guards itself too, rather than trusting the callee
        # alone.
        try {
            $dashboardHandle = Start-DashboardHost -ScriptRoot $ScriptRoot -DashboardPort $DashboardPort -ControlFilePath $ControlFilePath
        } catch {
            Write-Log -Level Error -Message "Dashboard host start raised an unexpected exception -- the dashboard is disabled for this run, but supervision and streaming continue unaffected. ($($_.Exception.Message))"
            $dashboardHandle = $null
        }
    }

    # Never gated on DashboardPort (MON-05/D-04): probes are a wholly separate
    # concern from the dashboard and must run even when the dashboard is
    # disabled -- the only gate is each probe's own .env enable flag (D-03),
    # so a probe host with zero enabled probes still starts, cheaply, and is
    # the MON-04 baseline. Started ONCE, before the tick loop, not per-tick
    # (mirrors the dashboard's own start-once placement immediately above,
    # for the identical reason: the loop does not tick while a pusher is
    # streaming, so the probe host needs its own execution context
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

        # Dashboard fault check runs on EVERY tick regardless of desired state
        # (D-03/05-01's HOST DECISION) -- placed BEFORE the idle branch's `continue`
        # immediately below, because idle is most of the week and a check placed
        # after that continue would never run while idle. Logged once per fault via
        # a flag, mirroring $lastLoggedDesiredState's transition-only convention and
        # for the identical reason (SVC-03/D-14): this loop ticks once a second for
        # the whole idle week between services. No restart is attempted here --
        # a listener whose port may be permanently taken is a log-flood risk to
        # retry automatically, and the recovery (a supervisor restart) is already
        # available to the operator; this is a deliberate omission, not an oversight.
        if ($dashboardHandle -and -not $dashboardHostFaultLogged -and (Test-DashboardHostFaulted -DashboardHandle $dashboardHandle)) {
            Write-Log -Level Error -Message 'Dashboard host has faulted or stopped -- the dashboard is unavailable, but supervision and streaming continue unaffected. Restart the supervisor to recover the dashboard.'
            $dashboardHostFaultLogged = $true
        }

        # Probe host fault check -- twin of the dashboard fault check immediately
        # above, same placement (BEFORE the idle branch's `continue` below, same
        # reason: idle is most of the week and a check placed after that continue
        # would never run while idle) and same "log once per fault via a flag,
        # never auto-restart" convention (MON-05/D-04: a faulted host is a
        # log-flood risk to retry automatically, and the recovery -- a supervisor
        # restart -- is already available to the operator).
        if ($probeHostHandle -and -not $probeHostFaultLogged -and (Test-ProbeHostFaulted -ProbeHostHandle $probeHostHandle)) {
            Write-Log -Level Error -Message 'Probe host has faulted or stopped -- probes are unavailable, but supervision and streaming continue unaffected. Restart the supervisor to recover probes.'
            $probeHostFaultLogged = $true
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

        $pusherExitCode = Start-PusherProcess -ScriptRoot $ScriptRoot
        $decision = Get-SupervisorExitDecision -ExitCode $pusherExitCode

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
            Set-PusherDesiredState -ControlFilePath $ControlFilePath -DesiredState 'stopped'
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
        # Every call here is guarded individually: Stop-DashboardListener's own
        # contract is to never throw, but the parameter bind itself (a $null
        # Listener on a fake/mocked handle in tests) can raise before that contract
        # ever applies, and PowerShell.Stop()/Dispose() are not guaranteed to exist
        # on a test double standing in for the real runspace handle.
        if ($dashboardHandle) {
            try { Stop-DashboardListener -Listener $dashboardHandle.Listener } catch { }
            try { $dashboardHandle.PowerShell.Stop() } catch { }
            try { $dashboardHandle.PowerShell.Dispose() } catch { }
        }

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

# Only run the real loop when this script is invoked directly -- when dot-sourced
# (tests/Supervisor.Tests.ps1's `. $script:SupervisorScriptPath`), every function
# above is defined and mockable, but nothing runs, blocks, or exits. This guard is
# the supervisor's single process edge -- the one place `exit` belongs (Invoke-
# Supervisor itself returns its exit code so the loop stays testable), exactly as
# install.ps1's bottom guard does.
if ($MyInvocation.InvocationName -ne '.') {
    Set-LogDirectory -Path (Join-Path $PSScriptRoot 'state/logs')

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
        $config = Read-PusherConfig -Path (Join-Path $PSScriptRoot '.env')
        $config = Resolve-PusherConfigPaths -Config $config -ScriptRoot $PSScriptRoot
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
    $sessionStateFilePath = Join-Path $PSScriptRoot 'state/session.json'

    exit (Invoke-Supervisor `
        -ControlFilePath (Get-PusherControlFilePath -ScriptRoot $PSScriptRoot) `
        -ScriptRoot $PSScriptRoot `
        -DashboardPort $dashboardPort `
        -RecordingFolderPath $recordingFolderPath `
        -RecordingFilenameGlob $recordingFilenameGlob `
        -StateFilePath $stateFilePath `
        -SessionStateFilePath $sessionStateFilePath `
        -AutoPickupEnabled $autoPickupEnabled)
}

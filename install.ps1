<#
.SYNOPSIS
Idempotent, elevation-aware installer for the Gapless SRT Pusher (SVC-01, SVC-02).

Verifies prerequisites (elevation, PowerShell 7, ffmpeg with libsrt support, a usable
operator account), copies `.env.example` -> `.env` on first run only (never overwrites
an operator-edited `.env`), and registers exactly ONE supervisor Scheduled Task,
'GaplessSupervisor': supervisor.ps1 run as the operator account (the account that ran
this elevated installer, or -OperatorUserName) under S4U (runs at boot before anyone
logs on, no stored password), RunLevel Limited, a boot trigger plus a daily 04:05
watchdog trigger that repeats every 5 minutes (a dead supervisor is relaunched within 5
minutes, a running one is never touched), no execution time limit, MultipleInstances
IgnoreNew. The supervisor
comes up IDLE and streams nothing until an operator explicitly starts it, and it owns
crash restart (the task settings do NOT restart the action on a non-zero exit; see
New-AlwaysOnTaskSettingSet). Only AFTER that registration succeeded, the legacy
'GaplessSrtPusher' SYSTEM task of older installs is retired
(Remove-LegacySupervisorScheduledTask): unregistered, or only disabled when it is
running, so a live stream is never touched.
All Session-0 hardening (PITFALLS.md Pitfall 10) is baked in: an absolute `pwsh.exe`
path, explicit `-ExecutionPolicy Bypass -NoProfile`, and an explicit WorkingDirectory =
script root -- a Scheduled Task launches with CWD = %windir%\system32 and cannot
be assumed to inherit the developer's own execution policy or PATH.

Functions are defined at top level (not wrapped in a module) so
tests/Install.Tests.ps1 can dot-source this file and Mock Get-Command /
Get-ScheduledTask / Register-ScheduledTask / Unregister-ScheduledTask /
Disable-ScheduledTask / Test-IsElevatedProcess / Get-OperatorAccountProblem /
Get-FfmpegProtocolsOutput without ever registering a real Scheduled Task --
real registration needs elevation and a real Windows box, and the real
reboot/Session-0 verification is deferred manual UAT (see 04-04-PLAN.md
user_setup / verification). Invoke-Install (the main flow) only runs when
this script is executed directly, never when dot-sourced -- see the guard at
the bottom of this file.

Exit codes (this installer's own contract, independent of pusher.ps1's D-12
runtime exit-code contract): 0 = install succeeded, 1 = one or more
prerequisites failed (nothing was registered -- never a half-applied install,
T-04-10), 3 = the new task IS registered but the legacy 'GaplessSrtPusher' task is
still running a supervisor (it was only disabled): action required -- reboot, or end
that supervisor in a no-stream window, then re-run install.ps1 to delete the task.
#>

param(
    # Opt-in tunnel autostart registration (AO-01/D-09, 14.5-06) -- registers
    # the ssh -L tunnel Scheduled Task + persists the NIC2 VPS route. Never
    # fires as a side effect of a bare `install.ps1` invocation; see
    # Invoke-TunnelRegistration below for why this is a separate opt-in flow.
    [switch] $RegisterTunnel,

    # Account the supervisor task runs as. Defaults to the account running this
    # elevated installer and is never hardcoded (D-09); pass it explicitly when the
    # installer is elevated under a different account than the operator's.
    [string] $OperatorUserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ScheduledTasks -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'lib/Logging.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Config.psm1') -Force

# Fixed TaskName (idempotency key, SVC-02): Register-ScheduledTask -Force always
# targets this exact name, so re-running install.ps1 updates the same task in
# place rather than creating a duplicate.
$script:TaskName = 'GaplessSupervisor'
# Task names earlier installs registered for the same supervisor. Retired after a
# successful registration: a second task launching supervisor.ps1 at boot was the
# real second launcher behind the 2026-09-13 and 2026-10-04 incidents.
$script:LegacySupervisorTaskNames = @('GaplessSrtPusher')
$script:SupervisorWatchdogTimeOfDay = '04:05'
# The supervisor's daily trigger repeats this often, so a dead supervisor is back within
# 5 minutes instead of up to 24 hours. Only the supervisor task repeats (the tunnel
# task's watchdog stays daily). Depends on the pusher single-instance guard (exit 4)
# and must never ship without it.
$script:SupervisorWatchdogRepetitionInterval = New-TimeSpan -Minutes 5
$script:TunnelWatchdogTimeOfDay = '04:00'
$script:LocalSystemSid = 'S-1-5-18'
# Well-known principals that are not a person: LocalService (19), NetworkService (20), and
# the BUILTIN (32), service (80) and virtual-account (90) groups. SYSTEM (18) is checked
# first with its own wording.
$script:NonUserPrincipalSidPattern = '^S-1-5-(18|19|20)$|^S-1-5-(32|80|90)-'
$script:ExitCodeSuccess = 0
$script:ExitCodePrerequisiteFailure = 1
$script:ExitCodeLegacySupervisorStillRunning = 3

# Tunnel autostart (AO-01/D-09, 14.5-06): its own fixed TaskName, distinct from
# $script:TaskName above, so registering/updating the tunnel task can never
# collide with or overwrite the supervisor's own GaplessSupervisor task.
$script:TunnelTaskName = 'GaplessTcpRelayTunnel'
$script:TunnelHelperRelativePath = 'tools/bin/tcp-relay-tunnel.ps1'

function Test-IsElevatedProcess {
    <#
    .SYNOPSIS
    Returns whether the current process is running with Administrator rights.
    Extracted into its own function (rather than inlined in
    Test-InstallPrerequisites) purely so Pester can Mock this .NET-backed check
    without needing a real elevated/non-elevated process to test both branches
    (T-04-10).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FfmpegProtocolsOutput {
    <#
    .SYNOPSIS
    Runs `<FfmpegPath> -protocols` and returns its combined stdout+stderr as a
    single string. Extracted into its own function so Pester can Mock this
    external-process call rather than depending on a real ffmpeg binary being
    present wherever the test suite runs (CLAUDE.md's mandated
    `ffmpeg -protocols | findstr srt` check, D-11).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $FfmpegPath
    )

    return (& $FfmpegPath -protocols 2>&1 | Out-String)
}

function Get-OperatorAccountProblem {
    <#
    .SYNOPSIS
    Returns '' when the account the supervisor task will run as is usable, else a
    one-line problem description. Never throws: an account that cannot be
    translated to a SID, or that resolves to SYSTEM, is reported as a problem so
    Test-InstallPrerequisites can abort before anything is registered.
    SYSTEM is refused because the VPS probe SSH key is ACL'd to the operator only
    (docs/vps-probe-ssh-key-setup.md) and a SYSTEM-owned supervisor is invisible to
    the operator's non-elevated tools.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $OperatorUserName
    )

    if ([string]::IsNullOrWhiteSpace($OperatorUserName)) {
        return 'Operator account is blank -- pass -OperatorUserName <COMPUTER\user>'
    }

    try {
        $operatorSid = ([Security.Principal.NTAccount] $OperatorUserName).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch {
        return "Operator account '$OperatorUserName' cannot be resolved -- pass -OperatorUserName <COMPUTER\user>"
    }

    if ($operatorSid -eq $script:LocalSystemSid) {
        return "Operator account resolves to SYSTEM -- run install.ps1 elevated from the operator's own account (or pass -OperatorUserName): SYSTEM cannot use the operator's VPS probe SSH key and is invisible to non-elevated operator tools"
    }
    if ($operatorSid -match $script:NonUserPrincipalSidPattern) {
        return "Operator account '$OperatorUserName' is a service account or group, not a user -- pass -OperatorUserName <COMPUTER\user> for the person who operates the stream: a service principal cannot use the operator's VPS probe SSH key and is invisible to non-elevated operator tools"
    }
    return ''
}

function Test-InstallPrerequisites {
    <#
    .SYNOPSIS
    Checks elevation, PowerShell 7 (pwsh) presence, ffmpeg-with-SRT support, and
    that the operator account is usable (not SYSTEM, resolvable).
    Mirrors Test-PusherConfig's contract (lib/Config.psm1): returns a problems
    list -- empty means valid -- and NEVER throws or exits itself; the caller
    (Invoke-Install, Task 2) decides how loud to fail. Collects every problem
    rather than short-circuiting on the first one, so a single re-run of
    install.ps1 can report all blockers at once instead of trickling them out
    one fix at a time.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string] $OperatorUserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    )

    $problems = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-IsElevatedProcess)) {
        $problems.Add('Not running as Administrator -- re-run install.ps1 from an elevated (Administrator) PowerShell session before it can register the Scheduled Task (T-04-10)')
    }

    $pwshCommand = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    if (-not $pwshCommand) {
        $problems.Add('pwsh.exe (PowerShell 7) was not found on PATH -- install PowerShell 7 before running install.ps1 (the Scheduled Task action requires pwsh.exe, never powershell.exe)')
    }

    $ffmpegCommand = Get-Command -Name 'ffmpeg' -ErrorAction SilentlyContinue
    if (-not $ffmpegCommand) {
        $problems.Add('ffmpeg was not found on PATH -- install an ffmpeg build with libsrt support (e.g. gyan.dev "full" build) before running install.ps1')
    } else {
        $protocolsOutput = Get-FfmpegProtocolsOutput -FfmpegPath $ffmpegCommand.Source
        if ($protocolsOutput -notmatch 'srt') {
            $problems.Add("ffmpeg at '$($ffmpegCommand.Source)' does not report SRT protocol support (ffmpeg -protocols | findstr srt found nothing) -- install a libsrt-enabled ffmpeg build (CLAUDE.md-mandated check)")
        }
    }

    $operatorAccountProblem = Get-OperatorAccountProblem -OperatorUserName $OperatorUserName
    if ($operatorAccountProblem) {
        $problems.Add($operatorAccountProblem)
    }

    # Unary comma (,) prevents PowerShell's return/pipeline enumeration from
    # unwrapping the array -- WITHOUT it, a zero-problem (i.e. fully healthy)
    # machine returns an empty array that collapses to $null on assignment, and a
    # one-problem machine collapses to a bare scalar string. The caller's
    # `$problems.Count` then throws under Set-StrictMode -Version Latest, so the
    # installer crashed on exactly the machines where every prerequisite PASSED
    # and never registered the Scheduled Task (SVC-01/SVC-02). Identical to
    # Test-PusherConfig's return in lib/Config.psm1 -- both honour an
    # [OutputType([string[]])] promise that bare `return` silently breaks.
    return , $problems.ToArray()
}

function Initialize-PusherEnvFile {
    <#
    .SYNOPSIS
    First-run convenience copy: `.env.example` -> `.env`, ONLY when `.env` is
    absent. An existing `.env` (an operator's already-configured deployment) is
    never touched -- this must remain safe to call on every install.ps1 rerun
    (D-11 idempotency covers this too, not just the Scheduled Task).
    #>
    [CmdletBinding()]
    param(
        [string] $ScriptRoot = $PSScriptRoot
    )

    $envPath = Join-Path $ScriptRoot '.env'
    $envExamplePath = Join-Path $ScriptRoot '.env.example'

    if (Test-Path -LiteralPath $envPath) {
        Write-Log -Level Debug -Message ".env already exists at '$envPath' -- leaving the operator's existing config untouched (never overwrite)"
        return
    }
    if (-not (Test-Path -LiteralPath $envExamplePath)) {
        Write-Log -Level Warning -Message ".env.example not found at '$envExamplePath' -- skipping first-run .env copy"
        return
    }

    Copy-Item -LiteralPath $envExamplePath -Destination $envPath
    Write-Log -Level Info -Message "First-run: copied .env.example to '$envPath' -- edit .env for this church's deployment before the service starts (CFG-01)"
}

function ConvertTo-WallClockStartBoundary {
    <#
    .SYNOPSIS
    Builds a Task Scheduler StartBoundary string for <TimeOfDay> on <Today> with NO
    UTC offset. Pure and culture-invariant.
    Why no offset: Task Scheduler pins an offset-carrying StartBoundary to UTC, so a
    daily trigger created in summer time fires an hour early after the clock change
    (the GaplessSundayStart 2026-10-25 lesson). A boundary without an offset stays
    on the local wall clock.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $TimeOfDay,
        [datetime] $Today = (Get-Date).Date
    )

    $boundary = $Today.Date + [TimeSpan]::Parse($TimeOfDay)
    return $boundary.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
}

function New-AlwaysOnTaskTriggerSet {
    <#
    .SYNOPSIS
    The trigger pair every always-on task shares: a boot trigger plus a daily
    watchdog trigger at <WatchdogTimeOfDay> with an offset-free StartBoundary
    (see ConvertTo-WallClockStartBoundary). Under MultipleInstances IgnoreNew the
    daily trigger does nothing while the task is alive and relaunches it if it
    died. Returned via unary comma so the two-element array survives the pipeline.

    WatchdogRepetitionInterval (default zero = none): when greater than zero, the daily
    trigger repeats at that interval for one day, which is every minute of every day
    because the trigger itself fires daily. StopAtDurationEnd is forced to false and is
    never true: the cmdlet default is true for a finite duration, and a repetition that
    stops tasks at the end of its duration would make Task Scheduler kill a running
    supervisor.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $WatchdogTimeOfDay,
        [TimeSpan] $WatchdogRepetitionInterval = [TimeSpan]::Zero
    )

    $bootTrigger = New-ScheduledTaskTrigger -AtStartup
    $dailyWatchdogTrigger = New-ScheduledTaskTrigger -Daily -At $WatchdogTimeOfDay
    $dailyWatchdogTrigger.StartBoundary = ConvertTo-WallClockStartBoundary -TimeOfDay $WatchdogTimeOfDay
    if ($WatchdogRepetitionInterval -gt [TimeSpan]::Zero) {
        $repetitionSource = New-ScheduledTaskTrigger -Once -At '00:00' `
            -RepetitionInterval $WatchdogRepetitionInterval -RepetitionDuration (New-TimeSpan -Days 1)
        $dailyWatchdogTrigger.Repetition = $repetitionSource.Repetition
        # New-ScheduledTaskTrigger leaves StopAtDurationEnd TRUE on a repetition with a
        # finite duration (verified in memory, 2026-10-18). True would make Task Scheduler
        # stop the running supervisor when the repetition duration ends, so it is forced off.
        $dailyWatchdogTrigger.Repetition.StopAtDurationEnd = $false
    }
    return , @($bootTrigger, $dailyWatchdogTrigger)
}

function New-AlwaysOnTaskSettingSet {
    <#
    .SYNOPSIS
    The settings every always-on task shares.

    RestartCount/RestartInterval do NOT restart the action on a non-zero exit code.
    This was believed for the whole of Phase 4 and is false: Task Scheduler's
    RestartOnFailure fires only on ABNORMAL TASK termination (a task-engine
    failure), never when the action process merely exits non-zero. Proven by an
    isolated probe on the real box -- a task with these exact settings whose action
    was `pwsh -Command "exit 1"` left lastRun FROZEN and rerun False across 160s,
    zero relaunches. These settings are kept for the abnormal-termination case they
    genuinely do cover; PROCESS DEATH IS COVERED BY supervisor.ps1 (and, for the
    supervisor itself, by the daily watchdog trigger). Phase 2's in-session
    reconnect loop (RES D-02) still owns network outages -- distinct mechanisms,
    distinct failures, no overlap.

    MultipleInstances IgnoreNew is PER TASK: it cannot see another task. Two tasks
    each launching supervisor.ps1 therefore started two supervisors on 2026-09-11
    and 2026-10-04; the cross-task guard is the per-install single-instance mutex
    (lib/SupervisorSingleInstance.psm1), not this setting.

    ExecutionTimeLimit zero (PT0S): the Task Scheduler default of PT72H killed the
    tunnel task on 2026-08-02 and the legacy SYSTEM supervisor at about
    2026-10-07 14:01 (LastTaskResult 0x00041306). An always-on task must have no
    time limit. The battery flags keep it running when the box switches to a UPS.
    #>
    [CmdletBinding()]
    param()

    return New-ScheduledTaskSettingsSet `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
}

function New-RepositoryScriptTaskAction {
    <#
    .SYNOPSIS
    The Session-0-hardened action every task shares (PITFALLS.md Pitfall 10): the
    absolute pwsh.exe path, explicit `-ExecutionPolicy Bypass -NoProfile -File
    <absolute script>`, and WorkingDirectory = script root (a Scheduled Task
    launches with CWD = %windir%\system32).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ScriptRoot,
        [Parameter(Mandatory)] [string] $RelativeScriptPath
    )

    $pwshPath = (Get-Command -Name 'pwsh.exe' -ErrorAction Stop).Source
    $scriptPath = Join-Path $ScriptRoot $RelativeScriptPath

    return New-ScheduledTaskAction -Execute $pwshPath `
        -Argument "-ExecutionPolicy Bypass -NoProfile -File `"$scriptPath`"" `
        -WorkingDirectory $ScriptRoot
}

function Register-SupervisorScheduledTask {
    <#
    .SYNOPSIS
    Registers the single supervisor task, 'GaplessSupervisor': supervisor.ps1 run as
    the operator account under S4U (no stored password, runs at boot before anyone
    logs on), RunLevel Limited, boot trigger + daily 04:05 watchdog, no execution
    time limit (shapes: the New-AlwaysOn* helpers above).

    Why the operator account and not SYSTEM: the VPS probe SSH key is ACL'd to the
    operator only (docs/vps-probe-ssh-key-setup.md), and the task and its processes
    stay visible and manageable from the operator's non-elevated console.

    The daily trigger is a watchdog that repeats every 5 minutes for 1 day (and fires
    again the next day). IgnoreNew refuses every fire while the supervisor is alive
    (TaskScheduler event 322; no process, no log line), so a running supervisor is never
    touched; a dead one is back within 5 minutes instead of up to 24 h. The repetition
    never stops tasks at its end (StopAtDurationEnd is forced false). It depends on the
    pusher single-instance guard (pusher exit 4, supervisor Pusher-mutex probe): a
    relaunched supervisor must not start a second pusher next to an orphaned one. This
    repetition must never ship without that guard.

    Register-ScheduledTask -Force is the whole idempotency mechanism (SVC-02) --
    a rerun with an existing same-name task updates it in place, never
    duplicates and never throws (T-04-11).
    #>
    [CmdletBinding()]
    param(
        [string] $ScriptRoot = $PSScriptRoot,
        [Parameter(Mandatory)] [string] $OperatorUserName
    )

    # The task launches supervisor.ps1, NOT pusher.ps1 directly. The supervisor comes
    # up IDLE and streams nothing until an operator explicitly starts it (start.ps1 or
    # Phase 5's dashboard Start button) -- a church machine must never begin pushing to
    # a LIVE YouTube audience unattended just because it rebooted. The supervisor is
    # also what actually restarts a crashed pusher.
    $action = New-RepositoryScriptTaskAction -ScriptRoot $ScriptRoot -RelativeScriptPath 'supervisor.ps1'
    $triggers = New-AlwaysOnTaskTriggerSet -WatchdogTimeOfDay $script:SupervisorWatchdogTimeOfDay `
        -WatchdogRepetitionInterval $script:SupervisorWatchdogRepetitionInterval
    $settings = New-AlwaysOnTaskSettingSet
    $principal = New-ScheduledTaskPrincipal -UserId $OperatorUserName -LogonType S4U -RunLevel Limited

    $existingTask = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Log -Level Info -Message "Existing Scheduled Task '$script:TaskName' found -- updating in place (idempotent -Force overwrite, SVC-02)"
    } else {
        Write-Log -Level Info -Message "No existing Scheduled Task '$script:TaskName' found -- installing fresh"
    }

    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $triggers `
        -Settings $settings -Principal $principal -Force | Out-Null

    Write-Log -Level Info -Message "Scheduled Task '$script:TaskName' registered -- runs supervisor.ps1 as '$OperatorUserName' (S4U: no stored password, runs at boot before anyone logs on), boot trigger + daily $script:SupervisorWatchdogTimeOfDay watchdog repeating every 5 minutes (a dead supervisor is relaunched within 5 minutes; a running one is never touched), no execution time limit, MultipleInstances IgnoreNew (SVC-01/T-04-11)"
}

function Remove-LegacySupervisorScheduledTask {
    <#
    .SYNOPSIS
    Retires supervisor tasks registered by older installs ($script:LegacySupervisorTaskNames).
    Called only AFTER Register-SupervisorScheduledTask returned without throwing, so
    there are never zero supervisor tasks.

    Absent: skipped. Running: Disable-ScheduledTask only -- the running process is
    left alone (no stream kills) and the task is deleted by a later install.ps1 run,
    once that supervisor is gone (reboot, or ended in a no-stream window).
    Otherwise: Unregister-ScheduledTask. It never calls Stop-ScheduledTask.

    .OUTPUTS
    Bool: $true when at least one legacy task was left running (the caller must not
    report a clean install), else $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $anyLegacyTaskLeftRunning = $false
    foreach ($legacyTaskName in $script:LegacySupervisorTaskNames) {
        $legacyTask = Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
        if (-not $legacyTask) {
            continue
        }

        if ($legacyTask.State -eq 'Running') {
            Disable-ScheduledTask -TaskName $legacyTaskName | Out-Null
            $runDetailText = Get-LegacyTaskRunDetailText -ScheduledTask $legacyTask
            Write-Log -Level Warning -Message "Legacy Scheduled Task '$legacyTaskName' is still running a supervisor (possibly the only one) -- disabled so it never launches at boot again; the running process was left alone (no stream kills). $runDetailText Remedy: reboot (the disabled task will not launch again), or end that supervisor in a no-stream window, then re-run install.ps1 to delete the task."
            $anyLegacyTaskLeftRunning = $true
            continue
        }

        Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false
        Write-Log -Level Info -Message "Removed legacy Scheduled Task '$legacyTaskName' (duplicate SYSTEM supervisor launcher)"
    }
    return $anyLegacyTaskLeftRunning
}

function Get-LegacyTaskRunDetailText {
    <#
    .SYNOPSIS
    One sentence for the operator: when the running legacy task last started and when the
    Task Scheduler's own execution time limit would end it (last run + limit; a limit of
    zero means the scheduler never ends it). Never throws -- unreadable details degrade to
    "unknown", because this only decorates a warning.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $ScheduledTask
    )

    $lastRunText = 'unknown'
    $killDeadlineText = 'unknown'
    try {
        $lastRunTime = (Get-ScheduledTaskInfo -TaskName $ScheduledTask.TaskName -ErrorAction Stop).LastRunTime
        $lastRunText = $lastRunTime.ToString('yyyy-MM-dd HH:mm:ss')
        $executionTimeLimit = [System.Xml.XmlConvert]::ToTimeSpan([string] $ScheduledTask.Settings.ExecutionTimeLimit)
        $killDeadlineText = if ($executionTimeLimit -le [timespan]::Zero) {
            'none (no execution time limit)'
        } else {
            $lastRunTime.Add($executionTimeLimit).ToString('yyyy-MM-dd HH:mm:ss')
        }
    } catch {
        # Fall through with whatever was readable.
    }
    return "Last run: $lastRunText; Task Scheduler kill deadline: $killDeadlineText."
}

function Register-TunnelScheduledTask {
    <#
    .SYNOPSIS
    Registers tools/bin/tcp-relay-tunnel.ps1 (the ssh -L tunnel loop) as its own
    Scheduled Task so the tunnel survives a church-PC reboot/logout (AO-01, D-09).
    It shares the supervisor task's trigger/settings/action helpers (boot + daily
    04:00 watchdog, no execution time limit), so a -RegisterTunnel re-run can no
    longer bring back the 72 h kill (2026-08-02) the PT0S fix removed.

    It does NOT mirror the supervisor's principal: SYSTEM stays because the tunnel
    needs no operator-only key and must run regardless of who is logged on. SYSTEM
    needs no stored password and runs before any interactive logon, which is the
    whole point of "always-on".

    Register-ScheduledTask -Force is the idempotency mechanism (AO-01
    adjacency edge, mirrors SVC-02): a re-run with an existing same-name task
    updates it in place, never a duplicate, never an error.
    #>
    [CmdletBinding()]
    param(
        [string] $ScriptRoot = $PSScriptRoot
    )

    $scriptPath = Join-Path $ScriptRoot $script:TunnelHelperRelativePath

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-Log -Level Warning -Message "Register-TunnelScheduledTask: tunnel helper script not found at '$scriptPath' -- no Scheduled Task was registered. This deployment does not ship the ssh-forwarding tunnel helper, which is only needed when the relay is not directly reachable from the OBS machine; a directly-reachable relay needs no tunnel, so this skip is expected and harmless."
        return
    }

    $action = New-RepositoryScriptTaskAction -ScriptRoot $ScriptRoot -RelativeScriptPath $script:TunnelHelperRelativePath
    $triggers = New-AlwaysOnTaskTriggerSet -WatchdogTimeOfDay $script:TunnelWatchdogTimeOfDay
    $settings = New-AlwaysOnTaskSettingSet

    $principal = New-ScheduledTaskPrincipal `
        -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    $existingTask = Get-ScheduledTask -TaskName $script:TunnelTaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Log -Level Info -Message "Existing Scheduled Task '$script:TunnelTaskName' found -- updating in place (idempotent -Force overwrite)"
    } else {
        Write-Log -Level Info -Message "No existing Scheduled Task '$script:TunnelTaskName' found -- installing fresh"
    }

    Register-ScheduledTask -TaskName $script:TunnelTaskName -Action $action -Trigger $triggers `
        -Settings $settings -Principal $principal -Force | Out-Null

    Write-Log -Level Info -Message "Scheduled Task '$script:TunnelTaskName' registered -- runs tools/bin/tcp-relay-tunnel.ps1 at boot as SYSTEM/ServiceAccount, daily $script:TunnelWatchdogTimeOfDay watchdog, no execution time limit"
}

function Get-VpsRouteConfiguration {
    <#
    .SYNOPSIS
    Reads VPS_ROUTE_PREFIX/VPS_ROUTE_NEXT_HOP from .env (lib/Config.psm1 schema) and
    returns them as DestinationPrefix/NextHop -- the mockable seam Set-VpsRoutePersistent
    calls first, so the Pester suite never has to touch the operator's real .env (the
    exact fixture-leak class 15-01 had to fix). ANY failure here (missing file,
    unreadable file, coercion failure) resolves to blank/blank rather than propagating,
    matching lib/NicTelemetry.psm1's and Read-LiveTunableOverrides' own never-throw
    edge-seam convention -- a route-config read failure must never crash the installer,
    it must simply be treated as "not configured" (Set-VpsRoutePersistent's own skip
    branch then logs the loud warning).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $EnvFilePath = (Join-Path $PSScriptRoot '.env')
    )

    try {
        $envConfig = Read-PusherConfig -Path $EnvFilePath
        return [pscustomobject]@{
            DestinationPrefix = [string] $envConfig.VpsRoutePrefix
            NextHop            = [string] $envConfig.VpsRouteNextHop
        }
    } catch {
        Write-Log -Level Warning -Message "Get-VpsRouteConfiguration: '$EnvFilePath' could not be read -- treating the persistent VPS route as unconfigured: $($_.Exception.Message)"
        return [pscustomobject]@{ DestinationPrefix = ''; NextHop = '' }
    }
}

function Find-RouteNextHopInterfaceIndex {
    <#
    .SYNOPSIS
    Finds the local network interface currently on-link with the configured route's
    next hop -- the ONLY interface the persistent-route step is ever allowed to touch.
    Scoped to the next hop's own /24 (derived from its first three octets) rather than
    any hardcoded subnet, so this works for whatever gateway an operator configures,
    while still refusing to guess: every other interface is never touched. Returns
    $null when the next hop does not parse into four dotted octets, and $null when no
    local interface holds an address on that /24 -- the caller must treat both cases
    identically and refuse to fall back to any other interface.
    #>
    [CmdletBinding()]
    [OutputType([Nullable[int]])]
    param(
        [Parameter(Mandatory)] [string] $NextHop
    )

    $nextHopOctets = $NextHop -split '\.'
    if ($nextHopOctets.Count -ne 4) {
        return $null
    }
    $onLinkMatchPattern = '{0}.{1}.{2}.*' -f $nextHopOctets[0], $nextHopOctets[1], $nextHopOctets[2]

    $onLinkAddress = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like $onLinkMatchPattern } |
        Select-Object -First 1

    if (-not $onLinkAddress) {
        return $null
    }
    return $onLinkAddress.InterfaceIndex
}

function ConvertTo-DottedSubnetMask {
    <#
    .SYNOPSIS
    Converts a CIDR prefix length (e.g. 32) to its dotted-decimal subnet mask
    (e.g. 255.255.255.255) -- needed because `route.exe add` (Add-PersistentNetRoute
    below) takes a mask, not a CIDR prefix length, unlike New-NetRoute's
    -DestinationPrefix.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [int] $PrefixLength
    )

    $maskBits = ('1' * $PrefixLength).PadRight(32, '0')
    $octets = for ($bitOffset = 0; $bitOffset -lt 32; $bitOffset += 8) {
        [Convert]::ToInt32($maskBits.Substring($bitOffset, 8), 2)
    }
    return ($octets -join '.')
}

function Add-PersistentNetRoute {
    <#
    .SYNOPSIS
    Thin wrapper around the classic `route.exe -p add` command, extracted into
    its own function purely so Pester can Mock this external-process call --
    mirrors this file's own established Get-FfmpegProtocolsOutput pattern.

    `New-NetRoute -PolicyStore PersistentStore` is deliberately NOT used here:
    live-run against the actual target church PC (14.5-06 Task 2) proved it
    fails outright with a native CIM error ("Invalid parameter PolicyStore
    PersistentStore", Windows System Error 87) on this machine's networking
    stack build, even under -WhatIf -- a genuine environment bug, not a
    parameter-value typo (Rule 1 fix). `route.exe -p add ... if <index>` was
    verified live to write into the SAME persistent-routes store Get-NetRoute
    -PolicyStore PersistentStore reads back from (round-tripped with a
    documentation-only TEST-NET-3 destination before touching the real VPS
    route), and its `if <index>` argument gives the same NIC-scoping guarantee
    -InterfaceIndex would have -- so this is a faithful, portable substitute,
    not a scope change.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $DestinationIp,
        [Parameter(Mandatory)] [string] $SubnetMask,
        [Parameter(Mandatory)] [string] $NextHop,
        [Parameter(Mandatory)] [int] $InterfaceIndex
    )

    route.exe -p add $DestinationIp mask $SubnetMask $NextHop if $InterfaceIndex | Out-Null
    return $LASTEXITCODE
}

function Test-VpsRoutePersistent {
    <#
    .SYNOPSIS
    Returns whether a persistent host route to the given destination prefix already
    exists in the PersistentStore (survives reboot) -- the check half of the
    check-then-add idempotency contract (a re-run when already persistent must be a
    no-op, not an error).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $DestinationPrefix
    )

    $persistentRoute = Get-NetRoute -DestinationPrefix $DestinationPrefix `
        -PolicyStore PersistentStore -ErrorAction SilentlyContinue
    return [bool]$persistentRoute
}

function Set-VpsRoutePersistent {
    <#
    .SYNOPSIS
    Idempotent (check-then-add): persists the operator-configured VPS_ROUTE_PREFIX ->
    VPS_ROUTE_NEXT_HOP host route (read via Get-VpsRouteConfiguration) so it survives
    reboot. Both keys default to blank (lib/Config.psm1) -- THE SAFETY BRANCH: when
    either is blank, this function logs a Warning naming BOTH env keys and the
    consequence in plain words, then returns WITHOUT throwing and WITHOUT writing any
    route. It must never claim a route was persisted when none was. Once both keys
    are set, the route write is scoped to ONLY the interface
    Find-RouteNextHopInterfaceIndex resolves (the interface currently on-link with the
    configured next hop); every other interface is never touched, and this function
    refuses (throws) rather than guessing an interface when that interface cannot be
    identified. Writes via Add-PersistentNetRoute (route.exe -p add), not
    New-NetRoute -- see that function's own doc comment for why (live-proven Rule 1
    environment-bug fix, 14.5-06 Task 2).
    #>
    [CmdletBinding()]
    param()

    $routeConfiguration = Get-VpsRouteConfiguration

    if ([string]::IsNullOrWhiteSpace($routeConfiguration.DestinationPrefix) -or [string]::IsNullOrWhiteSpace($routeConfiguration.NextHop)) {
        Write-Log -Level Warning -Message 'VPS_ROUTE_PREFIX and/or VPS_ROUTE_NEXT_HOP is blank in .env -- skipping the persistent host route step. No persistent route to the relay was added, so it will NOT survive a reboot until both keys are set and install.ps1 -RegisterTunnel is re-run.'
        return
    }

    $destinationPrefix = $routeConfiguration.DestinationPrefix
    $nextHop = $routeConfiguration.NextHop

    if (Test-VpsRoutePersistent -DestinationPrefix $destinationPrefix) {
        Write-Log -Level Info -Message "Persistent route $destinationPrefix -> $nextHop already present -- no-op (idempotent)"
        return
    }

    $interfaceIndex = Find-RouteNextHopInterfaceIndex -NextHop $nextHop
    if (-not $interfaceIndex) {
        throw "Cannot find an interface on-link with next hop '$nextHop' to scope the persistent VPS route to -- refusing to guess an interface. Connect the network carrying that gateway before re-running install.ps1 -RegisterTunnel."
    }

    $destinationPrefixParts = $destinationPrefix -split '/'
    $destinationIp = $destinationPrefixParts[0]
    $subnetMask = ConvertTo-DottedSubnetMask -PrefixLength ([int] $destinationPrefixParts[1])

    $routeExitCode = Add-PersistentNetRoute -DestinationIp $destinationIp -SubnetMask $subnetMask `
        -NextHop $nextHop -InterfaceIndex $interfaceIndex

    if ($routeExitCode -ne 0) {
        throw "route.exe -p add failed with exit code $routeExitCode while persisting $destinationPrefix -> $nextHop on interface index $interfaceIndex"
    }

    Write-Log -Level Info -Message "Persisted route $destinationPrefix -> $nextHop on interface index $interfaceIndex -- survives reboot"
}

function Invoke-TunnelRegistration {
    <#
    .SYNOPSIS
    Applies the tunnel Scheduled Task registration + persistent NIC2 VPS
    route (AO-01/D-09, 14.5-06 Task 2) -- the live-apply surface for
    install.ps1 -RegisterTunnel. Deliberately NOT part of Invoke-Install's
    default flow: this touches the network path currently carrying the live
    escape tunnel, so it must only run after the plan's operator checkpoint
    approves applying in a confirmed no-stream window. Registration/
    route-persistence itself does not restart the currently-running tunnel
    process or interrupt a live stream -- it only writes Task Scheduler and
    routing-table state that takes effect on the NEXT boot.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    Write-Log -Level Info -Message 'Gapless TCP relay tunnel registration starting (AO-01/D-09)'

    if (-not (Test-IsElevatedProcess)) {
        Write-Log -Level Error -Message 'Not running as Administrator -- re-run install.ps1 -RegisterTunnel from an elevated (Administrator) PowerShell session. Nothing was registered or persisted.'
        return $script:ExitCodePrerequisiteFailure
    }

    $pwshCommand = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    if (-not $pwshCommand) {
        Write-Log -Level Error -Message 'pwsh.exe (PowerShell 7) was not found on PATH -- install PowerShell 7 before running install.ps1 -RegisterTunnel. Nothing was registered or persisted.'
        return $script:ExitCodePrerequisiteFailure
    }

    Register-TunnelScheduledTask -ScriptRoot $PSScriptRoot
    Set-VpsRoutePersistent

    Write-Log -Level Info -Message "Tunnel registration complete -- see the preceding log lines for whether the Scheduled Task '$script:TunnelTaskName' was registered or skipped, and whether a persistent VPS route was added or skipped (AO-01/D-09)."
    return $script:ExitCodeSuccess
}

function Invoke-Install {
    <#
    .SYNOPSIS
    Main install flow: validate prerequisites (bail loud+non-zero before touching
    anything if invalid, T-04-10), then first-run .env copy, then register the
    GaplessSupervisor Scheduled Task, and only then retire the legacy
    GaplessSrtPusher task (a registration that throws never reaches the removal,
    so there are never zero supervisor tasks). Never a half-applied install --
    registration only runs once every prerequisite problem is resolved.

    RETURNS this installer's exit code rather than calling `exit` itself: `exit`
    is a flow-control exception that tears down the whole host, so an
    exit-inside-the-flow made the main path impossible to drive from Pester --
    which is precisely why the crash this function used to have on the
    all-prerequisites-PASS path shipped unnoticed. The single `exit` now lives at
    the script's bottom guard, the one place that is genuinely a process edge
    (CLAUDE.md: side effects isolated at edges). Every logging path stays on the
    error/warning/host streams (lib/Logging.psm1), so nothing pollutes the
    returned exit code.

    Exit codes: 0 = installed; 1 = prerequisite failure (nothing registered); 3 = the new
    task is registered but a legacy supervisor task is still running and was only
    disabled (action required: reboot or end it in a no-stream window, then re-run).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string] $OperatorUserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    )

    Write-Log -Level Info -Message "Gapless SRT Pusher installer starting (script root '$PSScriptRoot')"

    # Plain assignment, deliberately NOT `@(Test-InstallPrerequisites)`: the
    # callee returns its array via unary comma, which emits the array as ONE
    # un-enumerated pipeline item. `@(...)` collects pipeline ITEMS, so wrapping
    # this call would build a 1-element array CONTAINING the empty array --
    # .Count = 1 on a healthy machine, inverting the check and reporting a blank
    # "Prerequisite check failed: " problem. The unary-comma return is the whole
    # fix; an @() wrapper here re-breaks it. (`@($problems)` on the resulting
    # VARIABLE is safe -- that enumerates the array -- which is exactly why the
    # `@($problems).Count | Should -Be 0` unit assertion stayed green while the
    # real installer crashed. Mirrors pusher.ps1:64 / Test-PusherConfig.)
    $problems = Test-InstallPrerequisites -OperatorUserName $OperatorUserName
    if ($problems.Count -gt 0) {
        foreach ($problem in $problems) {
            Write-Log -Level Error -Message "Prerequisite check failed: $problem"
        }
        Write-Log -Level Error -Message 'Install aborted -- fix the problem(s) above and re-run install.ps1. No Scheduled Task was registered.'
        return $script:ExitCodePrerequisiteFailure
    }

    Initialize-PusherEnvFile -ScriptRoot $PSScriptRoot
    Register-SupervisorScheduledTask -ScriptRoot $PSScriptRoot -OperatorUserName $OperatorUserName
    $legacyTaskLeftRunning = @(Remove-LegacySupervisorScheduledTask) -contains $true

    if ($legacyTaskLeftRunning) {
        Write-Log -Level Error -Message "Install incomplete -- action required. Scheduled Task '$script:TaskName' is registered as '$OperatorUserName', but the legacy supervisor task is still running a supervisor (it was only disabled, nothing was stopped). Reboot (the disabled task will not launch again), or end that supervisor in a no-stream window, then re-run install.ps1 to delete the legacy task. Exit code $script:ExitCodeLegacySupervisorStillRunning."
        return $script:ExitCodeLegacySupervisorStillRunning
    }

    Write-Log -Level Info -Message "Install complete. Scheduled Task '$script:TaskName' will start supervisor.ps1 at boot as '$OperatorUserName' (SVC-01)."
    Write-Log -Level Info -Message 'The supervisor comes up IDLE at boot -- it streams NOTHING until you start it. Run start.ps1 to begin a service and stop.ps1 to end it (Phase 5''s dashboard buttons write the same control flag, state/control.json).'
    Write-Log -Level Info -Message 'pusher.ps1 exit-code contract (D-12), enforced by supervisor.ps1: 0 = clean end-of-service (stays down, and the control flag is set back to stopped), 2 = config validation failure (stays down -- fix .env, then run start.ps1 again), any other non-zero = crash (the supervisor relaunches the pusher automatically with backoff; the recording file on disk is the buffer, so the stream catches back up).'
    return $script:ExitCodeSuccess
}

# Only run the real install/registration flow when this script is invoked
# directly -- when dot-sourced (tests/Install.Tests.ps1's
# `. $script:InstallScriptPath`), every function above is defined and
# mockable, but nothing executes or exits. This guard is the installer's
# single process edge -- the one place `exit` belongs (Invoke-Install and
# Invoke-TunnelRegistration both return their exit code so each flow stays
# testable). -RegisterTunnel routes to the separate opt-in tunnel-autostart
# flow (AO-01/D-09) instead of the default pusher install flow -- see the
# param block and Invoke-TunnelRegistration's own doc comment for why these
# are never combined into one invocation.
if ($MyInvocation.InvocationName -ne '.') {
    if ($RegisterTunnel) {
        exit (Invoke-TunnelRegistration)
    }
    exit (Invoke-Install -OperatorUserName $OperatorUserName)
}

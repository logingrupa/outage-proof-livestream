# SupervisorSingleInstance.psm1
# Sole owner of "only one supervisor runs per install". supervisor.ps1 takes the mutex
# this module manages at its script entry point, BEFORE the config read, the dashboard,
# the probe host, the tick loop or any pusher.
#
# WHY THIS EXISTS: on 2026-10-04, after an unclean reboot, two independent supervisors
# ran, each with its own tick loop and pusher. Two DIFFERENT scheduled tasks each
# launched supervisor.ps1 once (the hand-made GaplessSupervisor, and the installer's
# legacy SYSTEM task retired on 2026-10-18); MultipleInstances=IgnoreNew is per task and
# cannot see another task, so it worked as designed. Both pushers happened to wait at the
# START-STALE hold that time, so no byte was sent twice. On 2026-09-13 the same split put
# two pushers on the single-accept ingest, and they pushed conflicting byte ranges: about
# 1 h 47 min of old content reached YouTube. With OBS recording, two pushers would push
# the same file at the same time and break the byte-order guarantee the whole system
# rests on. The scheduler setting cannot be the only guard, so the process guards itself.
#
# WHY A PER-INSTALL Global\ NAME: the scheduled task runs in an S4U session and an
# operator may also start supervisor.ps1 interactively; a Local\ name would miss
# duplicates across sessions. The name is derived from the install's full path so that
# tools/test-portable-kit.ps1 (an isolated dry-run supervisor from another tree on the
# same machine) and a portable kit never block the production install, while two copies
# of the SAME install are always mutually exclusive.
#
# WHY A SHORT WAIT, NOT AN INSTANT FAIL: when an operator kills a supervisor and starts
# it again, or a previous instance is still shutting down, the new instance must not give
# up in the one moment the old one is about to release. A mutex abandoned by a holder
# that died counts as ACQUIRED. Together these make "zero supervisors after startup"
# impossible by construction in the normal restart flows.
#
# WHY A SECOND, 'PUSHER' ROLE (261018): a five-minute watchdog on the supervisor task
# relaunches a supervisor that died, and a supervisor that died mid-service can leave its
# pusher running. A new supervisor would then start a second pusher on the same recording
# and the same offset -- the 2026-09-13 replay. So the pusher takes its own per-install
# mutex (same hashing, 'Pusher' prefix) before touching the offset, the control flag, the
# recording or ffmpeg, and stands down with exit 4 when it cannot; the supervisor probes
# that mutex with Test-SingleInstanceMutexHeld before every launch. The Supervisor role
# keeps its original name, byte for byte.
#
# This module logs nothing and imports nothing: the caller (supervisor.ps1, pusher.ps1)
# owns the one log line for the losing path.
#
# Exports: Get-SupervisorSingleInstanceMutexName, Enter-SupervisorSingleInstance,
#          Exit-SupervisorSingleInstance, Open-ExistingSingleInstanceMutexHandle,
#          Test-SingleInstanceMutexHeld

Set-StrictMode -Version Latest

$script:MutexNamePrefix = 'Global\GaplessSrtPusher-Supervisor-'
$script:PusherMutexNamePrefix = 'Global\GaplessSrtPusher-Pusher-'
$script:MutexNameHashLength = 16
$script:CrossPrincipalRetryMilliseconds = 250

function Get-SupervisorSingleInstanceMutexName {
    <#
    .SYNOPSIS
    Pure: the Global\ mutex name for one install. The path is normalized (full path,
    trailing separators trimmed, lower-cased) and hashed with SHA-256, so the same
    install always maps to the same name regardless of case or trailing separator, and
    different installs map to different names. The name has no backslash after the
    Global\ prefix, which Windows would reject.

    Role 'Supervisor' (the default) yields the original name, byte for byte, so a rolling
    deploy never leaves an old and a new supervisor with different names. Role 'Pusher'
    yields the name the pusher takes at startup and the supervisor probes before a launch.

    .OUTPUTS
    String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ScriptRoot,
        [ValidateSet('Supervisor', 'Pusher')] [string] $Role = 'Supervisor'
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($ScriptRoot).TrimEnd('\', '/').ToLowerInvariant()
    $hashBytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($normalizedPath))
    $hashText = [Convert]::ToHexString($hashBytes).ToLowerInvariant().Substring(0, $script:MutexNameHashLength)
    $namePrefix = if ($Role -eq 'Pusher') { $script:PusherMutexNamePrefix } else { $script:MutexNamePrefix }
    return $namePrefix + $hashText
}

function New-SupervisorSingleInstanceMutexHandle {
    <#
    .SYNOPSIS
    Opens (creating if needed) the named mutex WITHOUT taking ownership. A separate
    function only so tests can simulate the cross-principal UnauthorizedAccessException
    (another account, for example SYSTEM versus the operator, already created the name)
    by mocking it with -ModuleName.
    #>
    [CmdletBinding()]
    [OutputType([System.Threading.Mutex])]
    param(
        [Parameter(Mandatory)] [string] $MutexName
    )

    return [System.Threading.Mutex]::new($false, $MutexName)
}

function Wait-SupervisorSingleInstanceMutex {
    <#
    .SYNOPSIS
    Waits up to TimeoutMilliseconds to own an already-opened mutex. Returns the owned
    mutex, or $null (after disposing the handle) when it stayed held by someone else or
    the wait failed. A mutex abandoned by a holder that died counts as acquired: .NET
    raises AbandonedMutexException but the calling thread owns the mutex at that point.
    #>
    [CmdletBinding()]
    [OutputType([System.Threading.Mutex])]
    param(
        [Parameter(Mandatory)] [System.Threading.Mutex] $Mutex,
        [Parameter(Mandatory)] [int] $TimeoutMilliseconds
    )

    try {
        if ($Mutex.WaitOne($TimeoutMilliseconds)) { return $Mutex }
        $Mutex.Dispose()
        return $null
    } catch [System.Threading.AbandonedMutexException] {
        return $Mutex
    } catch {
        $Mutex.Dispose()
        return $null
    }
}

function Enter-SupervisorSingleInstance {
    <#
    .SYNOPSIS
    Takes the single-instance mutex for this install, waiting up to WaitSeconds for a
    previous holder to let go. Returns the held Mutex, or $null when another instance
    keeps it. NEVER throws: every failure path ends in $null, and the caller logs the
    one line about another instance.

    The wait matters. When an operator kills a supervisor and starts it again, or a
    previous instance is still shutting down, an instant failure here would end with
    ZERO supervisors running. A mutex abandoned by a holder that died counts as
    acquired. An UnauthorizedAccessException means another principal (for example SYSTEM
    versus the operator's own account) created the name with an ACL that denies this
    account; it is retried until the deadline rather than failing at once.

    The returned mutex must be released by Exit-SupervisorSingleInstance on the SAME
    thread (a mutex is owned by a thread).

    .OUTPUTS
    System.Threading.Mutex, or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.Threading.Mutex])]
    param(
        [Parameter(Mandatory)] [string] $MutexName,
        [Parameter(Mandatory)] [int] $WaitSeconds
    )

    $deadlineMilliseconds = $WaitSeconds * 1000
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    do {
        try {
            $mutex = New-SupervisorSingleInstanceMutexHandle -MutexName $MutexName
        } catch [System.UnauthorizedAccessException] {
            Start-Sleep -Milliseconds $script:CrossPrincipalRetryMilliseconds
            continue
        } catch {
            return $null
        }

        $remainingMilliseconds = [Math]::Max(0, $deadlineMilliseconds - $stopwatch.ElapsedMilliseconds)
        return Wait-SupervisorSingleInstanceMutex -Mutex $mutex -TimeoutMilliseconds ([int] $remainingMilliseconds)
    } while ($stopwatch.ElapsedMilliseconds -lt $deadlineMilliseconds)

    return $null
}

function Exit-SupervisorSingleInstance {
    <#
    .SYNOPSIS
    Releases and disposes the mutex Enter-SupervisorSingleInstance returned. A $null
    mutex is a no-op. Never throws. Must run on the thread that owns the mutex -- the
    supervisor's entry point runs entirely on the main thread. A process kill skips this
    on purpose: the mutex is then abandoned, which the next start counts as acquired.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] $Mutex
    )

    if ($null -eq $Mutex) { return }

    try { $Mutex.ReleaseMutex() } catch { }
    try { $Mutex.Dispose() } catch { }
}

function Open-ExistingSingleInstanceMutexHandle {
    <#
    .SYNOPSIS
    Opens a named mutex ONLY if it already exists; never creates one. Returns the Mutex,
    or $null when the name does not exist. An UnauthorizedAccessException (another
    principal owns the object with an ACL that denies this account) propagates to the
    caller. A separate function only so tests can simulate that denial by mocking it with
    -ModuleName, like New-SupervisorSingleInstanceMutexHandle.
    #>
    [CmdletBinding()]
    [OutputType([System.Threading.Mutex])]
    param(
        [Parameter(Mandatory)] [string] $MutexName
    )

    $existingMutex = $null
    if ([System.Threading.Mutex]::TryOpenExisting($MutexName, [ref]$existingMutex)) { return $existingMutex }
    return $null
}

function Test-SingleInstanceMutexHeld {
    <#
    .SYNOPSIS
    Answers "does a live process hold this named mutex right now?" without keeping it
    and without creating it. NEVER throws. This is the supervisor's orphan-pusher probe:
    a watchdog can relaunch a supervisor whose pusher outlived it, and a second pusher on
    the same recording would replay old content to YouTube (2026-09-13).

    - Name does not exist: not held.
    - Free, or abandoned by a holder that died: not held (the probe takes it for an
      instant and releases it again).
    - Owned by a live process: held.
    - UnauthorizedAccessException: held. Another principal created the object, so
      somebody is alive on it.
    - Any other failure: not held. The pusher's own guard is the backstop, so a broken
      probe must not stop a stream from starting.

    The opened handle is always disposed, so the probe never keeps the kernel object
    alive past its real holder.

    .OUTPUTS
    Bool.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $MutexName
    )

    $openedMutex = $null
    try {
        $openedMutex = Open-ExistingSingleInstanceMutexHandle -MutexName $MutexName
        if ($null -eq $openedMutex) { return $false }

        try {
            if (-not $openedMutex.WaitOne(0)) { return $true }
        } catch [System.Threading.AbandonedMutexException] {
            # The probing thread owns an abandoned mutex at this point, same as a normal acquire.
        }
        $openedMutex.ReleaseMutex()
        return $false
    } catch [System.UnauthorizedAccessException] {
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $openedMutex) {
            try { $openedMutex.Dispose() } catch { }
        }
    }
}

Export-ModuleMember -Function Get-SupervisorSingleInstanceMutexName, Enter-SupervisorSingleInstance, Exit-SupervisorSingleInstance, Open-ExistingSingleInstanceMutexHandle, Test-SingleInstanceMutexHeld

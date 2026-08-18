<#
.SYNOPSIS
Operator command: cut the stream NOW, accepting the lost backlog.

THE DIFFERENCE FROM stop.ps1, WHICH IS THE WHOLE POINT OF HAVING BOTH. Stop is
"the service is over": it flips the flag to 'stopped', the running pusher reads that
as an explicit end-of-service, drains every byte already on disk to the relay, and
exits 0. Nothing is lost, but it is not instant -- during catch-up the pusher can be
thousands of seconds behind live, and draining that honestly takes time.

Cut is "this must not be going out": wrong content is live and every second it stays
live is worse than losing the backlog. So it kills the pusher where it stands and
accepts that the un-sent bytes never reach YouTube. That is deliberate content loss,
which this system otherwise exists to make impossible -- so it is a separate button
with a separate name, never a mode of Stop.

NOTHING IS DESTROYED. The recording file on disk is never touched, and neither is the
persisted offset. The bytes are abandoned in the sense that they are not SENT now; a
later start.ps1 resumes from the persisted offset and they go out then. Cut is
recoverable; a deleted recording would not be.

WHY THE FLAG GOES FIRST. Killing the pusher makes it exit non-zero, and
Get-SupervisorExitDecision classifies any non-zero-but-not-2 exit as a CRASH ->
Relaunch: a crash is not an operator stop, so the supervisor's job is to bring the
stream back. Set the flag first and that relaunch is decided but never happens -- the
supervisor sleeps its backoff, loops, re-reads the flag at the top of the next tick,
sees 'stopped', and idles. Kill first and flag second, and there is a window in which
the supervisor relaunches the very stream the operator just cut, back on air at the
worst possible moment. The order is not a style preference; it is the correctness
argument. tests/Cut.Tests.ps1 asserts it from inside the kill.

Functions are defined at top level (not wrapped in a module) so tests/Cut.Tests.ps1
can dot-source this file and mock Stop-PusherProcesses without killing anything real
-- the same convention install.ps1 and supervisor.ps1 already use. Invoke-Cut runs
only when this script is executed directly: see the guard at the bottom.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Deliberately NOT -Force (supervisor.ps1 parity): dot-sourcing this file must not
# reset an already-configured Logging module back to its default log directory.
Import-Module (Join-Path $PSScriptRoot 'lib/Logging.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/ControlFlag.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/PusherProcess.psm1')

function Stop-PusherProcesses {
    <#
    .SYNOPSIS
    Kills every running pusher.ps1 process launched out of ScriptRoot and returns how
    many were killed. Isolated into its own function as the testability seam: Pester
    mocks this so every branch of Invoke-Cut can be driven without killing a real
    process (and so the flag-before-kill ORDER can be asserted from inside the kill).

    The process list comes from lib/PusherProcess.psm1's Get-RunningPusherProcesses --
    that module is the single owner of what counts as "a pusher process" (full
    command-line match, ordinal Contains, never -like); see its header for the reasoning
    this function used to carry alone. This function owns everything that is about
    KILLING, not matching.

    Killing the pusher orphans its ffmpeg child, whose stdin pipe then closes -- ffmpeg
    sees EOF, flushes what it already holds (well under a second at the configured SRT
    latency) and exits on its own. That is both correct and desirable: the stream ends
    on a whole TS packet rather than a torn one.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $ScriptRoot
    )

    $pusherProcesses = Get-RunningPusherProcesses -ScriptRoot $ScriptRoot

    $killedCount = 0
    foreach ($pusherProcess in $pusherProcesses) {
        # -ErrorAction SilentlyContinue: the pusher may have exited between the
        # enumeration above and this kill (it is being cut precisely because things are
        # moving), and a cut that throws on an already-dead process would leave the
        # operator staring at a red error for the outcome they asked for.
        Stop-Process -Id $pusherProcess.ProcessId -Force -ErrorAction SilentlyContinue
        $killedCount++
        Write-Log -Level Warning -Message "Cut: killed pusher process $($pusherProcess.ProcessId) -- the un-sent backlog is abandoned, the recording file and the persisted offset are untouched"
    }

    return $killedCount
}

function Invoke-Cut {
    <#
    .SYNOPSIS
    Sets desired=stopped, THEN kills the running pusher. Returns 0 -- a cut that found
    no pusher to kill is still a successful cut (the flag is written either way), so
    pressing Cut twice, or pressing it when nothing is running, is safe and reports
    success rather than an error the operator would have to interpret mid-incident.

    .OUTPUTS
    Int: the process exit code for the bottom guard (0 -- the cut was carried out).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $ControlFilePath,
        [Parameter(Mandatory)] [string] $ScriptRoot
    )

    # FIRST, always. See this file's header: everything about the correctness of a cut
    # is in the fact that this line has already run by the time the kill lands.
    Set-PusherDesiredState -ControlFilePath $ControlFilePath -DesiredState 'stopped'

    $killedCount = Stop-PusherProcesses -ScriptRoot $ScriptRoot

    if ($killedCount -eq 0) {
        Write-Log -Level Info -Message 'Cut: no pusher was running -- desired state is stopped, so the supervisor will not launch one.'
        return 0
    }

    Write-Log -Level Warning -Message "Cut: stopped $killedCount pusher process(es) immediately. The un-sent backlog was NOT delivered -- this is the deliberate cost of a cut. The recording on disk is intact and a later start.ps1 resumes from the persisted byte offset."
    return 0
}

# Only run the real cut when this script is invoked directly -- when dot-sourced
# (tests/Cut.Tests.ps1's `. $script:CutScriptPath`), every function above is defined
# and mockable, but nothing runs, kills, or exits. This guard is cut.ps1's single
# process edge -- the one place `exit` belongs (Invoke-Cut returns its exit code so
# it stays testable), exactly as supervisor.ps1's and install.ps1's bottom guards do.
if ($MyInvocation.InvocationName -ne '.') {
    Set-LogDirectory -Path (Join-Path $PSScriptRoot 'state/logs')
    exit (Invoke-Cut `
        -ControlFilePath (Get-PusherControlFilePath -ScriptRoot $PSScriptRoot) `
        -ScriptRoot $PSScriptRoot)
}

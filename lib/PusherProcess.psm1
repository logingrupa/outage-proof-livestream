# PusherProcess.psm1
# Sole owner of "what is a pusher process on this box". Extracted out of cut.ps1's
# Stop-PusherProcesses (which invented this filter first and proved it live) so the
# dashboard (05-05's PusherProcessAlive view-model input) can ask "is a pusher running
# right now?" WITHOUT reimplementing the CIM query a second time. A forked copy is
# worse than no copy: if the dashboard's filter ever drifted from cut.ps1's, the
# dashboard could say "not streaming" about a process cut.ps1 would still happily
# kill, or Start could arm itself over a pusher this module failed to see. One filter,
# two callers, is the whole point of this file.
#
# WHY MATCH ON FULL COMMAND LINE, NOT PROCESS NAME (carried from cut.ps1, this is the
# original reasoning -- a future reader deciding whether it is "safe" to simplify this
# to a process-name match needs it HERE, at the code, not two files away in a killer
# they may never open): the supervisor launches the pusher as
# `pwsh.exe ... -File <ScriptRoot>\pusher.ps1`, and every other pwsh.exe on the box --
# the supervisor itself, cut.ps1, an operator's own console -- is also pwsh.exe.
# Matching by name would make cut.ps1 kill the supervisor, the one process that must
# survive a cut so it can obey the next Start, and would make the dashboard's liveness
# check true for a box with no pusher at all. The match is deliberately on the full
# CommandLine containing this install's pusher.ps1 path.
#
# WHY ORDINAL Contains, NEVER -like: a real Windows path may legitimately contain
# -like's wildcard characters ([, ], ?). A ScriptRoot of `C:\app[1]\` silently fails to
# match under -like, which for cut.ps1 means a cut that kills nothing while reporting
# success, and for the dashboard means a permanently-wrong "not streaming" reading.
# [System.StringComparison]::OrdinalIgnoreCase + .Contains(...) has none of that trap.
#
# THIS MODULE OBSERVES, IT NEVER KILLS AND NEVER LOGS. Killing (and the loud per-kill
# Write-Log) stays in cut.ps1 -- that is a decision with consequences, not a read.
# Logging stays out entirely: Get-RunningPusherProcesses/Test-PusherProcessAlive are
# called by the dashboard's HTTP handler roughly once a second for the entire time the
# machine is idle (all week between services). A logged line per read would rot the
# bounded rotating log budget within hours (SVC-03/D-14), the exact reasoning that
# already makes StatsStore.psm1's Read-PusherStats silent -- this module follows the
# same convention and imports no Logging module at all, so there is no way to
# accidentally reach for Write-Log here later.
#
# SAFE DEFAULT for Test-PusherProcessAlive, chosen per-question (ControlFlag.psm1's
# convention: safe defaults are chosen per question, not per module): an uninspectable
# process table (Get-CimInstance throws) returns $false, "assume not alive". This is
# the same shape as Test-ObsProcessLiveness's degrade-to-safer-fallback precedent
# (Rotation.psm1, D-09), but a DIFFERENT bias: Test-ObsProcessLiveness returns $null so
# its caller can fall back to a longer degraded window; Test-PusherProcessAlive has no
# such third state available to an HTTP handler polled once a second; it must return a
# plain [bool] and never throw out of that handler (T-05-15). $false degrades the
# dashboard to showing Start enabled -- recoverable and visible, where a thrown
# exception inside the dashboard runspace is neither. The residual: if the process
# table is unreadable while a pusher IS live, Start appears armed during a stream.
# D-10's double-push hazard is bounded by the control seam itself, not by this
# function -- Set-PusherDesiredState 'streaming' while already streaming is
# idempotent, and the supervisor's single-launch-per-tick loop is what actually
# prevents a second pusher from ever running.
#
# Exports: Get-RunningPusherProcesses, Test-PusherProcessAlive

Set-StrictMode -Version Latest

function Get-RunningPusherProcesses {
    <#
    .SYNOPSIS
    Read-only CIM query: returns every process whose full CommandLine contains this
    install's `<ScriptRoot>\pusher.ps1` path (ordinal case-insensitive Contains --
    see module header for why not -like and why not a process-name match). Never
    kills anything and never logs. A process whose CommandLine cannot be read by CIM
    ($null, e.g. a protected/system process) is skipped, not thrown on.

    .OUTPUTS
    Array of CIM Win32_Process objects (possibly empty). Always a real array -- the
    unary-comma return guards a zero- or one-element result from PowerShell's
    return-enumeration collapsing it to $null or a bare scalar under a StrictMode
    caller's `.Count` access (the same trap Config.psm1's Test-PusherConfig already
    documents and guards).
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)] [string] $ScriptRoot
    )

    $pusherScriptPath = Join-Path $ScriptRoot 'pusher.ps1'

    $matchingProcesses = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine.Contains($pusherScriptPath, [System.StringComparison]::OrdinalIgnoreCase)
        })

    return , $matchingProcesses
}

function Test-PusherProcessAlive {
    <#
    .SYNOPSIS
    Read-only liveness check for the dashboard's D-10 view model: $true when
    Get-RunningPusherProcesses finds one or more matching processes, $false
    otherwise -- including when the CIM query itself throws (an uninspectable
    process table). See module header for why $false is the chosen safe default
    for THIS question specifically. Never throws.

    .OUTPUTS
    Bool.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $ScriptRoot
    )

    try {
        return (Get-RunningPusherProcesses -ScriptRoot $ScriptRoot).Count -gt 0
    } catch {
        return $false
    }
}

Export-ModuleMember -Function Get-RunningPusherProcesses, Test-PusherProcessAlive

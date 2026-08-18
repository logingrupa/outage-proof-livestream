# Clock.psm1
# Sole owner of the shared monotonic clock D-06's cross-process stats staleness design
# depends on. Get-MonotonicSeconds was PRIVATE to pusher.ps1 (pusher.ps1:160-168) until
# now -- but the dashboard's staleness check (05-02-PLAN.md D-06) requires
# supervisor.ps1 to compare "now" against a timestamp pusher.ps1 wrote, and that
# comparison is only meaningful if both processes read the SAME clock origin. This
# module exists to give both processes that one shared source, instead of two
# independently-private copies that could silently drift apart under a future edit.
#
# On Windows, [System.Diagnostics.Stopwatch]'s tick origin (QueryPerformanceCounter) is
# a SYSTEM-WIDE counter -- ticks since boot -- not a per-process one. That is what makes
# a value written by pusher.ps1 comparable to a value read moments later by
# supervisor.ps1, even though they are two independent processes with two independent
# CLR instances. This is NOT assumed: it is verified by tests/Clock.Tests.ps1's own
# child-process test, which writes a value from a genuinely separate `pwsh` process and
# compares it against this process's own reading (mirroring
# spike/Confirm-DashboardHost.ps1's Q2, recorded CONFIRMED in
# .planning/phases/05-local-dashboard-stats/05-SPIKE-FINDINGS.md).
#
# WHAT THIS CLOCK IS NOT FOR: it is a relative cadence/duration clock with an arbitrary
# origin (NOT epoch/wall-clock, IN-01) -- suitable only for computing elapsed seconds
# and staleness deadlines (e.g. "has more than 3 seconds passed since this was
# written?"). It must never be rendered to an operator as a date/time, and it must
# never be persisted as a wall-clock record: the origin is meaningless outside this
# machine's current boot session and carries no calendar meaning at all.
#
# This module imports nothing and has zero side effects on import -- both pusher.ps1's
# hot loop and the dashboard runspace must be able to Import-Module this file with no
# risk of it dragging in Logging, file I/O, or any other dependency along the way.
#
# Exports: Get-MonotonicSeconds

Set-StrictMode -Version Latest

function Get-MonotonicSeconds {
    <#
    .SYNOPSIS
    Monotonic seconds from a Stopwatch tick origin (NOT epoch/wall-clock) used only for
    relative cadence/duration/staleness decisions -- never treat the value as wall-clock
    time (IN-01). The origin is system-wide (ticks since boot), so a value written by
    one process is comparable to a value read by another, independent process -- see
    the module header for the verification this relies on.

    .OUTPUTS
    Double: seconds, on an arbitrary (boot-relative) origin.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param()

    return [System.Diagnostics.Stopwatch]::GetTimestamp() / [System.Diagnostics.Stopwatch]::Frequency
}

Export-ModuleMember -Function Get-MonotonicSeconds

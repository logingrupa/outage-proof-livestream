# Logging.psm1
# Loud logger: console + file, with a bounded-footprint rotation policy
# (SVC-03/D-14). The default log path anchors to this module's own location
# ($PSScriptRoot), never to the process CWD (D-15) -- a Scheduled Task
# launches with CWD = %windir%\system32 (Session 0), so a path derived from
# the current working directory would land there or fail to write at all (the
# same class of bug pusher.ps1's WR-03 $PSScriptRoot anchoring already guards
# against). Set-LogDirectory / Set-LogRotationPolicy let a caller (pusher.ps1,
# once Config.psm1 has loaded the operator's .env) redirect the active log
# path and override the size cap / retention count after startup.
#
# Rotation runs inline on Write-Log's existing Add-Content path -- there is no
# background job/runspace. There is NO locking: five or more concurrent writers
# exist in production (the supervisor main thread, the dashboard runspace, the
# probe runspace, the pusher, and start/stop/cut), and the torn log line at
# 2026-10-04 14:04:28 shows they do collide. No locking is added here (T-04-08
# stays open). Instead, file I/O in Write-Log is best-effort and never throws: a
# lost or torn line is acceptable, a dead supervisor is not.
#
# Exports: Write-Log, Set-LogDirectory, Set-LogRotationPolicy, Get-LogFilePath,
# Invoke-LogRotationIfNeeded, Get-ProcessIdentityLogText

Set-StrictMode -Version Latest

$script:LogDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../state/logs'))
$script:LogFilePath = Join-Path $script:LogDirectory 'pusher.log'
$script:LogMaxSizeBytes = 10485760
$script:LogRetentionCount = 5

function Set-LogDirectory {
    <#
    .SYNOPSIS
    Redirects the active log path to <Path>/pusher.log. A relative Path is
    anchored under this module's own root (WR-03 parity, D-15) -- never the
    process CWD -- so callers never need to pre-resolve an absolute path
    themselves; an already-rooted Path is used verbatim.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $resolvedDirectory = $Path
    if (-not [System.IO.Path]::IsPathRooted($resolvedDirectory)) {
        $resolvedDirectory = Join-Path $PSScriptRoot (Join-Path '..' $resolvedDirectory)
    }

    $script:LogDirectory = [System.IO.Path]::GetFullPath($resolvedDirectory)
    $script:LogFilePath = Join-Path $script:LogDirectory 'pusher.log'
}

function Set-LogRotationPolicy {
    <#
    .SYNOPSIS
    Overrides the log rotation size cap / retention count (D-14), letting
    pusher.ps1 inject the loaded .env values once Config.psm1 has run.
    Unspecified parameters leave the current value unchanged.
    #>
    [CmdletBinding()]
    param(
        [long] $MaxSizeBytes,
        [int] $RetentionCount
    )

    if ($PSBoundParameters.ContainsKey('MaxSizeBytes')) {
        $script:LogMaxSizeBytes = $MaxSizeBytes
    }
    if ($PSBoundParameters.ContainsKey('RetentionCount')) {
        $script:LogRetentionCount = $RetentionCount
    }
}

function Get-LogFilePath {
    <#
    .SYNOPSIS
    Returns the path Write-Log appends to, creating the parent directory if absent.
    #>
    $logDirectory = Split-Path -Parent $script:LogFilePath
    if (-not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }
    return $script:LogFilePath
}

function Invoke-LogFileOperationWithRetry {
    <#
    .SYNOPSIS
    Runs a rotation-chain filesystem Operation (Move-Item/Remove-Item),
    retrying with a short backoff on a transient IOException/
    UnauthorizedAccessException -- the same AV/indexer-lock discipline
    OffsetStore.psm1's Save-PusherOffset already applies to its own atomic
    rename. A persistent failure still throws after the final attempt to a
    direct caller; Write-Log (which reaches this through
    Invoke-LogRotationIfNeeded) absorbs it, because logging must never take
    down its caller (261018).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Operation
    )

    $maximumAttempts = 5
    $backoffMilliseconds = 20
    for ($attempt = 1; ; $attempt++) {
        try {
            & $Operation
            return
        } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if ($attempt -ge $maximumAttempts) {
                throw
            }
            Start-Sleep -Milliseconds $backoffMilliseconds
        }
    }
}

function Invoke-LogRotationIfNeeded {
    <#
    .SYNOPSIS
    Size+count-bounded rotation (D-14/SVC-03): when the active log at
    LogFilePath is at/over MaxSizeBytes, deletes anything beyond
    RetentionCount, shifts the remaining .N-1 -> .N descending (so no rename
    target is ever clobbered mid-chain), then moves the active file to .1.
    Below the cap, or when the active file does not exist yet, this is a
    no-op. Single-writer scope only (T-04-08) -- see module header.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $LogFilePath,

        [Parameter(Mandatory)]
        [long] $MaxSizeBytes,

        [Parameter(Mandatory)]
        [int] $RetentionCount
    )

    $activeLogFile = Get-Item -LiteralPath $LogFilePath -ErrorAction SilentlyContinue
    if ($null -eq $activeLogFile) { return }
    if ($activeLogFile.Length -lt $MaxSizeBytes) { return }

    $oldestKept = "$LogFilePath.$RetentionCount"
    if (Test-Path -LiteralPath $oldestKept) {
        Invoke-LogFileOperationWithRetry -Operation { Remove-Item -LiteralPath $oldestKept -Force }
    }

    for ($index = $RetentionCount - 1; $index -ge 1; $index--) {
        $source = "$LogFilePath.$index"
        $destination = "$LogFilePath." + ($index + 1)
        if (Test-Path -LiteralPath $source) {
            Invoke-LogFileOperationWithRetry -Operation { Move-Item -LiteralPath $source -Destination $destination -Force }
        }
    }

    Invoke-LogFileOperationWithRetry -Operation { Move-Item -LiteralPath $LogFilePath -Destination "$LogFilePath.1" -Force }
}

function Get-ProcessIdentityLogText {
    <#
    .SYNOPSIS
    One-line identity of THIS process for start-up log lines:
    "pid=<pid> ppid=<parent pid or unknown> user=<account> session=<session id> started=<ISO time>".
    The parent pid may be unreadable (for example Task Scheduler's svchost parent under a
    limited token), so a missing parent is "unknown", never claimed to be absent.

    WHY: on 2026-10-04 two supervisors ran side by side and nothing in the log said which
    was which. user= alone would have proved SYSTEM versus the operator account, and the
    pid maps to its trigger in the TaskScheduler/Operational log (event 129).

    No CIM: WMI can stall about 70 s after boot, and the PowerShell 7 Process.Parent is
    enough. Never throws: any failure degrades to just "pid=<pid>", so a logging aid can
    never block a start-up line.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $currentProcess = Get-Process -Id $PID -ErrorAction Stop
        $parentProcessText = if ($null -eq $currentProcess.Parent) { 'unknown' } else { $currentProcess.Parent.Id }
        $accountName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        return "pid=$PID ppid=$parentProcessText user=$accountName session=$($currentProcess.SessionId) started=$($currentProcess.StartTime.ToString('o'))"
    } catch {
        return "pid=$PID"
    }
}

function Write-Log {
    <#
    .SYNOPSIS
    Writes a timestamped line to both console and state/logs/pusher.log.
    Error and Warning levels are routed through the error/warning streams so
    failures are loud on an unattended church machine.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string] $Level,

        [Parameter(Mandatory)]
        [string] $Message
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $formattedLine = "[$timestamp] [$Level] $Message"

    # Best-effort by design (261018): under $ErrorActionPreference = 'Stop', a throw here on
    # the supervisor's main thread would end the supervisor with no log line, which is the
    # silent-death signature of 2026-10-04. Rotation and append are INDEPENDENT best-effort
    # steps: a failed rotation (locked chain) must not drop an append that would succeed.
    # The console / error-stream emit below still runs, so a line is never lost entirely.
    $logFilePath = $null
    try {
        $logFilePath = Get-LogFilePath
        Invoke-LogRotationIfNeeded -LogFilePath $logFilePath -MaxSizeBytes $script:LogMaxSizeBytes -RetentionCount $script:LogRetentionCount
    } catch {
        # Rotation failed; fall through to the append.
    }
    try {
        if ($null -eq $logFilePath) { $logFilePath = Get-LogFilePath }
        Add-Content -LiteralPath $logFilePath -Value $formattedLine
    } catch {
        # Append failed (locked / disk full); the emit below is the only copy of this line.
    }

    # -ErrorAction/-WarningAction Continue is explicit and NON-negotiable here (RES-01
    # bug fix, 02-07): Write-Log has no CmdletBinding, so $ErrorActionPreference is
    # dynamically inherited from whatever scope called into this function -- and
    # pusher.ps1 itself sets $ErrorActionPreference = 'Stop' at its own top-of-script
    # (D-16). Without this override, Write-Error here becomes a TERMINATING call the
    # instant ANY Error-level log fires anywhere downstream (Write-FfmpegStdin's
    # Hang/Fault paths, Restore-PusherOffset's corrupt-state handler, etc.), aborting
    # the entire pusher process on its very first "loud" error log -- silently
    # defeating classify -> backoff -> reconnect and violating D-10 ("the pusher must
    # never exit on a network outage") before that logic ever runs. "Loud" (visible on
    # the error/warning stream for an unattended church machine) must never mean
    # "fatal" -- that distinction is owned here, once, not by every call site.
    switch ($Level) {
        'Error'   { Write-Error $formattedLine -ErrorAction Continue }
        'Warning' { Write-Warning $formattedLine -WarningAction Continue }
        'Debug'   { Write-Debug $formattedLine }
        default   { Write-Host $formattedLine }
    }
}

Export-ModuleMember -Function Write-Log, Set-LogDirectory, Set-LogRotationPolicy, Get-LogFilePath, Invoke-LogRotationIfNeeded, Get-ProcessIdentityLogText

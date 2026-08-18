# NicTelemetry.psm1
# 260722-xbr: the SRT-path NIC upload-speed telemetry module. Answers "how fast is
# the physical adapter that carries SRT traffic to RELAY_HOST actually sending right
# now?" -- a signal the pusher's own sendBytesPerSecond cannot give, because that
# number is ffmpeg's own accepted-stdin rate, not what actually left the box over the
# wire (bonded WAN retransmits, OS-level queuing, etc. all sit between the two).
#
# PURE DECISION vs EDGE I/O SPLIT (this repo's established convention, mirrored from
# StatsStore.psm1/Dashboard.psm1): Get-NicUploadBytesPerSecond and
# Test-NicUploadLogShouldRotate are pure -- two counter samples plus an interval in,
# an honest number or $null out, no file/process/network access. Get-NicSentBytes,
# Resolve-SrtNicName, and Add-NicUploadSample are the edge seams: every one of them is
# NEVER-THROW by contract, because a telemetry read/write must never be allowed to
# disturb the always-on dashboard process that owns crash restart (T-xbr-02).
#
# NEVER FABRICATE (this project's D-13 bias, applied here): a counter reset/rollover
# (CurrentSentBytes < PreviousSentBytes) or a non-positive interval returns $null,
# never a negative or wrapped-huge rate. A resolution/read failure returns $null,
# never a stale or zero-substituted value. Add-NicUploadSample writes a genuine JSON
# null for an unreadable field, never the string "null" or a fabricated 0.
#
# Exports: Get-NicUploadBytesPerSecond, Get-NicSentBytes, Resolve-SrtNicName,
#          Test-NicUploadLogShouldRotate, Add-NicUploadSample

Set-StrictMode -Version Latest

function Get-NicUploadBytesPerSecond {
    <#
    .SYNOPSIS
    Pure. Derives bytes/sec from two byte-counter samples and the interval between
    them. Returns $null (never a fabricated number) when IntervalSeconds is not
    strictly positive, or when CurrentSentBytes is less than PreviousSentBytes -- an
    adapter counter reset or a 32/64-bit rollover, which an honest null beats a huge
    negative or wrapped number for.

    .OUTPUTS
    [Nullable[double]]
    #>
    [CmdletBinding()]
    [OutputType([Nullable[double]])]
    param(
        [Parameter(Mandatory)] [long] $PreviousSentBytes,
        [Parameter(Mandatory)] [long] $CurrentSentBytes,
        [Parameter(Mandatory)] [double] $IntervalSeconds
    )

    if ($IntervalSeconds -le 0) { return $null }
    if ($CurrentSentBytes -lt $PreviousSentBytes) { return $null }

    return ($CurrentSentBytes - $PreviousSentBytes) / $IntervalSeconds
}

function Get-NicSentBytes {
    <#
    .SYNOPSIS
    Edge testability seam (mirrors Get-DashboardStaticFileBytes's isolation pattern,
    Dashboard.psm1): wraps Get-NetAdapterStatistics in try/catch so an unplugged/
    renamed/vanished adapter degrades to $null rather than throwing into the
    supervisor's per-poll ApiStats handler. Isolated as its own named function so
    tests can Mock it directly.

    .OUTPUTS
    [Nullable[long]]
    #>
    [CmdletBinding()]
    [OutputType([Nullable[long]])]
    param(
        [Parameter(Mandatory)] [string] $NicName
    )

    try {
        $statistics = Get-NetAdapterStatistics -Name $NicName -ErrorAction Stop
        return [long] $statistics.SentBytes
    } catch {
        return $null
    }
}

function Resolve-SrtNicName {
    <#
    .SYNOPSIS
    Edge. Decides which physical adapter carries SRT traffic to RelayHost.
    OverrideNicName (the operator's SRT_NIC_NAME .env value) always wins when
    non-blank. Otherwise resolves via Find-NetRoute -RemoteIPAddress against the
    system routing table, then Get-NetAdapter on the winning route's InterfaceIndex.
    Never throws -- any failure (no route, adapter vanished mid-lookup) returns $null,
    which the caller treats as "NIC telemetry disabled this run", never a blocked
    dashboard start.

    .OUTPUTS
    [Nullable[string]]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $RelayHost,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $OverrideNicName
    )

    if (-not [string]::IsNullOrWhiteSpace($OverrideNicName)) {
        return $OverrideNicName
    }

    try {
        $route = Find-NetRoute -RemoteIPAddress $RelayHost -ErrorAction Stop | Select-Object -First 1
        $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop
        return $adapter.Name
    } catch {
        return $null
    }
}

function Test-NicUploadLogShouldRotate {
    <#
    .SYNOPSIS
    Pure. $true only when MaxSizeBytes is strictly positive AND CurrentSizeBytes
    exceeds it -- a non-positive MaxSizeBytes disables rotation outright (mirrors this
    repo's existing "<=0 disables" convention, e.g. LOG_MAX_SIZE_BYTES/GROWTH_RATE_
    SMOOTHING_SECONDS in Config.psm1).

    .OUTPUTS
    [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [long] $CurrentSizeBytes,
        [Parameter(Mandatory)] [long] $MaxSizeBytes
    )

    return ($MaxSizeBytes -gt 0) -and ($CurrentSizeBytes -gt $MaxSizeBytes)
}

function Add-NicUploadSample {
    <#
    .SYNOPSIS
    Edge. Appends exactly one compact JSON line (timestampUtc, nicName, uploadBps,
    pusherSendBitrateBps) to LogFilePath, single-generation size rotation at
    MaxSizeBytes (default ~5MB, T-xbr-01): when the existing file already exceeds the
    threshold, it is renamed to "<path>.1" (overwriting any prior .1) BEFORE the new
    line is written, so exactly one prior generation is ever retained.

    NEVER THROWS (T-xbr-02): the whole body is wrapped in try/catch and returns
    quietly on any failure -- a telemetry log is a nice-to-have that must never
    disturb the dashboard's per-poll handler. A $null UploadBps/PusherSendBitrateBps
    serializes as a genuine JSON null via ConvertTo-Json's native handling of $null --
    never coerced to 0 or the string "null".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $LogFilePath,
        [Parameter(Mandatory)] [string] $TimestampUtc,
        [Parameter(Mandatory)] [string] $NicName,
        [Nullable[double]] $UploadBps = $null,
        [Nullable[double]] $PusherSendBitrateBps = $null,
        [long] $MaxSizeBytes = 5242880
    )

    try {
        $absoluteLogFilePath = [System.IO.Path]::GetFullPath($LogFilePath)
        $logDirectory = Split-Path -Parent $absoluteLogFilePath
        if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }

        if (Test-Path -LiteralPath $absoluteLogFilePath) {
            $currentSizeBytes = (Get-Item -LiteralPath $absoluteLogFilePath).Length
            if (Test-NicUploadLogShouldRotate -CurrentSizeBytes $currentSizeBytes -MaxSizeBytes $MaxSizeBytes) {
                $rotatedLogFilePath = "$absoluteLogFilePath.1"
                [System.IO.File]::Move($absoluteLogFilePath, $rotatedLogFilePath, $true)
            }
        }

        $payloadObject = [ordered]@{
            timestampUtc         = $TimestampUtc
            nicName              = $NicName
            uploadBps            = $UploadBps
            pusherSendBitrateBps = $PusherSendBitrateBps
        }
        $line = $payloadObject | ConvertTo-Json -Compress
        [System.IO.File]::AppendAllText($absoluteLogFilePath, $line + "`n")
    } catch {
        # Best-effort only (T-xbr-02) -- a telemetry log write must never raise.
        return
    }
}

Export-ModuleMember -Function Get-NicUploadBytesPerSecond, Get-NicSentBytes, Resolve-SrtNicName, Test-NicUploadLogShouldRotate, Add-NicUploadSample

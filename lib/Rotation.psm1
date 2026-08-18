# Rotation.psm1
# Pure/mockable rotation + end-of-service decision component (ROT-01/ROT-02;
# ARCHITECTURE.md Rotation Detector). Decomposed into small pure functions over
# inputs the caller already has (file lists, liveness booleans, elapsed seconds) --
# no direct Get-ChildItem/Get-Process calls inside the decision functions themselves,
# matching Pacer.psm1's pure-function convention so Rotation.Tests.ps1 needs no real
# filesystem/process dependency.
#
# Exports: Get-NewestMatchingRecordingFile, Test-RotationDetected,
#          Test-ObsProcessLiveness, Get-EndOfServiceDecision, Test-RecordingFileFresh,
#          Get-RecordingFileLiveMetadata

Set-StrictMode -Version Latest

# Import the logger explicitly (WR-02): Test-ObsProcessLiveness's uninspectable-process
# catch block calls Write-Log, so relying on the caller to have imported Logging would
# turn a CommandNotFoundException loose exactly while handling the degraded (D-09) path.
Import-Module (Join-Path $PSScriptRoot 'Logging.psm1')

function Get-NewestMatchingRecordingFile {
    <#
    .SYNOPSIS
    I/O wrapper: returns the newest-by-LastWriteTime file in RecordingFolderPath that
    matches RecordingFilenameGlob, or $null if none match (caller guards this before
    calling Test-RotationDetected). -LiteralPath on the folder + -Filter (which has no
    ".." traversal semantics) keeps enumeration inside the configured folder -- no
    filename is ever concatenated into a path by hand (T-03-01 mitigation).
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)] [string] $RecordingFolderPath,
        [Parameter(Mandatory)] [string] $RecordingFilenameGlob
    )

    $newest = Get-ChildItem -LiteralPath $RecordingFolderPath -Filter $RecordingFilenameGlob -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    return $newest
}

function Test-RotationDetected {
    <#
    .SYNOPSIS
    Pure decision: rotation is a positive signal only -- $true exactly when the newest
    matching file's path differs from the currently-tailed path (D-02, never a timeout).
    No filesystem access inside this function; NewestFile is supplied by the caller.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $NewestFile,
        [Parameter(Mandatory)] [string] $CurrentFilePath
    )

    return ($NewestFile.FullName -ne $CurrentFilePath)
}

function Test-ObsProcessLiveness {
    <#
    .SYNOPSIS
    I/O wrapper: inspects the OS process table by name (read-only, no shell) and
    returns $true (running), $false (confirmed not running), or $null (could not be
    inspected -- logs loudly and degrades to the growth-stall-only path, D-09). Never
    throws: a spoofed same-named process only delays end-detection (fail-toward-
    keep-running), never causes a false stop (T-03-02).
    #>
    [CmdletBinding()]
    [OutputType([bool], [System.Nullable[bool]])]
    param(
        [Parameter(Mandatory)] [string] $ProcessName
    )

    try {
        $process = Get-Process -Name $ProcessName -ErrorAction Stop
        return ($null -ne $process)
    } catch [Microsoft.PowerShell.Commands.ProcessCommandException] {
        return $false   # confirmed not running
    } catch {
        Write-Log -Level Warning -Message "Test-ObsProcessLiveness: could not inspect process '$ProcessName' -- degrading to growth-stall-only (D-09): $($_.Exception.Message)"
        return $null    # could not be inspected -- D-09 graceful degradation path
    }
}

function Get-EndOfServiceDecision {
    <#
    .SYNOPSIS
    Pure end-of-service combiner (ROT-02, D-07/D-09): the sole terminal-stop authority.

    THREE ways in, one of which outranks the other two. ExplicitStopRequested is the
    operator saying the service is over (stop.ps1, or Phase 5's dashboard Stop button,
    via the control flag); the other two are the pusher GUESSING that it is:
      (a) OBS liveness confirmed $false AND growth stalled >= SustainedWindowSeconds
          -- both heuristic signals agree (D-07).
      (b) liveness uninspectable ($null) -- degrade to the single growth-stall signal
          against the longer DegradedWindowSeconds (D-09).
    A live OBS ($true) always returns 'Continue' for the heuristics, regardless of how
    long growth has stalled: a live OBS is never end-of-service (D-07/D-08).

    An explicit stop short-circuits BEFORE any of that, deliberately. It is strictly
    more trustworthy than either heuristic -- it is not evidence that the service
    probably ended, it is the operator stating that it did -- so it consults no window,
    needs no growth stall, and does not care whether OBS is still recording. Draining
    (not stopping) is what makes that safe to obey instantly: the caller's final-drain
    loop still sends every byte already on disk, so the operator gets a wind-down, not
    a cut. Cutting is cut.ps1's job, and it is a separate button on purpose.

    ExplicitStopRequested is optional and defaults to $false so every Phase 3 call
    shape still binds and still decides identically. Both properties are load-bearing:
    making it Mandatory would break end-of-service detection for every real service at
    runtime, and defaulting it to $true would drain every service the instant it began.

    No Get-Process/Get-ChildItem calls inside this function (100% pure, D-08) -- the
    caller resolves all three signals and passes them in.
    .OUTPUTS
    String: 'Continue' | 'Draining'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [double] $GrowthStalledSeconds,
        [Parameter(Mandatory)] [AllowNull()] [Nullable[bool]] $ObsLivenessResult,
        [Parameter(Mandatory)] [double] $SustainedWindowSeconds,
        [Parameter(Mandatory)] [double] $DegradedWindowSeconds,
        [bool] $ExplicitStopRequested = $false
    )

    if ($ExplicitStopRequested) {
        return 'Draining'   # the operator outranks both heuristics (locked extension item 6)
    }

    if ($null -eq $ObsLivenessResult) {
        # D-09: liveness uninspectable -- require the longer degraded window, single signal.
        if ($GrowthStalledSeconds -ge $DegradedWindowSeconds) { return 'Draining' }
        return 'Continue'
    }

    if (-not $ObsLivenessResult -and $GrowthStalledSeconds -ge $SustainedWindowSeconds) {
        return 'Draining'   # both signals agree (D-07)
    }

    return 'Continue'
}

function Test-RecordingFileFresh {
    <#
    .SYNOPSIS
    Pure decision (260809-ow9, START-STALE-01): is a candidate recording file "fresh"
    enough to latch onto at Start-Pusher's initial file pick, as opposed to a finished
    prior service's leftover file?

    This deliberately MIRRORS OffsetStore.psm1's Test-ResumeStateSameSession convention
    (same inclusive wall-clock bounds, same negative-elapsed-is-false clock-skew rule,
    same wall-clock-not-monotonic rationale) rather than importing it, for two reasons:
    (1) Rotation.psm1 must not take a module dependency on the offset-persistence
    module, and (2) "resume state same session" asserts something false at this call
    site -- there is no resume state at all here, only a newest-matching-file candidate.

    Two independent ways to be fresh (either is sufficient):
      1. Wall-clock: 0 <= (NowUtc - FileLastWriteTimeUtc) <= StaleAfterSeconds
         (inclusive, mirroring Test-ResumeStateSameSession). A future-dated mtime
         (clock skew, or a planted file) is never fresh -- negative elapsed is false.
      2. Growth: PreviousLengthBytes is non-null AND CurrentLengthBytes is strictly
         greater than it. This arm exists because an NTFS LastWriteTime on a file held
         open by a buffered writer (OBS) can lag behind the writer's actual last flush,
         so observed byte growth is the stronger "currently recording" signal -- and it
         is what the operator-facing requirement actually asks for (a file that is
         demonstrably growing right now must never be treated as stale).

    The null PreviousLengthBytes contract: no prior observation this wait means the
    growth arm CANNOT vote -- it is excluded from the decision entirely, never treated
    as a false-positive "not growing" vote. Only the wall-clock arm can pass on a file's
    very first observation.

    Kept pure (no Get-Item, no try/catch, no logging) -- the call site owns all I/O,
    exactly as Test-ResumeStateSameSession's own header states.

    .OUTPUTS
    Boolean: $true when either the wall-clock window or the growth arm passes,
    $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [DateTime] $FileLastWriteTimeUtc,
        [Parameter(Mandatory)] [DateTime] $NowUtc,
        [Parameter(Mandatory)] [double] $StaleAfterSeconds,
        [AllowNull()] [Nullable[long]] $PreviousLengthBytes = $null,
        [long] $CurrentLengthBytes = 0
    )

    $elapsedSeconds = ($NowUtc - $FileLastWriteTimeUtc).TotalSeconds
    $isFreshByWallClock = ($elapsedSeconds -ge 0) -and ($elapsedSeconds -le $StaleAfterSeconds)
    if ($isFreshByWallClock) {
        return $true
    }

    $isFreshByGrowth = ($null -ne $PreviousLengthBytes) -and ($CurrentLengthBytes -gt $PreviousLengthBytes)
    return $isFreshByGrowth
}

function Get-RecordingFileLiveMetadata {
    <#
    .SYNOPSIS
    I/O wrapper (260816-g70, START-STALE-02): reads a candidate recording file's
    length and last-write-time THROUGH AN OPEN HANDLE, never from the directory
    entry Get-ChildItem/Get-Item serve.

    Measured live on this machine on 2026-08-16: with a writer holding the file
    open and flushing every ~300ms, Get-ChildItem served Length=0 and a frozen
    creation-time mtime for the entire observation window (and, per the incident
    this fixes, for 8 minutes) -- the directory entry is a stale cache while a
    writer holds an exclusive-enough lock on the file's metadata, and only a
    handle-based read sees the truth. Opening a handle ALSO happens to refresh
    the directory entry for later enumerations, which is exactly why the
    operator's own diagnostic `ls -la` released the guard mid-incident.

    This is deliberately NOT used on the hot streaming path: Tailer.psm1's
    Read-StableChunk already reads length from its own long-lived open
    FileStream and is structurally immune to this bug. This function exists
    only for callers (the Start guard's wait loop) that do not yet hold an
    open handle on the candidate file.

    Opens with FileAccess.Read + FileShare.ReadWrite -- byte-identical to
    Open-TailerFileStream's triple (T-g70-03) -- so OBS's own writer is never
    locked out. The stream is opened and disposed within this single call
    (never held across polls), and disposal happens in a `finally` on every
    path (T-g70-02): the guard calls this ~4x/second for as long as it waits,
    so a leaked handle here is a real exhaustion path that would break the
    very fix this function is.

    Never throws: a vanished file, a FileShare.None-locked file, or any other
    failure returns $null and is never logged from inside this function --
    mirrors Test-ObsProcessLiveness's fail-toward-keep-running convention
    (D-09). A missing/locked file is a "no reading this poll" answer for the
    caller to degrade on, not a crash.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $FilePath
    )

    $fileStream = $null
    try {
        $fileStream = [System.IO.FileStream]::new(
            $FilePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )

        $lengthBytes = [long] $fileStream.Length
        $lastWriteTimeUtc = [System.IO.File]::GetLastWriteTimeUtc($fileStream.SafeFileHandle)

        return [pscustomobject] @{
            LengthBytes      = $lengthBytes
            LastWriteTimeUtc = $lastWriteTimeUtc
        }
    } catch {
        return $null
    } finally {
        if ($null -ne $fileStream) {
            $fileStream.Dispose()
        }
    }
}

Export-ModuleMember -Function Get-NewestMatchingRecordingFile, Test-RotationDetected, Test-ObsProcessLiveness, Get-EndOfServiceDecision, Test-RecordingFileFresh, Get-RecordingFileLiveMetadata

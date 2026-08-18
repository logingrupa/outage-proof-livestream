# OffsetStore.psm1
# Sole owner of durable "where am I" state (ARCHITECTURE.md Anti-Pattern 2).
# Offset means bytes successfully handed to ffmpeg stdin (D-04), advances only in
# whole-188-byte increments, persisted atomically via write-temp-then-rename (D-08),
# and floored-to-188 with a loud log on load (D-06/D-09). A missing or corrupt state
# file always falls back to the documented safe default (file=$null, byteOffset=0)
# and never throws -- this is the crash-safety core of the gapless guarantee: every
# decision here biases toward re-send over skip (D-05).
#
# Exports: Save-PusherOffset, Restore-PusherOffset, Resolve-ResumeOffset,
#          Test-ResumeStateSameSession, Get-ResumeSafetyMarginBytes

Set-StrictMode -Version Latest

# Import the logger explicitly (WR-02): Restore-PusherOffset's corrupt-state catch block
# calls Write-Log, so relying on the caller to have imported Logging would turn a
# CommandNotFoundException loose exactly while handling corruption -- defeating the
# documented "never throws" crash-safety guarantee when this module is used standalone.
Import-Module (Join-Path $PSScriptRoot 'Logging.psm1')

$script:TransportStreamPacketSizeBytes = 188

function Save-PusherOffset {
    <#
    .SYNOPSIS
    Atomically persists {file, byteOffset} to StateFilePath: writes a temp file in
    the same directory then renames it over the final path with the single-syscall
    atomic replace [System.IO.File]::Move(src, dst, overwrite:$true) (MoveFileEx +
    MOVEFILE_REPLACE_EXISTING) -- unlike Move-Item -Force, which is delete-then-move
    with a crash window in which no state file exists. A partially written temp file
    never replaces a good state file, and there is never an instant with no state file
    at all (D-08, CR-04). All paths are resolved absolute first: .NET static file APIs
    resolve relative paths against the process CWD, not the PowerShell location (WR-03).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StateFilePath,
        [Parameter(Mandatory)] [string] $RecordingFilePath,
        [Parameter(Mandatory)] [long] $ByteOffset
    )

    $absoluteStateFilePath = [System.IO.Path]::GetFullPath($StateFilePath)
    $stateDirectory = Split-Path -Parent $absoluteStateFilePath
    if ($stateDirectory -and -not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $temporaryPath = Join-Path $stateDirectory ("offset.{0}.tmp" -f [Guid]::NewGuid())
    $payload = @{ file = $RecordingFilePath; byteOffset = $ByteOffset } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($temporaryPath, $payload)

    # The atomic replace (MoveFileEx + MOVEFILE_REPLACE_EXISTING) can transiently fail with
    # "Access to the path is denied" when a scanner (Windows Defender real-time, Search
    # indexer, a backup agent) holds a momentary handle on the destination -- observed
    # against a live per-250ms commit cadence. The failure is transient (clears in a few
    # ms), so retry with a short backoff rather than crashing the whole push loop. The write
    # stays atomic: the temp file is already fully written, and on total exhaustion the
    # PREVIOUS good state file is still intact (we never deleted it), so the worst case is a
    # skipped update, never a corrupt/missing state file. A persistent denial (real ACL
    # problem) still throws loudly after the final attempt.
    $maximumMoveAttempts = 5
    $moveBackoffMilliseconds = 20
    for ($attempt = 1; ; $attempt++) {
        try {
            [System.IO.File]::Move($temporaryPath, $absoluteStateFilePath, $true)
            break
        } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if ($attempt -ge $maximumMoveAttempts) {
                if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
                throw
            }
            Start-Sleep -Milliseconds $moveBackoffMilliseconds
        }
    }
}

function Restore-PusherOffset {
    <#
    .SYNOPSIS
    Loads {file, byteOffset} from StateFilePath. Floors a misaligned byteOffset down
    to the nearest 188 multiple and logs loudly (D-06/D-09). A missing state file or
    corrupt/unparseable JSON falls back to the safe default (file=$null, byteOffset=0)
    -- always logged loudly, never thrown -- so the pusher never crash-loops on
    startup (ASVS V5 input validation control for this untrusted persisted input).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StateFilePath
    )

    if (-not (Test-Path -LiteralPath $StateFilePath)) {
        Write-Log -Level Warning -Message "No offset state found at '$StateFilePath' -- starting from byte 0 (safe default)"
        return @{ file = $null; byteOffset = 0 }
    }

    try {
        $state = Get-Content -LiteralPath $StateFilePath -Raw | ConvertFrom-Json
        # Untrusted persisted input (ASVS V5): cast to [long] so a non-numeric byteOffset
        # throws deterministically into the safe-default catch, and reject a negative
        # offset outright -- PowerShell's % preserves the dividend sign (-1000 % 188 = -60),
        # so flooring alone would return a negative "aligned" offset that only the caller's
        # own [Math]::Max(0, ...) happens to save; any other consumer would inherit the bug
        # (WR-04).
        $rawOffset = [long] $state.byteOffset
        if ($rawOffset -lt 0) {
            Write-Log -Level Error -Message "Persisted offset $rawOffset is negative -- falling back to byte 0 (safe default)"
            return @{ file = $null; byteOffset = 0 }
        }
        $flooredOffset = $rawOffset - ($rawOffset % $script:TransportStreamPacketSizeBytes)
        if ($flooredOffset -ne $rawOffset) {
            Write-Log -Level Warning -Message "Persisted offset $rawOffset was not $script:TransportStreamPacketSizeBytes-byte aligned -- flooring to $flooredOffset"
        }
        return @{ file = $state.file; byteOffset = $flooredOffset }
    } catch {
        Write-Log -Level Error -Message "Offset state file '$StateFilePath' corrupt -- falling back to byte 0: $($_.Exception.Message)"
        return @{ file = $null; byteOffset = 0 }
    }
}

function Resolve-ResumeOffset {
    <#
    .SYNOPSIS
    Reconciles a restored offset into a real resume point across a legitimate
    file rotation (D-14). A persisted file path that differs from "the newest
    file currently in RecordingFolderPath" is the EXPECTED case right after a
    rotation -- it must resume the persisted (older) file at its persisted
    offset and let the pusher's Rotating-state drain-then-switch logic handle
    the transition, instead of this guard silently zeroing a partially-drained
    file.

    Resets to byteOffset=0 ONLY when the persisted state cannot be trusted at
    all: the persisted file is missing/deleted/outside RecordingFolderPath
    (returns file=$null so the caller re-resolves via the Rotation Detector's
    Get-NewestMatchingRecordingFile), or the persisted offset exceeds that
    file's own current length (re-send bias, D-05). Every branch returns a
    hashtable and logs loudly (Write-Log Warning) -- this function never
    throws on untrusted persisted state (ASVS V5).

    The persisted file path is constrained to resolve inside RecordingFolderPath
    before it is ever passed to Test-Path/Get-Item (T-03-04): an out-of-folder
    path is treated exactly like a missing file rather than opened, so a
    tampered state file cannot be used to probe an arbitrary filesystem
    location.

    .OUTPUTS
    Hashtable: file (string or $null), byteOffset (long).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $RestoredState,
        [Parameter(Mandatory)] [string] $RecordingFolderPath
    )

    # WR-01: the whole body is wrapped in try/catch so this function genuinely never
    # throws on untrusted persisted state, matching Restore-PusherOffset's existing
    # pattern -- e.g. a TOCTOU race between Test-Path and the later Get-Item (the
    # persisted file deleted by a concurrent cleanup/AV process in that narrow
    # window) would otherwise throw an uncaught exception straight through
    # Start-Pusher, before its own try/finally begins, crashing the whole script at
    # startup with $ErrorActionPreference = 'Stop'.
    try {
        $persistedFile = $RestoredState.file
        $persistedOffset = [long] $RestoredState.byteOffset

        if (-not $persistedFile) {
            Write-Log -Level Warning -Message "Persisted file '$persistedFile' missing -- resetting to newest available file at offset 0 (D-05 re-send bias)"
            return @{ file = $null; byteOffset = 0 }
        }

        # WR-02: the traversal boundary check runs BEFORE any Test-Path/Get-Item
        # probe touches the filesystem -- T-03-04 (ASVS V5) requires the persisted
        # path be constrained to resolve inside RecordingFolderPath before it is
        # ever passed to Test-Path/Get-Item, not merely before Get-Item as before.
        # A tampered/corrupt out-of-folder path must never be used to probe the
        # filesystem for existence at all, not just to prevent reading its length.
        $absoluteRecordingFolderPath = [System.IO.Path]::GetFullPath($RecordingFolderPath)
        $absolutePersistedFilePath = [System.IO.Path]::GetFullPath($persistedFile)
        $isInsideRecordingFolder = $absolutePersistedFilePath.StartsWith(
            $absoluteRecordingFolderPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase
        )
        if (-not $isInsideRecordingFolder) {
            Write-Log -Level Warning -Message "Persisted file '$persistedFile' resolves outside recording folder '$RecordingFolderPath' -- treating as missing, resetting to offset 0 (T-03-04)"
            return @{ file = $null; byteOffset = 0 }
        }

        if (-not (Test-Path -LiteralPath $persistedFile)) {
            Write-Log -Level Warning -Message "Persisted file '$persistedFile' missing -- resetting to newest available file at offset 0 (D-05 re-send bias)"
            return @{ file = $null; byteOffset = 0 }
        }

        $persistedFileLength = (Get-Item -LiteralPath $persistedFile).Length
        if ($persistedOffset -gt $persistedFileLength) {
            Write-Log -Level Warning -Message "Persisted offset $persistedOffset exceeds '$persistedFile' length $persistedFileLength -- resetting to 0 (re-send bias, D-05)"
            return @{ file = $persistedFile; byteOffset = 0 }
        }

        # Persisted file still exists and offset fits -- resume it directly, EVEN IF
        # a newer file also exists in the folder (D-13/D-14): the normal Rotating-
        # state drain-then-switch path detects and handles that on its own, at the
        # correct pace, rather than this startup guard trying to fast-forward past it.
        return @{ file = $persistedFile; byteOffset = $persistedOffset }
    } catch {
        Write-Log -Level Warning -Message "Resolve-ResumeOffset: unexpected error resolving persisted resume state -- falling back to file=`$null, byteOffset=0 (never throws, D-05/ASVS V5): $($_.Exception.Message)"
        return @{ file = $null; byteOffset = 0 }
    }
}

function Test-ResumeStateSameSession {
    <#
    .SYNOPSIS
    Pure decision: is a resolved resume file's LastWriteTime recent enough to trust it
    as part of the CURRENT session, as opposed to a finished prior session (SESS-01)?

    This deliberately uses wall-clock DateTime comparison, NOT Clock.psm1's
    Get-MonotonicSeconds (mirroring Clock.psm1:20-25's own "what this clock is NOT
    for" framing, in reverse): a filesystem LastWriteTime is inherently a wall-clock
    timestamp with calendar meaning, not a boot-relative monotonic duration, so the
    two clocks must never be mixed.

    This function does NOT decide whether the file exists, is in-folder, or whether
    the offset fits its length -- Resolve-ResumeOffset already owns those questions
    (D-14) and is deliberately left unmodified so the locked rotation-crash-resume
    regression test (tests/OffsetStore.Tests.ps1, "resumes the persisted (older)
    file... even when a newer matching sibling file also exists") keeps passing
    unchanged (D-03). This function answers only the NEW question: recent enough to
    be this session? It is kept pure (no Get-Item, no try/catch) -- the call site
    (Plan 02) owns resolving LastWriteTimeUtc and any I/O errors around it.

    .OUTPUTS
    Boolean: $true when 0 <= elapsed seconds <= SessionStaleAfterSeconds (inclusive),
    $false otherwise (including negative elapsed, i.e. clock skew).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [DateTime] $ResolvedFileLastWriteTimeUtc,
        [Parameter(Mandatory)] [DateTime] $NowUtc,
        [Parameter(Mandatory)] [double] $SessionStaleAfterSeconds
    )

    $elapsedSeconds = ($NowUtc - $ResolvedFileLastWriteTimeUtc).TotalSeconds
    return ($elapsedSeconds -ge 0) -and ($elapsedSeconds -le $SessionStaleAfterSeconds)
}

function Get-ResumeSafetyMarginBytes {
    <#
    .SYNOPSIS
    Sizes the resume re-send margin from actual observed conditions instead of a
    guessed fixed constant (D-12), replacing Phase 1's fixed 64 KB
    $resumeSafetyMarginBytes heuristic: margin = ceil(SrtLatencySeconds *
    ObservedBytesPerSecond) + ChunkSizeBytes, rounded UP to the nearest 188-byte
    transport-stream packet boundary, then clamped to [FloorBytes, CeilingBytes].
    When ObservedBytesPerSecond is <= 0 (cold start, no rate observed yet), returns
    ColdStartMarginBytes (Phase 1's old fixed default, reused as the cold value).

    This rounds UP deliberately -- the opposite direction from Restore-PusherOffset's
    persisted-offset floor-down above. The persisted offset floors down because an
    unaligned *load* must never be trusted past what was actually confirmed 188-aligned;
    the resume *margin* rounds up because under-covering the re-send window would skip
    bytes on resume, violating the core zero-content-loss guarantee (D-13's bias to
    re-send over skip). The final seek position is still floored to 188 by the caller,
    so correctness never depends on this function's own alignment -- but rounding up
    here keeps the margin's semantics ("at least this much overlap") predictable for
    logging and tests.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)] [double] $SrtLatencySeconds,
        [Parameter(Mandatory)] [double] $ObservedBytesPerSecond,
        [Parameter(Mandatory)] [long] $ChunkSizeBytes,
        [Parameter(Mandatory)] [long] $FloorBytes,
        [Parameter(Mandatory)] [long] $CeilingBytes,
        [Parameter(Mandatory)] [long] $ColdStartMarginBytes
    )

    if ($ObservedBytesPerSecond -le 0) {
        return $ColdStartMarginBytes
    }

    $rawMargin = [Math]::Ceiling($SrtLatencySeconds * $ObservedBytesPerSecond) + $ChunkSizeBytes
    $alignedMargin = [Math]::Ceiling($rawMargin / $script:TransportStreamPacketSizeBytes) * $script:TransportStreamPacketSizeBytes
    $clampedMargin = [Math]::Max($FloorBytes, [Math]::Min($CeilingBytes, $alignedMargin))
    return [long] $clampedMargin
}

Export-ModuleMember -Function Save-PusherOffset, Restore-PusherOffset, Resolve-ResumeOffset, Test-ResumeStateSameSession, Get-ResumeSafetyMarginBytes

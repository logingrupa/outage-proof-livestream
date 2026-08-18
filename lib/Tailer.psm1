# Tailer.psm1
# Read side of the gapless pipeline (D-23, PUSH-01). Opens the current recording file
# with FileAccess.Read + FileShare.ReadWrite so it never blocks OBS's writer, and
# reads only bytes whose length is stable across 2 consecutive polls, in whole
# 188-byte units (D-15, torn-tail protection, RESEARCH.md Pattern 2). A sharing
# violation on open fails loud -- throws with the offending path, never a silent
# retry (D-02).
#
# Exports: Open-TailerFileStream, Read-StableChunk, Close-Tailer

Set-StrictMode -Version Latest

# Import the logger explicitly (WR-02): Open-TailerFileStream logs on the open-error path,
# so this module must not depend on the caller having imported Logging into the session.
Import-Module (Join-Path $PSScriptRoot 'Logging.psm1')

$script:TransportStreamPacketSizeBytes = 188
$script:DefaultChunkSizeBytes = 65424   # 348 * 188 (D-14)

function Open-TailerFileStream {
    <#
    .SYNOPSIS
    Opens FilePath as a FileStream with FileAccess.Read + FileShare.ReadWrite -- the
    concurrent-writer-safe open proven by spike/Confirm-FileShareTail.ps1. A sharing
    violation on open is never silently retried: it is logged loudly and re-thrown
    with the offending path in the message (D-02, T-01-LOCK).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FilePath
    )

    # FileNotFoundException and DirectoryNotFoundException both derive from IOException,
    # so they MUST be caught before the generic IOException/sharing-violation branch --
    # otherwise a missing recording file (OBS simply not started yet, a very likely
    # operator scenario) gets mislabelled as a sharing violation, misdirecting diagnosis
    # (WR-05). Each rethrow preserves the original exception type and inner exception.
    try {
        $fileStream = [System.IO.FileStream]::new(
            $FilePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
    } catch [System.IO.FileNotFoundException] {
        $notFoundMessage = "Recording file not found at '$FilePath' -- is OBS started and recording? ($($_.Exception.Message))"
        Write-Log -Level Error -Message $notFoundMessage
        throw [System.IO.FileNotFoundException]::new($notFoundMessage, $FilePath, $_.Exception)
    } catch [System.IO.DirectoryNotFoundException] {
        $directoryMissingMessage = "Recording directory does not exist for '$FilePath' -- check the configured recording path ($($_.Exception.Message))"
        Write-Log -Level Error -Message $directoryMissingMessage
        throw [System.IO.DirectoryNotFoundException]::new($directoryMissingMessage, $_.Exception)
    } catch [System.IO.IOException] {
        $sharingViolationMessage = "Sharing violation opening '$FilePath' for tail read: $($_.Exception.Message)"
        Write-Log -Level Error -Message $sharingViolationMessage
        throw [System.IO.IOException]::new($sharingViolationMessage, $_.Exception)
    }

    return $fileStream
}

function Read-StableChunk {
    <#
    .SYNOPSIS
    Reads only bytes observed stable across 2 consecutive polls (this call vs
    LastObservedLength), and only in whole 188-byte units (D-15). Never trusts a
    single-poll Length as safe-to-read.

    .DESCRIPTION
    - The safe-to-read watermark is min(LastObservedLength, currentLength): bytes at or
      below the previous poll's length are settled; bytes written since are the growing
      tail, held back one poll. This progresses against a continuously-growing writer
      (real OBS) instead of stalling until growth pauses.
    - When fewer than 188 settled unread bytes remain past the current Position, returns
      HasStableData=$false -- retry next poll.
    - Otherwise reads a whole-188-multiple chunk capped at ChunkSizeBytes (also floored
      to a 188 multiple, defensively, in case a caller ever passes a non-aligned
      ChunkSizeBytes).

    .OUTPUTS
    Hashtable: HasStableData (bool), NewObservedLength (long), Bytes (byte[] or $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.IO.FileStream] $FileStream,
        [Parameter(Mandatory)] [long] $LastObservedLength,
        [int] $ChunkSizeBytes = $script:DefaultChunkSizeBytes
    )

    # A ChunkSizeBytes under one whole packet would floor $readSize to 0 -> a "stable"
    # empty byte[], which Write-FfmpegStdin's [byte[]] Mandatory binding then rejects with
    # an opaque error mid-loop. Fail loud and specific at the boundary instead (IN-02).
    if ($ChunkSizeBytes -lt $script:TransportStreamPacketSizeBytes) {
        throw "ChunkSizeBytes must be >= $script:TransportStreamPacketSizeBytes (one whole TS packet); got $ChunkSizeBytes"
    }

    $currentLength = $FileStream.Length

    # The safe-to-read watermark is the PREVIOUS poll's observed length: those bytes were
    # seen a full poll ago and are settled on disk. Bytes written SINCE (currentLength
    # beyond LastObservedLength) are the still-growing tail held back one poll for
    # torn-packet protection (D-15). Reading up to the prior watermark -- rather than
    # requiring currentLength == LastObservedLength -- lets the tailer make progress
    # against a CONTINUOUS writer (real OBS never pauses, so its length changes on every
    # poll; the old equality gate then never read a single byte). Min() also caps the
    # watermark at the current length so a truncation/OBS-restart shrink never reads past
    # the new EOF.
    $stableLength = [Math]::Min($LastObservedLength, $currentLength)

    $unreadBytes = $stableLength - $FileStream.Position
    $alignedUnreadBytes = $unreadBytes - ($unreadBytes % $script:TransportStreamPacketSizeBytes)
    if ($alignedUnreadBytes -lt $script:TransportStreamPacketSizeBytes) {
        return @{ HasStableData = $false; NewObservedLength = $currentLength; Bytes = $null }
    }

    $alignedChunkSizeBytes = $ChunkSizeBytes - ($ChunkSizeBytes % $script:TransportStreamPacketSizeBytes)
    # Cast arg1 to [long] so [Math]::Min binds the (Int64,Int64) overload. On a >2GB
    # settled backlog $alignedUnreadBytes exceeds Int32.MaxValue; without the cast
    # PowerShell binds Min(Int32,Int32) from arg1's Int32 type and coercing the multi-GB
    # arg2 to Int32 throws "Value was either too large or too small for an Int32"
    # (int32-overflow-large-backlog). The result is still <= ChunkSizeBytes, so the
    # downstream byte[] alloc and FileStream.Read int args stay in Int32 range.
    $readSize = [Math]::Min([long]$alignedChunkSizeBytes, $alignedUnreadBytes)

    $buffer = New-Object byte[] $readSize
    $bytesRead = $FileStream.Read($buffer, 0, $readSize)

    # FileStream.Read may legally return fewer bytes than requested (e.g. the file was
    # truncated between the Length check and the Read -- an OBS restart race). Align the
    # returned count DOWN to a whole 188-byte multiple and rewind any remainder so the
    # offset never advances mid-packet and no torn TS packet is ever emitted (CR-05).
    $alignedBytesRead = $bytesRead - ($bytesRead % $script:TransportStreamPacketSizeBytes)

    if ($alignedBytesRead -lt $script:TransportStreamPacketSizeBytes) {
        # Fewer than a whole packet actually came back (including the 0-byte truncation
        # case, which would otherwise make $buffer[0..-1] a garbage 2-element slice).
        # Rewind everything read this call and retry next poll.
        if ($bytesRead -gt 0) {
            $FileStream.Seek(-$bytesRead, [System.IO.SeekOrigin]::Current) | Out-Null
        }
        return @{ HasStableData = $false; NewObservedLength = $currentLength; Bytes = $null }
    }

    if ($alignedBytesRead -lt $bytesRead) {
        # A sub-packet remainder trailed a short read: rewind just the remainder so the
        # next read resumes exactly on the packet boundary.
        $FileStream.Seek($alignedBytesRead - $bytesRead, [System.IO.SeekOrigin]::Current) | Out-Null
        $buffer = $buffer[0..($alignedBytesRead - 1)]
    }

    return @{ HasStableData = $true; NewObservedLength = $currentLength; Bytes = $buffer }
}

function Close-Tailer {
    <#
    .SYNOPSIS
    Disposes the FileStream opened by Open-TailerFileStream.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.IO.FileStream] $FileStream
    )

    $FileStream.Dispose()
}

Export-ModuleMember -Function Open-TailerFileStream, Read-StableChunk, Close-Tailer

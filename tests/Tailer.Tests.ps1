BeforeAll {
    $script:LoggingModulePath = Join-Path $PSScriptRoot '../lib/Logging.psm1'
    $script:TailerModulePath = Join-Path $PSScriptRoot '../lib/Tailer.psm1'
    $script:TestHelpersModulePath = Join-Path $PSScriptRoot 'TestHelpers.psm1'
}

Describe 'Tailer' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Tailer -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:TailerModulePath -Force
    }

    AfterEach {
        Remove-Module Tailer -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    Context 'Open-TailerFileStream' {

        It 'opens a normal file with FileAccess.Read and FileShare.ReadWrite, and seeking to a resumed offset positions correctly' {
            $filePath = Join-Path $TestDrive 'normal.ts'
            [System.IO.File]::WriteAllBytes($filePath, (New-Object byte[] 1000))

            $fileStream = Open-TailerFileStream -FilePath $filePath
            try {
                $fileStream.CanRead | Should -BeTrue
                $fileStream.CanWrite | Should -BeFalse

                $fileStream.Seek(376, [System.IO.SeekOrigin]::Begin) | Out-Null
                $fileStream.Position | Should -Be 376
            } finally {
                Close-Tailer -FileStream $fileStream
            }
        }

        It 'throws a FileNotFoundException (not a mislabelled sharing violation) when the recording file does not exist (WR-05)' {
            $missingPath = Join-Path $TestDrive 'never-created.ts'
            Test-Path -LiteralPath $missingPath | Should -BeFalse

            $thrownError = $null
            try {
                Open-TailerFileStream -FilePath $missingPath
            } catch {
                $thrownError = $_
            }

            $thrownError | Should -Not -BeNullOrEmpty
            $thrownError.Exception | Should -BeOfType [System.IO.FileNotFoundException]
            $thrownError.Exception.Message | Should -Match 'not found'
            $thrownError.Exception.Message | Should -Not -Match 'Sharing violation'
        }

        It 'throws a message containing the file path when the file has a deny-share lock (loud, not a silent retry)' {
            $lockedPath = Join-Path $TestDrive 'locked.ts'
            [System.IO.File]::WriteAllBytes($lockedPath, (New-Object byte[] 188))

            $lockingStream = [System.IO.FileStream]::new(
                $lockedPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::None
            )
            try {
                $thrownError = $null
                try {
                    Open-TailerFileStream -FilePath $lockedPath
                } catch {
                    $thrownError = $_
                }

                $thrownError | Should -Not -BeNullOrEmpty
                $thrownError.Exception.Message | Should -Match ([regex]::Escape($lockedPath))
            } finally {
                $lockingStream.Dispose()
            }
        }
    }

    Context 'Read-StableChunk' {

        It 'returns HasStableData=$false and the new observed length when the current length differs from the last observed length' {
            $filePath = Join-Path $TestDrive 'growing.ts'
            [System.IO.File]::WriteAllBytes($filePath, (New-Object byte[] 400))

            $fileStream = [System.IO.FileStream]::new($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $result = Read-StableChunk -FileStream $fileStream -LastObservedLength 0 -ChunkSizeBytes 65424

                $result.HasStableData | Should -BeFalse
                $result.NewObservedLength | Should -Be 400
                $result.Bytes | Should -BeNullOrEmpty
            } finally {
                $fileStream.Dispose()
            }
        }

        It 'reads the settled region (up to the prior observed length) while the file is STILL GROWING -- a continuous writer like real OBS whose length changes every poll must not stall (live-relay regression)' {
            $filePath = Join-Path $TestDrive 'continuously-growing.ts'
            $currentLength = 400 * 188   # what the file is NOW (grew since last poll)
            [System.IO.File]::WriteAllBytes($filePath, (New-Object byte[] $currentLength))

            $priorObservedLength = 200 * 188   # what the previous poll saw -- settled region

            $fileStream = [System.IO.FileStream]::new($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                # currentLength (75200) differs from LastObservedLength (37600) because the
                # writer never paused. The old equality gate returned no data here forever;
                # the fix reads up to the settled prior watermark instead.
                $result = Read-StableChunk -FileStream $fileStream -LastObservedLength $priorObservedLength -ChunkSizeBytes 65424

                $result.HasStableData | Should -BeTrue
                $result.Bytes.Length | Should -Be $priorObservedLength   # 37600 < 65424 chunk cap, so the whole settled region
                ($result.Bytes.Length % 188) | Should -Be 0
                $result.NewObservedLength | Should -Be $currentLength
                # never read into the still-growing tail beyond the prior watermark
                $fileStream.Position | Should -BeLessOrEqual $priorObservedLength
            } finally {
                $fileStream.Dispose()
            }
        }

        It 'returns HasStableData=$false (retry next poll) when length is stable but fewer than 188 unread bytes remain' {
            $filePath = Join-Path $TestDrive 'stable-small.ts'
            [System.IO.File]::WriteAllBytes($filePath, (New-Object byte[] 187))

            $fileStream = [System.IO.FileStream]::new($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $result = Read-StableChunk -FileStream $fileStream -LastObservedLength 187 -ChunkSizeBytes 65424

                $result.HasStableData | Should -BeFalse
                $result.NewObservedLength | Should -Be 187
            } finally {
                $fileStream.Dispose()
            }
        }

        It 'returns a whole-188-multiple chunk, capped at the configured chunk size, when length is stable with >= 188 unread bytes' {
            $filePath = Join-Path $TestDrive 'stable-large.ts'
            $totalBytes = 500 * 188   # larger than the default 348*188 chunk size

            [System.IO.File]::WriteAllBytes($filePath, (New-Object byte[] $totalBytes))

            $fileStream = [System.IO.FileStream]::new($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $result = Read-StableChunk -FileStream $fileStream -LastObservedLength $totalBytes -ChunkSizeBytes 65424

                $result.HasStableData | Should -BeTrue
                $result.Bytes.Length | Should -Be 65424
                ($result.Bytes.Length % 188) | Should -Be 0
            } finally {
                $fileStream.Dispose()
            }
        }

        It 'aligns the returned chunk down to the nearest whole 188-byte multiple when available bytes are not an exact multiple' {
            $filePath = Join-Path $TestDrive 'stable-partial.ts'
            $totalBytes = 300   # 1*188 + 112 remainder

            [System.IO.File]::WriteAllBytes($filePath, (New-Object byte[] $totalBytes))

            $fileStream = [System.IO.FileStream]::new($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $result = Read-StableChunk -FileStream $fileStream -LastObservedLength $totalBytes -ChunkSizeBytes 65424

                $result.HasStableData | Should -BeTrue
                $result.Bytes.Length | Should -Be 188
            } finally {
                $fileStream.Dispose()
            }
        }

        It 'never returns a byte count that is not a multiple of 188, across repeated calls advancing Position' {
            $filePath = Join-Path $TestDrive 'stable-sequence.ts'
            $totalBytes = 1000 * 188

            [System.IO.File]::WriteAllBytes($filePath, (New-Object byte[] $totalBytes))

            $fileStream = [System.IO.FileStream]::new($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $chunkSizeBytes = 65424   # 348*188
                for ($call = 0; $call -lt 3; $call++) {
                    $result = Read-StableChunk -FileStream $fileStream -LastObservedLength $totalBytes -ChunkSizeBytes $chunkSizeBytes
                    $result.HasStableData | Should -BeTrue
                    ($result.Bytes.Length % 188) | Should -Be 0
                }
            } finally {
                $fileStream.Dispose()
            }
        }
    }

    Context 'Large backlog beyond Int32.MaxValue (int32-overflow-large-backlog regression)' {

        It 'reads a chunk capped at ChunkSizeBytes without an Int32-overflow crash when the settled unread backlog exceeds Int32.MaxValue (>2GB outage buffer)' {
            # A >2GB settled unread backlog is the CORE resilience scenario: a long outage
            # grows the disk buffer past Int32.MaxValue (2147483647). Read-StableChunk must
            # still return a capped chunk instead of crashing on [Math]::Min overload
            # resolution (lib/Tailer.psm1:117). Build the backlog as an NTFS sparse file so
            # the test stays fast and allocates no real multi-GB on disk: SetLength moves EOF
            # past 2^31 bytes; sparse regions read back as zeros instantly.
            $largeBacklogPath = Join-Path $TestDrive 'huge-backlog.ts'

            $createStream = [System.IO.FileStream]::new($largeBacklogPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
            $createStream.Dispose()
            fsutil sparse setflag $largeBacklogPath | Out-Null

            $hugeBacklogLength = [int64]3000000000   # ~2.79 GB, comfortably past Int32.MaxValue
            $extendStream = [System.IO.FileStream]::new($largeBacklogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
            $extendStream.SetLength($hugeBacklogLength)
            $extendStream.Dispose()

            $fileStream = [System.IO.FileStream]::new($largeBacklogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                # LastObservedLength == current length and Position 0 => the whole >2GB file is
                # settled, unread backlog. alignedUnreadBytes exceeds Int32.MaxValue and must
                # not crash the [Math]::Min at Tailer.psm1:117.
                $result = Read-StableChunk -FileStream $fileStream -LastObservedLength $hugeBacklogLength -ChunkSizeBytes 65424

                $result.HasStableData | Should -BeTrue
                $result.Bytes.Length | Should -Be 65424           # capped at chunk size, not the 2GB backlog
                ($result.Bytes.Length % 188) | Should -Be 0
            } finally {
                $fileStream.Dispose()
            }
        }
    }

    Context 'ChunkSizeBytes validation (IN-02)' {

        It 'throws a specific error when ChunkSizeBytes is below one whole 188-byte packet' {
            $filePath = Join-Path $TestDrive 'guard-chunk.ts'
            [System.IO.File]::WriteAllBytes($filePath, (New-Object byte[] 376))

            $fileStream = [System.IO.FileStream]::new($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                { Read-StableChunk -FileStream $fileStream -LastObservedLength 376 -ChunkSizeBytes 100 } |
                    Should -Throw -ExpectedMessage '*must be >= 188*'
            } finally {
                $fileStream.Dispose()
            }
        }
    }

    Context 'Default chunk size (D-14)' {

        It 'defaults ChunkSizeBytes to 65424 (348*188) when not explicitly supplied' {
            $filePath = Join-Path $TestDrive 'default-chunk.ts'
            $totalBytes = 500 * 188

            [System.IO.File]::WriteAllBytes($filePath, (New-Object byte[] $totalBytes))

            $fileStream = [System.IO.FileStream]::new($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $result = Read-StableChunk -FileStream $fileStream -LastObservedLength $totalBytes

                $result.Bytes.Length | Should -Be 65424
            } finally {
                $fileStream.Dispose()
            }
        }
    }
}

Describe 'Tailer against a live synthetic writer' -Tag 'Integration' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Tailer -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:TailerModulePath -Force
        Import-Module $script:TestHelpersModulePath -Force
    }

    AfterEach {
        Remove-Module Tailer -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'opens without a sharing violation and reads growing, 188-aligned data while the writer holds the file open, never blocking the writer, with no skip/reorder' {
        $targetFilePath = Join-Path $TestDrive 'live-writer.ts'

        $writer = Start-SyntheticMpegtsWriter -TargetFilePath $targetFilePath -IntervalMilliseconds 200 -ChunkPacketCount 20 -TotalDurationSeconds 8

        try {
            # Wait for the writer to create the file before the Tailer opens it.
            $fileCreationTimeoutSeconds = 5
            $fileCreationStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $targetFilePath)) {
                if ($fileCreationStopwatch.Elapsed.TotalSeconds -gt $fileCreationTimeoutSeconds) {
                    throw "Synthetic writer did not create '$targetFilePath' within $fileCreationTimeoutSeconds seconds"
                }
                Start-Sleep -Milliseconds 100
            }

            $openDidNotThrow = $true
            $tailerFileStream = $null
            try {
                $tailerFileStream = Open-TailerFileStream -FilePath $targetFilePath
            } catch {
                $openDidNotThrow = $false
            }
            $openDidNotThrow | Should -BeTrue

            $accumulatedBytes = [System.Collections.Generic.List[byte]]::new()
            $lastObservedLength = 0
            $pollDeadline = (Get-Date).AddSeconds(3)

            # Poll faster than the writer's flush interval (200ms) so this loop can
            # actually observe the same length across 2 consecutive polls during the
            # idle window between writer flushes -- otherwise reader/writer cadence
            # can lock-step and the length never appears stable within the window.
            while ((Get-Date) -lt $pollDeadline) {
                $chunkResult = Read-StableChunk -FileStream $tailerFileStream -LastObservedLength $lastObservedLength -ChunkSizeBytes 65424
                $lastObservedLength = $chunkResult.NewObservedLength
                if ($chunkResult.HasStableData -and $chunkResult.Bytes) {
                    $accumulatedBytes.AddRange([byte[]]$chunkResult.Bytes)
                }
                Start-Sleep -Milliseconds 30
            }

            $finalWriterFileLength = (Get-Item -LiteralPath $targetFilePath).Length

            Close-Tailer -FileStream $tailerFileStream
        } finally {
            Stop-SyntheticMpegtsWriter -Writer $writer
        }

        # The writer must have kept growing the file throughout the tail — proving the
        # reader never blocked it.
        $finalWriterFileLength | Should -BeGreaterThan 0

        # Accumulated bytes must be 188-aligned in total (no torn packets ever accepted).
        ($accumulatedBytes.Count % 188) | Should -Be 0
        $accumulatedBytes.Count | Should -BeGreaterThan 0

        # No skip/reorder: the accumulated prefix must byte-match the corresponding
        # prefix of the source file.
        $sourceBytes = [System.IO.File]::ReadAllBytes($targetFilePath)
        for ($index = 0; $index -lt $accumulatedBytes.Count; $index++) {
            $accumulatedBytes[$index] | Should -Be $sourceBytes[$index]
        }
    }
}

BeforeAll {
    $script:LoggingModulePath = Join-Path $PSScriptRoot '../lib/Logging.psm1'
    $script:OffsetStoreModulePath = Join-Path $PSScriptRoot '../lib/OffsetStore.psm1'
}

Describe 'OffsetStore' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module OffsetStore -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:OffsetStoreModulePath -Force

        $script:StateDirectory = Join-Path $TestDrive 'state'
        $script:StateFilePath = Join-Path $script:StateDirectory 'offset.json'
        New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
    }

    AfterEach {
        Remove-Module OffsetStore -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'round-trips file and byteOffset exactly for an aligned offset' {
        Save-PusherOffset -StateFilePath $script:StateFilePath -RecordingFilePath 'D:\recording.ts' -ByteOffset 37600

        $restored = Restore-PusherOffset -StateFilePath $script:StateFilePath

        $restored.file | Should -Be 'D:\recording.ts'
        $restored.byteOffset | Should -Be 37600
    }

    It 'floors a non-188-aligned persisted offset to the nearest 188 multiple and logs a Warning' {
        $payload = @{ file = 'D:\recording.ts'; byteOffset = 100001 } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($script:StateFilePath, $payload)

        $restored = Restore-PusherOffset -StateFilePath $script:StateFilePath -WarningAction SilentlyContinue -WarningVariable capturedWarnings

        $restored.byteOffset | Should -Be 99828
        $capturedWarnings.Count | Should -BeGreaterThan 0
    }

    It 'returns the safe default with a Warning log and does not throw when the state file is missing' {
        Remove-Item -LiteralPath $script:StateFilePath -ErrorAction SilentlyContinue
        Test-Path -LiteralPath $script:StateFilePath | Should -BeFalse

        # Called directly (not wrapped in a scriptblock) so a thrown exception fails
        # this It block on its own -- and -WarningVariable stays visible in this scope.
        $restored = Restore-PusherOffset -StateFilePath $script:StateFilePath -WarningAction SilentlyContinue -WarningVariable capturedWarnings

        $restored.byteOffset | Should -Be 0
        $restored.file | Should -BeNullOrEmpty
        $capturedWarnings.Count | Should -BeGreaterThan 0
    }

    It 'returns the safe default with an Error log and does not throw when the state file is corrupt/truncated' {
        [System.IO.File]::WriteAllText($script:StateFilePath, '{ "file": "D:\recording.ts", "byteOff')

        # Called directly (not wrapped in a scriptblock) so a thrown exception fails
        # this It block on its own -- and -ErrorVariable stays visible in this scope.
        $restored = Restore-PusherOffset -StateFilePath $script:StateFilePath -ErrorAction SilentlyContinue -ErrorVariable capturedErrors

        $restored.byteOffset | Should -Be 0
        $capturedErrors.Count | Should -BeGreaterThan 0
    }

    It 'rejects a negative persisted offset and falls back to byte 0 with an Error log (WR-04)' {
        # PowerShell's % preserves the dividend sign, so a tampered/corrupt negative
        # offset must be rejected outright rather than "floored" to another negative.
        $payload = @{ file = 'D:\recording.ts'; byteOffset = -1000 } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($script:StateFilePath, $payload)

        $restored = Restore-PusherOffset -StateFilePath $script:StateFilePath -ErrorAction SilentlyContinue -ErrorVariable capturedErrors

        $restored.byteOffset | Should -Be 0
        $restored.file | Should -BeNullOrEmpty
        $capturedErrors.Count | Should -BeGreaterThan 0
    }

    It 'falls back to byte 0 for a non-numeric persisted offset (WR-04)' {
        $payload = @{ file = 'D:\recording.ts'; byteOffset = 'not-a-number' } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($script:StateFilePath, $payload)

        $restored = Restore-PusherOffset -StateFilePath $script:StateFilePath -ErrorAction SilentlyContinue

        $restored.byteOffset | Should -Be 0
    }

    Context 'Resolve-ResumeOffset (D-14 post-rotation resume reconciler)' {

        BeforeEach {
            $script:RecordingFolder = Join-Path $TestDrive 'recordings'
            New-Item -ItemType Directory -Path $script:RecordingFolder -Force | Out-Null

            $script:PersistedFilePath = Join-Path $script:RecordingFolder 'recording-001.ts'
            [System.IO.File]::WriteAllBytes($script:PersistedFilePath, [byte[]]::new(100000))
        }

        It 'resumes the persisted (older) file at its persisted offset even when a newer matching sibling file also exists (D-13/D-14)' {
            $newerSiblingPath = Join-Path $script:RecordingFolder 'recording-002.ts'
            [System.IO.File]::WriteAllBytes($newerSiblingPath, [byte[]]::new(500))

            $restored = @{ file = $script:PersistedFilePath; byteOffset = 37600 }

            $resolved = Resolve-ResumeOffset -RestoredState $restored -RecordingFolderPath $script:RecordingFolder

            $resolved.file | Should -Be $script:PersistedFilePath
            $resolved.byteOffset | Should -Be 37600
        }

        It 'returns file=$null, byteOffset=0 with a Warning when the persisted file no longer exists (deleted/moved)' {
            $missingFilePath = Join-Path $script:RecordingFolder 'gone.ts'
            $restored = @{ file = $missingFilePath; byteOffset = 37600 }

            $resolved = Resolve-ResumeOffset -RestoredState $restored -RecordingFolderPath $script:RecordingFolder -WarningAction SilentlyContinue -WarningVariable capturedWarnings

            $resolved.file | Should -BeNullOrEmpty
            $resolved.byteOffset | Should -Be 0
            $capturedWarnings.Count | Should -BeGreaterThan 0
        }

        It 'resets to byteOffset=0 (keeping the persisted file) with a Warning when the persisted offset exceeds the persisted files own current length' {
            $restored = @{ file = $script:PersistedFilePath; byteOffset = 500000 }

            $resolved = Resolve-ResumeOffset -RestoredState $restored -RecordingFolderPath $script:RecordingFolder -WarningAction SilentlyContinue -WarningVariable capturedWarnings

            $resolved.file | Should -Be $script:PersistedFilePath
            $resolved.byteOffset | Should -Be 0
            $capturedWarnings.Count | Should -BeGreaterThan 0
        }

        It 'returns file=$null, byteOffset=0 when the persisted file field is $null (fresh safe-default state)' {
            $restored = @{ file = $null; byteOffset = 0 }

            $resolved = Resolve-ResumeOffset -RestoredState $restored -RecordingFolderPath $script:RecordingFolder

            $resolved.file | Should -BeNullOrEmpty
            $resolved.byteOffset | Should -Be 0
        }

        It 'returns file=$null, byteOffset=0 when the persisted file field is empty string' {
            $restored = @{ file = ''; byteOffset = 0 }

            $resolved = Resolve-ResumeOffset -RestoredState $restored -RecordingFolderPath $script:RecordingFolder

            $resolved.file | Should -BeNullOrEmpty
            $resolved.byteOffset | Should -Be 0
        }

        It 'treats a persisted path outside RecordingFolderPath as missing and resets to file=$null (T-03-04 traversal guard)' {
            $outsideFolder = Join-Path $TestDrive 'outside'
            New-Item -ItemType Directory -Path $outsideFolder -Force | Out-Null
            $outsidePath = Join-Path $outsideFolder 'recording-elsewhere.ts'
            [System.IO.File]::WriteAllBytes($outsidePath, [byte[]]::new(1000))

            $restored = @{ file = $outsidePath; byteOffset = 100 }

            $resolved = Resolve-ResumeOffset -RestoredState $restored -RecordingFolderPath $script:RecordingFolder -WarningAction SilentlyContinue -WarningVariable capturedWarnings

            $resolved.file | Should -BeNullOrEmpty
            $resolved.byteOffset | Should -Be 0
            $capturedWarnings.Count | Should -BeGreaterThan 0
        }

        It 'never throws on any persisted-state shape' {
            {
                Resolve-ResumeOffset -RestoredState @{ file = $null; byteOffset = 0 } -RecordingFolderPath $script:RecordingFolder -WarningAction SilentlyContinue
            } | Should -Not -Throw
        }

        It 'runs the traversal boundary check BEFORE Test-Path/Get-Item ever touches the filesystem, even for a non-existent out-of-folder path (WR-02)' {
            # Deliberately never created on disk -- Test-Path -LiteralPath $outsidePath
            # would also return $false, so if the boundary check ran AFTER Test-Path
            # (the pre-WR-02 ordering), this would still surface as the generic
            # "missing" warning rather than the "outside recording folder" one --
            # masking the real reason and still probing the filesystem with the raw,
            # unvalidated path first.
            $outsideFolder = Join-Path $TestDrive 'outside-nonexistent'
            $outsidePath = Join-Path $outsideFolder 'recording-elsewhere.ts'

            $restored = @{ file = $outsidePath; byteOffset = 100 }

            $resolved = Resolve-ResumeOffset -RestoredState $restored -RecordingFolderPath $script:RecordingFolder -WarningAction SilentlyContinue -WarningVariable capturedWarnings

            $resolved.file | Should -BeNullOrEmpty
            $resolved.byteOffset | Should -Be 0
            $capturedWarnings.Count | Should -BeGreaterThan 0
            ($capturedWarnings[0] -match 'outside recording folder') | Should -BeTrue -Because 'WR-02: the traversal boundary check must run before Test-Path, so an out-of-folder path is rejected for THAT reason even when it also happens not to exist'
        }

        It 'returns the safe default without throwing when Get-Item throws mid-resolution (WR-01 never-throws contract, e.g. a TOCTOU race)' {
            # Simulates the exact TOCTOU race WR-01 describes: Test-Path succeeds
            # (the file exists at that instant), but a concurrent cleanup/AV process
            # deletes it before the later Get-Item.Length read -- which would
            # otherwise throw an uncaught ItemNotFoundException straight through
            # Start-Pusher, crashing the whole script at startup.
            Mock -ModuleName OffsetStore Get-Item {
                throw [System.Management.Automation.ItemNotFoundException]::new('simulated TOCTOU race: file vanished between Test-Path and Get-Item')
            }

            $restored = @{ file = $script:PersistedFilePath; byteOffset = 100 }

            # Called directly (not wrapped in a scriptblock) so a thrown exception
            # fails this It block on its own, and $resolved/-WarningVariable stay
            # visible in this scope (matching the convention already used above for
            # Restore-PusherOffset's own never-throws tests).
            $resolved = Resolve-ResumeOffset -RestoredState $restored -RecordingFolderPath $script:RecordingFolder -WarningAction SilentlyContinue -WarningVariable capturedWarnings

            $resolved.file | Should -BeNullOrEmpty
            $resolved.byteOffset | Should -Be 0
            $capturedWarnings.Count | Should -BeGreaterThan 0
        }
    }

    It 'writes to a temp path then atomically renames over the destination, leaving no partial temp file and preserving a clean final replace' {
        Save-PusherOffset -StateFilePath $script:StateFilePath -RecordingFilePath 'D:\recording.ts' -ByteOffset 188

        Save-PusherOffset -StateFilePath $script:StateFilePath -RecordingFilePath 'D:\recording.ts' -ByteOffset 376

        $restored = Restore-PusherOffset -StateFilePath $script:StateFilePath
        $restored.byteOffset | Should -Be 376
        (Get-ChildItem -Path $script:StateDirectory -Filter 'offset.*.tmp').Count | Should -Be 0
    }

    Context 'Get-ResumeSafetyMarginBytes (D-12 latency-derived resume margin)' {

        It 'computes ceil(latencySeconds x observedBytesPerSecond) + oneChunk, rounded UP to the nearest 188, within the clamp' {
            $margin = Get-ResumeSafetyMarginBytes -SrtLatencySeconds 0.5 -ObservedBytesPerSecond 1000000 `
                -ChunkSizeBytes 65424 -FloorBytes 65424 -CeilingBytes 4000000 -ColdStartMarginBytes 65424

            # raw = ceil(0.5 * 1_000_000) + 65424 = 500000 + 65424 = 565424
            # 565424 / 188 = 3007.5744... -> ceil = 3008 -> 3008 * 188 = 565504
            $margin | Should -Be 565504
        }

        It 'returns the cold-start margin when observedBytesPerSecond is 0 (D-12)' {
            $margin = Get-ResumeSafetyMarginBytes -SrtLatencySeconds 0.5 -ObservedBytesPerSecond 0 `
                -ChunkSizeBytes 65424 -FloorBytes 65424 -CeilingBytes 4000000 -ColdStartMarginBytes 65424

            $margin | Should -Be 65424
        }

        It 'clamps UP to FloorBytes when the computed margin would fall below the floor (never below one chunk, D-12)' {
            $margin = Get-ResumeSafetyMarginBytes -SrtLatencySeconds 0.001 -ObservedBytesPerSecond 100 `
                -ChunkSizeBytes 0 -FloorBytes 65424 -CeilingBytes 4000000 -ColdStartMarginBytes 65424

            $margin | Should -Be 65424
        }

        It 'clamps DOWN to CeilingBytes when the computed margin would exceed the ceiling (bounded over-send)' {
            $margin = Get-ResumeSafetyMarginBytes -SrtLatencySeconds 10 -ObservedBytesPerSecond 100000000 `
                -ChunkSizeBytes 65424 -FloorBytes 65424 -CeilingBytes 4000000 -ColdStartMarginBytes 65424

            $margin | Should -Be 4000000
        }

        It 'always returns a multiple of 188 (188-aligned, rounded up)' {
            $margin = Get-ResumeSafetyMarginBytes -SrtLatencySeconds 0.37 -ObservedBytesPerSecond 123457 `
                -ChunkSizeBytes 65424 -FloorBytes 65424 -CeilingBytes 4000000 -ColdStartMarginBytes 65424

            ($margin % 188) | Should -Be 0
        }

        It 'does not throw when observedBytesPerSecond is 0' {
            {
                Get-ResumeSafetyMarginBytes -SrtLatencySeconds 0.5 -ObservedBytesPerSecond 0 `
                    -ChunkSizeBytes 65424 -FloorBytes 65424 -CeilingBytes 4000000 -ColdStartMarginBytes 65424
            } | Should -Not -Throw
        }
    }

    Context 'Test-ResumeStateSameSession (SESS-01)' {

        It 'returns $true for a fresh file (elapsed 10s, window 1800s)' {
            $nowUtc = [DateTime]::UtcNow
            $lastWriteTimeUtc = $nowUtc.AddSeconds(-10)

            $result = Test-ResumeStateSameSession -ResolvedFileLastWriteTimeUtc $lastWriteTimeUtc -NowUtc $nowUtc -SessionStaleAfterSeconds 1800

            $result | Should -BeTrue
        }

        It 'returns $false for a stale file (elapsed 46800s / 13h, window 1800s)' {
            $nowUtc = [DateTime]::UtcNow
            $lastWriteTimeUtc = $nowUtc.AddSeconds(-46800)

            $result = Test-ResumeStateSameSession -ResolvedFileLastWriteTimeUtc $lastWriteTimeUtc -NowUtc $nowUtc -SessionStaleAfterSeconds 1800

            $result | Should -BeFalse
        }

        It 'returns $true at the exact boundary (elapsed == SessionStaleAfterSeconds, inclusive -le)' {
            $nowUtc = [DateTime]::UtcNow
            $lastWriteTimeUtc = $nowUtc.AddSeconds(-1800)

            $result = Test-ResumeStateSameSession -ResolvedFileLastWriteTimeUtc $lastWriteTimeUtc -NowUtc $nowUtc -SessionStaleAfterSeconds 1800

            $result | Should -BeTrue
        }

        It 'returns $false for negative elapsed time (LastWriteTimeUtc slightly in the future vs NowUtc, clock skew)' {
            $nowUtc = [DateTime]::UtcNow
            $lastWriteTimeUtc = $nowUtc.AddSeconds(5)

            $result = Test-ResumeStateSameSession -ResolvedFileLastWriteTimeUtc $lastWriteTimeUtc -NowUtc $nowUtc -SessionStaleAfterSeconds 1800

            $result | Should -BeFalse
        }

        It 'returns $true for a real just-created temp files LastWriteTimeUtc vs [DateTime]::UtcNow with window 1800' {
            $tempFilePath = Join-Path $TestDrive ("session-freshness-{0}.tmp" -f [Guid]::NewGuid())
            [System.IO.File]::WriteAllText($tempFilePath, 'x')

            $lastWriteTimeUtc = (Get-Item -LiteralPath $tempFilePath).LastWriteTimeUtc

            $result = Test-ResumeStateSameSession -ResolvedFileLastWriteTimeUtc $lastWriteTimeUtc -NowUtc ([DateTime]::UtcNow) -SessionStaleAfterSeconds 1800

            $result | Should -BeTrue
        }
    }
}

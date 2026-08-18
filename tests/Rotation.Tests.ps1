BeforeAll {
    $script:LoggingModulePath = Join-Path $PSScriptRoot '../lib/Logging.psm1'
    $script:RotationModulePath = Join-Path $PSScriptRoot '../lib/Rotation.psm1'
}

Describe 'Rotation' -Tag 'Quick' {

    BeforeEach {
        Remove-Module Rotation -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:RotationModulePath -Force
    }

    AfterEach {
        Remove-Module Rotation -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
    }

    Context 'Test-RotationDetected' {

        It 'returns $true when the newest file path differs from the current path (D-02 positive signal)' {
            $newestFile = [PSCustomObject]@{ FullName = 'C:\state\b.ts' }
            Test-RotationDetected -NewestFile $newestFile -CurrentFilePath 'C:\state\a.ts' | Should -Be $true
        }

        It 'returns $false when the newest file path equals the current path (no rotation)' {
            $newestFile = [PSCustomObject]@{ FullName = 'C:\state\a.ts' }
            Test-RotationDetected -NewestFile $newestFile -CurrentFilePath 'C:\state\a.ts' | Should -Be $false
        }
    }

    Context 'Get-NewestMatchingRecordingFile' {

        It 'returns the FileInfo with the newest LastWriteTime among files matching the glob' {
            $olderFilePath = Join-Path $TestDrive 'recording-01.ts'
            $newerFilePath = Join-Path $TestDrive 'recording-02.ts'
            Set-Content -LiteralPath $olderFilePath -Value 'old'
            Set-Content -LiteralPath $newerFilePath -Value 'new'

            (Get-Item -LiteralPath $olderFilePath).LastWriteTime = (Get-Date).AddMinutes(-10)
            (Get-Item -LiteralPath $newerFilePath).LastWriteTime = (Get-Date)

            $result = Get-NewestMatchingRecordingFile -RecordingFolderPath $TestDrive -RecordingFilenameGlob '*.ts'

            $result.FullName | Should -Be $newerFilePath
        }

        It 'returns $null when the folder has no matching file' {
            $emptyFolderPath = Join-Path $TestDrive 'empty-folder'
            New-Item -ItemType Directory -Path $emptyFolderPath -Force | Out-Null

            $result = Get-NewestMatchingRecordingFile -RecordingFolderPath $emptyFolderPath -RecordingFilenameGlob '*.ts'

            $result | Should -BeNullOrEmpty
        }
    }

    Context 'Test-RecordingFileFresh (260809-ow9, START-STALE-01)' {

        It 'returns $true when mtime is 10s before NowUtc and the threshold is 300s' {
            $nowUtc = [DateTime]::UtcNow
            $fileLastWriteTimeUtc = $nowUtc.AddSeconds(-10)

            Test-RecordingFileFresh -FileLastWriteTimeUtc $fileLastWriteTimeUtc -NowUtc $nowUtc -StaleAfterSeconds 300 | Should -BeTrue
        }

        It 'returns $false when mtime is 3000s before NowUtc and the threshold is 300s' {
            $nowUtc = [DateTime]::UtcNow
            $fileLastWriteTimeUtc = $nowUtc.AddSeconds(-3000)

            Test-RecordingFileFresh -FileLastWriteTimeUtc $fileLastWriteTimeUtc -NowUtc $nowUtc -StaleAfterSeconds 300 | Should -BeFalse
        }

        It 'returns $true when elapsed seconds exactly equal the threshold (inclusive, mirrors Test-ResumeStateSameSession)' {
            $nowUtc = [DateTime]::UtcNow
            $fileLastWriteTimeUtc = $nowUtc.AddSeconds(-300)

            Test-RecordingFileFresh -FileLastWriteTimeUtc $fileLastWriteTimeUtc -NowUtc $nowUtc -StaleAfterSeconds 300 | Should -BeTrue
        }

        It 'returns $false when mtime is in the future relative to NowUtc (negative elapsed / clock skew)' {
            $nowUtc = [DateTime]::UtcNow
            $fileLastWriteTimeUtc = $nowUtc.AddSeconds(10)

            Test-RecordingFileFresh -FileLastWriteTimeUtc $fileLastWriteTimeUtc -NowUtc $nowUtc -StaleAfterSeconds 300 | Should -BeFalse
        }

        It 'returns $true for a stale mtime when CurrentLengthBytes is greater than PreviousLengthBytes (demonstrably growing)' {
            $nowUtc = [DateTime]::UtcNow
            $fileLastWriteTimeUtc = $nowUtc.AddSeconds(-3000)

            Test-RecordingFileFresh -FileLastWriteTimeUtc $fileLastWriteTimeUtc -NowUtc $nowUtc -StaleAfterSeconds 300 `
                -PreviousLengthBytes 1000 -CurrentLengthBytes 2000 | Should -BeTrue
        }

        It 'returns $false for a stale mtime when PreviousLengthBytes is $null (no prior observation this wait -- never votes false-positive)' {
            $nowUtc = [DateTime]::UtcNow
            $fileLastWriteTimeUtc = $nowUtc.AddSeconds(-3000)

            Test-RecordingFileFresh -FileLastWriteTimeUtc $fileLastWriteTimeUtc -NowUtc $nowUtc -StaleAfterSeconds 300 `
                -PreviousLengthBytes $null -CurrentLengthBytes 2000 | Should -BeFalse
        }

        It 'returns $false for a stale mtime when CurrentLengthBytes equals PreviousLengthBytes (not growing)' {
            $nowUtc = [DateTime]::UtcNow
            $fileLastWriteTimeUtc = $nowUtc.AddSeconds(-3000)

            Test-RecordingFileFresh -FileLastWriteTimeUtc $fileLastWriteTimeUtc -NowUtc $nowUtc -StaleAfterSeconds 300 `
                -PreviousLengthBytes 2000 -CurrentLengthBytes 2000 | Should -BeFalse
        }

        It 'returns $false for a stale mtime when CurrentLengthBytes is less than PreviousLengthBytes (file replaced/truncated)' {
            $nowUtc = [DateTime]::UtcNow
            $fileLastWriteTimeUtc = $nowUtc.AddSeconds(-3000)

            Test-RecordingFileFresh -FileLastWriteTimeUtc $fileLastWriteTimeUtc -NowUtc $nowUtc -StaleAfterSeconds 300 `
                -PreviousLengthBytes 2000 -CurrentLengthBytes 1000 | Should -BeFalse
        }
    }

    Context 'Get-RecordingFileLiveMetadata (260816-g70, START-STALE-02)' {

        BeforeAll {
            function Start-G70HeldOpenTestWriterProcess {
                <#
                .SYNOPSIS
                Background pwsh process that opens TargetFilePath with FileMode.Create,
                FileAccess.Write, FileShare.ReadWrite, writes one ChunkSizeBytes chunk
                immediately, then either holds the handle open with no further writes
                (-WriteOnce, for a stable/exact-length fixture) or keeps appending an
                identical chunk every IntervalMilliseconds (default, for a growing-file
                fixture) -- but NEVER closes the handle until stopped or
                TotalDurationSeconds elapses (a generous safety net, not the real
                teardown path).
                #>
                param(
                    [Parameter(Mandatory)] [string] $TargetFilePath,
                    [Parameter(Mandatory)] [int] $ChunkSizeBytes,
                    [int] $IntervalMilliseconds = 100,
                    [int] $TotalDurationSeconds = 60,
                    [switch] $WriteOnce
                )

                $scratchDirectoryPath = Join-Path $env:TEMP ("g70-held-open-writer-{0}" -f ([Guid]::NewGuid()))
                New-Item -ItemType Directory -Path $scratchDirectoryPath -Force | Out-Null
                $writerScriptFilePath = Join-Path $scratchDirectoryPath 'Write-HeldOpen.ps1'

                $writerScriptContent = @'
param(
    [Parameter(Mandatory)] [string] $TargetFilePath,
    [Parameter(Mandatory)] [int] $ChunkSizeBytes,
    [int] $IntervalMilliseconds = 100,
    [int] $TotalDurationSeconds = 60,
    [switch] $WriteOnce
)
$ErrorActionPreference = 'Stop'
$targetStream = [System.IO.FileStream]::new($TargetFilePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
try {
    $buffer = New-Object byte[] $ChunkSizeBytes
    (New-Object Random).NextBytes($buffer)
    $targetStream.Write($buffer, 0, $buffer.Length)
    $targetStream.Flush($true)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TotalDurationSeconds) {
        if (-not $WriteOnce) {
            $targetStream.Write($buffer, 0, $buffer.Length)
            $targetStream.Flush($true)
        }
        Start-Sleep -Milliseconds $IntervalMilliseconds
    }
} finally {
    $targetStream.Dispose()
}
'@
                Set-Content -LiteralPath $writerScriptFilePath -Value $writerScriptContent -Encoding utf8

                $processArguments = @(
                    '-NoProfile', '-NonInteractive', '-File', $writerScriptFilePath,
                    '-TargetFilePath', $TargetFilePath,
                    '-ChunkSizeBytes', $ChunkSizeBytes,
                    '-IntervalMilliseconds', $IntervalMilliseconds,
                    '-TotalDurationSeconds', $TotalDurationSeconds
                )
                if ($WriteOnce) { $processArguments += '-WriteOnce' }

                $writerProcess = Start-Process -FilePath 'pwsh' -ArgumentList $processArguments -WindowStyle Hidden -PassThru
                return [PSCustomObject]@{ Process = $writerProcess; ScratchDirectory = $scratchDirectoryPath }
            }

            function Start-G70ExclusiveLockTestProcess {
                <#
                .SYNOPSIS
                Background pwsh process that opens TargetFilePath with FileShare.None
                (never ReadWrite) and holds it for HoldDurationSeconds -- simulates
                "another process has this file exclusively locked" for the
                never-crashes-on-a-locked-file case.
                #>
                param(
                    [Parameter(Mandatory)] [string] $TargetFilePath,
                    [int] $HoldDurationSeconds = 60
                )

                $scratchDirectoryPath = Join-Path $env:TEMP ("g70-exclusive-lock-{0}" -f ([Guid]::NewGuid()))
                New-Item -ItemType Directory -Path $scratchDirectoryPath -Force | Out-Null
                $lockScriptFilePath = Join-Path $scratchDirectoryPath 'Hold-ExclusiveLock.ps1'

                $lockScriptContent = @'
param(
    [Parameter(Mandatory)] [string] $TargetFilePath,
    [int] $HoldDurationSeconds = 60
)
$ErrorActionPreference = 'Stop'
$stream = [System.IO.FileStream]::new($TargetFilePath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {
    Start-Sleep -Seconds $HoldDurationSeconds
} finally {
    $stream.Dispose()
}
'@
                Set-Content -LiteralPath $lockScriptFilePath -Value $lockScriptContent -Encoding utf8

                $processArguments = @(
                    '-NoProfile', '-NonInteractive', '-File', $lockScriptFilePath,
                    '-TargetFilePath', $TargetFilePath,
                    '-HoldDurationSeconds', $HoldDurationSeconds
                )
                $lockProcess = Start-Process -FilePath 'pwsh' -ArgumentList $processArguments -WindowStyle Hidden -PassThru
                return [PSCustomObject]@{ Process = $lockProcess; ScratchDirectory = $scratchDirectoryPath }
            }

            function Stop-G70BackgroundTestProcess {
                param(
                    [Parameter(Mandatory)] $Handle
                )
                if ($Handle.Process -and -not $Handle.Process.HasExited) {
                    Stop-Process -Id $Handle.Process.Id -Force -ErrorAction SilentlyContinue
                    $Handle.Process.WaitForExit(5000) | Out-Null
                }
                Remove-Item -LiteralPath $Handle.ScratchDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }

            function Wait-G70LiveMetadataReady {
                <#
                .SYNOPSIS
                Polls Get-RecordingFileLiveMetadata itself (never Get-Item/FileInfo, which
                would be irrelevant here since Task 1's tests are not exercising directory-
                entry staleness) until Predicate is satisfied or TimeoutMilliseconds elapses.
                A spawned background writer process's actual startup time (pwsh runtime
                init, JIT, antivirus scan of a freshly-written script) is real and variable
                on this machine -- a fixed sleep before the first read is a flaky-test
                pattern; polling the function under test is not.
                #>
                param(
                    [Parameter(Mandatory)] [string] $FilePath,
                    [Parameter(Mandatory)] [scriptblock] $Predicate,
                    [int] $TimeoutMilliseconds = 10000,
                    [int] $PollIntervalMilliseconds = 100
                )
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $lastResult = $null
                while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
                    $lastResult = Get-RecordingFileLiveMetadata -FilePath $FilePath
                    if (& $Predicate $lastResult) { return $lastResult }
                    Start-Sleep -Milliseconds $PollIntervalMilliseconds
                }
                return $lastResult
            }
        }

        It 'returns the held-open writer''s true byte count while the file has been written but never closed' {
            $targetFilePath = Join-Path $TestDrive ("g70-live-length-{0}.ts" -f ([Guid]::NewGuid()))
            $chunkSizeBytes = 5000
            $writer = Start-G70HeldOpenTestWriterProcess -TargetFilePath $targetFilePath -ChunkSizeBytes $chunkSizeBytes -WriteOnce -TotalDurationSeconds 30
            try {
                $result = Wait-G70LiveMetadataReady -FilePath $targetFilePath -Predicate { param($metadata) ($null -ne $metadata) -and ($metadata.LengthBytes -eq $chunkSizeBytes) }

                $result | Should -Not -BeNullOrEmpty
                $result.LengthBytes | Should -Be $chunkSizeBytes
            } finally {
                Stop-G70BackgroundTestProcess -Handle $writer
            }
        }

        It 'returns a LastWriteTimeUtc within 5 seconds of UtcNow while the writer is writing right now' {
            $targetFilePath = Join-Path $TestDrive ("g70-live-mtime-{0}.ts" -f ([Guid]::NewGuid()))
            $writer = Start-G70HeldOpenTestWriterProcess -TargetFilePath $targetFilePath -ChunkSizeBytes 5000 -WriteOnce -TotalDurationSeconds 30
            try {
                $result = Wait-G70LiveMetadataReady -FilePath $targetFilePath -Predicate { param($metadata) ($null -ne $metadata) -and ($metadata.LengthBytes -gt 0) }

                $result | Should -Not -BeNullOrEmpty
                ([DateTime]::UtcNow - $result.LastWriteTimeUtc).TotalSeconds | Should -BeLessOrEqual 5
            } finally {
                Stop-G70BackgroundTestProcess -Handle $writer
            }
        }

        It 'returns $null and throws nothing when the path does not exist' {
            $nonExistentFilePath = Join-Path $TestDrive ("g70-does-not-exist-{0}.ts" -f ([Guid]::NewGuid()))

            { $script:g70NonExistentResult = Get-RecordingFileLiveMetadata -FilePath $nonExistentFilePath } | Should -Not -Throw
            $script:g70NonExistentResult | Should -BeNullOrEmpty
        }

        It 'returns $null and throws nothing when the file is held with FileShare.None by another process' {
            $targetFilePath = Join-Path $TestDrive ("g70-exclusively-locked-{0}.ts" -f ([Guid]::NewGuid()))
            $lock = Start-G70ExclusiveLockTestProcess -TargetFilePath $targetFilePath -HoldDurationSeconds 30
            try {
                # Confirm the exclusive lock is actually acquired (not just "file not yet
                # created") by polling a transient probe open, never Get-Item/FileInfo.
                $lockConfirmed = $false
                $lockStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                while ($lockStopwatch.ElapsedMilliseconds -lt 10000) {
                    if (Test-Path -LiteralPath $targetFilePath) {
                        try {
                            $probeStream = [System.IO.FileStream]::new($targetFilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                            $probeStream.Dispose()
                        } catch {
                            $lockConfirmed = $true
                            break
                        }
                    }
                    Start-Sleep -Milliseconds 100
                }
                $lockConfirmed | Should -BeTrue

                { $script:g70LockedResult = Get-RecordingFileLiveMetadata -FilePath $targetFilePath } | Should -Not -Throw
                $script:g70LockedResult | Should -BeNullOrEmpty
            } finally {
                Stop-G70BackgroundTestProcess -Handle $lock
            }
        }

        It 'T-g70-02: leaves no leaked handles across 500 consecutive calls against a held-open growing file' {
            $targetFilePath = Join-Path $TestDrive ("g70-handle-exhaustion-{0}.ts" -f ([Guid]::NewGuid()))
            $writer = Start-G70HeldOpenTestWriterProcess -TargetFilePath $targetFilePath -ChunkSizeBytes 2000 -IntervalMilliseconds 100 -TotalDurationSeconds 30
            try {
                $ready = Wait-G70LiveMetadataReady -FilePath $targetFilePath -Predicate { param($metadata) ($null -ne $metadata) -and ($metadata.LengthBytes -gt 0) }
                $ready | Should -Not -BeNullOrEmpty

                $lastResult = $null
                for ($iteration = 0; $iteration -lt 500; $iteration++) {
                    $lastResult = Get-RecordingFileLiveMetadata -FilePath $targetFilePath
                }
                $lastResult | Should -Not -BeNullOrEmpty

                # If any of the 500 calls above leaked its FileStream, this exclusive open
                # of a DIFFERENT scratch file would fail with a sharing violation.
                $scratchFilePath = Join-Path $TestDrive ("g70-handle-exhaustion-scratch-{0}.ts" -f ([Guid]::NewGuid()))
                Set-Content -LiteralPath $scratchFilePath -Value 'scratch' -Encoding utf8
                $exclusiveScratchStream = $null
                $exclusiveOpenThrew = $false
                try {
                    $exclusiveScratchStream = [System.IO.FileStream]::new($scratchFilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                } catch {
                    $exclusiveOpenThrew = $true
                } finally {
                    if ($null -ne $exclusiveScratchStream) { $exclusiveScratchStream.Dispose() }
                }
                $exclusiveOpenThrew | Should -BeFalse
                $exclusiveScratchStream | Should -Not -BeNullOrEmpty
            } finally {
                Stop-G70BackgroundTestProcess -Handle $writer
            }
        }

        It 'T-g70-03: the writer''s next Write+Flush still succeeds and length still advances after a call' {
            $targetFilePath = Join-Path $TestDrive ("g70-writer-not-locked-out-{0}.ts" -f ([Guid]::NewGuid()))
            $writer = Start-G70HeldOpenTestWriterProcess -TargetFilePath $targetFilePath -ChunkSizeBytes 2000 -IntervalMilliseconds 200 -TotalDurationSeconds 15
            try {
                $before = Wait-G70LiveMetadataReady -FilePath $targetFilePath -Predicate { param($metadata) ($null -ne $metadata) -and ($metadata.LengthBytes -gt 0) }
                $before | Should -Not -BeNullOrEmpty

                $after = Wait-G70LiveMetadataReady -FilePath $targetFilePath -Predicate { param($metadata) ($null -ne $metadata) -and ($metadata.LengthBytes -gt $before.LengthBytes) } -TimeoutMilliseconds 8000
                $after | Should -Not -BeNullOrEmpty
                $after.LengthBytes | Should -BeGreaterThan $before.LengthBytes
            } finally {
                Stop-G70BackgroundTestProcess -Handle $writer
            }
        }
    }
}

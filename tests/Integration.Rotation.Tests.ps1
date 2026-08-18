# Integration.Rotation.Tests.ps1
# End-to-end proof for ROT-01 (file-rotation drain-and-switch byte order) and ROT-02
# (two-signal end-of-service, pause-not-stop, clean-finish-exit-0) against the REAL
# wired pusher.ps1 (03-05, closing 03-VALIDATION.md's Wave 0 integration gap). Mirrors
# tests/Integration.KillAndResume.Tests.ps1's structure exactly: a test-tuned copy of
# pusher.ps1 (top-of-script variables overridden, production pusher.ps1 never modified)
# driven against a local ffmpeg SRT mode=listener receiver and synthetic OBS-like
# writers, so byte continuity/behavior is provable without a real OBS install or relay.
#
# Hard-kill note (same rationale as Integration.KillAndResume.Tests.ps1's file header):
# the kill-at-rotation-instant scenario uses `taskkill /F /PID` on ONLY the pusher
# process (never /T, which would also kill its ffmpeg child). Killing only the parent
# closes ffmpeg's stdin pipe (EOF), letting the orphaned ffmpeg drain whatever it
# already accepted and exit on its own -- exactly the D-04 commit boundary being tested.
#
# Writer-stop note: every scenario lets its OBS-simulating writer(s) finish NATURALLY
# (via a bounded -TotalDurationSeconds) rather than force-killing them mid-write. A
# forced Kill() mid-write could leave a non-188-aligned trailing partial chunk that NO
# pusher session -- original or resumed -- could ever fully drain (Read-StableChunk's
# 2-poll stable-length gate never consumes a sub-188-byte remainder), which would hang
# the rotation switch-complete / end-of-service drain-complete detection forever. Every
# writer here uses an 18800-byte (=100*188) chunk size, so a natural loop-exit always
# leaves the file at an exact, 188-aligned length.

BeforeAll {
    $script:RepoRootPath           = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:PusherSourcePath       = Join-Path $script:RepoRootPath 'pusher.ps1'
    $script:LoggingModulePath      = Join-Path $script:RepoRootPath 'lib/Logging.psm1'
    $script:OffsetStoreModulePath  = Join-Path $script:RepoRootPath 'lib/OffsetStore.psm1'
    $script:TestHelpersModulePath  = Join-Path $PSScriptRoot 'TestHelpers.psm1'
    $script:TransportStreamPacketSizeBytes = 188

    # Mirrors of pusher.ps1's top-of-script Claude's-discretion constants (D-19,
    # 02-06-SUMMARY.md "key-decisions"), duplicated here (not imported) since they are
    # plain script config, not exported module functions -- keep in sync with
    # pusher.ps1 if those values ever change. Only Scenario B (kill-at-rotation-instant)
    # needs the dynamic resume-margin constants, mirrored from
    # Integration.KillAndResume.Tests.ps1's own BeforeAll.
    $script:PusherChunkSizeBytes                        = 65424     # 348 * 188 bytes (D-14)
    $script:PusherSrtLatencySeconds                      = 0.5       # $latencyMicroseconds(500000)/1000000.0 (D-12/D-19)
    $script:PusherNetworkDeathDetectionDelaySeconds      = 10.0
    $script:PusherResumeMarginLatencySeconds             = $script:PusherSrtLatencySeconds + $script:PusherNetworkDeathDetectionDelaySeconds
    $script:PusherResumeMarginFloorBytes                 = 65424     # >= one chunk (D-12)
    $script:PusherResumeMarginCeilingBytes               = 2097152   # 2 MB ceiling (D-12)
    $script:PusherColdStartResumeMarginBytes             = 65424     # cold-start fallback, no rate observed yet (D-12)

    # New-TestTunedPusherCopy, Start-ValidMpegtsGrowthWriter, Stop-ValidMpegtsGrowthWriter,
    # and Start-SecondValidMpegtsRecording all live in tests/TestHelpers.psm1 (Phase 3,
    # 03-04) -- shared/exported there specifically so this file could reuse them without
    # duplicating that logic (DRY). Imported below via $script:TestHelpersModulePath
    # (Import-Module ... -Force in each BeforeEach).

    function Start-TestPusherProcess {
        <#
        .SYNOPSIS
        Launches a pusher.ps1 (or test-tuned copy) as a detached pwsh process with
        stdout/stderr redirected to temp files for post-mortem debugging. Identical to
        Integration.KillAndResume.Tests.ps1's helper of the same name (not shared into
        TestHelpers.psm1, matching that file's existing convention of keeping harness-
        wiring helpers local to each integration test file).
        #>
        param([Parameter(Mandatory)] [string] $PusherScriptPath)

        $stdoutPath = [System.IO.Path]::GetTempFileName()
        $stderrPath = [System.IO.Path]::GetTempFileName()
        $processHandle = Start-Process -FilePath 'pwsh' `
            -ArgumentList @('-NoProfile', '-File', $PusherScriptPath) `
            -WorkingDirectory $script:RepoRootPath -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

        return [PSCustomObject]@{ Process = $processHandle; StdOutPath = $stdoutPath; StdErrPath = $stderrPath }
    }

    function Wait-ForFileToExist {
        param(
            [Parameter(Mandatory)] [string] $Path,
            [int] $TimeoutMilliseconds = 15000,
            [int] $PollMilliseconds = 100
        )
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds -and -not (Test-Path -LiteralPath $Path)) {
            Start-Sleep -Milliseconds $PollMilliseconds
        }
        return (Test-Path -LiteralPath $Path)
    }

    function Wait-ForFileGrowth {
        <#
        .SYNOPSIS
        Polls Path until its length reaches at least MinimumLength -- used to detect
        that an SRT listener has actually started receiving output, without a blind
        fixed sleep.
        #>
        param(
            [Parameter(Mandatory)] [string] $Path,
            [int] $TimeoutMilliseconds = 45000,
            [int] $PollMilliseconds = 500,
            [long] $MinimumLength = 1
        )
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            if (Test-Path -LiteralPath $Path) {
                $length = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).Length
                if ($length -ge $MinimumLength) {
                    return $true
                }
            }
            Start-Sleep -Milliseconds $PollMilliseconds
        }
        return $false
    }

    function Wait-ForLogPatternInFiles {
        <#
        .SYNOPSIS
        Polls the given redirected-stdout/stderr files (from Start-TestPusherProcess)
        until one of them contains Pattern, or times out. Used to detect a specific
        Write-Log line (e.g. the rotation-detected / rotation-switch-complete lines)
        without a blind sleep.
        #>
        param(
            [Parameter(Mandatory)] [string[]] $Paths,
            [Parameter(Mandatory)] [string] $Pattern,
            [int] $TimeoutMilliseconds = 30000,
            [int] $PollMilliseconds = 500
        )
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            foreach ($path in $Paths) {
                if (Test-Path -LiteralPath $path) {
                    $content = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
                    if ($content -and ($content -match $Pattern)) {
                        return $true
                    }
                }
            }
            Start-Sleep -Milliseconds $PollMilliseconds
        }
        return $false
    }

    function Start-SrtListenerWithRetry {
        <#
        .SYNOPSIS
        Starts an SRT listener on Port, retrying if the bind fails because the OS has
        not yet released a just-exited prior listener's UDP socket on the same port. A
        failed bind manifests as ffmpeg exiting almost immediately. Identical to
        Integration.KillAndResume.Tests.ps1's helper of the same name.
        #>
        param(
            [Parameter(Mandatory)] [int] $Port,
            [Parameter(Mandatory)] [string] $OutputPath,
            [int] $MaxAttempts = 6,
            [int] $RetryDelayMilliseconds = 500,
            [int] $StartupSettleMilliseconds = 400
        )
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            $listenerProcess = Start-SrtListener -Port $Port -OutputPath $OutputPath
            Start-Sleep -Milliseconds $StartupSettleMilliseconds
            if (-not $listenerProcess.HasExited) {
                return $listenerProcess
            }
            Start-Sleep -Milliseconds $RetryDelayMilliseconds
        }
        throw "Start-SrtListenerWithRetry: failed to bind port $Port after $MaxAttempts attempts"
    }
}

Describe 'Pusher rotation + end-of-service: real drain/switch and end-detection over local SRT (ROT-01/ROT-02, D-02/D-07/D-13)' -Tag 'Integration' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Remove-Module OffsetStore -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:OffsetStoreModulePath -Force
        Import-Module $script:TestHelpersModulePath -Force
    }

    AfterEach {
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Remove-Module OffsetStore -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'drains old file before new: byte order preserved across a real rotation, no interleave (ROT-01)' {
        # Per-scenario unique work directory (not just $TestDrive directly): this
        # Describe's four Its all end their pusher process with a forceful external
        # Stop-Process, which orphans pusher.ps1's ffmpeg child (it never runs its own
        # `finally`/Stop-FfmpegProcess) -- the orphan self-terminates once its inherited
        # stdin handle closes (same EOF mechanism as the documented taskkill /F case),
        # but can take a little longer under load. A unique per-It folder guarantees a
        # slow-to-die orphan from one scenario can never bleed into the identically-named
        # 'recording-001.ts'/'received.ts' paths of the NEXT scenario sharing $TestDrive.
        $testWorkDirectory   = Join-Path $TestDrive ("case-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $testWorkDirectory -Force | Out-Null
        $samplePath          = Join-Path $testWorkDirectory 'sample.ts'
        $recordingFolderPath = Join-Path $testWorkDirectory 'recordings'
        New-Item -ItemType Directory -Path $recordingFolderPath -Force | Out-Null
        $recording001Path    = Join-Path $recordingFolderPath 'recording-001.ts'
        $recording002Path    = Join-Path $recordingFolderPath 'recording-002.ts'
        $receivedFile001Path = Join-Path $testWorkDirectory 'received-001.ts'
        $receivedFile002Path = Join-Path $testWorkDirectory 'received-002.ts'
        $statePath           = Join-Path $testWorkDirectory 'offset.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 60 -VideoSize '320x240' -FrameRate 25 | Out-Null

        $listenPort = Get-Random -Minimum 20000 -Maximum 40000
        $writer1    = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recording001Path -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 6
        $listener1  = Start-SrtListenerWithRetry -Port $listenPort -OutputPath $receivedFile001Path

        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recording001Path -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort $listenPort -StateFilePath $statePath -ObsLivenessOverrideLiteral '{ $true }'
        $writer2 = $null
        $listener2 = $null
        $pusherHandle = $null
        try {
            Start-Sleep -Milliseconds 800   # let the writer produce initial bytes before the pusher opens the file
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            (Wait-ForFileToExist -Path $statePath -TimeoutMilliseconds 15000) | Should -BeTrue

            # Let writer1 finish naturally -- OBS closes the old recording -- so file
            # 001's final length is always a clean, 188-aligned stopping point (see file
            # header rationale).
            $writer1.Process.WaitForExit(15000) | Out-Null
            $file001FinalLength = (Get-Item -LiteralPath $recording001Path).Length
            $file001FinalLength | Should -BeGreaterThan 0

            # OBS opens the new recording (D-02 positive signal, never a growth-timeout).
            $writer2 = Start-SecondValidMpegtsRecording -SamplePath $samplePath -TargetFilePath $recording002Path `
                -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 20

            $rotationDetected = Wait-ForLogPatternInFiles -Paths @($pusherHandle.StdOutPath, $pusherHandle.StdErrPath) `
                -Pattern 'Rotation detected' -TimeoutMilliseconds 15000
            $rotationDetected | Should -BeTrue

            $rotationSwitchComplete = Wait-ForLogPatternInFiles -Paths @($pusherHandle.StdOutPath, $pusherHandle.StdErrPath) `
                -Pattern 'Rotation switch complete' -TimeoutMilliseconds 25000
            $rotationSwitchComplete | Should -BeTrue

            # listener1's single ffmpeg input session ends when the OLD (file-001) ffmpeg
            # is gracefully stopped as part of the switch (Stop-FfmpegProcess + SRT linger
            # flush) -- it finishes writing $receivedFile001Path and exits on its own.
            $listener1.WaitForExit(8000) | Out-Null
            if (-not $listener1.HasExited) { Stop-SrtListener -Process $listener1 }

            # Fresh listener, SAME port -- the running pusher's ffmpeg args (including
            # RelayPort) are fixed for its whole lifetime, so the NEW ffmpeg session
            # started for file 002 reconnects to the identical port (mirrors the
            # hard-kill/outage Describes' same-port-fresh-listener pattern).
            $listener2 = Start-SrtListenerWithRetry -Port $listenPort -OutputPath $receivedFile002Path
            $reconnectedToNewFile = Wait-ForFileGrowth -Path $receivedFile002Path -TimeoutMilliseconds 20000
            $reconnectedToNewFile | Should -BeTrue

            $committedState = Restore-PusherOffset -StateFilePath $statePath
            $committedState.file | Should -Be $recording002Path

            Start-Sleep -Milliseconds 2000   # let a little more file-002 content accumulate before stopping

            Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
            $pusherHandle.Process.WaitForExit(5000) | Out-Null
            Stop-ValidMpegtsGrowthWriter -Writer $writer2

            $listener2.WaitForExit(8000) | Out-Null
            if (-not $listener2.HasExited) { Stop-SrtListener -Process $listener2 }

            # Drain-old-before-new, byte-order-preserved (D-04/D-13): the ENTIRE file 001
            # (its full final length, fixed the moment writer1 stopped) was accepted and
            # sent to listener1 BEFORE the switch happened -- proven by byte-exact
            # comparison over everything that arrived, plus a bounded-shortfall check.
            #
            # This deliberately does NOT demand byte-exact equality over file 001's full
            # final length. That assertion was unsatisfiable at ~31% of cut points and was
            # misdiagnosed as flakiness for a whole phase: listener1's ffmpeg re-frames the
            # TS container and does not re-emit the trailing 1-2 container-framing packets
            # when the file's cut point does not align with its output framing. Pushing the
            # identical file through a pure local ffmpeg -c copy remux -- no pusher, no SRT,
            # no network -- reproduces the exact same shortfall (357200 -> 356824) with an
            # identical 783-packet elementary stream, so those bytes are container framing,
            # not content, and no correct pusher could ever make the old assertion pass.
            # Test-DeliveredPrefixIntact still fails loudly on any real under-delivery.
            Test-DeliveredPrefixIntact -SourcePath $recording001Path -ReceivedPath $receivedFile001Path -ExpectedDeliveredLength $file001FinalLength | Should -BeTrue

            # No interleaving (D-06): file 002's bytes only ever reach listener2, a
            # SEPARATE ffmpeg session/listener that could only start receiving after
            # listener1's file-001 session had already ended -- ordering is structural
            # (two sequential SRT connections), not just logged.
            $receivedFile002Length = (Get-Item -LiteralPath $receivedFile002Path -ErrorAction SilentlyContinue).Length
            $receivedFile002Length | Should -BeGreaterThan 0
            $receivedFile002Probe = & ffprobe -v error -show_entries stream=codec_type -of csv=p=0 $receivedFile002Path 2>&1
            $LASTEXITCODE | Should -Be 0
            $receivedFile002Probe | Should -Not -BeNullOrEmpty
        } finally {
            if ($pusherHandle -and -not $pusherHandle.Process.HasExited) {
                Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
                $pusherHandle.Process.WaitForExit(5000) | Out-Null
            }
            Stop-ValidMpegtsGrowthWriter -Writer $writer1
            if ($writer2) { Stop-ValidMpegtsGrowthWriter -Writer $writer2 }
            if (-not $listener1.HasExited) { Stop-SrtListener -Process $listener1 }
            if ($listener2 -and -not $listener2.HasExited) { Stop-SrtListener -Process $listener2 }
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'switches rotation even when the old file''s final length is NOT 188-aligned -- no infinite hang (CR-01 regression)' {
        # CR-01 regression: Read-StableChunk only ever advances Position in whole
        # 188-byte increments, so a trailing sub-packet remainder on the OLD file
        # (e.g. OBS crash/partial flush mid-TS-packet) must never hang the Rotating
        # switch-complete detection forever. Every other It in this file sidesteps
        # this exact hazard by using an exactly-188-aligned writer chunk size (see
        # file header) -- this test deliberately breaks that alignment by appending a
        # non-188-aligned tail directly onto recording-001.ts after its normal writer
        # finishes, then asserts the switch still completes within a bounded timeout
        # (proving no infinite hang) and that all WHOLE-packet content was still
        # delivered byte-exact and in order.
        $testWorkDirectory   = Join-Path $TestDrive ("case-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $testWorkDirectory -Force | Out-Null
        $samplePath          = Join-Path $testWorkDirectory 'sample.ts'
        $recordingFolderPath = Join-Path $testWorkDirectory 'recordings'
        New-Item -ItemType Directory -Path $recordingFolderPath -Force | Out-Null
        $recording001Path    = Join-Path $recordingFolderPath 'recording-001.ts'
        $recording002Path    = Join-Path $recordingFolderPath 'recording-002.ts'
        $receivedFile001Path = Join-Path $testWorkDirectory 'received-001.ts'
        $receivedFile002Path = Join-Path $testWorkDirectory 'received-002.ts'
        $statePath           = Join-Path $testWorkDirectory 'offset.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 60 -VideoSize '320x240' -FrameRate 25 | Out-Null

        $listenPort = Get-Random -Minimum 20000 -Maximum 40000
        $writer1    = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recording001Path -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 6
        $listener1  = Start-SrtListenerWithRetry -Port $listenPort -OutputPath $receivedFile001Path

        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recording001Path -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort $listenPort -StateFilePath $statePath -ObsLivenessOverrideLiteral '{ $true }'
        $writer2 = $null
        $listener2 = $null
        $pusherHandle = $null
        try {
            Start-Sleep -Milliseconds 800   # let the writer produce initial bytes before the pusher opens the file
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            (Wait-ForFileToExist -Path $statePath -TimeoutMilliseconds 15000) | Should -BeTrue

            # Let writer1 finish naturally first, exactly like the other Its -- this
            # gives a clean, always-188-aligned baseline length before we deliberately
            # corrupt it below with a non-aligned appended remainder.
            $writer1.Process.WaitForExit(15000) | Out-Null
            $alignedFinalLength = (Get-Item -LiteralPath $recording001Path).Length
            $alignedFinalLength | Should -BeGreaterThan 0
            ($alignedFinalLength % $script:TransportStreamPacketSizeBytes) | Should -Be 0 -Because 'the natural writer always stops on a 188-aligned boundary (file header rationale)'

            # Append a non-188-aligned trailing remainder directly onto the OLD file --
            # simulating a crash/partial-flush mid-TS-packet, the exact hazard CR-01
            # fixes. This remainder can never become a whole deliverable packet once
            # the file has stopped growing (it is not a "skippable" packet, D-04/D-05).
            $trailingRemainderBytes = 100
            $appendStream = [System.IO.FileStream]::new($recording001Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try {
                $remainderBuffer = New-Object byte[] $trailingRemainderBytes
                for ($index = 0; $index -lt $remainderBuffer.Length; $index++) { $remainderBuffer[$index] = 0x47 }
                $appendStream.Write($remainderBuffer, 0, $remainderBuffer.Length)
                $appendStream.Flush($true)
            } finally {
                $appendStream.Dispose()
            }
            $file001FinalLength = (Get-Item -LiteralPath $recording001Path).Length
            $file001FinalLength | Should -Be ($alignedFinalLength + $trailingRemainderBytes)
            ($file001FinalLength % $script:TransportStreamPacketSizeBytes) | Should -Not -Be 0 -Because 'this is the exact non-188-aligned final length CR-01 must tolerate without hanging'

            # OBS opens the new recording (D-02 positive signal, never a growth-timeout).
            $writer2 = Start-SecondValidMpegtsRecording -SamplePath $samplePath -TargetFilePath $recording002Path `
                -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 20

            $rotationDetected = Wait-ForLogPatternInFiles -Paths @($pusherHandle.StdOutPath, $pusherHandle.StdErrPath) `
                -Pattern 'Rotation detected' -TimeoutMilliseconds 15000
            $rotationDetected | Should -BeTrue

            # The regression assertion: a BOUNDED timeout proves this is not an
            # infinite hang -- before the CR-01 fix, Position could never reach this
            # non-188-aligned Length, so 'Rotation switch complete' would never be
            # logged and this assertion would fail on timeout instead of freezing the
            # whole test run.
            $rotationSwitchComplete = Wait-ForLogPatternInFiles -Paths @($pusherHandle.StdOutPath, $pusherHandle.StdErrPath) `
                -Pattern 'Rotation switch complete' -TimeoutMilliseconds 25000
            $rotationSwitchComplete | Should -BeTrue -Because 'CR-01: a non-188-aligned old-file final length must never hang the Rotating switch-complete detection'

            $listener1.WaitForExit(8000) | Out-Null
            if (-not $listener1.HasExited) { Stop-SrtListener -Process $listener1 }

            $listener2 = Start-SrtListenerWithRetry -Port $listenPort -OutputPath $receivedFile002Path
            $reconnectedToNewFile = Wait-ForFileGrowth -Path $receivedFile002Path -TimeoutMilliseconds 20000
            $reconnectedToNewFile | Should -BeTrue

            $committedState = Restore-PusherOffset -StateFilePath $statePath
            $committedState.file | Should -Be $recording002Path

            Start-Sleep -Milliseconds 2000   # let a little more file-002 content accumulate before stopping

            Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
            $pusherHandle.Process.WaitForExit(5000) | Out-Null
            Stop-ValidMpegtsGrowthWriter -Writer $writer2

            $listener2.WaitForExit(8000) | Out-Null
            if (-not $listener2.HasExited) { Stop-SrtListener -Process $listener2 }

            # Byte-order continuity of the whole-packet content (D-04/D-13): every
            # WHOLE 188-byte packet of the old file -- up to $alignedFinalLength, BEFORE
            # the deliberately-appended non-188 remainder -- must have been delivered
            # byte-exact and in order. The trailing remainder itself was never a
            # deliverable whole packet to begin with, so correctly never being sent is
            # not a skip (D-05).
            #
            # Shortfall-tolerant for the same measured reason as the ROT-01 scenario above:
            # the receiving ffmpeg does not re-emit the trailing 1-2 TS container-framing
            # packets. See Test-DeliveredPrefixIntact's notes.
            Test-DeliveredPrefixIntact -SourcePath $recording001Path -ReceivedPath $receivedFile001Path -ExpectedDeliveredLength $alignedFinalLength | Should -BeTrue

            $receivedFile002Length = (Get-Item -LiteralPath $receivedFile002Path -ErrorAction SilentlyContinue).Length
            $receivedFile002Length | Should -BeGreaterThan 0
            $receivedFile002Probe = & ffprobe -v error -show_entries stream=codec_type -of csv=p=0 $receivedFile002Path 2>&1
            $LASTEXITCODE | Should -Be 0
            $receivedFile002Probe | Should -Not -BeNullOrEmpty
        } finally {
            if ($pusherHandle -and -not $pusherHandle.Process.HasExited) {
                Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
                $pusherHandle.Process.WaitForExit(5000) | Out-Null
            }
            Stop-ValidMpegtsGrowthWriter -Writer $writer1
            if ($writer2) { Stop-ValidMpegtsGrowthWriter -Writer $writer2 }
            if (-not $listener1.HasExited) { Stop-SrtListener -Process $listener1 }
            if ($listener2 -and -not $listener2.HasExited) { Stop-SrtListener -Process $listener2 }
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'kill at rotation instant resumes correctly with no skipped old-file bytes (D-13)' {
        # Per-scenario unique work directory -- see the rationale comment in the
        # 'drains old file before new' scenario above (a slow-to-die orphaned ffmpeg
        # from a prior scenario must never bleed into this scenario's identically-named
        # recording/received paths under the shared $TestDrive).
        $testWorkDirectory       = Join-Path $TestDrive ("case-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $testWorkDirectory -Force | Out-Null
        $samplePath              = Join-Path $testWorkDirectory 'sample.ts'
        $recordingFolderPath     = Join-Path $testWorkDirectory 'recordings'
        New-Item -ItemType Directory -Path $recordingFolderPath -Force | Out-Null
        $recording001Path        = Join-Path $recordingFolderPath 'recording-001.ts'
        $recording002Path        = Join-Path $recordingFolderPath 'recording-002.ts'
        $receivedBeforeKillPath  = Join-Path $testWorkDirectory 'received-before-kill.ts'
        $receivedAfterResumePath = Join-Path $testWorkDirectory 'received-after-resume.ts'
        $statePath               = Join-Path $testWorkDirectory 'offset.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 60 -VideoSize '320x240' -FrameRate 25 | Out-Null

        $listenPortBeforeKill = Get-Random -Minimum 20000 -Maximum 40000
        $writer1              = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recording001Path -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 6
        $listenerBeforeKill   = Start-SrtListenerWithRetry -Port $listenPortBeforeKill -OutputPath $receivedBeforeKillPath

        $testPusherPath1 = New-TestTunedPusherCopy -RecordingFilePath $recording001Path -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort $listenPortBeforeKill -StateFilePath $statePath -ObsLivenessOverrideLiteral '{ $true }'
        $testPusherPath2 = $null
        $writer2 = $null
        $pusherHandle1 = $null
        $pusherHandle2 = $null
        $listenerAfterResume = $null
        try {
            Start-Sleep -Milliseconds 800
            $pusherHandle1 = Start-TestPusherProcess -PusherScriptPath $testPusherPath1

            (Wait-ForFileToExist -Path $statePath -TimeoutMilliseconds 15000) | Should -BeTrue

            # Let writer1 finish naturally (never force-killed, see file header) before
            # triggering the rotation.
            $writer1.Process.WaitForExit(15000) | Out-Null

            # OBS opens the new recording (D-02 positive signal) -- start it immediately
            # so whatever small residual backlog the pusher still has in file 001 (it
            # polls every $pollIntervalMilliseconds) gives a real, if brief, mid-drain
            # window for the kill below.
            $writer2 = Start-SecondValidMpegtsRecording -SamplePath $samplePath -TargetFilePath $recording002Path `
                -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 20

            $rotationDetected = Wait-ForLogPatternInFiles -Paths @($pusherHandle1.StdOutPath, $pusherHandle1.StdErrPath) `
                -Pattern 'Rotation detected' -TimeoutMilliseconds 15000
            $rotationDetected | Should -BeTrue

            # Kill ONLY the pusher process (never /T -- file header rationale) as close to
            # the rotation switch instant as the harness can time it (D-13's mandatory
            # hard-kill test): right after detecting the rotation, before waiting for the
            # switch to confirm complete.
            & taskkill /F /PID $pusherHandle1.Process.Id 2>&1 | Out-Null

            Start-Sleep -Milliseconds 1500   # let the orphaned ffmpeg drain + the listener flush to disk
            if (-not $listenerBeforeKill.HasExited) { Stop-SrtListener -Process $listenerBeforeKill }

            $stateAfterKill = Restore-PusherOffset -StateFilePath $statePath
            $stateAfterKill.file | Should -BeIn @($recording001Path, $recording002Path)

            $actualReceivedLengthBeforeKill = (Get-Item -LiteralPath $receivedBeforeKillPath -ErrorAction SilentlyContinue).Length
            $actualReceivedLengthBeforeKill | Should -BeGreaterThan 0
            # Whatever DID arrive before the kill must be byte-correct (no corruption or
            # reorder), the same D-04 commit-boundary property proven by the existing
            # hard-kill Describe in Integration.KillAndResume.Tests.ps1.
            Test-ByteRangeEquality -SourcePath $recording001Path -ReceivedPath $receivedBeforeKillPath -StartOffset 0 -Length $actualReceivedLengthBeforeKill | Should -BeTrue

            # Resume: fresh listener, SAME port -- a fresh pusher process rebuilds its own
            # ffmpeg args at startup, so this test is free to reuse the identical port.
            $listenerAfterResume = Start-SrtListenerWithRetry -Port $listenPortBeforeKill -OutputPath $receivedAfterResumePath
            $testPusherPath2 = New-TestTunedPusherCopy -RecordingFilePath $recording001Path -RecordingFilenameGlob 'recording-*.ts' `
                -RelayPort $listenPortBeforeKill -StateFilePath $statePath -ObsLivenessOverrideLiteral '{ $true }'

            Start-Sleep -Milliseconds 300
            $pusherHandle2 = Start-TestPusherProcess -PusherScriptPath $testPusherPath2

            if ($stateAfterKill.file -eq $recording001Path) {
                # Crash landed genuinely mid-drain (D-13's primary case): the restarted
                # pusher must resume the OLD file at its persisted offset, re-detect the
                # still-pending rotation (file 002 already exists), re-drain, and switch
                # -- never skip straight to file 002 and never lose the undrained tail.
                $rotationSwitchComplete = Wait-ForLogPatternInFiles -Paths @($pusherHandle2.StdOutPath, $pusherHandle2.StdErrPath) `
                    -Pattern 'Rotation switch complete' -TimeoutMilliseconds 25000
                $rotationSwitchComplete | Should -BeTrue
            } else {
                # Crash landed just after the switch had already committed file 002's
                # identity (D-05's commit-then-persist ordering guarantees file 001 was
                # ALREADY fully drained and committed before this could happen) -- the
                # restarted pusher simply resumes file 002 directly, no re-drain needed.
                $reconnectedToFile002 = Wait-ForFileGrowth -Path $receivedAfterResumePath -TimeoutMilliseconds 20000
                $reconnectedToFile002 | Should -BeTrue
            }

            Start-Sleep -Seconds 3   # let the resumed session stream real content before probing

            Stop-Process -Id $pusherHandle2.Process.Id -Force -ErrorAction SilentlyContinue
            $pusherHandle2.Process.WaitForExit(5000) | Out-Null
            Stop-ValidMpegtsGrowthWriter -Writer $writer2

            $listenerAfterResume.WaitForExit(8000) | Out-Null
            if (-not $listenerAfterResume.HasExited) { Stop-SrtListener -Process $listenerAfterResume }

            $receivedAfterResumeLength = (Get-Item -LiteralPath $receivedAfterResumePath -ErrorAction SilentlyContinue).Length
            $receivedAfterResumeLength | Should -BeGreaterThan 0

            if ($stateAfterKill.file -eq $recording001Path) {
                # No-permanent-gap arithmetic proof (D-13), same shape as the existing
                # hard-kill Describe: the restarted session's dynamic resume-safety
                # margin (D-12) must cover back to at or before everything session 1
                # actually delivered for file 001 -- computed the SAME way pusher.ps1
                # computes it internally (cold start, no rate observed yet on a fresh
                # process), not hardcoded.
                $dynamicResumeSafetyMarginBytes = Get-ResumeSafetyMarginBytes -SrtLatencySeconds $script:PusherResumeMarginLatencySeconds `
                    -ObservedBytesPerSecond 0 -ChunkSizeBytes $script:PusherChunkSizeBytes `
                    -FloorBytes $script:PusherResumeMarginFloorBytes -CeilingBytes $script:PusherResumeMarginCeilingBytes `
                    -ColdStartMarginBytes $script:PusherColdStartResumeMarginBytes
                $expectedResumeSeekPosition = [Math]::Max(0, $stateAfterKill.byteOffset - $dynamicResumeSafetyMarginBytes)
                $expectedResumeSeekPosition -= ($expectedResumeSeekPosition % $script:TransportStreamPacketSizeBytes)
                $expectedResumeSeekPosition | Should -BeLessOrEqual $actualReceivedLengthBeforeKill
            }

            # Structural playability of the resumed output (same convention as the
            # existing hard-kill Describe -- ffmpeg -c copy regenerates TS container
            # framing on every fresh input session, so byte-exact comparison does not
            # apply to a resumed session's output).
            $receivedAfterResumeProbe = & ffprobe -v error -show_entries stream=codec_type -of csv=p=0 $receivedAfterResumePath 2>&1
            $LASTEXITCODE | Should -Be 0
            $receivedAfterResumeProbe | Should -Not -BeNullOrEmpty

            # Whichever path was taken, the resumed session must end up fully on file 002
            # (rotation resolved) with a well-formed committed offset.
            $finalState = Restore-PusherOffset -StateFilePath $statePath
            $finalState.file | Should -Be $recording002Path
            ($finalState.byteOffset % $script:TransportStreamPacketSizeBytes) | Should -Be 0
        } finally {
            if ($pusherHandle1 -and -not $pusherHandle1.Process.HasExited) {
                Stop-Process -Id $pusherHandle1.Process.Id -Force -ErrorAction SilentlyContinue
                $pusherHandle1.Process.WaitForExit(5000) | Out-Null
            }
            if ($pusherHandle2 -and -not $pusherHandle2.Process.HasExited) {
                Stop-Process -Id $pusherHandle2.Process.Id -Force -ErrorAction SilentlyContinue
                $pusherHandle2.Process.WaitForExit(5000) | Out-Null
            }
            Stop-ValidMpegtsGrowthWriter -Writer $writer1
            if ($writer2) { Stop-ValidMpegtsGrowthWriter -Writer $writer2 }
            if (-not $listenerBeforeKill.HasExited) { Stop-SrtListener -Process $listenerBeforeKill }
            if ($listenerAfterResume -and -not $listenerAfterResume.HasExited) { Stop-SrtListener -Process $listenerAfterResume }
            Remove-Item -LiteralPath $testPusherPath1 -Force -ErrorAction SilentlyContinue
            if ($testPusherPath2) { Remove-Item -LiteralPath $testPusherPath2 -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'pause not stop: a brief growth stall with OBS reported alive does NOT trigger end-of-service (ROT-02)' {
        # Per-scenario unique work directory -- see rationale comment above.
        $testWorkDirectory   = Join-Path $TestDrive ("case-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $testWorkDirectory -Force | Out-Null
        $samplePath          = Join-Path $testWorkDirectory 'sample.ts'
        $recordingFolderPath = Join-Path $testWorkDirectory 'recordings'
        New-Item -ItemType Directory -Path $recordingFolderPath -Force | Out-Null
        $recordingPath = Join-Path $recordingFolderPath 'recording-001.ts'
        $receivedPath  = Join-Path $testWorkDirectory 'received.ts'
        $statePath     = Join-Path $testWorkDirectory 'offset.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 60 -VideoSize '320x240' -FrameRate 25 | Out-Null

        $listenPort                        = Get-Random -Minimum 20000 -Maximum 40000
        $pauseAfterSeconds                 = 3
        $pauseDurationSeconds               = 6
        $growthStallSustainedWindowSeconds = 2   # short, tuned window (test-only override, matches production D-19 tuning convention)
        $writer   = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath -IntervalMilliseconds 300 -ChunkSizeBytes 18800 `
            -TotalDurationSeconds 30 -PauseAfterSeconds $pauseAfterSeconds -PauseDurationSeconds $pauseDurationSeconds
        $listener = Start-SrtListener -Port $listenPort -OutputPath $receivedPath

        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort $listenPort -StateFilePath $statePath -GrowthStallSustainedWindowSeconds $growthStallSustainedWindowSeconds `
            -ObsLivenessOverrideLiteral '{ $true }'
        $pusherHandle = $null
        try {
            Start-Sleep -Milliseconds 800
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            (Wait-ForFileToExist -Path $statePath -TimeoutMilliseconds 15000) | Should -BeTrue

            # Wait past the ENTIRE pause window (writer stays alive, file stops growing)
            # plus a margin well beyond the tuned sustained-stall window -- if
            # pause-not-stop were broken, the pusher would already have declared
            # end-of-service and exited well before this point.
            Start-Sleep -Seconds ($pauseAfterSeconds + $pauseDurationSeconds + 2)

            $pusherHandle.Process.HasExited | Should -BeFalse -Because 'a brief growth stall with OBS liveness forced true must never be treated as end-of-service (D-07/D-08)'
            $writer.Process.HasExited | Should -BeFalse -Because 'the writer itself never exits during pause-not-stop, only its file growth pauses'

            # Growth resumes on its own once the pause window elapses (TestHelpers' own
            # writer behavior) -- confirm the pusher is still actively streaming
            # afterwards, not just idly alive.
            $receivedLengthBeforeResume = (Get-Item -LiteralPath $receivedPath -ErrorAction SilentlyContinue).Length
            if (-not $receivedLengthBeforeResume) { $receivedLengthBeforeResume = 0 }
            $resumedGrowth = Wait-ForFileGrowth -Path $receivedPath -TimeoutMilliseconds 15000 -MinimumLength ($receivedLengthBeforeResume + 1)
            $resumedGrowth | Should -BeTrue
            $pusherHandle.Process.HasExited | Should -BeFalse

            Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
            $pusherHandle.Process.WaitForExit(5000) | Out-Null
            Stop-ValidMpegtsGrowthWriter -Writer $writer

            $listener.WaitForExit(8000) | Out-Null
            if (-not $listener.HasExited) { Stop-SrtListener -Process $listener }
        } finally {
            if ($pusherHandle -and -not $pusherHandle.Process.HasExited) {
                Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
                $pusherHandle.Process.WaitForExit(5000) | Out-Null
            }
            Stop-ValidMpegtsGrowthWriter -Writer $writer
            if (-not $listener.HasExited) { Stop-SrtListener -Process $listener }
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'clean finish: pusher drains the final tail and exits with exit 0 at true end-of-service (ROT-02)' {
        # Per-scenario unique work directory -- see rationale comment above.
        $testWorkDirectory   = Join-Path $TestDrive ("case-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $testWorkDirectory -Force | Out-Null
        $samplePath          = Join-Path $testWorkDirectory 'sample.ts'
        $recordingFolderPath = Join-Path $testWorkDirectory 'recordings'
        New-Item -ItemType Directory -Path $recordingFolderPath -Force | Out-Null
        $recordingPath = Join-Path $recordingFolderPath 'recording-001.ts'
        $receivedPath  = Join-Path $testWorkDirectory 'received.ts'
        $statePath     = Join-Path $testWorkDirectory 'offset.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 60 -VideoSize '320x240' -FrameRate 25 | Out-Null

        $listenPort = Get-Random -Minimum 20000 -Maximum 40000
        $growthStallSustainedWindowSeconds = 2   # short, tuned window
        $writer   = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 6
        $listener = Start-SrtListener -Port $listenPort -OutputPath $receivedPath

        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort $listenPort -StateFilePath $statePath -GrowthStallSustainedWindowSeconds $growthStallSustainedWindowSeconds `
            -ObsLivenessOverrideLiteral '{ $false }'
        $pusherHandle = $null
        try {
            Start-Sleep -Milliseconds 800
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            (Wait-ForFileToExist -Path $statePath -TimeoutMilliseconds 15000) | Should -BeTrue

            # True end-of-service: the writer stops entirely (never resumes) and OBS
            # liveness is forced $false -- both signals agree (D-07).
            $writer.Process.WaitForExit(15000) | Out-Null
            $finalFileLength = (Get-Item -LiteralPath $recordingPath).Length
            $finalFileLength | Should -BeGreaterThan 0

            # The pusher must detect this itself and exit ON ITS OWN -- no external
            # Stop-Process here (the exact "no zombie loop" gate, D-11/Pitfall 1).
            # Bounded wait well beyond the tuned sustained-stall window so this fails
            # loudly (not hang the whole suite) if the pusher never notices.
            $exitedOnItsOwn = $pusherHandle.Process.WaitForExit(30000)
            $exitedOnItsOwn | Should -BeTrue -Because 'the pusher must self-exit at true end-of-service, never loop forever (Pitfall 1)'
            $pusherHandle.Process.ExitCode | Should -Be 0

            $listener.WaitForExit(8000) | Out-Null
            if (-not $listener.HasExited) { Stop-SrtListener -Process $listener }

            $committedState = Restore-PusherOffset -StateFilePath $statePath
            $committedState.file | Should -Be $recordingPath
            $committedState.byteOffset | Should -Be $finalFileLength -Because 'the final tail must be fully drained before a clean exit (D-11)'

            $receivedLength = (Get-Item -LiteralPath $receivedPath -ErrorAction SilentlyContinue).Length
            $receivedLength | Should -BeGreaterThan 0
            # Same measured container-framing tolerance as the rotation scenarios above --
            # this site carried the identical unsatisfiable assertion (the committed offset
            # is the full drained file length, which the receiving ffmpeg re-frames).
            Test-DeliveredPrefixIntact -SourcePath $recordingPath -ReceivedPath $receivedPath -ExpectedDeliveredLength $committedState.byteOffset | Should -BeTrue

            $receivedProbe = & ffprobe -v error -show_entries stream=codec_type -of csv=p=0 $receivedPath 2>&1
            $LASTEXITCODE | Should -Be 0
            $receivedProbe | Should -Not -BeNullOrEmpty
        } finally {
            if ($pusherHandle -and -not $pusherHandle.Process.HasExited) {
                Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
                $pusherHandle.Process.WaitForExit(5000) | Out-Null
            }
            Stop-ValidMpegtsGrowthWriter -Writer $writer
            if (-not $listener.HasExited) { Stop-SrtListener -Process $listener }
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }
}

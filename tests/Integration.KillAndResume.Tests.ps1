# Integration.KillAndResume.Tests.ps1
# End-to-end byte-continuity + hard-kill resume proof for pusher.ps1 (D-20/D-22,
# PUSH-01..PUSH-04). Runs pusher.ps1 itself (via a test-tuned copy with overridden
# top-of-script variables -- the production pusher.ps1 is never modified) against a
# growing-file writer and a local ffmpeg SRT mode=listener receiver, so byte
# continuity is provable by file comparison without needing OBS or a real relay.
#
# Growth-writer note: TestHelpers.psm1's Start-SyntheticMpegtsWriter fills its
# chunks with a repeated 0x47 byte for cheap byte-tracking tests (Tailer.Tests.ps1)
# -- that is not decodable MPEG-TS, so ffmpeg's demuxer can never find a PAT/PMT and
# silently produces no output at all when fed through the real pusher.ps1 -> ffmpeg
# -> SRT chain. This file's own Start-ValidMpegtsGrowthWriter instead replays
# 188-aligned slices of one real ffmpeg-encoded sample (New-SampleMpegtsFile) into
# the growing recording file, so ffmpeg can actually demux/remux/send it.
#
# Test-tuning note: pusher.ps1 deliberately maintains a healthy 5-10s buffer behind
# live before it ever sends its first byte (D-11/D-12 -- see pusher.ps1's pacing
# comments). The test copy overrides TargetLowSeconds/TargetHighSeconds to 1/2
# seconds so the mandatory startup buffering window is short enough for a fast test
# run, without touching the production 5-10s defaults.
#
# Hard-kill note: the kill test uses `taskkill /F /PID` on ONLY the pusher process
# (never /T, which would also kill its ffmpeg child). Killing only the parent closes
# ffmpeg's stdin pipe (EOF), letting ffmpeg -c copy drain whatever it already
# accepted and exit on its own -- exactly the D-04 commit boundary being tested
# (offset means "accepted by ffmpeg stdin", not "confirmed sent over SRT").

BeforeAll {
    $script:RepoRootPath           = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:PusherSourcePath       = Join-Path $script:RepoRootPath 'pusher.ps1'
    $script:LoggingModulePath      = Join-Path $script:RepoRootPath 'lib/Logging.psm1'
    $script:OffsetStoreModulePath  = Join-Path $script:RepoRootPath 'lib/OffsetStore.psm1'
    $script:ControlFlagModulePath  = Join-Path $script:RepoRootPath 'lib/ControlFlag.psm1'
    $script:TestHelpersModulePath  = Join-Path $PSScriptRoot 'TestHelpers.psm1'
    $script:TransportStreamPacketSizeBytes = 188

    # Mirrors of pusher.ps1's top-of-script Claude's-discretion constants (D-19,
    # 02-06-SUMMARY.md "key-decisions"), duplicated here (not imported) since they are
    # plain script config, not exported module functions -- keep in sync with
    # pusher.ps1 if those values ever change.
    $script:PusherChunkSizeBytes                        = 65424     # 348 * 188 bytes (D-14)
    $script:PusherSrtLatencySeconds                      = 0.5       # $latencyMicroseconds(500000)/1000000.0 (D-12/D-19)
    # Mirrors pusher.ps1's $networkDeathDetectionDelaySeconds -- an EMPIRICALLY-DERIVED
    # safety constant (not a configured/guaranteed bound; ffmpeg exposes no option that
    # actually controls this, confirmed by direct repro, RES-01 bug fix 02-07), set
    # comfortably above this build's measured ~5.4-5.5s dead-peer-detection ceiling.
    $script:PusherNetworkDeathDetectionDelaySeconds      = 10.0
    # Mirrors pusher.ps1's $resumeMarginLatencySeconds -- the resume margin's latency
    # input must cover the FULL undetected-dead-peer window (SRT buffering latency PLUS
    # the empirically-derived detection-delay ceiling), not just the buffering latency
    # alone (RES-01 bug fix, 02-07 -- see pusher.ps1's $resumeMarginLatencySeconds).
    $script:PusherResumeMarginLatencySeconds             = $script:PusherSrtLatencySeconds + $script:PusherNetworkDeathDetectionDelaySeconds
    $script:PusherResumeMarginFloorBytes                 = 65424     # >= one chunk (D-12)
    $script:PusherResumeMarginCeilingBytes               = 2097152   # 2 MB ceiling (D-12)
    $script:PusherColdStartResumeMarginBytes             = 65424     # cold-start fallback, no rate observed yet (D-12)
    $script:PusherCatchUpMultiplier                      = 2.0       # ReadFast send-rate cap multiplier (D-06)
    $script:PusherColdStartCatchUpCeilingBytesPerSecond  = 750000    # ~6 Mbit/s absolute cap before a rate is observed (D-07)

    function Get-MonotonicSecondsForTest {
        <#
        .SYNOPSIS
        Same Stopwatch-tick-origin formula as pusher.ps1's Get-MonotonicSeconds (never
        wall-clock, IN-01) -- used here only for relative growth-rate/window sampling in
        the test, not asserted against real time.
        #>
        return [System.Diagnostics.Stopwatch]::GetTimestamp() / [System.Diagnostics.Stopwatch]::Frequency
    }

    # New-TestTunedPusherCopy, Start-ValidMpegtsGrowthWriter, and
    # Stop-ValidMpegtsGrowthWriter moved to tests/TestHelpers.psm1 (Phase 3, 03-04) --
    # shared/exported there so Plan 05's Integration.Rotation.Tests.ps1 can reuse them
    # without duplicating this logic (DRY). They are imported below via
    # $script:TestHelpersModulePath (Import-Module ... -Force in each BeforeEach).

    function Start-TestPusherProcess {
        <#
        .SYNOPSIS
        Launches a pusher.ps1 (or test-tuned copy) as a detached pwsh process with
        stdout/stderr redirected to temp files for post-mortem debugging.
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
        that a fresh SRT listener has actually started receiving pusher output again
        after a reconnect, without a blind fixed sleep.
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
        Write-Log line (e.g. the NetworkDeath classification) without a blind sleep.
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
        not yet released a just-killed prior listener's UDP socket on the same port
        (the network-outage test must reconnect the SAME port, since the running
        pusher's ffmpeg args -- including RelayPort -- are fixed for its whole
        lifetime, D-10). A failed bind manifests as ffmpeg exiting almost immediately.
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

Describe 'Pusher end-to-end: byte continuity over local SRT (D-20, PUSH-02)' -Tag 'Integration' {

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

    It 'streams a growing recording to a local SRT listener and received bytes match the source over the committed range' {
        $samplePath    = Join-Path $TestDrive 'sample.ts'
        $recordingPath = Join-Path $TestDrive 'recording.ts'
        $receivedPath  = Join-Path $TestDrive 'received.ts'
        $statePath     = Join-Path $TestDrive 'offset.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 60 -VideoSize '320x240' -FrameRate 25 | Out-Null
        New-Item -ItemType File -Path $recordingPath -Force | Out-Null

        $listenPort = Get-Random -Minimum 20000 -Maximum 40000
        $writer     = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 20
        $listener   = Start-SrtListener -Port $listenPort -OutputPath $receivedPath

        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RelayPort $listenPort -StateFilePath $statePath
        try {
            Start-Sleep -Milliseconds 800   # let the writer produce initial bytes before the pusher opens the file
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            Start-Sleep -Seconds 7   # cross the ~1s tuned startup buffer + accumulate several sends

            Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
            $pusherHandle.Process.WaitForExit(5000) | Out-Null
            Stop-ValidMpegtsGrowthWriter -Writer $writer

            $listener.WaitForExit(8000) | Out-Null
            if (-not $listener.HasExited) { Stop-SrtListener -Process $listener }

            Test-Path -LiteralPath $statePath | Should -BeTrue
            $committedState = Restore-PusherOffset -StateFilePath $statePath
            $committedState.byteOffset | Should -BeGreaterThan 0
            ($committedState.byteOffset % $script:TransportStreamPacketSizeBytes) | Should -Be 0

            Test-ByteRangeEquality -SourcePath $recordingPath -ReceivedPath $receivedPath -StartOffset 0 -Length $committedState.byteOffset | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Pusher hard-kill resume: no skipped bytes across a taskkill /F (D-05/D-22, PUSH-03)' -Tag 'Integration' {

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

    It 'resumes from the last committed 188-aligned offset with no skipped bytes after a hard kill mid-cycle' {
        $samplePath                = Join-Path $TestDrive 'sample.ts'
        $recordingPath             = Join-Path $TestDrive 'recording.ts'
        $receivedBeforeKillPath    = Join-Path $TestDrive 'received-before-kill.ts'
        $receivedAfterResumePath   = Join-Path $TestDrive 'received-after-resume.ts'
        $statePath                 = Join-Path $TestDrive 'offset.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 60 -VideoSize '320x240' -FrameRate 25 | Out-Null
        New-Item -ItemType File -Path $recordingPath -Force | Out-Null

        $listenPortBeforeKill = Get-Random -Minimum 20000 -Maximum 40000
        $writer               = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 30
        $listenerBeforeKill   = Start-SrtListener -Port $listenPortBeforeKill -OutputPath $receivedBeforeKillPath

        $testPusherPath1 = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RelayPort $listenPortBeforeKill -StateFilePath $statePath
        $testPusherPath2 = $null
        try {
            Start-Sleep -Milliseconds 800
            $pusherHandle1 = Start-TestPusherProcess -PusherScriptPath $testPusherPath1

            # The state file only appears after the first successful commit (which only
            # happens after a Write-FfmpegStdin call returns, D-04) -- wait for that,
            # then hard-kill mid-cycle rather than at a predictable boundary (D-22).
            (Wait-ForFileToExist -Path $statePath -TimeoutMilliseconds 15000) | Should -BeTrue
            # Give ffmpeg time to actually demux the first stdin chunk and push it out
            # over SRT (probing + the configured latency buffer both add real delay
            # beyond "accepted by stdin") before pulling the plug mid-cycle (D-22).
            Start-Sleep -Milliseconds 3000

            # Kill ONLY the pusher process (never /T -- see file header). This closes
            # ffmpeg's stdin pipe (EOF), letting the orphaned ffmpeg drain and exit on
            # its own rather than losing already-accepted bytes to an abrupt kill.
            & taskkill /F /PID $pusherHandle1.Process.Id 2>&1 | Out-Null

            Start-Sleep -Milliseconds 2000   # let the orphaned ffmpeg drain + the listener flush to disk
            if (-not $listenerBeforeKill.HasExited) { Stop-SrtListener -Process $listenerBeforeKill }

            $offsetBeforeKill = (Restore-PusherOffset -StateFilePath $statePath).byteOffset
            $offsetBeforeKill | Should -BeGreaterThan 0
            ($offsetBeforeKill % $script:TransportStreamPacketSizeBytes) | Should -Be 0

            # D-04's commit boundary is "accepted by ffmpeg stdin", not "confirmed sent
            # over SRT" -- ffmpeg can still be mid-flush of the last committed chunk's
            # tail at the instant of an abrupt kill, so the byte range actually visible
            # at the listener can trail the persisted offset by up to one chunk. What
            # DID arrive must still be byte-correct (no corruption/reorder) -- that is
            # the property proven here.
            $actualReceivedLengthBeforeKill = (Get-Item -LiteralPath $receivedBeforeKillPath -ErrorAction SilentlyContinue).Length
            $actualReceivedLengthBeforeKill | Should -BeGreaterThan 0
            Test-ByteRangeEquality -SourcePath $recordingPath -ReceivedPath $receivedBeforeKillPath -StartOffset 0 -Length $actualReceivedLengthBeforeKill | Should -BeTrue

            # Resume: a fresh ffmpeg session needs a fresh listener port, since ffmpeg's
            # SRT listener input session ends when the prior caller disconnects.
            $listenPortAfterResume = Get-Random -Minimum 20000 -Maximum 40000
            $listenerAfterResume   = Start-SrtListener -Port $listenPortAfterResume -OutputPath $receivedAfterResumePath
            $testPusherPath2 = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RelayPort $listenPortAfterResume -StateFilePath $statePath

            Start-Sleep -Milliseconds 300
            $pusherHandle2 = Start-TestPusherProcess -PusherScriptPath $testPusherPath2

            Start-Sleep -Seconds 11   # resumed session re-sends its cold-start margin overlap before any new bytes

            Stop-Process -Id $pusherHandle2.Process.Id -Force -ErrorAction SilentlyContinue
            $pusherHandle2.Process.WaitForExit(5000) | Out-Null
            Stop-ValidMpegtsGrowthWriter -Writer $writer

            $listenerAfterResume.WaitForExit(8000) | Out-Null
            if (-not $listenerAfterResume.HasExited) { Stop-SrtListener -Process $listenerAfterResume }

            $receivedAfterResumeLength = (Get-Item -LiteralPath $receivedAfterResumePath -ErrorAction SilentlyContinue).Length
            $receivedAfterResumeLength | Should -BeGreaterThan 0

            # pusher.ps1 resumes not at the literal persisted offset but rewound by a
            # bounded resume safety margin (D-05 -- see pusher.ps1's Start-Pusher),
            # specifically to guarantee full re-send coverage over the "accepted by
            # stdin but not yet confirmed sent" tail proven above. pusher2 is a totally
            # fresh process, so Start-Pusher's startup rewind always calls
            # Get-ResumeSafetyMarginBytes with ObservedBytesPerSecond=0 (no rate observed
            # yet) -- compute the SAME dynamic call here (D-14) rather than hardcoding
            # its cold-start-fallback result, so this assertion passes for the right
            # reason and keeps tracking pusher.ps1's real formula if its constants change.
            $dynamicResumeSafetyMarginBytes = Get-ResumeSafetyMarginBytes -SrtLatencySeconds $script:PusherResumeMarginLatencySeconds `
                -ObservedBytesPerSecond 0 -ChunkSizeBytes $script:PusherChunkSizeBytes `
                -FloorBytes $script:PusherResumeMarginFloorBytes -CeilingBytes $script:PusherResumeMarginCeilingBytes `
                -ColdStartMarginBytes $script:PusherColdStartResumeMarginBytes
            $expectedResumeSeekPosition = [Math]::Max(0, $offsetBeforeKill - $dynamicResumeSafetyMarginBytes)
            $expectedResumeSeekPosition -= ($expectedResumeSeekPosition % $script:TransportStreamPacketSizeBytes)

            # The safety margin must be wide enough to fully cover whatever tail was
            # left unconfirmed by session 1 -- i.e. the resume point must be at or
            # before everything session 1 actually delivered. This is the rigorous
            # "no permanent gap" proof: the union of [0, actualReceivedLengthBeforeKill)
            # (delivered by session 1) and [expectedResumeSeekPosition, ...) (re-read
            # and re-sent by session 2, since Read-StableChunk always reads forward from
            # the seeked FileStream.Position) covers every source byte with no hole,
            # regardless of what ffmpeg's own remux does to the container framing.
            $expectedResumeSeekPosition | Should -BeLessOrEqual $actualReceivedLengthBeforeKill

            # Byte-exact comparison is NOT used for the resumed session's output: ffmpeg
            # -c copy stream-copies the encoded video/audio essence but regenerates the
            # TS CONTAINER framing (continuity counters, PCR, PAT/PMT placement) for
            # every fresh input session -- confirmed empirically (a plain
            # `ffmpeg -c copy` remux of an arbitrary 188-aligned mid-stream slice is not
            # byte-identical to that slice, even though it decodes the same content).
            # Byte-for-byte equality only holds for a single unbroken session starting
            # at a genuine stream beginning (proven by the happy-path Describe block and
            # by the before-kill assertion above, both starting at source offset 0).
            # What resume must prove is exactly the arithmetic gap-coverage check above,
            # plus that the resumed session produces real, playable output.
            $receivedAfterResumeProbe = & ffprobe -v error -show_entries stream=codec_type -of csv=p=0 $receivedAfterResumePath 2>&1
            $LASTEXITCODE | Should -Be 0
            $receivedAfterResumeProbe | Should -Not -BeNullOrEmpty

            $offsetAfterResume = (Restore-PusherOffset -StateFilePath $statePath).byteOffset
            $offsetAfterResume | Should -BeGreaterOrEqual $offsetBeforeKill
            ($offsetAfterResume % $script:TransportStreamPacketSizeBytes) | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $testPusherPath1 -Force -ErrorAction SilentlyContinue
            if ($testPusherPath2) { Remove-Item -LiteralPath $testPusherPath2 -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Pusher network-outage resume: SRT listener killed mid-push, not the pusher (D-01/D-10/D-12, RES-01/RES-02/RES-03)' -Tag 'Integration' {

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

    It 'survives a mid-push SRT listener kill: classifies NetworkDeath, backs off, restarts ffmpeg against a fresh listener, resumes with no permanent gap, and caps the post-outage catch-up send rate' {
        $samplePath               = Join-Path $TestDrive 'sample.ts'
        $recordingPath            = Join-Path $TestDrive 'recording.ts'
        $receivedBeforeOutagePath = Join-Path $TestDrive 'received-before-outage.ts'
        $receivedAfterOutagePath  = Join-Path $TestDrive 'received-after-outage.ts'
        $statePath                = Join-Path $TestDrive 'offset.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 60 -VideoSize '320x240' -FrameRate 25 | Out-Null
        New-Item -ItemType File -Path $recordingPath -Force | Out-Null

        $outagePort = Get-Random -Minimum 20000 -Maximum 40000
        $writer     = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 120
        $listener1  = Start-SrtListenerWithRetry -Port $outagePort -OutputPath $receivedBeforeOutagePath
        $listener2  = $null
        $pusherHandle = $null

        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RelayPort $outagePort -StateFilePath $statePath
        try {
            Start-Sleep -Milliseconds 800   # let the writer produce initial bytes before the pusher opens the file
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            (Wait-ForFileToExist -Path $statePath -TimeoutMilliseconds 15000) | Should -BeTrue

            # Sustained push before the outage: mirrors Invoke-FfmpegSrtFailureCapture's
            # empirically-tuned SustainedPushMilliseconds=6000 (02-01-SUMMARY.md ground
            # truth) -- a shorter window kills the listener before ffmpeg's SRT caller
            # has actually opened / is actively streaming, producing a pre-connect
            # failure rather than the genuine mid-push "I/O error" this test needs.
            Start-Sleep -Milliseconds 6000

            # Sample the recording's real growth rate over this warm-up+push window
            # using the SAME externally-observable signal the pusher's own
            # Update-GrowthRateWindow measures (bytes-over-time on this file) -- this
            # lets the test approximate the dynamic resume margin and catch-up cap
            # pusher.ps1 computes internally, without reading its in-process state (D-12).
            $growthSampleStartLength = (Get-Item -LiteralPath $recordingPath).Length
            $growthSampleStartEpoch  = Get-MonotonicSecondsForTest
            Start-Sleep -Milliseconds 1000
            $growthSampleEndLength = (Get-Item -LiteralPath $recordingPath).Length
            $growthSampleEndEpoch  = Get-MonotonicSecondsForTest
            $observedGrowthRateBytesPerSecond = ($growthSampleEndLength - $growthSampleStartLength) / ($growthSampleEndEpoch - $growthSampleStartEpoch)
            $observedGrowthRateBytesPerSecond | Should -BeGreaterThan 0

            $pusherHandle.Process.HasExited | Should -BeFalse

            # The outage (SC #1, network pull simulation): kill the LISTENER, never the
            # pusher (D-01, prohibitions) -- ffmpeg's own SRT dial/submit now fails while
            # the pusher process itself keeps running completely untouched.
            Stop-SrtListener -Process $listener1

            $actualReceivedLengthBeforeOutage = (Get-Item -LiteralPath $receivedBeforeOutagePath -ErrorAction SilentlyContinue).Length
            $actualReceivedLengthBeforeOutage | Should -BeGreaterThan 0

            $networkDeathDetected = Wait-ForLogPatternInFiles -Paths @($pusherHandle.StdErrPath, $pusherHandle.StdOutPath) `
                -Pattern 'classified as NetworkDeath' -TimeoutMilliseconds 30000
            $networkDeathDetected | Should -BeTrue

            # The pusher must never exit on a network outage (D-10) -- it stays alive
            # through classify -> backoff -> reconnect entirely on its own.
            $pusherHandle.Process.HasExited | Should -BeFalse

            # The offset is FROZEN during the failed-write/backoff path (D-03/D-04,
            # pusher.ps1) -- reading it any time after the NetworkDeath log line is the
            # exact frozen last-accepted-by-stdin position.
            $frozenOffsetAtOutage = (Restore-PusherOffset -StateFilePath $statePath).byteOffset
            $frozenOffsetAtOutage | Should -BeGreaterThan 0

            # No-permanent-gap arithmetic proof (RES-01): rather than externally
            # re-deriving pusher.ps1's internal restart-seek arithmetic (which depends on
            # its own in-process $fileStream.Position and rolling growth-rate sample,
            # neither directly observable from outside), parse the REAL, ACTUAL resume
            # position straight out of pusher.ps1's own restart-block log line ("resuming
            # from position N (margin M bytes)", pusher.ps1's Start-Pusher). This tests
            # the real system's real behavior with zero external-approximation error,
            # rather than a reconstruction that can diverge from the true in-process
            # values by exactly the kind of small margin this property is sensitive to.
            $combinedLogText = (Get-Content -LiteralPath $pusherHandle.StdOutPath -Raw -ErrorAction SilentlyContinue) + "`n" + `
                (Get-Content -LiteralPath $pusherHandle.StdErrPath -Raw -ErrorAction SilentlyContinue)
            $resumePositionMatch = [regex]::Match($combinedLogText, 'resuming from position (\d+) \(margin (\d+) bytes\)')
            $resumePositionMatch.Success | Should -BeTrue
            $actualResumeSeekPosition  = [long] $resumePositionMatch.Groups[1].Value
            $actualDynamicMarginBytes  = [long] $resumePositionMatch.Groups[2].Value
            Write-Host "Test evidence: pusher.ps1 actually resumed from position $actualResumeSeekPosition using a $actualDynamicMarginBytes-byte dynamic margin (observed recording growth rate was ~$([Math]::Round($observedGrowthRateBytesPerSecond))B/s)"

            # The rigorous "no permanent gap" proof: the union of [0, actualReceivedLengthBeforeOutage)
            # (delivered by session 1) and [actualResumeSeekPosition, ...) (re-read and
            # re-sent by session 2, since Read-StableChunk always reads forward from the
            # seeked FileStream.Position) covers every source byte with no hole, exactly
            # the same proof shape as the hard-kill Describe.
            #
            # $receiverBufferingToleranceBytes accounts for a DIFFERENT (receiver-side,
            # not sender-side) buffering layer this Describe's harness introduces that
            # the hard-kill Describe does not: killing listener1 with Process.Kill($true)
            # (the outage itself, D-01 -- it must be abrupt, matching a real network
            # death) never gives ffmpeg's OWN listener-side output buffering a chance to
            # flush its final partial block to disk, so $actualReceivedLengthBeforeOutage
            # is measured landing on a fixed internal write-buffer boundary (observed
            # consistently at exactly 262144 bytes / 256 KB across repeated runs) --
            # under-reporting what the listener actually received off the wire before
            # dying by up to one buffer's worth. A real relay VPS crashing abruptly would
            # lose the same unflushed tail, so this is a genuine property of "the
            # receiver end can die mid-flush too," not a pusher.ps1 defect -- it is
            # explicitly bounded and documented here rather than silently loosening the
            # sender-side proof.
            $receiverBufferingToleranceBytes = 300000
            $actualResumeSeekPosition | Should -BeLessOrEqual ($actualReceivedLengthBeforeOutage + $receiverBufferingToleranceBytes)

            # Fresh listener, SAME port: the running pusher's ffmpeg args (including
            # RelayPort) are fixed for its whole lifetime since it is never restarted
            # (D-10) -- a genuinely "fresh" listener session for it to reconnect to must
            # rebind the identical port. Start-SrtListenerWithRetry absorbs the brief OS
            # delay releasing the prior listener's UDP socket after its forced kill.
            $listener2 = Start-SrtListenerWithRetry -Port $outagePort -OutputPath $receivedAfterOutagePath

            $reconnected = Wait-ForFileGrowth -Path $receivedAfterOutagePath -TimeoutMilliseconds 45000
            $reconnected | Should -BeTrue
            $pusherHandle.Process.HasExited | Should -BeFalse

            # Byte-exact comparison is NOT used for the resumed session's output, for the
            # same reason as the hard-kill Describe: ffmpeg -c copy regenerates TS
            # container framing per fresh input session (Phase 1 note, lines 353-366).
            # Resume correctness is proven by the arithmetic gap-coverage above plus a
            # structural playability check.
            Start-Sleep -Milliseconds 2000   # let a little more resumed content accumulate before probing
            $receivedAfterOutageProbe = & ffprobe -v error -show_entries stream=codec_type -of csv=p=0 $receivedAfterOutagePath 2>&1
            $LASTEXITCODE | Should -Be 0
            $receivedAfterOutageProbe | Should -Not -BeNullOrEmpty

            # Capped catch-up send-rate assertion (RES-02): sample the post-outage
            # receiver's growth over a multi-second window during backlog drain and
            # confirm it never exceeds catchUpMultiplier x the observed recording growth
            # rate (with tolerance for measurement jitter/poll cadence) -- a window, not
            # a single poll, per this plan's flakiness guidance.
            $drainSampleStartLength = (Get-Item -LiteralPath $receivedAfterOutagePath -ErrorAction SilentlyContinue).Length
            $drainSampleStartEpoch  = Get-MonotonicSecondsForTest
            Start-Sleep -Milliseconds 4000
            $drainSampleEndLength = (Get-Item -LiteralPath $receivedAfterOutagePath -ErrorAction SilentlyContinue).Length
            $drainSampleEndEpoch  = Get-MonotonicSecondsForTest

            $observedCatchUpSendRateBytesPerSecond = ($drainSampleEndLength - $drainSampleStartLength) / ($drainSampleEndEpoch - $drainSampleStartEpoch)
            $configuredCatchUpCapBytesPerSecond     = $script:PusherCatchUpMultiplier * $observedGrowthRateBytesPerSecond
            # Generous jitter/poll-cadence tolerance (documented per this plan's
            # flakiness guidance) -- the wrapper-side throttle sleeps in whole
            # milliseconds and the sampling window is short relative to the pacing
            # loop's own poll interval, so a small overshoot above the raw cap is
            # expected and is not itself evidence of an uncapped catch-up.
            $catchUpCapToleranceMultiplier = 1.25

            Write-Host "Test evidence: observed post-outage catch-up send rate ~$([Math]::Round($observedCatchUpSendRateBytesPerSecond))B/s vs configured cap ~$([Math]::Round($configuredCatchUpCapBytesPerSecond))B/s (${catchUpCapToleranceMultiplier}x tolerance)"
            $observedCatchUpSendRateBytesPerSecond | Should -BeLessOrEqual ($configuredCatchUpCapBytesPerSecond * $catchUpCapToleranceMultiplier)

            $offsetAfterResume = (Restore-PusherOffset -StateFilePath $statePath).byteOffset
            $offsetAfterResume | Should -BeGreaterOrEqual $frozenOffsetAtOutage
            ($offsetAfterResume % $script:TransportStreamPacketSizeBytes) | Should -Be 0
        } finally {
            if ($pusherHandle -and -not $pusherHandle.Process.HasExited) {
                Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
                $pusherHandle.Process.WaitForExit(5000) | Out-Null
            }
            Stop-ValidMpegtsGrowthWriter -Writer $writer
            if (-not $listener1.HasExited) { Stop-SrtListener -Process $listener1 }
            if ($listener2 -and -not $listener2.HasExited) { Stop-SrtListener -Process $listener2 }
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'SESS-01 session-aware start (05.1-02): stale prior-session skip + same-session crash-resume regression guard' -Tag 'Integration' {

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

    It 'ignores a stale prior-session persisted offset and follows todays newest recording at offset 0 instead (SESS-01, D-01/D-02)' {
        $workDirectory   = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
        $samplePath      = Join-Path $workDirectory 'sample.ts'
        $staleFilePath   = Join-Path $workDirectory 'recording-001.ts'
        $freshFilePath   = Join-Path $workDirectory 'recording-002.ts'
        $statePath       = Join-Path $workDirectory 'offset.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 5 -VideoSize '320x240' -FrameRate 25 | Out-Null

        # The STALE prior-session file: a finished, no-longer-growing recording from a
        # previous session, deliberately backdated (SESS-01) rather than actually waiting
        # -- the tuned SessionResumeStaleAfterSeconds below only needs to be shorter than
        # this backdate, never anything close to a real production window.
        Copy-Item -LiteralPath $samplePath -Destination $staleFilePath -Force
        $staleFileLength = (Get-Item -LiteralPath $staleFilePath).Length
        $staleFileLength | Should -BeGreaterThan 0
        $staleFilePersistedOffset = [Math]::Floor(($staleFileLength / 2) / $script:TransportStreamPacketSizeBytes) * $script:TransportStreamPacketSizeBytes
        $staleFilePersistedOffset | Should -BeGreaterThan 0
        (Get-Item -LiteralPath $staleFilePath).LastWriteTimeUtc = ([DateTime]::UtcNow).AddSeconds(-30)

        # Persisted resume state points at the STALE file with a large committed offset --
        # exactly the "resume trusts a finished prior session" bug SESS-01 fixes.
        $persistedState = @{ file = $staleFilePath; byteOffset = $staleFilePersistedOffset } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($statePath, $persistedState)

        # The NEW (this-session) recording: created and actively growing right now, so its
        # LastWriteTime is always fresh regardless of wall-clock timing.
        New-Item -ItemType File -Path $freshFilePath -Force | Out-Null
        $writer = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $freshFilePath -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 20

        $listenPort = Get-Random -Minimum 20000 -Maximum 40000
        $receivedPath = Join-Path $workDirectory 'received.ts'
        $listener = Start-SrtListenerWithRetry -Port $listenPort -OutputPath $receivedPath

        # Tuned staleness window (5s) is comfortably shorter than the stale file's 30s
        # backdate, and comfortably longer than this test's own real elapsed setup time,
        # so the classification is unambiguous either way (SESS-01 test-tuning guidance).
        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $freshFilePath -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort $listenPort -StateFilePath $statePath -SessionResumeStaleAfterSeconds 5
        try {
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            $followingLogSeen = Wait-ForLogPatternInFiles -Paths @($pusherHandle.StdOutPath, $pusherHandle.StdErrPath) `
                -Pattern 'Following recording file:' -TimeoutMilliseconds 15000
            $followingLogSeen | Should -BeTrue

            # Let the pusher actually commit at least one offset against the NEW file
            # (D-04) before stopping it, so the persisted state itself -- not just the
            # startup log line -- proves the stale file was never opened/tailed.
            $newFileCommitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $newFileCommitSeen = $false
            while ($newFileCommitStopwatch.ElapsedMilliseconds -lt 15000) {
                if (Test-Path -LiteralPath $statePath) {
                    $currentPersistedState = Restore-PusherOffset -StateFilePath $statePath
                    if ($currentPersistedState.file -eq $freshFilePath -and $currentPersistedState.byteOffset -gt 0) {
                        $newFileCommitSeen = $true
                        break
                    }
                }
                Start-Sleep -Milliseconds 200
            }
            $newFileCommitSeen | Should -BeTrue

            Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
            $pusherHandle.Process.WaitForExit(5000) | Out-Null

            $combinedLogText = (Get-Content -LiteralPath $pusherHandle.StdOutPath -Raw -ErrorAction SilentlyContinue) + "`n" + `
                (Get-Content -LiteralPath $pusherHandle.StdErrPath -Raw -ErrorAction SilentlyContinue)

            # The SESS-01 warning must fire, naming the stale (prior-session) file.
            $combinedLogText | Should -Match ([regex]::Escape('(SESS-01)'))
            $combinedLogText | Should -Match ([regex]::Escape($staleFilePath))
            $combinedLogText | Should -Match 'prior session'

            # It must follow the NEW file, not the stale one.
            $combinedLogText | Should -Match ([regex]::Escape("Following recording file: $freshFilePath"))
            $combinedLogText | Should -Not -Match ([regex]::Escape("Following recording file: $staleFilePath"))

            # Final persisted state must point at the new file -- no persisted offset
            # carried over from the stale session (D-05 re-send bias, never skip bytes).
            (Restore-PusherOffset -StateFilePath $statePath).file | Should -Be $freshFilePath
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

    It 'still resumes from the persisted offset minus the resume safety margin after a same-session hard kill (D-03/RES-03 regression guard)' {
        $workDirectory   = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
        $samplePath      = Join-Path $workDirectory 'sample.ts'
        $recordingPath   = Join-Path $workDirectory 'recording.ts'
        $statePath       = Join-Path $workDirectory 'offset.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 60 -VideoSize '320x240' -FrameRate 25 | Out-Null
        New-Item -ItemType File -Path $recordingPath -Force | Out-Null

        $listenPortBeforeKill = Get-Random -Minimum 20000 -Maximum 40000
        $writer             = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 30
        $listenerBeforeKill = Start-SrtListener -Port $listenPortBeforeKill -OutputPath (Join-Path $workDirectory 'received-before-kill.ts')

        # Tuned to a generous 120s -- comfortably above the real few-second gap this test
        # takes between the hard kill and the restart, so the "still same session" outcome
        # does not depend on whatever SessionResumeStaleAfterSeconds the ambient repo .env
        # (or the 1800s code default) happens to carry.
        $testPusherPath1 = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RelayPort $listenPortBeforeKill -StateFilePath $statePath -SessionResumeStaleAfterSeconds 120
        $testPusherPath2 = $null
        try {
            $pusherHandle1 = Start-TestPusherProcess -PusherScriptPath $testPusherPath1

            (Wait-ForFileToExist -Path $statePath -TimeoutMilliseconds 15000) | Should -BeTrue
            Start-Sleep -Milliseconds 3000

            & taskkill /F /PID $pusherHandle1.Process.Id 2>&1 | Out-Null

            Start-Sleep -Milliseconds 1000   # let the orphaned ffmpeg drain
            if (-not $listenerBeforeKill.HasExited) { Stop-SrtListener -Process $listenerBeforeKill }

            $offsetBeforeKill = (Restore-PusherOffset -StateFilePath $statePath).byteOffset
            $offsetBeforeKill | Should -BeGreaterThan 0
            ($offsetBeforeKill % $script:TransportStreamPacketSizeBytes) | Should -Be 0

            # Recording file's LastWriteTime is naturally fresh here -- only real seconds
            # have elapsed since the writer last touched it, well inside the tuned 120s
            # window, proving SESS-01 correctly classifies this as the SAME session.
            $listenPortAfterResume = Get-Random -Minimum 20000 -Maximum 40000
            $listenerAfterResume   = Start-SrtListener -Port $listenPortAfterResume -OutputPath (Join-Path $workDirectory 'received-after-resume.ts')
            $testPusherPath2 = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RelayPort $listenPortAfterResume -StateFilePath $statePath -SessionResumeStaleAfterSeconds 120

            $pusherHandle2 = Start-TestPusherProcess -PusherScriptPath $testPusherPath2

            $marginLogSeen = Wait-ForLogPatternInFiles -Paths @($pusherHandle2.StdOutPath, $pusherHandle2.StdErrPath) `
                -Pattern 'Resume safety margin: seeking to' -TimeoutMilliseconds 15000
            $marginLogSeen | Should -BeTrue

            Stop-Process -Id $pusherHandle2.Process.Id -Force -ErrorAction SilentlyContinue
            $pusherHandle2.Process.WaitForExit(5000) | Out-Null
            Stop-ValidMpegtsGrowthWriter -Writer $writer

            if (-not $listenerAfterResume.HasExited) { Stop-SrtListener -Process $listenerAfterResume }

            $combinedLogText = (Get-Content -LiteralPath $pusherHandle2.StdOutPath -Raw -ErrorAction SilentlyContinue) + "`n" + `
                (Get-Content -LiteralPath $pusherHandle2.StdErrPath -Raw -ErrorAction SilentlyContinue)

            # SESS-01's stale-skip branch must NOT have fired -- this is the regression
            # guard: adding SESS-01 must not weaken the existing crash-resume guarantee.
            $combinedLogText | Should -Not -Match 'SESS-01'
            $combinedLogText | Should -Not -Match 'treating as a prior session'
            $combinedLogText | Should -Match ([regex]::Escape("Following recording file: $recordingPath"))

            # Resumed at persisted-offset-minus-margin, the same dynamic cold-start
            # formula pusher.ps1 itself computes (D-12) -- the exact "resumes from the
            # persisted offset minus the resume safety margin" property this guard exists
            # to prove.
            $resumeMarginMatch = [regex]::Match($combinedLogText, 'Resume safety margin: seeking to (\d+)')
            $resumeMarginMatch.Success | Should -BeTrue
            $actualResumeSeekPosition = [long] $resumeMarginMatch.Groups[1].Value

            $dynamicResumeSafetyMarginBytes = Get-ResumeSafetyMarginBytes -SrtLatencySeconds $script:PusherResumeMarginLatencySeconds `
                -ObservedBytesPerSecond 0 -ChunkSizeBytes $script:PusherChunkSizeBytes `
                -FloorBytes $script:PusherResumeMarginFloorBytes -CeilingBytes $script:PusherResumeMarginCeilingBytes `
                -ColdStartMarginBytes $script:PusherColdStartResumeMarginBytes
            $expectedResumeSeekPosition = [Math]::Max([long] 0, $offsetBeforeKill - $dynamicResumeSafetyMarginBytes)
            $expectedResumeSeekPosition -= ($expectedResumeSeekPosition % $script:TransportStreamPacketSizeBytes)

            $actualResumeSeekPosition | Should -Be $expectedResumeSeekPosition
            $actualResumeSeekPosition | Should -BeLessOrEqual $offsetBeforeKill

            $offsetAfterResume = (Restore-PusherOffset -StateFilePath $statePath).byteOffset
            $offsetAfterResume | Should -BeGreaterOrEqual $offsetBeforeKill
            ($offsetAfterResume % $script:TransportStreamPacketSizeBytes) | Should -Be 0
        } finally {
            if ($pusherHandle2 -and -not $pusherHandle2.Process.HasExited) {
                Stop-Process -Id $pusherHandle2.Process.Id -Force -ErrorAction SilentlyContinue
                $pusherHandle2.Process.WaitForExit(5000) | Out-Null
            }
            Stop-ValidMpegtsGrowthWriter -Writer $writer
            if (-not $listenerBeforeKill.HasExited) { Stop-SrtListener -Process $listenerBeforeKill }
            if ($listenerAfterResume -and -not $listenerAfterResume.HasExited) { Stop-SrtListener -Process $listenerAfterResume }
            Remove-Item -LiteralPath $testPusherPath1 -Force -ErrorAction SilentlyContinue
            if ($testPusherPath2) { Remove-Item -LiteralPath $testPusherPath2 -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'START-STALE-01 stale-file Start guard (260809-ow9)' -Tag 'Integration' {

    BeforeAll {
        function Start-G70NoFlushMpegtsGrowthWriter {
            <#
            .SYNOPSIS
            260816-g70 (START-STALE-02) fixture: a variant of TestHelpers.psm1's
            Start-ValidMpegtsGrowthWriter that deliberately never forces an OS-level
            disk flush (FlushFileBuffers) on the growing target file -- real OBS does
            not fsync every frame either, and it is precisely that deferred-flush
            behavior that leaves the NTFS directory entry (Get-ChildItem/FindFirstFile)
            frozen at its creation-time length/mtime while the file keeps growing
            underneath a still-open write handle.

            Measured directly on this machine (2026-08-16, this quick task): a writer
            calling FileStream.Flush($true) (Start-ValidMpegtsGrowthWriter's own
            behavior) forces the directory entry to stay current every poll -- it does
            NOT reproduce the incident. Dropping to a plain FileStream.Flush() (no
            forced disk sync -- .NET still pushes the write through to the OS cache,
            so a handle-based reader sees it immediately; only the MFT directory-entry
            refresh is deferred) reproduces the frozen Length=0 / frozen mtime pattern
            for the writer's entire run, exactly matching the PLAN.md incident
            measurement. This is why this test needs its OWN writer instead of reusing
            the shared TestHelpers.psm1 helper (not touched -- it is relied on by many
            other passing tests and changing its flush behavior is out of this plan's
            declared file scope).

            Same return shape as Start-ValidMpegtsGrowthWriter
            ([PSCustomObject]@{ Process; ScratchDirectory }), so the shared
            Stop-ValidMpegtsGrowthWriter teardown helper works unchanged.
            #>
            param(
                [Parameter(Mandatory)] [string] $SamplePath,
                [Parameter(Mandatory)] [string] $TargetFilePath,
                [int] $IntervalMilliseconds = 300,
                [int] $ChunkSizeBytes = 18800,
                [int] $TotalDurationSeconds = 45
            )

            $targetDirectory = Split-Path -Parent $TargetFilePath
            if ($targetDirectory -and -not (Test-Path -LiteralPath $targetDirectory)) {
                New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
            }

            $scratchDirectoryPath = Join-Path $env:TEMP ("g70-noflush-writer-{0}" -f ([Guid]::NewGuid()))
            New-Item -ItemType Directory -Path $scratchDirectoryPath -Force | Out-Null
            $writerScriptFilePath = Join-Path $scratchDirectoryPath 'Write-NoFlushGrowth.ps1'

            $writerScriptContent = @'
param(
    [Parameter(Mandatory)] [string] $SamplePath,
    [Parameter(Mandatory)] [string] $TargetFilePath,
    [Parameter(Mandatory)] [int] $IntervalMilliseconds,
    [Parameter(Mandatory)] [int] $ChunkSizeBytes,
    [Parameter(Mandatory)] [int] $TotalDurationSeconds
)
$ErrorActionPreference = 'Stop'

$sourceStream = [System.IO.FileStream]::new($SamplePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
$targetStream = [System.IO.FileStream]::new($TargetFilePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
try {
    $buffer = New-Object byte[] $ChunkSizeBytes
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TotalDurationSeconds) {
        $bytesRead = $sourceStream.Read($buffer, 0, $buffer.Length)
        if ($bytesRead -le 0) {
            $sourceStream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
            continue
        }
        $targetStream.Write($buffer, 0, $bytesRead)
        # Deliberately Flush() with NO forced-disk-sync argument (never Flush($true))
        # -- see this function's own header for why that is the whole point.
        $targetStream.Flush()
        Start-Sleep -Milliseconds $IntervalMilliseconds
    }
} finally {
    $sourceStream.Dispose()
    $targetStream.Dispose()
}
'@
            Set-Content -LiteralPath $writerScriptFilePath -Value $writerScriptContent -Encoding utf8

            $processArguments = @(
                '-NoProfile', '-NonInteractive', '-File', $writerScriptFilePath,
                '-SamplePath', $SamplePath,
                '-TargetFilePath', $TargetFilePath,
                '-IntervalMilliseconds', $IntervalMilliseconds,
                '-ChunkSizeBytes', $ChunkSizeBytes,
                '-TotalDurationSeconds', $TotalDurationSeconds
            )
            $writerProcess = Start-Process -FilePath 'pwsh' -ArgumentList $processArguments -WindowStyle Hidden -PassThru

            return [PSCustomObject]@{ Process = $writerProcess; ScratchDirectory = $scratchDirectoryPath }
        }
    }

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Remove-Module OffsetStore -ErrorAction SilentlyContinue
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:OffsetStoreModulePath -Force
        Import-Module $script:ControlFlagModulePath -Force
        Import-Module $script:TestHelpersModulePath -Force
    }

    AfterEach {
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Remove-Module OffsetStore -ErrorAction SilentlyContinue
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'holds while the newest recording is stale, then latches the fresh file at offset 0' {
        $workDirectory  = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
        $samplePath     = Join-Path $workDirectory 'sample.ts'
        $staleFilePath  = Join-Path $workDirectory 'recording-001.ts'
        $freshFilePath  = Join-Path $workDirectory 'recording-002.ts'
        $statePath      = Join-Path $workDirectory 'offset.json'
        # Sibling of the scratch state file, exactly like pusher.ps1's own
        # $statsFilePath = Join-Path (Split-Path -Parent $stateFilePath) 'stats.json'.
        $statsPath      = Join-Path $workDirectory 'stats.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 5 -VideoSize '320x240' -FrameRate 25 | Out-Null

        # The STALE newest-by-name candidate: a finished recording, backdated well past
        # the tuned 5s threshold below. No offset.json is written -- Resolve-ResumeOffset
        # yields a null file, so the null-resume start-pick guard branch under test is
        # the one Start-Pusher actually takes (never the SESS-01 resume path).
        Copy-Item -LiteralPath $samplePath -Destination $staleFilePath -Force
        (Get-Item -LiteralPath $staleFilePath).LastWriteTimeUtc = ([DateTime]::UtcNow).AddSeconds(-120)

        $listenPort   = Get-Random -Minimum 20000 -Maximum 40000
        $receivedPath = Join-Path $workDirectory 'received.ts'
        $listener     = Start-SrtListenerWithRetry -Port $listenPort -OutputPath $receivedPath

        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $staleFilePath -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort $listenPort -StateFilePath $statePath -RecordingStartStaleAfterSeconds 5
        $writer = $null
        try {
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            $waitingWarningSeen = Wait-ForLogPatternInFiles -Paths @($pusherHandle.StdOutPath, $pusherHandle.StdErrPath) `
                -Pattern ([regex]::Escape('START-STALE-01: holding')) -TimeoutMilliseconds 15000
            $waitingWarningSeen | Should -BeTrue

            $combinedLogTextWhileWaiting = (Get-Content -LiteralPath $pusherHandle.StdOutPath -Raw -ErrorAction SilentlyContinue) + "`n" + `
                (Get-Content -LiteralPath $pusherHandle.StdErrPath -Raw -ErrorAction SilentlyContinue)
            $combinedLogTextWhileWaiting | Should -Not -Match 'Following recording file:'
            (Test-Path -LiteralPath $statePath) | Should -BeFalse

            $statsShowsWaiting = $false
            $statsStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            while ($statsStopwatch.ElapsedMilliseconds -lt 15000) {
                if (Test-Path -LiteralPath $statsPath) {
                    try {
                        $parsedStats = Get-Content -LiteralPath $statsPath -Raw -ErrorAction Stop | ConvertFrom-Json
                        if ($parsedStats.pusherState -eq 'WaitingForRecording') {
                            $statsShowsWaiting = $true
                            break
                        }
                    } catch {
                        # A torn read racing the pusher's own atomic rename -- retry.
                    }
                }
                Start-Sleep -Milliseconds 200
            }
            $statsShowsWaiting | Should -BeTrue

            # Release the guard: a genuinely fresh sibling recording appears, growing now.
            New-Item -ItemType File -Path $freshFilePath -Force | Out-Null
            $writer = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $freshFilePath -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 20

            $followingLogSeen = Wait-ForLogPatternInFiles -Paths @($pusherHandle.StdOutPath, $pusherHandle.StdErrPath) `
                -Pattern ([regex]::Escape("Following recording file: $freshFilePath")) -TimeoutMilliseconds 15000
            $followingLogSeen | Should -BeTrue

            $newFileCommitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $newFileCommitSeen = $false
            while ($newFileCommitStopwatch.ElapsedMilliseconds -lt 15000) {
                if (Test-Path -LiteralPath $statePath) {
                    $currentPersistedState = Restore-PusherOffset -StateFilePath $statePath
                    if ($currentPersistedState.file -eq $freshFilePath -and $currentPersistedState.byteOffset -gt 0) {
                        $newFileCommitSeen = $true
                        break
                    }
                }
                Start-Sleep -Milliseconds 200
            }
            $newFileCommitSeen | Should -BeTrue

            Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
            $pusherHandle.Process.WaitForExit(5000) | Out-Null

            $combinedLogText = (Get-Content -LiteralPath $pusherHandle.StdOutPath -Raw -ErrorAction SilentlyContinue) + "`n" + `
                (Get-Content -LiteralPath $pusherHandle.StdErrPath -Raw -ErrorAction SilentlyContinue)
            $combinedLogText | Should -Not -Match ([regex]::Escape("Following recording file: $staleFilePath"))
        } finally {
            if ($pusherHandle -and -not $pusherHandle.Process.HasExited) {
                Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
                $pusherHandle.Process.WaitForExit(5000) | Out-Null
            }
            if ($writer) { Stop-ValidMpegtsGrowthWriter -Writer $writer }
            if (-not $listener.HasExited) { Stop-SrtListener -Process $listener }
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'latches the same file once it starts growing again (growth-arm proof)' {
        $workDirectory = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
        $samplePath    = Join-Path $workDirectory 'sample.ts'
        $staleFilePath = Join-Path $workDirectory 'recording-001.ts'
        $statePath     = Join-Path $workDirectory 'offset.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 5 -VideoSize '320x240' -FrameRate 25 | Out-Null

        # A SINGLE backdated recording, no fresh sibling this time -- the only way this
        # guard can ever release is that SAME file resuming growth (the growth arm).
        Copy-Item -LiteralPath $samplePath -Destination $staleFilePath -Force
        (Get-Item -LiteralPath $staleFilePath).LastWriteTimeUtc = ([DateTime]::UtcNow).AddSeconds(-120)

        $listenPort   = Get-Random -Minimum 20000 -Maximum 40000
        $receivedPath = Join-Path $workDirectory 'received.ts'
        $listener     = Start-SrtListenerWithRetry -Port $listenPort -OutputPath $receivedPath

        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $staleFilePath -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort $listenPort -StateFilePath $statePath -RecordingStartStaleAfterSeconds 5
        $writer = $null
        try {
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            $waitingWarningSeen = Wait-ForLogPatternInFiles -Paths @($pusherHandle.StdOutPath, $pusherHandle.StdErrPath) `
                -Pattern ([regex]::Escape('START-STALE-01: holding')) -TimeoutMilliseconds 15000
            $waitingWarningSeen | Should -BeTrue

            $combinedLogTextWhileWaiting = (Get-Content -LiteralPath $pusherHandle.StdOutPath -Raw -ErrorAction SilentlyContinue) + "`n" + `
                (Get-Content -LiteralPath $pusherHandle.StdErrPath -Raw -ErrorAction SilentlyContinue)
            $combinedLogTextWhileWaiting | Should -Not -Match 'Following recording file:'

            # A couple of extra at-rest polls (same stale file, no change) so the latch
            # below is provably a reaction to growth starting, not a race against the
            # very first observation (the growth arm can never fire on iteration one --
            # PreviousLengthBytes is null then, by design).
            Start-Sleep -Milliseconds 600

            $writer = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $staleFilePath -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 20

            $followingLogSeen = Wait-ForLogPatternInFiles -Paths @($pusherHandle.StdOutPath, $pusherHandle.StdErrPath) `
                -Pattern ([regex]::Escape("Following recording file: $staleFilePath")) -TimeoutMilliseconds 15000
            $followingLogSeen | Should -BeTrue

            $commitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $commitSeen = $false
            while ($commitStopwatch.ElapsedMilliseconds -lt 15000) {
                if (Test-Path -LiteralPath $statePath) {
                    $currentPersistedState = Restore-PusherOffset -StateFilePath $statePath
                    if ($currentPersistedState.file -eq $staleFilePath -and $currentPersistedState.byteOffset -gt 0) {
                        $commitSeen = $true
                        break
                    }
                }
                Start-Sleep -Milliseconds 200
            }
            $commitSeen | Should -BeTrue

            Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
            $pusherHandle.Process.WaitForExit(5000) | Out-Null
        } finally {
            if ($pusherHandle -and -not $pusherHandle.Process.HasExited) {
                Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
                $pusherHandle.Process.WaitForExit(5000) | Out-Null
            }
            if ($writer) { Stop-ValidMpegtsGrowthWriter -Writer $writer }
            if (-not $listener.HasExited) { Stop-SrtListener -Process $listener }
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'honors an operator stop while the guard is holding -- exits 0, never opens the stale file, and publishes an honest final state' {
        $workDirectory = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
        $samplePath    = Join-Path $workDirectory 'sample.ts'
        $staleFilePath = Join-Path $workDirectory 'recording-001.ts'
        $statePath     = Join-Path $workDirectory 'offset.json'
        # Sibling of the scratch state file, exactly like pusher.ps1's own
        # $statsFilePath = Join-Path (Split-Path -Parent $stateFilePath) 'stats.json'.
        $statsPath     = Join-Path $workDirectory 'stats.json'
        $controlPath   = Join-Path $workDirectory 'control.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 5 -VideoSize '320x240' -FrameRate 25 | Out-Null

        # A stale newest-by-name candidate -- the guard must be actively holding on it
        # (no offset.json, so the null-resume start-pick branch under test is the one
        # Start-Pusher takes) at the moment the operator's stop signal arrives.
        Copy-Item -LiteralPath $samplePath -Destination $staleFilePath -Force
        (Get-Item -LiteralPath $staleFilePath).LastWriteTimeUtc = ([DateTime]::UtcNow).AddSeconds(-120)

        # The pusher must be RUNNING (desired=streaming) when it starts -- same control
        # channel and convention as Integration.ExplicitStop.Tests.ps1 -- before the
        # operator's later stop.
        Set-PusherDesiredState -ControlFilePath $controlPath -DesiredState 'streaming'

        # No SRT listener is started here, deliberately: while the guard holds, the
        # wait loop never reaches Build-FfmpegArguments/Start-FfmpegProcess, so no
        # ffmpeg process is ever spawned and no listener is ever needed for this case.
        $listenPort = Get-Random -Minimum 20000 -Maximum 40000

        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $staleFilePath -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort $listenPort -StateFilePath $statePath -ControlFilePath $controlPath -RecordingStartStaleAfterSeconds 5
        $pusherHandle = $null
        try {
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            $waitingWarningSeen = Wait-ForLogPatternInFiles -Paths @($pusherHandle.StdOutPath, $pusherHandle.StdErrPath) `
                -Pattern ([regex]::Escape('START-STALE-01: holding')) -TimeoutMilliseconds 15000
            $waitingWarningSeen | Should -BeTrue -Because 'the guard must be actively holding before the stop is pressed, or this test proves nothing'
            $pusherHandle.Process.HasExited | Should -BeFalse -Because 'the pusher must still be alive and waiting at the moment the stop is pressed'

            # THE OPERATOR PRESSES STOP while the guard is still holding -- same control
            # channel Get-ResolvedExplicitStopRequest reads (via
            # Test-PusherExplicitStopRequested), the same seam stop.ps1 and Phase 5's
            # dashboard Stop button write (Integration.ExplicitStop.Tests.ps1 convention).
            Set-PusherDesiredState -ControlFilePath $controlPath -DesiredState 'stopped'
            $stopSignalAtUtc = [DateTime]::UtcNow

            # Bounded window: the wait loop checks the stop flag every poll iteration
            # (150ms, tuned copy default) -- nowhere near the 30s/90s heuristic windows,
            # since this explicit-stop path needs neither.
            $exitedOnItsOwn = $pusherHandle.Process.WaitForExit(15000)
            $exitedOnItsOwn | Should -BeTrue -Because 'an explicit operator stop must end a waiting pusher promptly, not hold it forever'
            $pusherHandle.Process.ExitCode | Should -Be 0 -Because 'a stop while waiting is a clean end-of-service -- no FileStream/ffmpeg was ever opened to drain'

            $secondsToExit = ([DateTime]::UtcNow - $stopSignalAtUtc).TotalSeconds
            $secondsToExit | Should -BeLessThan 15 -Because 'the wait loop consults the stop flag every iteration, so the exit must be near-immediate'

            $combinedLogText = (Get-Content -LiteralPath $pusherHandle.StdOutPath -Raw -ErrorAction SilentlyContinue) + "`n" + `
                (Get-Content -LiteralPath $pusherHandle.StdErrPath -Raw -ErrorAction SilentlyContinue)
            # (b) never opened the stale file: the guard must never have latched, so
            # Open-TailerFileStream (and the "Following recording file:" log line that
            # immediately follows it) was never reached.
            $combinedLogText | Should -Not -Match 'Following recording file:' -Because 'the guard must never have latched onto the stale file before the stop arrived'
            $combinedLogText | Should -Match ([regex]::Escape('START-STALE-01: operator stop requested while waiting'))
            (Test-Path -LiteralPath $statePath) | Should -BeFalse -Because 'no offset was ever committed -- the pusher never opened a FileStream to read from'

            # Belt-and-suspenders proof the file was never opened by this process: an
            # exclusive-access FileStream (FileShare.None) against the exact stale path
            # succeeds immediately now that the pusher has exited -- if pusher.ps1 (or an
            # ffmpeg child it spawned) had ever held it open, this would still be
            # contended for a moment right after a graceful exit.
            $exclusiveStream = [System.IO.File]::Open($staleFilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $exclusiveStream.Dispose()

            # (c) final published state is honest -- never Streaming.
            (Test-Path -LiteralPath $statsPath) | Should -BeTrue -Because 'the wait loop publishes a terminal Stopped record before returning'
            $finalStats = Get-Content -LiteralPath $statsPath -Raw | ConvertFrom-Json
            $finalStats.pusherState | Should -Be 'Stopped'
            $finalStats.pusherState | Should -Not -Be 'Streaming'
        } finally {
            if ($pusherHandle -and -not $pusherHandle.Process.HasExited) {
                Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
                $pusherHandle.Process.WaitForExit(5000) | Out-Null
            }
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'latches a growing recording whose NTFS directory entry is frozen and stale (260816-g70, START-STALE-02)' {
        $workDirectory     = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
        $samplePath        = Join-Path $workDirectory 'sample.ts'
        $candidateFilePath = Join-Path $workDirectory 'recording-001.ts'
        $statePath         = Join-Path $workDirectory 'offset.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 5 -VideoSize '320x240' -FrameRate 25 | Out-Null

        $listenPort   = Get-Random -Minimum 20000 -Maximum 40000
        $receivedPath = Join-Path $workDirectory 'received.ts'
        $listener     = Start-SrtListenerWithRetry -Port $listenPort -OutputPath $receivedPath

        $staleThresholdSeconds = 5
        $writer         = $null
        $testPusherPath = $null
        $pusherHandle   = $null
        try {
            # Order matters and is the entire point of the fixture: start the writer
            # FIRST, before the pusher and before the tuned staleness threshold has
            # elapsed, so at pusher-start time the candidate already looks (via
            # directory enumeration) like it has been sitting untouched past the
            # threshold -- exactly the 2026-08-16 incident's shape -- while it is in
            # fact growing right now under a still-open write handle.
            $writer = Start-G70NoFlushMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $candidateFilePath `
                -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 45

            Start-Sleep -Seconds ($staleThresholdSeconds + 4)

            # Fixture precondition, folder enumeration ONLY (Get-ChildItem over the
            # directory) -- never Get-Item, FileInfo.Refresh, or any handle open on the
            # candidate file itself before this assertion. Any per-file query (as
            # opposed to a directory-level enumeration) refreshes the very NTFS
            # directory-entry cache this fixture depends on staying stale, silently
            # turning this into a green test that proves nothing (confirmed live on
            # this machine: interleaving a handle-based read un-freezes the very next
            # enumeration).
            $precondition = Get-ChildItem -LiteralPath $workDirectory -Filter 'recording-*.ts' -File | Select-Object -First 1
            $preconditionSatisfied = ($null -ne $precondition) -and ($precondition.Length -eq 0) -and `
                ((([DateTime]::UtcNow) - $precondition.LastWriteTimeUtc).TotalSeconds -ge $staleThresholdSeconds)

            if (-not $preconditionSatisfied) {
                Set-ItResult -Inconclusive -Because 'the OS did not leave the directory entry frozen/stale this run (it may have refreshed the cache on its own timing) -- the START-STALE-02 condition could not be staged, so this run proves nothing either way'
                return
            }

            $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $candidateFilePath -RecordingFilenameGlob 'recording-*.ts' `
                -RelayPort $listenPort -StateFilePath $statePath -RecordingStartStaleAfterSeconds $staleThresholdSeconds
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            $followingLogSeen = Wait-ForLogPatternInFiles -Paths @($pusherHandle.StdOutPath, $pusherHandle.StdErrPath) `
                -Pattern ([regex]::Escape("Following recording file: $candidateFilePath")) -TimeoutMilliseconds 15000
            $followingLogSeen | Should -BeTrue -Because 'a file that is demonstrably growing right now must latch within one poll interval regardless of what the directory entry claims'

            $newFileCommitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $newFileCommitSeen = $false
            while ($newFileCommitStopwatch.ElapsedMilliseconds -lt 15000) {
                if (Test-Path -LiteralPath $statePath) {
                    $currentPersistedState = Restore-PusherOffset -StateFilePath $statePath
                    if ($currentPersistedState.file -eq $candidateFilePath -and $currentPersistedState.byteOffset -gt 0) {
                        $newFileCommitSeen = $true
                        break
                    }
                }
                Start-Sleep -Milliseconds 200
            }
            $newFileCommitSeen | Should -BeTrue

            Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
            $pusherHandle.Process.WaitForExit(5000) | Out-Null
        } finally {
            if ($pusherHandle -and -not $pusherHandle.Process.HasExited) {
                Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
                $pusherHandle.Process.WaitForExit(5000) | Out-Null
            }
            if ($writer) { Stop-ValidMpegtsGrowthWriter -Writer $writer }
            if (-not $listener.HasExited) { Stop-SrtListener -Process $listener }
            if ($testPusherPath) { Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

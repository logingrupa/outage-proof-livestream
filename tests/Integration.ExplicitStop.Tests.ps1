# Integration.ExplicitStop.Tests.ps1
# End-to-end proof for the locked design extension item 6: stop = DRAIN, then stop.
# Driven against the REAL wired pusher.ps1 (a test-tuned copy; production pusher.ps1
# is never modified) with a real ffmpeg SRT mode=listener receiver and a real
# OBS-simulating writer, mirroring tests/Integration.Rotation.Tests.ps1's structure.
#
# THE SCENARIO THIS FILE EXISTS FOR. stop.ps1 sets desired=stopped, but pusher.ps1
# only ever exits on its OWN end-of-service heuristics (OBS liveness + growth stall).
# Press Stop while OBS is still recording and today the pusher streams on regardless:
# Stop stops nothing. The fix must not be a kill, and that is load-bearing -- during
# catch-up the pusher is BEHIND LIVE (7689s behind in the phase-4 outage test), so a
# kill abandons the whole un-sent backlog. Deliberate content loss, in the one system
# whose entire reason to exist is zero content loss.
#
# HOW THE HEURISTICS ARE RULED OUT AS AN EXPLANATION. Every scenario here forces
# $obsLivenessOverride = { $true }: a live OBS is never end-of-service (D-07/D-08), so
# Get-EndOfServiceDecision returns Continue no matter how long growth stalls. The
# growth-stall windows are left at their production values (30s/90s) as well. That
# means NEITHER heuristic can fire, ever, in any test in this file -- so a pusher that
# drains and exits 0 here can only have done it because of the operator's explicit
# signal. Without that control, a passing test would prove nothing: it could just be
# end-detection firing on its own.
#
# CatchUpMultiplier 0.5 pins the pusher permanently BEHIND LIVE: the cap sits at half
# the writer's rate, so backlog grows and the pusher stays in sustained ReadFast for
# the whole test -- the miniature of the 7689s-behind case, and the state in which
# BOTH existing call sites of the end-of-service gate are unreachable (the Wait-pacing
# branch and the no-stable-chunk branch are both idle-path only). A stop signal wired
# only into those two call sites passes every unit test and still hangs here.

BeforeAll {
    $script:RepoRootPath          = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:LoggingModulePath     = Join-Path $script:RepoRootPath 'lib/Logging.psm1'
    $script:OffsetStoreModulePath = Join-Path $script:RepoRootPath 'lib/OffsetStore.psm1'
    $script:ControlFlagModulePath = Join-Path $script:RepoRootPath 'lib/ControlFlag.psm1'
    $script:TestHelpersModulePath = Join-Path $PSScriptRoot 'TestHelpers.psm1'

    function Start-TestPusherProcess {
        <#
        .SYNOPSIS
        Launches a test-tuned pusher.ps1 copy as a detached pwsh process with
        stdout/stderr redirected to temp files for post-mortem debugging. Same helper
        (and same local-to-the-file convention) as Integration.Rotation.Tests.ps1.
        #>
        param([Parameter(Mandatory)] [string] $PusherScriptPath)

        $stdoutPath = [System.IO.Path]::GetTempFileName()
        $stderrPath = [System.IO.Path]::GetTempFileName()
        $processHandle = Start-Process -FilePath 'pwsh' `
            -ArgumentList @('-NoProfile', '-File', $PusherScriptPath) `
            -WorkingDirectory $script:RepoRootPath -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

        return @{ Process = $processHandle; StdOutPath = $stdoutPath; StdErrPath = $stderrPath }
    }

    function Wait-ForFileToExist {
        param([Parameter(Mandatory)] [string] $Path, [int] $TimeoutMilliseconds = 15000)

        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath $Path) { return $true }
            Start-Sleep -Milliseconds 100
        }
        return $false
    }

    function Wait-ForFileLength {
        <#
        .SYNOPSIS
        Waits until Path is at least MinimumLength bytes. Used to confirm the pusher is
        genuinely streaming (bytes reaching the SRT listener) BEFORE the stop signal is
        given -- a stop asserted against a pusher that never started would prove nothing.
        #>
        param(
            [Parameter(Mandatory)] [string] $Path,
            [Parameter(Mandatory)] [long] $MinimumLength,
            [int] $TimeoutMilliseconds = 20000
        )

        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            $currentLength = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).Length
            if ($currentLength -and $currentLength -ge $MinimumLength) { return $true }
            Start-Sleep -Milliseconds 100
        }
        return $false
    }
}

Describe 'Pusher explicit stop: drain the backlog, then exit 0 (locked extension item 6)' -Tag 'Integration' {

    BeforeEach {
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Remove-Module OffsetStore -ErrorAction SilentlyContinue
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:OffsetStoreModulePath -Force
        Import-Module $script:ControlFlagModulePath -Force
        Import-Module $script:TestHelpersModulePath -Force
    }

    AfterEach {
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Remove-Module OffsetStore -ErrorAction SilentlyContinue
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
    }

    It 'drains the un-sent backlog and exits 0 when the operator stops while OBS is still recording and the pusher is behind live' {
        $testWorkDirectory = Join-Path $TestDrive ("case-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $testWorkDirectory -Force | Out-Null
        $samplePath          = Join-Path $testWorkDirectory 'sample.ts'
        $recordingFolderPath = Join-Path $testWorkDirectory 'recordings'
        New-Item -ItemType Directory -Path $recordingFolderPath -Force | Out-Null
        $recordingPath = Join-Path $recordingFolderPath 'recording-001.ts'
        $receivedPath  = Join-Path $testWorkDirectory 'received.ts'
        $statePath     = Join-Path $testWorkDirectory 'offset.json'
        $controlPath   = Join-Path $testWorkDirectory 'control.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 60 -VideoSize '320x240' -FrameRate 25 | Out-Null

        $listenPort = Get-Random -Minimum 20000 -Maximum 40000
        # 18800 = 100 * 188, so a natural writer loop-exit always leaves the file at an
        # exact 188-aligned length (Integration.Rotation.Tests.ps1's writer-stop note).
        # The writer outlives the whole assertion window: OBS is STILL RECORDING when
        # the operator presses Stop -- that is the gap being closed.
        $writer   = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath `
            -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 40
        $listener = Start-SrtListener -Port $listenPort -OutputPath $receivedPath

        # The pusher must be RUNNING, not idle, when the test starts: the supervisor is
        # the component that gates on 'streaming', so the flag starts at streaming here.
        Set-PusherDesiredState -ControlFilePath $controlPath -DesiredState 'streaming'

        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort $listenPort -StateFilePath $statePath -ControlFilePath $controlPath `
            -CatchUpMultiplier 0.5 -ObsLivenessOverrideLiteral '{ $true }'
        $pusherHandle = $null
        try {
            Start-Sleep -Milliseconds 800
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            (Wait-ForFileToExist -Path $statePath -TimeoutMilliseconds 15000) | Should -BeTrue
            # Confirm real bytes are really flowing to the real listener before stopping.
            (Wait-ForFileLength -Path $receivedPath -MinimumLength 18800 -TimeoutMilliseconds 20000) |
                Should -BeTrue -Because 'the stop signal must be given to a pusher that is genuinely streaming'
            Start-Sleep -Seconds 3   # let a real backlog accumulate under the 0.5x cap

            $lengthBeforeStop = (Get-Item -LiteralPath $recordingPath).Length
            $offsetBeforeStop = (Restore-PusherOffset -StateFilePath $statePath).byteOffset
            $offsetBeforeStop | Should -BeGreaterThan 0

            # The pusher must be BEHIND LIVE at the moment of the stop -- otherwise
            # there is no backlog and "drains the backlog" is vacuously true.
            $offsetBeforeStop | Should -BeLessThan $lengthBeforeStop -Because 'the 0.5x catch-up cap must leave un-sent bytes on disk at the instant Stop is pressed'

            # THE OPERATOR PRESSES STOP. Same module, same flag, same seam stop.ps1 and
            # Phase 5's dashboard Stop button write.
            Set-PusherDesiredState -ControlFilePath $controlPath -DesiredState 'stopped'
            $stopSignalAtUtc = [DateTime]::UtcNow

            # 20s is far below the 30s production sustained window (and the 90s degraded
            # window) that this tuned copy still carries, and OBS is forced alive, so
            # NEITHER heuristic can account for an exit inside this budget.
            $exitedOnItsOwn = $pusherHandle.Process.WaitForExit(20000)
            $exitedOnItsOwn | Should -BeTrue -Because 'an explicit operator stop must wind the pusher down; today it streams on forever while OBS keeps recording'
            $pusherHandle.Process.ExitCode | Should -Be 0 -Because 'a drained explicit stop is a clean end-of-service, and the supervisor stays down on exit 0'

            $secondsToExit = ([DateTime]::UtcNow - $stopSignalAtUtc).TotalSeconds
            $secondsToExit | Should -BeLessThan 20 -Because 'the explicit signal needs no sustained window, no degraded window and no OBS death'

            # OBS was still recording the whole time -- proving no growth stall could
            # have driven this, and that the writer never had to die for Stop to work.
            $writer.Process.HasExited | Should -BeFalse -Because 'the whole gap is that Stop does nothing while OBS is still recording'
            (Get-Item -LiteralPath $recordingPath).Length | Should -BeGreaterThan $lengthBeforeStop -Because 'the recording kept growing across the stop, so growth never stalled'

            $listener.WaitForExit(8000) | Out-Null
            if (-not $listener.HasExited) { Stop-SrtListener -Process $listener }

            $committedState = Restore-PusherOffset -StateFilePath $statePath

            # ZERO CONTENT LOSS -- the assertion this entire extension exists for. A cut
            # (plain kill) leaves the offset exactly where it was when Stop was pressed;
            # a drain carries it past every byte that was already on disk at that moment.
            $committedState.byteOffset | Should -BeGreaterThan $offsetBeforeStop -Because 'a kill would abandon the un-sent backlog -- the drain must keep sending after the stop signal'
            $committedState.byteOffset | Should -BeGreaterOrEqual $lengthBeforeStop -Because 'every byte already recorded when the operator pressed Stop must reach the relay'

            # GAPLESS -- and actually SENT, not merely counted: the bytes the listener
            # received must be byte-identical to the source range the offset claims.
            $receivedLength = (Get-Item -LiteralPath $receivedPath -ErrorAction SilentlyContinue).Length
            $receivedLength | Should -BeGreaterThan 0

            # WHY THIS RANGE IS CAPPED AT THE SAMPLE LENGTH, and why that is not a
            # weakened assertion. Start-ValidMpegtsGrowthWriter LOOPS its sample: once
            # it has written all $sampleLength bytes it wraps and replays the sample
            # from byte 0 (measured directly -- the recording restarts the sample at
            # exactly byte $sampleLength). At that wrap the recording contains a real
            # mpegts discontinuity: PAT/PMT and timestamps restart mid-stream. ffmpeg
            # -c copy demuxes and RE-MUXES, so across that discontinuity it legitimately
            # re-writes TS continuity counters instead of reproducing the source bytes
            # verbatim -- the first differing byte lands 2 bytes into the first packet
            # of the second lap, i.e. inside a TS header, never in payload.
            #
            # So beyond one lap, "received == source" stops being a valid oracle for
            # ANY pusher, correct or not: it measures the writer's loop, not the drain.
            # This is why tests/Integration.Rotation.Tests.ps1's clean-finish check
            # passes -- it never exceeds one lap (376000 < $sampleLength) -- while this
            # test, which deliberately runs long enough to build a real backlog, does.
            # Capping the range keeps the assertion honest AND still proves the whole
            # claim: every byte of a full lap arrived intact and in order over real SRT.
            $sampleLength = (Get-Item -LiteralPath $samplePath).Length
            $byteEqualityLength = [Math]::Min($committedState.byteOffset, $sampleLength)
            # Guards the cap itself: if the range ever collapsed to something trivial,
            # the equality check below would pass while proving nothing.
            $byteEqualityLength | Should -BeGreaterThan 18800 -Because 'the byte-identity check must cover a substantial streamed range, not a token prefix'
            Test-ByteRangeEquality -SourcePath $recordingPath -ReceivedPath $receivedPath `
                -StartOffset 0 -Length $byteEqualityLength | Should -BeTrue -Because 'the drained bytes must arrive intact and in order, never skipped or reordered'

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

    It 'keeps streaming when no control file exists at all (a missing flag is not an operator stop)' {
        # THE REGRESSION GUARD for the whole existing integration suite. The control
        # flag's safe default is 'stopped' for a reason -- it answers "may the SUPERVISOR
        # start?", where refusing to stream unattended is the safe answer. It must NOT
        # be read as "the operator pressed Stop" by a RUNNING pusher: every existing
        # integration test (and any hand-run pusher.ps1) has no control file, and would
        # otherwise drain and exit 0 the instant it started, silently turning this suite
        # green for entirely the wrong reason. A transient unreadable flag must likewise
        # never end a live church service.
        $testWorkDirectory = Join-Path $TestDrive ("case-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $testWorkDirectory -Force | Out-Null
        $samplePath          = Join-Path $testWorkDirectory 'sample.ts'
        $recordingFolderPath = Join-Path $testWorkDirectory 'recordings'
        New-Item -ItemType Directory -Path $recordingFolderPath -Force | Out-Null
        $recordingPath = Join-Path $recordingFolderPath 'recording-001.ts'
        $receivedPath  = Join-Path $testWorkDirectory 'received.ts'
        $statePath     = Join-Path $testWorkDirectory 'offset.json'
        $controlPath   = Join-Path $testWorkDirectory 'control.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 60 -VideoSize '320x240' -FrameRate 25 | Out-Null

        $listenPort = Get-Random -Minimum 20000 -Maximum 40000
        $writer   = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath `
            -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 30
        $listener = Start-SrtListener -Port $listenPort -OutputPath $receivedPath

        Test-Path -LiteralPath $controlPath | Should -BeFalse

        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort $listenPort -StateFilePath $statePath -ControlFilePath $controlPath `
            -ObsLivenessOverrideLiteral '{ $true }'
        $pusherHandle = $null
        try {
            Start-Sleep -Milliseconds 800
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            (Wait-ForFileToExist -Path $statePath -TimeoutMilliseconds 15000) | Should -BeTrue
            (Wait-ForFileLength -Path $receivedPath -MinimumLength 18800 -TimeoutMilliseconds 20000) | Should -BeTrue

            Start-Sleep -Seconds 6
            $pusherHandle.Process.HasExited | Should -BeFalse -Because 'no control file means the operator has said nothing -- it must never be read as an explicit stop'

            $receivedLengthBefore = (Get-Item -LiteralPath $receivedPath).Length
            (Wait-ForFileLength -Path $receivedPath -MinimumLength ($receivedLengthBefore + 1) -TimeoutMilliseconds 15000) |
                Should -BeTrue -Because 'the pusher must still be actively streaming, not merely still alive'
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

# Integration.EndOfServiceDrain.Tests.ps1
# Front C failure-injection proof (260718-j58/EOS-DRAIN-01, folding the pending i4m
# plan): end-of-service drain must reconnect through a relay drop and finish the
# backlog before a clean finish; a persistently-down relay must yield a BOUNDED,
# HONEST exit-3 give-up ("finished-with-undelivered-backlog") with the remainder
# recoverable from the exact persisted offset -- never a silent, unbounded content-loss
# abandon (the pre-existing i4m defect: the drain write-failure branch used to log a
# warning and `break`, permanently abandoning whatever was still un-sent).
#
# Modelled on tests/Integration.ExplicitStop.Tests.ps1 (real ffmpeg SRT listener + real
# growth writer + New-TestTunedPusherCopy, ObsLivenessOverrideLiteral '{ $true }',
# explicit control-flag Stop to enter Draining, CatchUpMultiplier well below 1.0 to
# guarantee a real un-sent backlog at Stop). Uses short tuned give-up/backoff knobs
# (Task 3's TestHelpers.psm1 additions) for deterministic, fast runs.
#
# tests/Integration.KillAndResume.Tests.ps1 is NOT modified by this file and must stay
# green/unmodified -- proving Front C changed nothing about genuine mid-stream death.

BeforeAll {
    $script:RepoRootPath          = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:LoggingModulePath     = Join-Path $script:RepoRootPath 'lib/Logging.psm1'
    $script:OffsetStoreModulePath = Join-Path $script:RepoRootPath 'lib/OffsetStore.psm1'
    $script:ControlFlagModulePath = Join-Path $script:RepoRootPath 'lib/ControlFlag.psm1'
    $script:StatsStoreModulePath  = Join-Path $script:RepoRootPath 'lib/StatsStore.psm1'
    $script:TestHelpersModulePath = Join-Path $PSScriptRoot 'TestHelpers.psm1'

    function Start-TestPusherProcess {
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

    function Wait-ForProcessExit {
        param([Parameter(Mandatory)] [System.Diagnostics.Process] $Process, [int] $TimeoutMilliseconds = 30000)
        return $Process.WaitForExit($TimeoutMilliseconds)
    }

    function Wait-ForLogText {
        <#
        .SYNOPSIS
        Waits until Path's content contains Pattern -- used as the "pusher has genuinely
        started" readiness signal in scenarios where state/offset.json itself cannot be
        trusted as that signal: when the relay stand-in never drains anything from the
        very first launch (by design, simulating a relay that is already down),
        Save-PusherOffset never runs and offset.json legitimately never appears until
        AFTER the first successful write, which in those scenarios only happens post-
        reconnect. Waiting on the process's own stdout log instead observes readiness
        directly, with no dependency on any write ever succeeding.
        #>
        param(
            [Parameter(Mandatory)] [string] $Path,
            [Parameter(Mandatory)] [string] $Pattern,
            [int] $TimeoutMilliseconds = 15000
        )
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -match $Pattern) { return $true }
            Start-Sleep -Milliseconds 150
        }
        return $false
    }

    function Stop-ProcessTree {
        <#
        .SYNOPSIS
        Kills ProcessId and its ENTIRE descendant tree (taskkill /T) -- Scenario 2 uses
        the same .cmd-wrapped pwsh stand-in "ffmpeg" fixture as
        Integration.SrtBackpressure.Tests.ps1 (New-StdinStallStandinFfmpeg); killing only
        the top PID leaves the cmd.exe host (and its own pwsh grandchild, if one is still
        mid-launch) orphaned and holding an open file handle, which then breaks Pester's
        own TestDrive cleanup with a "file in use" error.
        #>
        param([Parameter(Mandatory)] [int] $ProcessId)

        try {
            & taskkill.exe /PID $ProcessId /T /F 2>&1 | Out-Null
        } catch {
            # Best-effort cleanup only -- never fail a test on a cleanup-path error.
        }
    }
}

Describe 'Front C: end-of-service drain reconnects through a relay drop and finishes the backlog (260718-j58)' -Tag 'Integration' {

    BeforeEach {
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Remove-Module OffsetStore -ErrorAction SilentlyContinue
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:OffsetStoreModulePath -Force
        Import-Module $script:ControlFlagModulePath -Force
        Import-Module $script:StatsStoreModulePath -Force
        Import-Module $script:TestHelpersModulePath -Force
    }

    AfterEach {
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Remove-Module OffsetStore -ErrorAction SilentlyContinue
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
    }

    It 'Scenario 1: a relay drop during drain reconnects and delivers the WHOLE backlog before a clean exit 0' {
        # WHY THIS SCENARIO USES THE DETERMINISTIC STAND-IN FIXTURE, NOT a real ffmpeg +
        # dropped/restarted SRT listener: a real ffmpeg caller's own internal buffering
        # can keep silently ACCEPTING stdin writes for a while after its actual SRT peer
        # has died (the same "ffmpeg does not give you SRT health" characteristic
        # documented in lib/FfmpegProcess.psm1's header) -- and restarting a brand-new
        # listener process on the same port does not make that SAME already-established
        # caller connection reattach to it. Measured directly: with a real listener
        # drop+restart and a modest test backlog, the pusher's committed offset advanced
        # well past what the new listener actually received, because the OLD caller
        # process kept "accepting" bytes it could never actually deliver. The stand-in
        # (proven in Task 2) makes the write failure itself deterministic and
        # attributable to the mechanism under test, not to ffmpeg's own internal
        # buffering depth.
        #
        # Attempt 1 (the pusher's initial ffmpeg launch) never drains its stdin --
        # standing in for a relay that is ALREADY down when streaming begins. Attempt 2
        # (the reconnect Front C's drain give-up-evaluation performs once its small
        # duration bound is reached) drains immediately -- standing in for the relay
        # RECOVERING. A generous mid-stream SRT_STALL_TOLERANCE_SECONDS keeps this
        # deliberately BELOW the streaming escalation threshold for the whole test, so
        # the recovery is proven to happen via the DRAIN's own reconnect path, not a
        # mid-stream one.
        $testWorkDirectory = Join-Path $TestDrive ("case-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $testWorkDirectory -Force | Out-Null
        $samplePath          = Join-Path $testWorkDirectory 'sample.ts'
        $recordingFolderPath = Join-Path $testWorkDirectory 'recordings'
        New-Item -ItemType Directory -Path $recordingFolderPath -Force | Out-Null
        $recordingPath = Join-Path $recordingFolderPath 'recording-001.ts'
        $receivedPath  = Join-Path $testWorkDirectory 'received.ts'
        $statePath     = Join-Path $testWorkDirectory 'offset.json'
        $controlPath   = Join-Path $testWorkDirectory 'control.json'
        $attemptCounterPath = Join-Path $testWorkDirectory 'attempt-counter.txt'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 20 -VideoSize '320x240' -FrameRate 25 | Out-Null

        $standin = New-StdinStallStandinFfmpeg -ScratchDirectory (Join-Path $testWorkDirectory 'standin') `
            -ReceivedFilePath $receivedPath -AttemptCounterFilePath $attemptCounterPath -StallForeverOnAttempts @(1)

        Set-PusherDesiredState -ControlFilePath $controlPath -DesiredState 'streaming'

        $writer = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath `
            -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 40

        # CatchUpMultiplier pinned generously large (Task 4 hardening): the cold-start
        # EWMA growth-rate estimate (Update-GrowthRateWindow) is sensitive to poll-timing
        # jitter under system load and can occasionally seed an anomalously LOW rate,
        # which -- at the production 1.5x default -- computes a catch-up cap so small
        # the throttle sleep before the FIRST write attempt can stretch into minutes
        # (measured directly: cap=937B/s implied a ~70s pre-write sleep). This scenario
        # tests reconnect/give-up mechanics, not catch-up pacing, so a large multiplier
        # keeps the cap comfortably above any transient low estimate without weakening
        # what is actually under test.
        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort 19996 -StateFilePath $statePath -ControlFilePath $controlPath -ObsLivenessOverrideLiteral '{ $true }' `
            -FfmpegPath $standin.WrapperPath -WatchdogTimeoutMilliseconds 300 -SrtStallToleranceSeconds 120 `
            -EndOfServiceReconnectMaxDurationSeconds 3 -EndOfServiceReconnectMaxAttempts 50 `
            -BackoffBaseMilliseconds 100 -BackoffCeilingMilliseconds 400 -CatchUpMultiplier 1000

        $pusherHandle = $null
        try {
            Start-Sleep -Milliseconds 500
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            (Wait-ForLogText -Path $pusherHandle.StdOutPath -Pattern 'Following recording file' -TimeoutMilliseconds 15000) |
                Should -BeTrue -Because 'the pusher must have genuinely started -- offset.json itself cannot be trusted as the readiness signal here, since attempt 1 never drains anything'

            # Let a real backlog accumulate on disk while the relay stand-in is down
            # (attempt 1 never drains, so nothing is accepted yet).
            Start-Sleep -Seconds 5
            $lengthBeforeStop = (Get-Item -LiteralPath $recordingPath).Length
            $lengthBeforeStop | Should -BeGreaterThan 0

            # THE OPERATOR PRESSES STOP -- entering Draining with the whole backlog
            # still un-sent (the relay stand-in has never drained anything).
            Set-PusherDesiredState -ControlFilePath $controlPath -DesiredState 'stopped'

            # THE RELAY RECOVERS during the drain -- attempt 2 (triggered once the
            # drain's own small duration bound is reached) drains immediately.
            $exitedCleanly = Wait-ForProcessExit -Process $pusherHandle.Process -TimeoutMilliseconds 40000
            $exitedCleanly | Should -BeTrue -Because 'the drain must reconnect through the relay recovery and finish, not hang forever'
            $pusherHandle.Process.ExitCode | Should -Be 0 -Because 'a fully-drained finish after reconnecting through a relay drop is still a clean end-of-service'

            $committedState = Restore-PusherOffset -StateFilePath $statePath
            $committedState.byteOffset | Should -BeGreaterOrEqual $lengthBeforeStop -Because 'the WHOLE backlog present at Stop must be delivered -- reconnecting through the relay drop must never abandon it (the i4m content-loss bug this fixes)'

            $receivedLength = (Get-Item -LiteralPath $receivedPath -ErrorAction SilentlyContinue).Length
            $receivedLength | Should -BeGreaterThan 0
            $sampleLength = (Get-Item -LiteralPath $samplePath).Length
            $byteEqualityLength = [Math]::Min($committedState.byteOffset, $sampleLength)
            $byteEqualityLength | Should -BeGreaterThan 18800 -Because 'the byte-identity check must cover a substantial streamed range'
            Test-ByteRangeEquality -SourcePath $recordingPath -ReceivedPath $receivedPath `
                -StartOffset 0 -Length $byteEqualityLength | Should -BeTrue -Because 'delivered bytes must be byte-exact and in order -- no skip, no reorder, no corruption from the relay drop/reconnect'
        } finally {
            if ($pusherHandle -and -not $pusherHandle.Process.HasExited) {
                Stop-ProcessTree -ProcessId $pusherHandle.Process.Id
                $pusherHandle.Process.WaitForExit(5000) | Out-Null
            }
            Stop-ValidMpegtsGrowthWriter -Writer $writer
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Scenario 2: a persistently-down relay at end-of-service yields a bounded, honest exit-3 give-up with a recoverable remainder' {
        # WHY THIS SCENARIO USES THE DETERMINISTIC STAND-IN FIXTURE (New-StdinStallStandinFfmpeg,
        # proven in Task 2's Integration.SrtBackpressure.Tests.ps1), NOT a real ffmpeg +
        # killed SRT listener: with a small end-of-service backlog, a real ffmpeg's own
        # internal buffering can silently absorb the whole remaining backlog into memory
        # before ever reporting a stdin write failure -- the SRT transport never gets a
        # chance to fail visibly at the stdin boundary at all (the same "ffmpeg buffers
        # input before failing" characteristic documented in lib/FfmpegProcess.psm1's own
        # header). The stand-in makes the stdin-write failure itself deterministic and
        # attributable to THIS give-up mechanism, not to how much ffmpeg happens to buffer.
        $testWorkDirectory = Join-Path $TestDrive ("case-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $testWorkDirectory -Force | Out-Null
        $samplePath          = Join-Path $testWorkDirectory 'sample.ts'
        $recordingFolderPath = Join-Path $testWorkDirectory 'recordings'
        New-Item -ItemType Directory -Path $recordingFolderPath -Force | Out-Null
        $recordingPath = Join-Path $recordingFolderPath 'recording-001.ts'
        $receivedPath  = Join-Path $testWorkDirectory 'received.ts'
        $statePath     = Join-Path $testWorkDirectory 'offset.json'
        $controlPath   = Join-Path $testWorkDirectory 'control.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 20 -VideoSize '320x240' -FrameRate 25 | Out-Null

        # A relay that is dead from before this pusher ever starts -- every single launch
        # (the initial one AND every reconnect, mid-stream or drain-time) never drains its
        # own stdin, standing in for a persistently-unreachable relay throughout.
        $standin = New-StdinStallStandinFfmpeg -ScratchDirectory (Join-Path $testWorkDirectory 'standin') `
            -ReceivedFilePath $receivedPath -StallForeverOnAttempts @(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)

        Set-PusherDesiredState -ControlFilePath $controlPath -DesiredState 'streaming'

        $writer = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath `
            -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 40

        # Small mid-stream stall tolerance keeps the pre-Draining reconnect churn fast;
        # tiny give-up bounds mean the DRAIN itself must give up quickly once entered,
        # since this relay never comes back.
        # CatchUpMultiplier pinned generously large -- see Scenario 1's identical note
        # (the cold-start EWMA growth-rate estimate can occasionally seed low under
        # system load and stretch the pre-write throttle sleep to minutes).
        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort 19997 -StateFilePath $statePath -ControlFilePath $controlPath -ObsLivenessOverrideLiteral '{ $true }' `
            -FfmpegPath $standin.WrapperPath -WatchdogTimeoutMilliseconds 300 -SrtStallToleranceSeconds 2 `
            -EndOfServiceReconnectMaxDurationSeconds 6 -EndOfServiceReconnectMaxAttempts 3 `
            -BackoffBaseMilliseconds 100 -BackoffCeilingMilliseconds 400 -CatchUpMultiplier 1000

        $pusherHandle = $null
        try {
            Start-Sleep -Milliseconds 500
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            (Wait-ForLogText -Path $pusherHandle.StdOutPath -Pattern 'Following recording file' -TimeoutMilliseconds 15000) |
                Should -BeTrue -Because 'the pusher must have genuinely started -- offset.json itself cannot be trusted as the readiness signal here, since every launch never drains anything'

            # Let a real, un-deliverable backlog accumulate on disk (the relay never
            # drains anything, so the file simply keeps growing behind the frozen offset).
            Start-Sleep -Seconds 5

            $lengthBeforeStop = (Get-Item -LiteralPath $recordingPath).Length
            $lengthBeforeStop | Should -BeGreaterThan 0 -Because 'the writer must have produced a real backlog for this scenario to mean anything'

            Set-PusherDesiredState -ControlFilePath $controlPath -DesiredState 'stopped'

            $exitedWithinBound = Wait-ForProcessExit -Process $pusherHandle.Process -TimeoutMilliseconds 30000
            $exitedWithinBound | Should -BeTrue -Because 'the bounded give-up ceiling must terminate the drain, never hang forever against a dead relay'
            $pusherHandle.Process.ExitCode | Should -Be 3 -Because 'a persistently-down relay must yield the honest undelivered-backlog exit code, not 0 (which would falsely claim everything was sent)'

            $committedState = Restore-PusherOffset -StateFilePath $statePath
            $committedState.byteOffset | Should -BeLessThan $lengthBeforeStop -Because 'the give-up must be HONEST -- some backlog genuinely remains undelivered, or this scenario is not testing what it claims to'

            # On-disk recording intact -- the source file itself is never touched/truncated.
            (Get-Item -LiteralPath $recordingPath).Length | Should -BeGreaterOrEqual $lengthBeforeStop

            $stderrLog = Get-Content -LiteralPath $pusherHandle.StdErrPath -Raw -ErrorAction SilentlyContinue
            $stdoutLog = Get-Content -LiteralPath $pusherHandle.StdOutPath -Raw -ErrorAction SilentlyContinue
            $combinedLog = "$stdoutLog`n$stderrLog"
            $combinedLog | Should -Match 'UNDELIVERED' -Because 'the give-up terminal must log the undelivered-backlog line, not a clean-all-sent line'
            $combinedLog | Should -Not -Match 'drain complete -- stopping cleanly'
        } finally {
            if ($pusherHandle -and -not $pusherHandle.Process.HasExited) {
                Stop-ProcessTree -ProcessId $pusherHandle.Process.Id
                $pusherHandle.Process.WaitForExit(5000) | Out-Null
            }
            Stop-ValidMpegtsGrowthWriter -Writer $writer
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Scenario 3 (regression): a healthy end-of-service still fully drains and exits 0 with PendingBytes==0' {
        $testWorkDirectory = Join-Path $TestDrive ("case-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $testWorkDirectory -Force | Out-Null
        $samplePath          = Join-Path $testWorkDirectory 'sample.ts'
        $recordingFolderPath = Join-Path $testWorkDirectory 'recordings'
        New-Item -ItemType Directory -Path $recordingFolderPath -Force | Out-Null
        $recordingPath = Join-Path $recordingFolderPath 'recording-001.ts'
        $receivedPath  = Join-Path $testWorkDirectory 'received.ts'
        $statePath     = Join-Path $testWorkDirectory 'offset.json'
        $controlPath   = Join-Path $testWorkDirectory 'control.json'
        $statsPath     = Join-Path $testWorkDirectory 'stats.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 60 -VideoSize '320x240' -FrameRate 25 | Out-Null

        # Task 2 (CHUR-01/D-02): the Draining loop now paces to the SAME ceiling dials
        # as live streaming (CatchUpMultiplier x frozen record rate here, since
        # SEND_CEILING_BYTES_PER_SECOND is pinned to 0/off by New-TestTunedPusherCopy)
        # instead of blasting the backlog through unconstrained. Mid-stream ReadFast
        # pacing (unchanged, untouched by this plan) resolves an in-band backlog back
        # under TargetHighSeconds quickly once it starts draining -- so a backlog that
        # only starts accumulating AFTER the pusher is already reading closes again
        # before Stop is ever pressed, and this scenario would prove nothing. Instead
        # the writer runs ALONE for a lead-in window BEFORE the pusher even starts,
        # producing a real, substantial, un-sent backlog that already exists the
        # moment the pusher opens the file -- Stop is then pressed almost immediately,
        # so Draining inherits that backlog while it is still large, giving the
        # ceiling gate a genuinely multi-second job with plenty of samples.
        $listenPort = Get-Random -Minimum 20000 -Maximum 40000
        $writer   = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath `
            -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 10
        $listener = Start-SrtListener -Port $listenPort -OutputPath $receivedPath

        Set-PusherDesiredState -ControlFilePath $controlPath -DesiredState 'streaming'

        # Writer lead-in (Task 2): ~4s of solo writer activity before the pusher ever
        # opens the file, at the writer's own known ~62,667 B/s pace, banks roughly
        # 250KB of genuinely un-sent backlog.
        Start-Sleep -Seconds 4

        # GrowthRateSmoothingSeconds 0 (Task 2): disables the 30s-tau EWMA in favor of
        # the raw window average -- this test's whole streaming phase is only a few
        # seconds, far shorter than the production time constant, so the smoothed rate
        # (and, via it, the frozen last-known-good rate a ceiling-respecting Draining
        # now depends on) would otherwise stay pinned near whatever noisy value the
        # first couple of ticks happened to seed instead of converging to the writer's
        # actual, known, constant rate. See -GrowthRateSmoothingSeconds' own parameter
        # comment in TestHelpers.psm1 for the full mechanism.
        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort $listenPort -StateFilePath $statePath -ControlFilePath $controlPath -ObsLivenessOverrideLiteral '{ $true }' `
            -CatchUpMultiplier 0.5 -GrowthRateSmoothingSeconds 0

        $pusherHandle = $null
        try {
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            (Wait-ForFileToExist -Path $statePath -TimeoutMilliseconds 15000) | Should -BeTrue

            # Deliberately brief -- Stop must land while the lead-in backlog is still
            # substantial, before mid-stream ReadFast/Throttle has a chance to work it
            # back down near zero (see this scenario's own header comment above).
            Start-Sleep -Milliseconds 500

            $lengthBeforeStop = (Get-Item -LiteralPath $recordingPath).Length

            Set-PusherDesiredState -ControlFilePath $controlPath -DesiredState 'stopped'

            # Task 2 (CHUR-01/D-02): poll instead of a single blocking
            # Wait-ForProcessExit so the drain's ceiling-bounded pacing can be
            # verified against ground truth -- the RECEIVED file's own growth,
            # wall-clock-timed, independent of any pusher-internal bookkeeping --
            # and so CatchUpCapUtilization can be observed while pusherState is
            # still genuinely 'Draining'.
            #
            # Task 3 (CHUR-03): the SAME sampling pass also records each
            # Draining-tagged stats.json snapshot in full (not just
            # catchUpCapUtilization) so the live-telemetry assertions below --
            # sendBytesPerSecond genuinely changing, secondsBehindLive never
            # increasing, updatedEpochSeconds refreshing on a bounded cadence --
            # can be checked against the SAME real drain run, no second pusher
            # launch needed.
            $drainReceivedSamples = [System.Collections.Generic.List[object]]::new()
            $drainObservedCatchUpCapUtilizationValues = [System.Collections.Generic.List[double]]::new()
            $drainStatsSnapshots = [System.Collections.Generic.List[object]]::new()
            $drainWaitDeadlineUtc = [DateTime]::UtcNow.AddMilliseconds(60000)
            while ([DateTime]::UtcNow -lt $drainWaitDeadlineUtc -and -not $pusherHandle.Process.HasExited) {
                $receivedLengthNow = (Get-Item -LiteralPath $receivedPath -ErrorAction SilentlyContinue).Length
                if ($receivedLengthNow) {
                    $drainReceivedSamples.Add([PSCustomObject]@{ CapturedAtUtc = [DateTime]::UtcNow; ReceivedLength = [long] $receivedLengthNow })
                }
                $statsDuringDrain = Read-PusherStats -StatsFilePath $statsPath
                if ($null -ne $statsDuringDrain -and $statsDuringDrain.pusherState -eq 'Draining') {
                    $drainObservedCatchUpCapUtilizationValues.Add([double] $statsDuringDrain.catchUpCapUtilization)
                    $drainStatsSnapshots.Add([PSCustomObject]@{
                        SendBytesPerSecond  = [double] $statsDuringDrain.sendBytesPerSecond
                        SecondsBehindLive   = [double] $statsDuringDrain.secondsBehindLive
                        UpdatedEpochSeconds = [double] $statsDuringDrain.updatedEpochSeconds
                    })
                }
                Start-Sleep -Milliseconds 300
            }
            if (-not $pusherHandle.Process.HasExited) {
                $pusherHandle.Process.WaitForExit(2000) | Out-Null
            }
            $exitedCleanly = $pusherHandle.Process.HasExited
            $exitedCleanly | Should -BeTrue -Because 'a healthy end-of-service drain must still complete under the new ceiling-respecting pacing (D-02), not hang'
            $pusherHandle.Process.ExitCode | Should -Be 0

            $listener.WaitForExit(8000) | Out-Null
            if (-not $listener.HasExited) { Stop-SrtListener -Process $listener }

            $committedState = Restore-PusherOffset -StateFilePath $statePath
            $committedState.byteOffset | Should -BeGreaterOrEqual $lengthBeforeStop

            # NOTE (mirrors Scenario 1's identical note): PendingBytes is checked
            # against $lengthBeforeStop above, not against the stats payload's
            # possibly-still-growing terminal fileLengthBytes -- the growth writer
            # keeps appending for a few seconds past Stop (per its own bounded
            # TotalDurationSeconds above), so under load a single-pass drain can
            # legitimately complete with a small, not-yet-2-poll-stable remainder
            # still on disk (never lost -- recoverable exactly like any other
            # clean-finish resume). A tolerance of one writer chunk (18800 bytes)
            # absorbs that legitimate race without weakening the load-bearing
            # assertion above.
            $stats = Read-PusherStats -StatsFilePath $statsPath
            $stats | Should -Not -BeNullOrEmpty
            $pendingAtTerminalPublish = [Math]::Max(0, [long]($stats.fileLengthBytes - $stats.offsetBytes))
            $pendingAtTerminalPublish | Should -BeLessOrEqual 18800 -Because 'a genuinely healthy end-of-service must drain to at most one legitimate not-yet-stable trailing chunk, never a real backlog'

            # Task 2 (CHUR-01/D-02): the drain must obey the SAME ceiling dials as
            # live streaming. Measured as an OVERALL average over the whole sampled
            # window (first sample to last), not per-consecutive-sample-pair -- the
            # real ffmpeg SRT receiver flushes to disk in its own bursts (long flat
            # stretches then a jump), so a per-interval rate is a noisy, receiver-side
            # artifact unrelated to how the SENDER is paced; the whole-window average
            # is what actually reflects the sender's ceiling. The tolerance is
            # generous ON PURPOSE -- this proves the drain is CAPPED, not that it hits
            # the ceiling to the byte; an unconstrained (pre-Task-2) drain on this
            # loopback SRT path would blow past this bound by well over an order of
            # magnitude (it delivers the whole backlog in well under a second).
            $writerNominalBytesPerSecond   = 18800 / 0.3
            $catchUpMultiplierUsedByThisScenario = 0.5
            $expectedCeilingBytesPerSecond = $catchUpMultiplierUsedByThisScenario * $writerNominalBytesPerSecond
            $ceilingToleranceFactor        = 4.0
            $maxAllowedObservedBytesPerSecond = $expectedCeilingBytesPerSecond * $ceilingToleranceFactor

            $drainReceivedSamples.Count | Should -BeGreaterThan 3 -Because 'need multiple samples across the drain window to compute an observed throughput'
            $firstDrainSample = $drainReceivedSamples[0]
            $lastDrainSample  = $drainReceivedSamples[-1]
            $overallElapsedSeconds = ($lastDrainSample.CapturedAtUtc - $firstDrainSample.CapturedAtUtc).TotalSeconds
            $overallElapsedSeconds | Should -BeGreaterThan 0 -Because 'need real wall-clock elapsed time across the sampled window to compute an overall observed throughput'
            $overallObservedBytesPerSecond = ($lastDrainSample.ReceivedLength - $firstDrainSample.ReceivedLength) / $overallElapsedSeconds
            $overallObservedBytesPerSecond | Should -BeLessOrEqual $maxAllowedObservedBytesPerSecond `
                -Because "the drain must obey the SAME ceiling dials as live (D-02) -- overall observed ${overallObservedBytesPerSecond} B/s across the sampled window exceeds the tolerant bound ${maxAllowedObservedBytesPerSecond} B/s"

            # CatchUpCapUtilization must be set during Draining the same way ReadFast
            # sets it (Task 2) -- the observable that proves the ceiling gate is
            # actually being applied, not merely computed and ignored.
            ($drainObservedCatchUpCapUtilizationValues | Where-Object { $_ -gt 0 } | Measure-Object).Count | Should -BeGreaterThan 0 `
                -Because 'CatchUpCapUtilization must be a real, non-zero number at least once during Draining (Task 2)'

            # Task 3 (CHUR-03): the Draining loop must publish LIVE numbers, not the
            # values frozen at the moment Draining was entered -- this is the backend
            # half of the "drain rate, remaining bytes and ETA keep moving" requirement.
            $drainStatsSnapshots.Count | Should -BeGreaterThan 3 -Because 'need multiple Draining-tagged stats.json snapshots to prove the telemetry is live, not frozen'

            # (a) sendBytesPerSecond must genuinely change across the drain -- a value
            # frozen at drain entry would read as the exact same number every sample.
            $distinctSendBytesPerSecondValues = @($drainStatsSnapshots.SendBytesPerSecond | Select-Object -Unique)
            $distinctSendBytesPerSecondValues.Count | Should -BeGreaterThan 1 `
                -Because 'sendBytesPerSecond must be recomputed live throughout Draining (Task 3), not published once and left stale'

            # (b) secondsBehindLive must never INCREASE across consecutive Draining
            # samples -- the backlog only shrinks while draining (D-01/D-06); a small
            # tolerance absorbs the frozen-divisor's own poll-to-poll floating-point
            # noise, never a real climb.
            $secondsBehindLiveNonIncreaseToleranceSeconds = 0.25
            for ($drainSampleIndex = 1; $drainSampleIndex -lt $drainStatsSnapshots.Count; $drainSampleIndex++) {
                $previousDrainStatsSnapshot = $drainStatsSnapshots[$drainSampleIndex - 1]
                $currentDrainStatsSnapshot  = $drainStatsSnapshots[$drainSampleIndex]
                $currentDrainStatsSnapshot.SecondsBehindLive | Should -BeLessOrEqual ($previousDrainStatsSnapshot.SecondsBehindLive + $secondsBehindLiveNonIncreaseToleranceSeconds) `
                    -Because "secondsBehindLive must monotonically decrease (within jitter tolerance) while Draining shrinks the backlog (Task 3) -- sample $drainSampleIndex rose from $($previousDrainStatsSnapshot.SecondsBehindLive) to $($currentDrainStatsSnapshot.SecondsBehindLive)"
            }

            # (c) updatedEpochSeconds must refresh on a bounded cadence throughout the
            # drain (including while a write is stalled and no bytes are committed) --
            # the dashboard must never see a stale/lost-contact gap during Draining.
            # PersistIntervalMilliseconds defaults to 250ms (not overridden by
            # New-TestTunedPusherCopy); a generous multiple absorbs real scheduling
            # jitter without weakening the load-bearing "it keeps refreshing" claim.
            $distinctUpdatedEpochSecondsValues = @($drainStatsSnapshots.UpdatedEpochSeconds | Select-Object -Unique)
            $distinctUpdatedEpochSecondsValues.Count | Should -BeGreaterThan 1 `
                -Because 'updatedEpochSeconds must advance across Draining samples (Task 3) -- a frozen publish would read the exact same timestamp every sample'
        } finally {
            if ($pusherHandle -and -not $pusherHandle.Process.HasExited) {
                Stop-Process -Id $pusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
                $pusherHandle.Process.WaitForExit(5000) | Out-Null
            }
            Stop-ValidMpegtsGrowthWriter -Writer $writer
            if ($listener -and -not $listener.HasExited) { Stop-SrtListener -Process $listener }
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Scenario 4: secondsBehindLive never inflates faster than wall clock once the recording stops growing (CHUR-01, 15-01 Task 1)' {
        # Failure-injection proof for the 2026-07-26 "30 min -> 8h21m in one minute"
        # incident: Get-SecondsBehindLive's divisor used to be the LIVE decaying EWMA
        # (growthRateWindow.SmoothedBytesPerSecond), which decays toward zero the
        # instant the recording file stops growing -- inflating the displayed delay
        # far faster than the (unshrinking) backlog actually warrants. The frozen
        # last-known-good record rate (Get-LastKnownGoodRecordRate, lib/Pacer.psm1)
        # replaces that divisor. This scenario builds a real backlog while streaming
        # (CatchUpMultiplier well below 1.0, same technique Scenario 3 uses), then
        # STOPS ONLY THE GROWTH WRITER -- leaving the recording file in place and the
        # pusher itself still running/streaming (ObsLivenessOverrideLiteral defaults
        # to '{ $true }', so the two-signal end-of-service gate never fires here; this
        # scenario deliberately proves the display fix during ongoing Streaming, per
        # Task 1's explicit "not gated on Draining" design) -- and samples
        # state/stats.json for well over the GROWTH_RATE_SMOOTHING_SECONDS default
        # (30.0s) so the EWMA has genuinely, fully decayed before the assertion runs
        # (Pitfall 1: a trivially-fast check would pass even against the pre-fix bug).
        $testWorkDirectory = Join-Path $TestDrive ("case-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $testWorkDirectory -Force | Out-Null
        $samplePath          = Join-Path $testWorkDirectory 'sample.ts'
        $recordingFolderPath = Join-Path $testWorkDirectory 'recordings'
        New-Item -ItemType Directory -Path $recordingFolderPath -Force | Out-Null
        $recordingPath = Join-Path $recordingFolderPath 'recording-001.ts'
        $receivedPath  = Join-Path $testWorkDirectory 'received.ts'
        $statePath     = Join-Path $testWorkDirectory 'offset.json'
        $controlPath   = Join-Path $testWorkDirectory 'control.json'
        $statsPath     = Join-Path $testWorkDirectory 'stats.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 20 -VideoSize '320x240' -FrameRate 25 | Out-Null

        $listenPort = Get-Random -Minimum 20000 -Maximum 40000
        # Long TotalDurationSeconds -- this writer is stopped EXPLICITLY (below), not
        # by its own duration expiring, so the recording-file-stops-growing moment is
        # deterministic and test-controlled.
        $writer   = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath `
            -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 180
        $listener = Start-SrtListener -Port $listenPort -OutputPath $receivedPath

        Set-PusherDesiredState -ControlFilePath $controlPath -DesiredState 'streaming'

        # CatchUpMultiplier well below 1.0 (mirrors Scenario 3's own rationale): the
        # ReadFast ceiling paces SLOWER than the writer's own record rate, guaranteeing
        # a real, persistent, GROWING backlog while the writer is still active -- not a
        # transient/borderline one that could race to zero before the writer stops.
        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort $listenPort -StateFilePath $statePath -ControlFilePath $controlPath -ObsLivenessOverrideLiteral '{ $true }' `
            -CatchUpMultiplier 0.5

        $pusherHandle = $null
        try {
            Start-Sleep -Milliseconds 800
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            (Wait-ForFileToExist -Path $statePath -TimeoutMilliseconds 15000) | Should -BeTrue
            (Wait-ForFileLength -Path $receivedPath -MinimumLength 18800 -TimeoutMilliseconds 20000) | Should -BeTrue

            # Let a genuine backlog accumulate while the writer is still active.
            Start-Sleep -Seconds 8

            $statsBeforeStop = Read-PusherStats -StatsFilePath $statsPath
            $statsBeforeStop | Should -Not -BeNullOrEmpty
            $statsBeforeStop.secondsBehindLive | Should -BeGreaterThan 0 -Because 'the multiplier-below-1.0 backlog must be real before the growth writer stops, or this scenario proves nothing'

            # THE RECORDING STOPS GROWING -- writer killed, file stays on disk exactly
            # as-is, pusher process keeps running/streaming throughout.
            Stop-ValidMpegtsGrowthWriter -Writer $writer

            # Sample state/stats.json for well over one full GROWTH_RATE_SMOOTHING_SECONDS
            # window (default 30.0s) so the EWMA has genuinely decayed before judging.
            $samples = [System.Collections.Generic.List[object]]::new()
            $samplingDeadlineUtc = [DateTime]::UtcNow.AddSeconds(50)
            while ([DateTime]::UtcNow -lt $samplingDeadlineUtc) {
                $currentStats = Read-PusherStats -StatsFilePath $statsPath
                if ($null -ne $currentStats) {
                    $samples.Add([PSCustomObject]@{
                        CapturedAtUtc     = [DateTime]::UtcNow
                        SecondsBehindLive = [double] $currentStats.secondsBehindLive
                    })
                }
                Start-Sleep -Milliseconds 1000
            }

            $samples.Count | Should -BeGreaterThan 30 -Because 'need enough samples across the >=45s sampling window for the wall-clock-bound assertion to be meaningful'

            # The load-bearing assertion (CHUR-01 root fix): between EVERY consecutive
            # pair of samples, secondsBehindLive must never grow by more than the
            # wall-clock seconds elapsed between those two samples (a small tolerance
            # absorbs poll/publish jitter, never the multi-hour-per-minute pre-fix
            # blowup this scenario exists to catch).
            $pollJitterToleranceSeconds = 1.5
            for ($sampleIndex = 1; $sampleIndex -lt $samples.Count; $sampleIndex++) {
                $previousSample = $samples[$sampleIndex - 1]
                $currentSample  = $samples[$sampleIndex]
                $elapsedWallClockSeconds = ($currentSample.CapturedAtUtc - $previousSample.CapturedAtUtc).TotalSeconds
                $secondsBehindLiveDelta  = $currentSample.SecondsBehindLive - $previousSample.SecondsBehindLive
                $secondsBehindLiveDelta | Should -BeLessOrEqual ($elapsedWallClockSeconds + $pollJitterToleranceSeconds) `
                    -Because "secondsBehindLive must never inflate faster than wall clock once the recording stops growing (CHUR-01) -- sample $sampleIndex grew by ${secondsBehindLiveDelta}s over ${elapsedWallClockSeconds}s of wall clock"
            }
        } finally {
            Set-PusherDesiredState -ControlFilePath $controlPath -DesiredState 'stopped'
            if ($pusherHandle -and -not $pusherHandle.Process.HasExited) {
                Wait-ForProcessExit -Process $pusherHandle.Process -TimeoutMilliseconds 15000 | Out-Null
            }
            if ($pusherHandle -and -not $pusherHandle.Process.HasExited) {
                Stop-ProcessTree -ProcessId $pusherHandle.Process.Id
                $pusherHandle.Process.WaitForExit(5000) | Out-Null
            }
            Stop-ValidMpegtsGrowthWriter -Writer $writer
            if ($listener -and -not $listener.HasExited) { Stop-SrtListener -Process $listener }
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }
}

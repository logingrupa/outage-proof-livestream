# Integration.SrtBackpressure.Tests.ps1
# Front A failure-injection proof (260718-j58/HARDEN-A): the PRIMARY destabilizer fix.
#
# THE DEFECT THIS FILE PROVES FIXED. Under bond congestion ffmpeg's SRT send buffer
# fills, so its stdin write stalls -- BEFORE this fix, Write-FfmpegStdin unconditionally
# killed ffmpeg on the first stdin-write timeout and the loop classified it as
# NetworkDeath and reconnected, tearing the session down every ~8-10s under load. In
# file mode a full send buffer is NORMAL, TCP-like backpressure that self-heals when the
# bond drains; killing on it was the destabilizer.
#
# WHY THIS FILE DOES NOT INDUCE REAL SRT BOND CONGESTION. A genuine SRT-listener-side
# receive stall proved too fragile to reproduce deterministically against this
# ffmpeg/libsrt build in isolation from a real bonded WAN. Per the plan's own documented
# fallback, this file drives the stall through the FfmpegProcess seam instead: a small
# pwsh stand-in "ffmpeg" (New-StdinStallStandinFfmpeg, TestHelpers.psm1) that simply does
# not drain its own stdin for a controlled window -- the OS pipe buffer genuinely fills
# and a real Write-FfmpegStdin call genuinely times out, with no fabrication inside
# FfmpegProcess.psm1 itself. This proves the PUSHER's hold/escalate decision end-to-end
# against a real stdin pipe, without requiring a real SRT connection at all.
#
# tests/Integration.KillAndResume.Tests.ps1 (genuine ffmpeg-exit/pipe-fault death) is
# NOT modified by this file and must stay green -- proving Front A changed nothing about
# how a real death is handled.

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

    function Wait-ForCondition {
        param([Parameter(Mandatory)] [scriptblock] $Condition, [int] $TimeoutMilliseconds = 20000)
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (& $Condition) { return $true }
            Start-Sleep -Milliseconds 150
        }
        return $false
    }

    function Stop-ProcessTree {
        <#
        .SYNOPSIS
        Kills ProcessId and its ENTIRE descendant tree (taskkill /T), not just the one
        PID. The stand-in "ffmpeg" fixture in this file is a .cmd wrapper (cmd.exe)
        that launches a pwsh child (standin.ps1) -- Stop-Process/Process.Kill() only
        ever terminates the single PID it is given, so killing just the pusher (or just
        the immediate ffmpeg-handle process, which IS the cmd.exe host) leaves the
        grandchild pwsh stand-in running, still holding an open handle on its received
        file. That orphan is what made Pester's own TestDrive cleanup fail with "file in
        use" after this file's tests. A plain per-PID kill is not sufficient here.
        #>
        param([Parameter(Mandatory)] [int] $ProcessId)

        try {
            & taskkill.exe /PID $ProcessId /T /F 2>&1 | Out-Null
        } catch {
            # Best-effort cleanup only -- never fail a test on a cleanup-path error.
        }
    }
}

Describe 'Front A: pusher holds ONE SRT session through transient backpressure (260718-j58)' -Tag 'Integration' {

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

    It 'Scenario 1: a transient stall below SRT_STALL_TOLERANCE_SECONDS holds the session -- no restart, offset frozen, then resumes byte-exact' {
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

        # The stand-in never drains for 6s (long enough to exceed the 300ms tuned
        # watchdog several times over, genuinely stalling multiple polls), then drains
        # continuously -- well BELOW the 20s tuned stall tolerance below, so the pusher
        # must never escalate to a reconnect.
        $standin = New-StdinStallStandinFfmpeg -ScratchDirectory (Join-Path $testWorkDirectory 'standin') `
            -ReceivedFilePath $receivedPath -InitialStallSeconds 6

        Set-PusherDesiredState -ControlFilePath $controlPath -DesiredState 'streaming'

        $writer = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath `
            -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 40

        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort 19999 -StateFilePath $statePath -ControlFilePath $controlPath -ObsLivenessOverrideLiteral '{ $true }' `
            -FfmpegPath $standin.WrapperPath -WatchdogTimeoutMilliseconds 300 -SrtStallToleranceSeconds 20

        $pusherHandle = $null
        try {
            Start-Sleep -Milliseconds 500
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            (Wait-ForFileToExist -Path $statePath -TimeoutMilliseconds 60000) | Should -BeTrue

            # While the stand-in is deliberately not draining, the process must stay
            # alive and streaming (no restart) -- confirmed by reading stats.json
            # directly rather than trusting a possibly-stale offset file.
            Start-Sleep -Seconds 3
            $pusherHandle.Process.HasExited | Should -BeFalse -Because 'holding a transient stall must never exit the pusher'

            $statsDuringStall = Read-PusherStats -StatsFilePath $statsPath
            if ($null -ne $statsDuringStall) {
                $statsDuringStall.cumulativeReconnectCount | Should -Be 0 -Because 'a transient stall below tolerance must never reconnect'
            }

            # Once the stand-in starts draining (after its 6s stall), bytes must start
            # flowing and accumulate in the received file.
            (Wait-ForFileLength -Path $receivedPath -MinimumLength 18800 -TimeoutMilliseconds 60000) |
                Should -BeTrue -Because 'once the transient stall clears the SAME held session must resume sending'

            $statsAfterResume = Read-PusherStats -StatsFilePath $statsPath
            $statsAfterResume | Should -Not -BeNullOrEmpty
            $statsAfterResume.cumulativeReconnectCount | Should -Be 0 -Because 'a transient backpressure stall must resolve WITHOUT any reconnect (Front A)'

            $receivedLength = (Get-Item -LiteralPath $receivedPath).Length
            $sampleLength = (Get-Item -LiteralPath $samplePath).Length
            $compareLength = [Math]::Min($receivedLength, $sampleLength)
            $compareLength | Should -BeGreaterThan 18800 -Because 'the byte-identity check must cover a substantial range'
            Test-ByteRangeEquality -SourcePath $recordingPath -ReceivedPath $receivedPath -StartOffset 0 -Length $compareLength |
                Should -BeTrue -Because 'a held-then-resumed session must deliver byte-exact, in-order data -- no skip, no reorder'
        } finally {
            if ($pusherHandle -and -not $pusherHandle.Process.HasExited) {
                Stop-ProcessTree -ProcessId $pusherHandle.Process.Id
                $pusherHandle.Process.WaitForExit(5000) | Out-Null
            }
            Stop-ValidMpegtsGrowthWriter -Writer $writer
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Scenario 2: a stall past SRT_STALL_TOLERANCE_SECONDS escalates to exactly one reconnect, then resumes byte-exact' {
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
        $attemptCounterPath = Join-Path $testWorkDirectory 'attempt-counter.txt'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 20 -VideoSize '320x240' -FrameRate 25 | Out-Null

        # Attempt 1 (the initial ffmpeg launch) NEVER drains -- simulating a genuinely
        # dead/stuck peer. Attempt 2 (the reconnect Front A must perform once the tiny
        # 2s tolerance is exceeded) drains immediately, so the pusher can be observed
        # recovering cleanly after exactly one reconnect.
        $standin = New-StdinStallStandinFfmpeg -ScratchDirectory (Join-Path $testWorkDirectory 'standin') `
            -ReceivedFilePath $receivedPath -AttemptCounterFilePath $attemptCounterPath -StallForeverOnAttempts @(1)

        Set-PusherDesiredState -ControlFilePath $controlPath -DesiredState 'streaming'

        $writer = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath `
            -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 40

        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RecordingFilenameGlob 'recording-*.ts' `
            -RelayPort 19998 -StateFilePath $statePath -ControlFilePath $controlPath -ObsLivenessOverrideLiteral '{ $true }' `
            -FfmpegPath $standin.WrapperPath -WatchdogTimeoutMilliseconds 300 -SrtStallToleranceSeconds 2 `
            -BackoffBaseMilliseconds 100 -BackoffCeilingMilliseconds 500

        $pusherHandle = $null
        try {
            Start-Sleep -Milliseconds 500
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            (Wait-ForFileToExist -Path $statePath -TimeoutMilliseconds 60000) | Should -BeTrue

            # The tolerance-exceeded escalation must reconnect to a fresh ffmpeg instance
            # (attempt 2), which drains immediately -- bytes must start flowing.
            (Wait-ForFileLength -Path $receivedPath -MinimumLength 18800 -TimeoutMilliseconds 30000) |
                Should -BeTrue -Because 'the bounded stall ceiling must eventually escalate to a reconnect and resume sending'

            $stats = Read-PusherStats -StatsFilePath $statsPath
            $stats | Should -Not -BeNullOrEmpty
            $stats.cumulativeReconnectCount | Should -Be 1 -Because 'exactly one reconnect must fire -- neither zero (never escalated) nor more than one (a second, unnecessary reconnect)'

            $receivedLength = (Get-Item -LiteralPath $receivedPath).Length
            $sampleLength = (Get-Item -LiteralPath $samplePath).Length
            $compareLength = [Math]::Min($receivedLength, $sampleLength)
            $compareLength | Should -BeGreaterThan 18800 -Because 'the byte-identity check must cover a substantial range'
            Test-ByteRangeEquality -SourcePath $recordingPath -ReceivedPath $receivedPath -StartOffset 0 -Length $compareLength |
                Should -BeTrue -Because 'the reconnect must resume byte-exact from the persisted offset (D-05 margin only) -- no permanent gap'
        } finally {
            if ($pusherHandle -and -not $pusherHandle.Process.HasExited) {
                Stop-ProcessTree -ProcessId $pusherHandle.Process.Id
                $pusherHandle.Process.WaitForExit(5000) | Out-Null
            }
            Stop-ValidMpegtsGrowthWriter -Writer $writer
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }
}

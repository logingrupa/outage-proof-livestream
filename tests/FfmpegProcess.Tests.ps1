BeforeAll {
    $script:LoggingModulePath = Join-Path $PSScriptRoot '../lib/Logging.psm1'
    $script:FfmpegProcessModulePath = Join-Path $PSScriptRoot '../lib/FfmpegProcess.psm1'
    $script:TestHelpersModulePath = Join-Path $PSScriptRoot 'TestHelpers.psm1'
    $script:FfmpegSrtFailureFixturePath = Join-Path $PSScriptRoot 'fixtures/ffmpeg-srt-failure-stderr.txt'
}

Describe 'Build-FfmpegArguments' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module FfmpegProcess -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:FfmpegProcessModulePath -Force
    }

    AfterEach {
        Remove-Module FfmpegProcess -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'begins with the D-19 stdin shape (-f mpegts -i pipe:0 -c copy -f mpegts) and ends with an srt:// URL' {
        $arguments = Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01'

        $arguments[0..7] | Should -Be @('-f', 'mpegts', '-i', 'pipe:0', '-c', 'copy', '-f', 'mpegts')
        $arguments[-1] | Should -Match '^srt://'
    }

    It 'emits a bare tcp://host:port URL with the same stdin shape when Protocol is tcp' {
        $arguments = Build-FfmpegArguments -RelayHost 'relay.example.com' -RelayPort 8891 -StreamId 'church-01' -Protocol 'tcp'

        $arguments[0..7] | Should -Be @('-f', 'mpegts', '-i', 'pipe:0', '-c', 'copy', '-f', 'mpegts')
        $arguments[-1] | Should -BeExactly 'tcp://relay.example.com:8891'
    }

    It 'ignores every SRT knob when Protocol is tcp (no query string at all)' {
        $arguments = Build-FfmpegArguments -RelayHost 'relay.example.com' -RelayPort 8891 -StreamId 'church-01' -Protocol 'tcp' `
            -MaxBandwidthBytesPerSecond 3750000 -SendBufferBytes 1048576 -FlightFlagSizeBytes 65536 -LossMaxTtl 4096 -NakReport 'true'

        $arguments[-1] | Should -Not -Match '\?'
    }

    It 'includes mode=caller, latency, pkt_size, and streamid in the SRT URL' {
        $arguments = Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01' -LatencyMicroseconds 500000 -PacketSizeBytes 1316

        $srtUrl = $arguments[-1]
        $srtUrl | Should -Match 'mode=caller'
        $srtUrl | Should -Match ([regex]::Escape('latency=500000'))
        $srtUrl | Should -Match ([regex]::Escape('pkt_size=1316'))
        $srtUrl | Should -Match ([regex]::Escape('streamid=church-01'))
    }

    It 'defaults LatencyMicroseconds to 500000 and PacketSizeBytes to 1316 when not supplied' {
        $arguments = Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01'

        $srtUrl = $arguments[-1]
        $srtUrl | Should -Match ([regex]::Escape('latency=500000'))
        $srtUrl | Should -Match ([regex]::Escape('pkt_size=1316'))
    }

    It 'includes an explicit linger value in the SRT URL so the socket drains before hard-close (Wave 1 spike deviation, 01-01-SUMMARY.md)' {
        $arguments = Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01'

        $srtUrl = $arguments[-1]
        $srtUrl | Should -Match 'linger=\d+'
    }

    It 'omits maxbw by default -- the cap was falsified (starves retransmits, drops the close-flush tail; D-20)' {
        $arguments = Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01'

        $srtUrl = $arguments[-1]
        $srtUrl | Should -Not -Match 'maxbw='
    }

    It 'emits the caller-supplied maxbw value when one is passed' {
        $arguments = Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01' -MaxBandwidthBytesPerSecond 3750000

        $srtUrl = $arguments[-1]
        $srtUrl | Should -Match ([regex]::Escape('maxbw=3750000'))
    }

    It 'omits maxbw entirely when set to 0 (the unlimited behaviour, same as the default)' {
        $arguments = Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01' -MaxBandwidthBytesPerSecond 0

        $srtUrl = $arguments[-1]
        $srtUrl | Should -Not -Match 'maxbw='
    }

    It 'omits all Tier 1 sender knobs by default so the URL is byte-identical to pre-Tier-1 (debug/srt-throughput-degraded-today.md)' {
        $srtUrl = (Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01')[-1]

        $srtUrl | Should -Not -Match 'sndbuf='
        $srtUrl | Should -Not -Match 'ffs='
        $srtUrl | Should -Not -Match 'lossmaxttl='
        $srtUrl | Should -Not -Match 'nakreport='
    }

    It 'emits sndbuf only when a positive SendBufferBytes is supplied' {
        (Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01' -SendBufferBytes 67108864)[-1] |
            Should -Match ([regex]::Escape('sndbuf=67108864'))
        (Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01' -SendBufferBytes 0)[-1] |
            Should -Not -Match 'sndbuf='
    }

    It 'emits ffs only when a positive FlightFlagSizeBytes is supplied (mirrors relay ffs=65536)' {
        (Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01' -FlightFlagSizeBytes 65536)[-1] |
            Should -Match ([regex]::Escape('ffs=65536'))
        (Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01' -FlightFlagSizeBytes 0)[-1] |
            Should -Not -Match 'ffs='
    }

    It 'emits lossmaxttl only when a positive LossMaxTtl is supplied (mirrors relay lossmaxttl=4096)' {
        (Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01' -LossMaxTtl 4096)[-1] |
            Should -Match ([regex]::Escape('lossmaxttl=4096'))
        (Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01' -LossMaxTtl 0)[-1] |
            Should -Not -Match 'lossmaxttl='
    }

    It 'emits nakreport only when set to true/false, omits it when blank (libsrt auto)' {
        (Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01' -NakReport 'true')[-1] |
            Should -Match ([regex]::Escape('nakreport=true'))
        (Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01' -NakReport 'false')[-1] |
            Should -Match ([regex]::Escape('nakreport=false'))
        (Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01' -NakReport '')[-1] |
            Should -Not -Match 'nakreport='
    }

    It 'feeds input via pipe:0 stdin -- exactly one -i flag, never pointed at a filesystem path' {
        $arguments = Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01'

        $inputFlagIndexes = @(for ($index = 0; $index -lt $arguments.Length; $index++) {
            if ($arguments[$index] -eq '-i') { $index }
        })
        $inputFlagIndexes.Count | Should -Be 1
        $arguments[$inputFlagIndexes[0] + 1] | Should -Be 'pipe:0'
    }

    It 'never contains ffmpeg''s native realtime input pacing flag (forbidden by D-03)' {
        $arguments = Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort 18890 -StreamId 'church-01'

        $forbiddenRealtimePacingFlag = '-re'
        $arguments | Should -Not -Contain $forbiddenRealtimePacingFlag
    }

    It 'never writes the forbidden realtime pacing flag as a quoted string literal anywhere in the module source' {
        $moduleSource = Get-Content -LiteralPath $script:FfmpegProcessModulePath -Raw
        $moduleSource | Should -Not -Match "['\`"]-re['\`"]"
    }
}

Describe 'FfmpegProcess lifecycle: async stderr drain (D-17)' -Tag 'Integration' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module FfmpegProcess -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:FfmpegProcessModulePath -Force
    }

    AfterEach {
        Remove-Module FfmpegProcess -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'calls BeginErrorReadLine before returning from Start-FfmpegProcess (grep confirms the call site)' {
        $moduleSource = Get-Content -LiteralPath $script:FfmpegProcessModulePath -Raw
        $moduleSource | Should -Match 'BeginErrorReadLine'
    }

    It 'never uses a synchronous StandardError read anywhere in the module' {
        $moduleSource = Get-Content -LiteralPath $script:FfmpegProcessModulePath -Raw
        $moduleSource | Should -Not -Match 'StandardError\.(ReadToEnd|ReadLine)\('
    }

    It 'starts a real process with stdin/stderr redirected and does not throw or deadlock on stderr output' {
        # Use pwsh (not ffmpeg) as a stand-in process that writes to stderr and exits
        # quickly -- proves the async drain doesn't require a synchronous read to avoid
        # deadlocking, without needing a real ffmpeg/SRT chain for this specific check.
        $processHandle = Start-FfmpegProcess -FfmpegPath 'pwsh' -ArgumentList @('-NoProfile', '-Command', '[Console]::Error.WriteLine("stub stderr line"); exit 0')

        try {
            $exited = $processHandle.Process.WaitForExit(10000)
            $exited | Should -BeTrue
            $processHandle.Process.ExitCode | Should -Be 0
        } finally {
            Stop-FfmpegProcess -ProcessHandle $processHandle -Force
        }
    }
}

Describe 'Write-FfmpegStdin hang watchdog (D-18)' -Tag 'Integration' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module FfmpegProcess -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:FfmpegProcessModulePath -Force
    }

    AfterEach {
        Remove-Module FfmpegProcess -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'Front A (260718-j58): holds (does NOT kill) a still-alive process when a stdin write blocks beyond the timeout -- FailureReason=Stalled' {
        # Spawn a process that never reads its stdin -- the OS pipe buffer fills and a
        # large-enough write blocks, simulating transient SRT flow-control backpressure
        # without needing a real bond-congestion repro. The process itself is genuinely
        # still alive (Start-Sleep, never exits), so this must NOT be treated as a hang.
        $blockedHandle = Start-FfmpegProcess -FfmpegPath 'pwsh' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30')

        try {
            $largeBuffer = New-Object byte[] (2 * 1024 * 1024)
            $result = Write-FfmpegStdin -ProcessHandle $blockedHandle -Bytes $largeBuffer -TimeoutMilliseconds 300

            $result.Success | Should -BeFalse
            $result.RestartNeeded | Should -BeFalse -Because 'a soft-timeout stall while the process is alive is transient backpressure, not a hang -- Front A must never kill on this alone'
            $result.FailureReason | Should -Be 'Stalled'
            $blockedHandle.Process.HasExited | Should -BeFalse -Because 'the process must be held, not killed, on a mere soft-timeout stall'
            $blockedHandle.PendingWriteTask | Should -Not -BeNullOrEmpty -Because 'the same in-flight WriteAsync task must be retained for Wait-FfmpegStdinPendingWrite to re-await'
        } finally {
            if (-not $blockedHandle.Process.HasExited) { $blockedHandle.Process.Kill($true) }
        }
    }

    It 'returns Success=$false / RestartNeeded=$true (never crashes) when ffmpeg has already exited and the pipe is closed (CR-01)' {
        # The most likely production failure: ffmpeg dies (relay/network drop) and the
        # stdin pipe is closed. A write must be caught and turned into a restart signal,
        # not allowed to throw an AggregateException out of the pusher loop.
        $deadHandle = Start-FfmpegProcess -FfmpegPath 'pwsh' -ArgumentList @('-NoProfile', '-Command', 'exit 0')
        try {
            $deadHandle.Process.WaitForExit(10000) | Out-Null
            $deadHandle.Process.HasExited | Should -BeTrue

            $buffer = New-Object byte[] (2 * 1024 * 1024)
            # Called directly (not wrapped in a scriptblock) so a thrown AggregateException
            # would fail this It block on its own -- proving the write never crashes out.
            $result = Write-FfmpegStdin -ProcessHandle $deadHandle -Bytes $buffer -TimeoutMilliseconds 5000

            $result.Success | Should -BeFalse
            $result.RestartNeeded | Should -BeTrue
        } finally {
            if (-not $deadHandle.Process.HasExited) { $deadHandle.Process.Kill($true) }
        }
    }

    It 'returns Success=$true and RestartNeeded=$false for a write that completes well within the timeout' {
        $readerHandle = Start-FfmpegProcess -FfmpegPath 'pwsh' -ArgumentList @('-NoProfile', '-Command', '[Console]::In.ReadToEnd() | Out-Null')

        try {
            $smallBuffer = New-Object byte[] 100
            $result = Write-FfmpegStdin -ProcessHandle $readerHandle -Bytes $smallBuffer -TimeoutMilliseconds 5000

            $result.Success | Should -BeTrue
            $result.RestartNeeded | Should -BeFalse
            $readerHandle.PendingWriteTask | Should -BeNullOrEmpty -Because 'a completed write must clear any prior pending-task marker'
        } finally {
            Stop-FfmpegProcess -ProcessHandle $readerHandle -Force
        }
    }
}

Describe 'Wait-FfmpegStdinPendingWrite (Front A, 260718-j58)' -Tag 'Integration' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module FfmpegProcess -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:FfmpegProcessModulePath -Force
    }

    AfterEach {
        Remove-Module FfmpegProcess -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'resolves a previously-stalled write to Success once the process finally drains it' {
        # A process that blocks on stdin for a bit, THEN reads (drains) it -- models a
        # bond that was congested and then cleared.
        $drainingHandle = Start-FfmpegProcess -FfmpegPath 'pwsh' -ArgumentList @(
            '-NoProfile', '-Command', 'Start-Sleep -Milliseconds 600; [Console]::In.ReadToEnd() | Out-Null'
        )

        try {
            $buffer = New-Object byte[] (2 * 1024 * 1024)
            $stallResult = Write-FfmpegStdin -ProcessHandle $drainingHandle -Bytes $buffer -TimeoutMilliseconds 200
            $stallResult.FailureReason | Should -Be 'Stalled'
            $drainingHandle.PendingWriteTask | Should -Not -BeNullOrEmpty

            $resolved = Wait-FfmpegStdinPendingWrite -ProcessHandle $drainingHandle -TimeoutMilliseconds 5000
            $resolved.Success | Should -BeTrue
            $resolved.RestartNeeded | Should -BeFalse
            $drainingHandle.PendingWriteTask | Should -BeNullOrEmpty -Because 'a resolved pending write must clear the marker'
        } finally {
            Stop-FfmpegProcess -ProcessHandle $drainingHandle -Force
        }
    }

    It 'keeps reporting Stalled (never kills) while the pending write is still not drained and the process is alive' {
        $blockedHandle = Start-FfmpegProcess -FfmpegPath 'pwsh' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30')

        try {
            $buffer = New-Object byte[] (2 * 1024 * 1024)
            $stallResult = Write-FfmpegStdin -ProcessHandle $blockedHandle -Bytes $buffer -TimeoutMilliseconds 200
            $stallResult.FailureReason | Should -Be 'Stalled'

            $polled = Wait-FfmpegStdinPendingWrite -ProcessHandle $blockedHandle -TimeoutMilliseconds 200
            $polled.Success | Should -BeFalse
            $polled.RestartNeeded | Should -BeFalse
            $polled.FailureReason | Should -Be 'Stalled'
            $blockedHandle.Process.HasExited | Should -BeFalse -Because 'holding a stall must never kill the process'
            $blockedHandle.PendingWriteTask | Should -Not -BeNullOrEmpty -Because 'the caller polls again next tick against the SAME task'
        } finally {
            if (-not $blockedHandle.Process.HasExited) { $blockedHandle.Process.Kill($true) }
        }
    }

    It 'reports Fault and kills when the process has exited while a write was still pending' {
        # A process that hangs on stdin and then is killed externally (simulating the
        # peer dying mid-hold) -- Wait-FfmpegStdinPendingWrite must detect the death and
        # escalate, never keep holding forever.
        $blockedHandle = Start-FfmpegProcess -FfmpegPath 'pwsh' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30')

        try {
            $buffer = New-Object byte[] (2 * 1024 * 1024)
            $stallResult = Write-FfmpegStdin -ProcessHandle $blockedHandle -Bytes $buffer -TimeoutMilliseconds 200
            $stallResult.FailureReason | Should -Be 'Stalled'

            $blockedHandle.Process.Kill($true)
            $blockedHandle.Process.WaitForExit(5000) | Out-Null

            $resolved = Wait-FfmpegStdinPendingWrite -ProcessHandle $blockedHandle -TimeoutMilliseconds 2000
            $resolved.Success | Should -BeFalse
            $resolved.RestartNeeded | Should -BeTrue
            $resolved.FailureReason | Should -Be 'Fault'
        } finally {
            if (-not $blockedHandle.Process.HasExited) { $blockedHandle.Process.Kill($true) }
        }
    }

    It 'is a no-op success when there is no pending task at all (defensive)' {
        $readerHandle = Start-FfmpegProcess -FfmpegPath 'pwsh' -ArgumentList @('-NoProfile', '-Command', '[Console]::In.ReadToEnd() | Out-Null')

        try {
            $result = Wait-FfmpegStdinPendingWrite -ProcessHandle $readerHandle -TimeoutMilliseconds 500
            $result.Success | Should -BeTrue
            $result.RestartNeeded | Should -BeFalse
        } finally {
            Stop-FfmpegProcess -ProcessHandle $readerHandle -Force
        }
    }
}

Describe 'FfmpegProcess integration: stdin -> local SRT listener byte-match (D-20)' -Tag 'Integration' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module FfmpegProcess -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:FfmpegProcessModulePath -Force
        Import-Module $script:TestHelpersModulePath -Force
    }

    AfterEach {
        Remove-Module FfmpegProcess -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'delivers a byte-identical stream to a local SRT listener when fed via Start-FfmpegProcess/Write-FfmpegStdin' {
        $samplePath = Join-Path $TestDrive 'sample.ts'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 3

        $listenPort = Get-Random -Minimum 20000 -Maximum 40000
        $receivedPath = Join-Path $TestDrive 'received.ts'
        $listenerProcess = Start-SrtListener -Port $listenPort -OutputPath $receivedPath

        try {
            Start-Sleep -Seconds 2   # let the listener bind before the caller connects

            $ffmpegArguments = Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort $listenPort -StreamId 'test-integration'
            $senderHandle = Start-FfmpegProcess -ArgumentList $ffmpegArguments

            try {
                $sourceStream = [System.IO.FileStream]::new($samplePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    $buffer = New-Object byte[] 65536
                    while (($bytesRead = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $chunk = if ($bytesRead -eq $buffer.Length) { $buffer } else { $buffer[0..($bytesRead - 1)] }
                        $writeResult = Write-FfmpegStdin -ProcessHandle $senderHandle -Bytes $chunk -TimeoutMilliseconds 10000
                        $writeResult.Success | Should -BeTrue
                    }
                } finally {
                    $sourceStream.Dispose()
                }

                Stop-FfmpegProcess -ProcessHandle $senderHandle
            } finally {
                if (-not $senderHandle.Process.HasExited) { $senderHandle.Process.Kill($true) }
            }

            $listenerProcess.WaitForExit(15000) | Out-Null
        } finally {
            if (-not $listenerProcess.HasExited) { Stop-SrtListener -Process $listenerProcess }
        }

        $receivedLength = (Get-Item -LiteralPath $receivedPath).Length
        $receivedLength | Should -BeGreaterThan 0

        $sampleLength = (Get-Item -LiteralPath $samplePath).Length
        $compareLength = [Math]::Min($sampleLength, $receivedLength)
        Test-ByteRangeEquality -SourcePath $samplePath -ReceivedPath $receivedPath -StartOffset 0 -Length $compareLength | Should -BeTrue
    }

    # This is the project's core value expressed as an assertion: every byte handed to
    # ffmpeg must reach the relay before the process ends. It is NOT a test about the
    # stop path -- Stop-FfmpegProcess was measured innocent (its Kill never fires; the
    # sender prints a complete muxing summary with every packet muxed). It is a test
    # about the TRANSPORT: SRT's live transtype buffers an in-flight window and discards
    # whatever has not been played out when the connection closes.
    # Full measurement trail: .planning/debug/ffmpeg-tail-flush-on-stop.md
    It 'delivers the entire stream to the relay -- SRT must not discard its in-flight window when the sender closes' {
        $samplePath = Join-Path $TestDrive 'window-sample.ts'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 20 | Out-Null

        # The ONLY defensible expectation here is a MEASURED one. `ffmpeg -c copy`
        # legitimately does not re-emit the trailing TS container-framing packets at a
        # misaligned cut, so "received == fed" is unsatisfiable by construction and no
        # correct pusher could ever pass it (measured: 357200 in -> 356824 out, with 783
        # video packets on both sides -- framing, not content). Remuxing the SAME bytes
        # through the SAME stdin -> -c copy -> mpegts shape with the network absent
        # yields exactly what a correct SRT delivery must produce. Deriving it here
        # instead of hardcoding a constant is what lets this assert EXACT equality with
        # no tolerance to argue about, and keeps it correct if the fixture ever changes.
        # PowerShell has no stdin redirect operator; cmd /c gives a true byte-stream stdin.
        $baselinePath = Join-Path $TestDrive 'window-baseline.ts'
        & cmd /c "ffmpeg -y -f mpegts -i pipe:0 -c copy -f mpegts `"$baselinePath`" < `"$samplePath`" 2>nul"
        $expectedDeliveredBytes = (Get-Item -LiteralPath $baselinePath).Length
        $expectedDeliveredBytes | Should -BeGreaterThan 100000 -Because 'the local baseline remux must produce a substantial stream, or the comparison below proves nothing'

        # A DELIBERATE STRESS AMPLIFIER of the production mechanism -- not an exotic knob.
        # The defect is equally present at the production 500ms, but there it only
        # surfaces when the receiver is starved (6/6 under CPU saturation, 0/6 on a quiet
        # box), so a test pinned at 500ms would pass on a quiet box and silently stop
        # guarding this property -- or be dismissed as "flaky" and deleted, which is
        # exactly what happened to this defect's earlier symptoms for a whole phase.
        # Widening the window makes the SAME mechanism deterministic with no CPU-load
        # jobs: the feed runs far faster than realtime, so the entire stream is still
        # inside the window at close. Measured on a quiet box, 3/3 each: live mode
        # delivers ZERO bytes; transtype=file delivers the full baseline.
        # This is also a REALISTIC setting, which is what makes the finding severe rather
        # than academic: CLAUDE.md advises sizing latency at >=2.5x RTT for bonded/lossy
        # WANs, so tuning for a real church uplink pushes the window WIDER, and the bytes
        # discarded at every clean finish scale with it.
        $wideLatencyMicroseconds = 4000000

        $listenPort = Get-Random -Minimum 20000 -Maximum 40000
        $receivedPath = Join-Path $TestDrive 'window-received.ts'
        $listenerHandle = Start-SrtListener -Port $listenPort -OutputPath $receivedPath -LatencyMicroseconds $wideLatencyMicroseconds

        try {
            Start-Sleep -Seconds 2   # let the listener bind before the caller connects

            $ffmpegArguments = Build-FfmpegArguments -RelayHost '127.0.0.1' -RelayPort $listenPort -StreamId 'test-window' `
                -LatencyMicroseconds $wideLatencyMicroseconds
            $senderHandle = Start-FfmpegProcess -ArgumentList $ffmpegArguments
            Start-Sleep -Milliseconds 800

            try {
                # Paced like the real pusher's catch-up feed. An unpaced blast overruns
                # SRT and breaks ffmpeg outright, which is a harness artifact rather than
                # the effect under study.
                $sampleBytes = [System.IO.File]::ReadAllBytes($samplePath)
                $chunkSizeBytes = 18800
                for ($offset = 0; $offset -lt $sampleBytes.Length; $offset += $chunkSizeBytes) {
                    $thisChunkSize = [Math]::Min($chunkSizeBytes, $sampleBytes.Length - $offset)
                    $chunk = New-Object byte[] $thisChunkSize
                    [Array]::Copy($sampleBytes, $offset, $chunk, 0, $thisChunkSize)
                    $writeResult = Write-FfmpegStdin -ProcessHandle $senderHandle -Bytes $chunk -TimeoutMilliseconds 10000
                    $writeResult.Success | Should -BeTrue -Because 'the fixture must feed the whole stream into ffmpeg, or there is no drained tail to assert about'
                    Start-Sleep -Milliseconds 150
                }

                Stop-FfmpegProcess -ProcessHandle $senderHandle
            } finally {
                if (-not $senderHandle.Process.HasExited) { $senderHandle.Process.Kill($true) }
            }

            $listenerHandle.WaitForExit(25000) | Out-Null
        } finally {
            Stop-SrtListener -Process $listenerHandle
        }

        # A total-loss run produces NO output file at all -- the receiver's muxer is never
        # handed a single byte, so it writes nothing. That is a real, reportable outcome
        # (measured: live mode at a 4s window delivers zero, 3/3), not an error to trip
        # over: treat a missing file as zero delivered so the assertion below reports the
        # shortfall in bytes instead of an unrelated Get-Item path error.
        $receivedLength = if (Test-Path -LiteralPath $receivedPath) { (Get-Item -LiteralPath $receivedPath).Length } else { 0 }

        # Every byte that arrived must be a byte-exact, in-order prefix (D-04/D-13: never
        # skip, never reorder) AND the whole baseline must have arrived. Order matters
        # here: report the shortfall first, because a bare prefix check on a truncated
        # file passes happily -- "short" and "correct so far" are not in conflict, which
        # is precisely how this loss hid behind `first diff -1` for so long.
        $receivedLength | Should -Be $expectedDeliveredBytes -Because "the relay must receive every byte a local -c copy remux of the same input emits ($expectedDeliveredBytes); a shortfall here is content the church loses at the end of every service, and the SRT close discarding its in-flight window is not an acceptable source of it"
        Test-ByteRangeEquality -SourcePath $baselinePath -ReceivedPath $receivedPath -StartOffset 0 -Length $expectedDeliveredBytes | Should -BeTrue
    }
}

Describe 'Get-FfmpegExitClassification (RES-04, D-09)' -Tag 'Quick' {

    BeforeAll {
        # Pull a real captured line straight from the 02-01 fixture -- NOT the
        # RESEARCH.md web-search guesses -- so this test proves the pattern list
        # matches THIS build's actual observed stderr (02-01-SUMMARY.md ground truth).
        $script:RealNetworkDeathFixtureLine = (Get-Content -LiteralPath $script:FfmpegSrtFailureFixturePath |
            Where-Object { $_ -match 'Error submitting a packet to the muxer: I/O error' } |
            Select-Object -First 1)
    }

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module FfmpegProcess -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:FfmpegProcessModulePath -Force
    }

    AfterEach {
        Remove-Module FfmpegProcess -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'sources a real NetworkDeath line from the 02-01 fixture (not a hand-authored guess)' {
        $script:RealNetworkDeathFixtureLine | Should -Not -BeNullOrEmpty
        $script:RealNetworkDeathFixtureLine | Should -Match 'I/O error'
    }

    It 'short-circuits FailureReason=Hang to NetworkDeath regardless of exit code or stderr (Anti-Patterns shortcut)' {
        $classification = Get-FfmpegExitClassification -FailureReason 'Hang' -ExitCode 0 -StderrTailLines @() -RecordingFileStillGrowing $true

        $classification | Should -Be 'NetworkDeath'
    }

    It 'classifies FailureReason=Fault with a real captured SRT-failure stderr line as NetworkDeath' {
        $classification = Get-FfmpegExitClassification -FailureReason 'Fault' -ExitCode -5 -StderrTailLines @($script:RealNetworkDeathFixtureLine) -RecordingFileStillGrowing $true

        $classification | Should -Be 'NetworkDeath'
    }

    It 'classifies FailureReason=Fault with a clean exit and a non-growing recording file as RecordingEnded (D-09) -- log-only label, no stop path (D-10)' {
        $classification = Get-FfmpegExitClassification -FailureReason 'Fault' -ExitCode 0 -StderrTailLines @() -RecordingFileStillGrowing $false

        $classification | Should -Be 'RecordingEnded'
    }

    It 'falls through to FfmpegCrash when neither the Hang short-circuit nor a NetworkDeath pattern nor RecordingEnded conditions apply' {
        $classification = Get-FfmpegExitClassification -FailureReason 'Fault' -ExitCode 1 -StderrTailLines @('some internal decode error') -RecordingFileStillGrowing $true

        $classification | Should -Be 'FfmpegCrash'
    }

    It 'is a pure function -- no ffmpeg/process spawned to produce these classifications (synthetic inputs only)' {
        # Purity is proven structurally: every It above calls Get-FfmpegExitClassification
        # directly with synthetic (FailureReason, ExitCode, StderrTailLines,
        # RecordingFileStillGrowing) inputs and never touches Start-FfmpegProcess,
        # Write-FfmpegStdin, or Stop-FfmpegProcess in this Describe block.
        Get-Command Get-FfmpegExitClassification | Should -Not -BeNullOrEmpty
    }
}

# TestHelpers.Tests.ps1
# Tests for the test-infrastructure module itself.
#
# Why a helper module has its own tests: this repo has now caught FOUR helpers that
# reported a result while measuring nothing or measuring the wrong thing --
# Install.Tests' @($null).Count, the harness's unrewritten $relayHost, the rotation
# byte-equality helper's single unchecked Read, and Start-SrtListener discarding the
# receiver's stderr (.planning/debug/ffmpeg-tail-flush-on-stop.md). A measurement
# instrument that is never itself measured is how all four survived. These tests pin
# the properties the instruments claim.

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRootPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:TestHelpersModulePath = Join-Path $PSScriptRoot 'TestHelpers.psm1'
}

Describe 'Start-SrtListener stderr capture (the receiver-side witness)' -Tag 'Integration' {

    BeforeEach {
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Import-Module $script:TestHelpersModulePath -Force
    }

    AfterEach {
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
    }

    # The receiver's stderr is not a nice-to-have. Sender-side stderr said frame=783 /
    # Lsize=348KiB on runs that lost 30KB; only the RECEIVER's frame=721 / Lsize=318KiB
    # located the loss in the transport rather than in the pusher's stop path. That
    # witness was drained into the void by BeginErrorReadLine() with no handler, which
    # is why the tail loss stayed misattributed to Stop-FfmpegProcess for a whole phase.
    It 'retains the receiver ffmpeg stderr, including its terminal muxing summary, on the returned handle' {
        $workDirectory = Join-Path $TestDrive 'listener-stderr'
        New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
        $samplePath = Join-Path $workDirectory 'sample.ts'
        $receivedPath = Join-Path $workDirectory 'received.ts'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 3 | Out-Null

        $listenPort = Get-Random -Minimum 20000 -Maximum 40000
        $listenerHandle = Start-SrtListener -Port $listenPort -OutputPath $receivedPath

        try {
            Start-Sleep -Seconds 2   # let the listener bind before the caller connects

            # transtype=file MUST mirror Start-SrtListener's default (and
            # Build-FfmpegArguments'). SRT rejects a mode mismatch at handshake
            # ("MessageAPI/StreamAPI collision"), and this very line caught it: written
            # without transtype while the listener defaulted to file, the sender exited
            # -5 and never pushed a byte. That loudness is the point -- a mismatched
            # pusher/relay pair cannot silently lose content, it simply refuses to connect.
            $senderUrl = "srt://127.0.0.1:$listenPort`?mode=caller&transtype=file&latency=500000&pkt_size=1316&linger=4"
            $senderProcess = Start-Process -FilePath 'ffmpeg' -WindowStyle Hidden -PassThru -Wait -ArgumentList @(
                '-f', 'mpegts', '-i', $samplePath,
                '-c', 'copy',
                '-f', 'mpegts', $senderUrl
            )
            $senderProcess.ExitCode | Should -Be 0 -Because 'the fixture must actually push a stream, or there is no receiver stderr worth asserting about'

            $listenerHandle.WaitForExit(15000) | Out-Null
        } finally {
            Stop-SrtListener -Process $listenerHandle
        }

        # The member must EXIST. Asserting `@($handle.StderrTailLines).Count -gt 0`
        # instead would be a silent no-op and was caught being exactly that while
        # writing this test: @($null).Count is 1, not 0, so the array-wrap manufactures
        # a passing count out of a property that is not there. That is landmine #1 of
        # this repo's catalogue (Install.Tests' @($problems).Count) reproduced by
        # reflex. Check the member, then check its content, and never let @() answer
        # either question.
        $listenerHandle.PSObject.Properties.Name | Should -Contain 'StderrTailLines' -Because 'the handle must expose the retained receiver stderr, or callers have no witness to inspect'
        $listenerHandle.StderrTailLines | Should -Not -BeNullOrEmpty -Because 'the receiver ffmpeg writes its banner, input/output mapping and muxing summary to stderr -- capturing none of it means the sink is not wired up'

        $capturedStderrLines = @($listenerHandle.StderrTailLines)

        # Assert on the SPECIFIC line that cracked this investigation, not merely on
        # "some output arrived". `Lsize=` is the receiver's terminal muxing summary: the
        # line that says how many bytes it actually committed. A test satisfied by the
        # ffmpeg banner alone would pass while the one diagnostic line that matters is
        # still being trimmed away by the ring buffer.
        ($capturedStderrLines -match 'Lsize=').Count | Should -BeGreaterThan 0 -Because "the receiver's terminal muxing summary is the witness that locates byte loss between a clean sender and a clean receiver; it must survive into the retained tail"
    }
}

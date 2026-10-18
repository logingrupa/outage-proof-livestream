# TestHelpers.psm1
# Shared Pester fixtures for Phase 1 (01-core-pusher) integration tests: a synthetic
# OBS-like growing-file writer, a local SRT listener receiver, byte-range equality,
# and a sample mpegts generator. Lets PUSH-01/PUSH-02/PUSH-03 tests run without OBS
# or a real relay (RESEARCH.md Validation Architecture Wave 0 Gaps).
#
# Wave 1 spike deviations baked in here (01-01-SUMMARY.md):
#   - SRT sender needs an explicit linger=<seconds> so the socket drains before
#     hard-close (relevant to callers of these fixtures that build their own sender).
#   - SRT listener needs an explicit 127.0.0.1 host, not an empty host segment
#     ("srt://:<port>?..." fails "Bad parameters" on this ffmpeg/libsrt build).
#
# Phase 3 (03-04): New-TestTunedPusherCopy, Start-ValidMpegtsGrowthWriter and
# Stop-ValidMpegtsGrowthWriter moved here from Integration.KillAndResume.Tests.ps1's
# local BeforeAll (they were duplicated-logic risks the moment a second integration
# file needed them, DRY) -- New-TestTunedPusherCopy now resolves the repo root/pusher
# source internally from $PSScriptRoot instead of requiring script-scoped variables
# from the caller's BeforeAll, and gained optional folder+glob/end-detection override
# params (-RecordingFilenameGlob, -ObsProcessName, -GrowthStallSustainedWindowSeconds,
# -GrowthStallDegradedWindowSeconds, -ObsLivenessOverrideLiteral) on top of the 03-03
# coordinated fix (regex-targets $recordingFolderPath/$recordingFilenameGlob/
# $obsLivenessOverride, not the removed $recordingFilePath). Also new here:
# Start-SecondValidMpegtsRecording (rotation fixture, Plan 05) and a pause-not-stop
# capability on Start-ValidMpegtsGrowthWriter (-PauseAfterSeconds/-PauseDurationSeconds)
# for asserting end-detection does not fire on a brief growth stall.
#
# Exports: New-SampleMpegtsFile, Start-SyntheticMpegtsWriter, Stop-SyntheticMpegtsWriter,
#          Start-SrtListener, Stop-SrtListener, Test-ByteRangeEquality,
#          Invoke-FfmpegSrtFailureCapture, New-TestTunedPusherCopy,
#          Start-ValidMpegtsGrowthWriter, Stop-ValidMpegtsGrowthWriter,
#          Start-SecondValidMpegtsRecording, New-StdinStallStandinFfmpeg,
#          New-FakePusherProcess

Set-StrictMode -Version Latest

$script:TransportStreamPacketSizeBytes = 188

function New-SampleMpegtsFile {
    <#
    .SYNOPSIS
    Generates a known-size synthetic .ts sample file via ffmpeg lavfi testsrc.
    #>
    param(
        [Parameter(Mandatory)] [string] $OutputPath,
        [int] $DurationSeconds = 3,
        [string] $VideoSize = '320x240',
        [int] $FrameRate = 25
    )

    $outputDirectory = Split-Path -Parent $OutputPath
    if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }

    $ffmpegArguments = @(
        '-y',
        '-f', 'lavfi', '-i', "testsrc=duration=$DurationSeconds`:size=$VideoSize`:rate=$FrameRate",
        '-c:v', 'libx264',
        '-f', 'mpegts', $OutputPath
    )

    $sampleProcess = Start-Process -FilePath 'ffmpeg' -ArgumentList $ffmpegArguments -WindowStyle Hidden -PassThru -Wait
    if ($sampleProcess.ExitCode -ne 0) {
        throw "New-SampleMpegtsFile: ffmpeg exited with code $($sampleProcess.ExitCode) generating '$OutputPath'"
    }
    if (-not (Test-Path -LiteralPath $OutputPath) -or (Get-Item -LiteralPath $OutputPath).Length -eq 0) {
        throw "New-SampleMpegtsFile: sample file '$OutputPath' was not created or is empty"
    }

    return $OutputPath
}

function Start-SyntheticMpegtsWriter {
    <#
    .SYNOPSIS
    Starts a background writer that appends 188-byte-multiple chunks to TargetFilePath
    on a bounded interval while holding the file handle open — simulates OBS's
    hold-file-open-while-writing behavior for tests, without needing a real OBS install.

    .OUTPUTS
    A handle object (Process, ScriptFilePath, LogFilePath, TargetFilePath) to pass to
    Stop-SyntheticMpegtsWriter.
    #>
    param(
        [Parameter(Mandatory)] [string] $TargetFilePath,
        [int] $IntervalMilliseconds = 250,
        [int] $ChunkPacketCount = 10,
        [int] $TotalDurationSeconds = 30
    )

    $targetDirectory = Split-Path -Parent $TargetFilePath
    if ($targetDirectory -and -not (Test-Path -LiteralPath $targetDirectory)) {
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    }

    $scratchDirectoryPath = Join-Path $env:TEMP ("gapless-srt-pusher-synthetic-writer-{0}" -f ([Guid]::NewGuid()))
    New-Item -ItemType Directory -Path $scratchDirectoryPath -Force | Out-Null
    $writerScriptFilePath = Join-Path $scratchDirectoryPath 'Write-SyntheticMpegtsChunks.ps1'
    $logFilePath = Join-Path $scratchDirectoryPath 'writer.log'

    # Self-contained script FILE (not an inline -Command string) run in a detached pwsh
    # process — matches the pattern proven in spike/Confirm-FileShareTail.ps1. Deliberately
    # keeps the write handle open across the whole loop, the concurrent-writer condition
    # PUSH-01's tests need to exercise.
    $writerScriptContent = @'
param(
    [Parameter(Mandatory)] [string] $TargetFilePath,
    [Parameter(Mandatory)] [int] $IntervalMilliseconds,
    [Parameter(Mandatory)] [int] $ChunkPacketCount,
    [Parameter(Mandatory)] [int] $PacketSizeBytes,
    [Parameter(Mandatory)] [int] $TotalDurationSeconds,
    [Parameter(Mandatory)] [string] $LogPath
)

$ErrorActionPreference = 'Stop'

$writerFileStream = [System.IO.FileStream]::new(
    $TargetFilePath,
    [System.IO.FileMode]::Create,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::ReadWrite
)
try {
    $chunkSizeBytes = $ChunkPacketCount * $PacketSizeBytes
    $chunkBuffer = New-Object byte[] $chunkSizeBytes
    $fillByteValue = 0x47   # MPEG-TS sync byte, cosmetic realism only
    for ($index = 0; $index -lt $chunkBuffer.Length; $index++) { $chunkBuffer[$index] = $fillByteValue }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $chunksWritten = 0
    while ($stopwatch.Elapsed.TotalSeconds -lt $TotalDurationSeconds) {
        $writerFileStream.Write($chunkBuffer, 0, $chunkBuffer.Length)
        $writerFileStream.Flush($true)
        $chunksWritten++
        Start-Sleep -Milliseconds $IntervalMilliseconds
    }
    $totalBytesWritten = $writerFileStream.Length
    "writer done: $chunksWritten chunks, $totalBytesWritten bytes total" | Out-File -FilePath $LogPath -Encoding utf8
}
finally {
    $writerFileStream.Dispose()
}
'@

    Set-Content -LiteralPath $writerScriptFilePath -Value $writerScriptContent -Encoding utf8

    $processArguments = @(
        '-NoProfile', '-NonInteractive', '-File', $writerScriptFilePath,
        '-TargetFilePath', $TargetFilePath,
        '-IntervalMilliseconds', $IntervalMilliseconds,
        '-ChunkPacketCount', $ChunkPacketCount,
        '-PacketSizeBytes', $script:TransportStreamPacketSizeBytes,
        '-TotalDurationSeconds', $TotalDurationSeconds,
        '-LogPath', $logFilePath
    )

    $writerProcess = Start-Process -FilePath 'pwsh' -ArgumentList $processArguments -WindowStyle Hidden -PassThru

    return [PSCustomObject]@{
        Process           = $writerProcess
        ScratchDirectory  = $scratchDirectoryPath
        ScriptFilePath    = $writerScriptFilePath
        LogFilePath       = $logFilePath
        TargetFilePath    = $TargetFilePath
    }
}

function Stop-SyntheticMpegtsWriter {
    <#
    .SYNOPSIS
    Stops a writer handle returned by Start-SyntheticMpegtsWriter and cleans up its
    scratch directory.
    #>
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Writer
    )

    if ($null -ne $Writer.Process -and -not $Writer.Process.HasExited) {
        try {
            $Writer.Process.Kill($true)
            $Writer.Process.WaitForExit(5000) | Out-Null
        } catch {
            # Process already exited between the check and the kill — not an error.
        }
    }

    if ($Writer.ScratchDirectory -and (Test-Path -LiteralPath $Writer.ScratchDirectory)) {
        Remove-Item -LiteralPath $Writer.ScratchDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Start-SrtListener {
    <#
    .SYNOPSIS
    Spawns a local ffmpeg SRT receiver (mode=listener) writing received bytes to disk,
    so byte-continuity is provable by file comparison (D-20). Binds explicitly to
    127.0.0.1 — an empty host segment ("srt://:<port>?...") fails "Bad parameters" on
    this ffmpeg/libsrt build (Wave 1 spike deviation, 01-01-SUMMARY.md).

    .OUTPUTS
    The receiver System.Diagnostics.Process, already started with async stderr/stdout
    draining (Pitfall 5 deadlock avoidance), carrying two added members: StderrTailLines
    (the retained receiver stderr) and ErrorSubscriptionId (unregistered by
    Stop-SrtListener). The Process itself is returned unchanged so every existing caller
    keeps working -- .HasExited, .WaitForExit(), .Id and `Stop-SrtListener -Process` are
    all untouched.

    .NOTES
    StderrTailLines exists because its absence cost a phase. This function used to call
    BeginErrorReadLine() with NO handler and no sink, which does not disable stderr --
    it actively drains it into the void. The RECEIVER's stderr is the only witness that
    can distinguish "the sender never emitted the tail" from "the sender emitted it and
    the transport dropped it": on the byte-losing runs the sender reported frame=783 /
    Lsize=348KiB while the receiver reported frame=721 / Lsize=318KiB, and that 30KiB
    difference is what finally located the loss in the SRT close rather than in
    Stop-FfmpegProcess, where it had been misattributed for a phase
    (.planning/debug/ffmpeg-tail-flush-on-stop.md). A test fixture that discards the
    evidence of the failure it exists to catch is not neutral -- it is a fixture that
    launders a real defect into "flakiness".

    Mirrors Start-FfmpegProcess's bounded synchronized ring buffer (T-02-BUF) rather
    than introducing a second stderr-retention pattern: the handler fires on a
    different thread than the caller that later reads the buffer, so the synchronized
    wrapper is required, and the ring trim keeps a chatty/looping ffmpeg from growing
    it without bound.
    #>
    param(
        [Parameter(Mandatory)] [int] $Port,
        [Parameter(Mandatory)] [string] $OutputPath,
        [int] $LatencyMicroseconds = 500000,
        [int] $TimeoutMicroseconds = 10000000,
        [int] $MaxStderrTailLines = 20,
        # Must mirror lib/FfmpegProcess.psm1's $script:DefaultSrtTransmissionType. This
        # fixture stands in for the relay VPS, and SRT REJECTS a file-mode caller against
        # a live-mode listener at handshake ("MessageAPI/StreamAPI collision"), so a
        # mismatch here does not quietly weaken the tests -- it fails every integration
        # test outright with an I/O error at connect. Kept as a parameter so a test can
        # deliberately pin 'live' to reproduce the discarded-in-flight-window defect.
        [ValidateSet('file', 'live')] [string] $TransmissionType = 'file'
    )

    $outputDirectory = Split-Path -Parent $OutputPath
    if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }

    $listenerUrl = "srt://127.0.0.1:$Port`?mode=listener&transtype=$TransmissionType&latency=$LatencyMicroseconds&timeout=$TimeoutMicroseconds"
    $listenerArguments = @(
        '-y',
        '-i', $listenerUrl,
        '-c', 'copy', $OutputPath
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'ffmpeg'
    foreach ($argumentValue in $listenerArguments) { $startInfo.ArgumentList.Add($argumentValue) }
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.UseShellExecute = $false

    $listenerProcess = [System.Diagnostics.Process]::new()
    $listenerProcess.StartInfo = $startInfo

    $stderrTailBuffer = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $errorSubscription = Register-ObjectEvent -InputObject $listenerProcess -EventName ErrorDataReceived -Action {
        if ($EventArgs.Data) {
            $null = $Event.MessageData.Buffer.Add($EventArgs.Data)
            while ($Event.MessageData.Buffer.Count -gt $Event.MessageData.MaxLines) {
                $Event.MessageData.Buffer.RemoveAt(0)
            }
        }
    } -MessageData ([PSCustomObject]@{ Buffer = $stderrTailBuffer; MaxLines = $MaxStderrTailLines })

    $listenerProcess.Start() | Out-Null
    $listenerProcess.BeginErrorReadLine()
    $listenerProcess.BeginOutputReadLine()

    Add-Member -InputObject $listenerProcess -MemberType NoteProperty -Name 'StderrTailLines' -Value $stderrTailBuffer
    Add-Member -InputObject $listenerProcess -MemberType NoteProperty -Name 'ErrorSubscriptionId' -Value $errorSubscription.Id

    return $listenerProcess
}

function Stop-SrtListener {
    <#
    .SYNOPSIS
    Stops an SRT listener process returned by Start-SrtListener, drains its outstanding
    async stderr, and unregisters the stderr event subscription.

    .NOTES
    The parameterless WaitForExit() is load-bearing, not defensive noise. WaitForExit(ms)
    returning $true only means the PROCESS is gone -- it explicitly does NOT guarantee
    the async ErrorDataReceived handlers have finished draining the pipe. Only the
    parameterless overload waits for that. Since the single most valuable line in the
    receiver's stderr is its LAST one (the terminal `Lsize=` muxing summary that says how
    many bytes it actually committed), skipping this drain would lose precisely the
    witness Start-SrtListener now exists to retain -- intermittently, which is the worst
    possible way to lose it. It is bounded here because the process is already confirmed
    exited before it is called.
    #>
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    try {
        if (-not $Process.HasExited) {
            try {
                $Process.Kill($true)
                $Process.WaitForExit(5000) | Out-Null
            } catch {
                # Process already exited between the check and the kill — not an error.
            }
        }
        # Flush any stderr still in flight before the subscription goes away.
        try { $Process.WaitForExit() } catch { }
    } finally {
        if ($Process.PSObject.Properties.Name -contains 'ErrorSubscriptionId' -and $Process.ErrorSubscriptionId) {
            Unregister-Event -SubscriptionId $Process.ErrorSubscriptionId -ErrorAction SilentlyContinue
        }
    }
}

function Test-DeliveredPrefixIntact {
    <#
    .SYNOPSIS
    Asserts the byte-continuity property that is actually TRUE and actually valuable
    across an ffmpeg -c copy hop: every byte the receiver got is a byte-exact prefix of
    the source (order preserved, nothing skipped, nothing reordered), AND essentially the
    whole expected range arrived -- short only by the trailing TS container-framing
    packets ffmpeg's muxer structurally does not re-emit.

    .NOTES
    Replaces a direct `Test-ByteRangeEquality -Length <old file's full final length>`,
    which was UNSATISFIABLE BY CONSTRUCTION at roughly a third of possible cut points and
    was consequently misread as flakiness / box load for an entire phase.

    Why the old assertion could not hold: the pusher genuinely feeds every byte of the old
    file into ffmpeg's stdin (pusher.ps1 will not log 'Rotation switch complete' until
    Length - Position < 188), but the ffmpeg on the far side re-frames the TS container.
    Feeding the EXACT same 357200-byte file through a pure local ffmpeg -c copy remux with
    the pusher, SRT and the network entirely absent produces 356824 bytes -- the identical
    shortfall the integration test reported -- while carrying an identical 783-packet
    elementary stream. So the missing 376 bytes are container framing, not content, and no
    correct pusher could ever make that assertion pass.

    Which cut points lose bytes is a function of wall-clock timing (the fixture's writer
    runs a timed loop, so it stops on a different chunk count run to run), which is exactly
    why the failure count wandered between 1 and 3 on an idle box with no code change.

    This function still fails loudly on real under-delivery: anything beyond the measured
    2-packet tolerance is a genuine byte-loss finding and throws, and a substantiality
    guard stops the check from passing vacuously on a trivially short range.

    .PARAMETER ExpectedDeliveredLength
    The source-file length the receiver was expected to have fully drained (e.g. the old
    file's final length at the moment its writer stopped).

    .PARAMETER MinimumComparedLengthBytes
    The compared range must be at least this large or the assertion is treated as vacuous
    and throws. Defaults to one full writer chunk (18800 bytes = 100 TS packets) -- a
    check that "passes" by comparing a trivial handful of bytes proves nothing.
    #>
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $ReceivedPath,
        [Parameter(Mandatory)] [long] $ExpectedDeliveredLength,
        [int] $ContainerFramingToleranceBytes = $script:MaximumContainerFramingTailBytes,
        [int] $MinimumComparedLengthBytes = 18800
    )

    $receivedLength = (Get-Item -LiteralPath $ReceivedPath).Length
    $shortfallBytes = $ExpectedDeliveredLength - $receivedLength

    if ($shortfallBytes -gt $ContainerFramingToleranceBytes) {
        throw "Test-DeliveredPrefixIntact: UNDER-DELIVERY -- received $receivedLength bytes but expected $ExpectedDeliveredLength ($shortfallBytes bytes short, tolerance is $ContainerFramingToleranceBytes = $($ContainerFramingToleranceBytes / $script:TransportStreamPacketSizeBytes) TS packets of container framing). This exceeds anything an ffmpeg -c copy re-frame can account for and is a genuine byte-loss finding. Source '$SourcePath', received '$ReceivedPath'."
    }

    if ($shortfallBytes -lt 0) {
        throw "Test-DeliveredPrefixIntact: received MORE bytes ($receivedLength) than the source range asserted about ($ExpectedDeliveredLength). The comparison is not meaningful -- the caller's ExpectedDeliveredLength is wrong, or content was duplicated. Source '$SourcePath', received '$ReceivedPath'."
    }

    if ($receivedLength -lt $MinimumComparedLengthBytes) {
        throw "Test-DeliveredPrefixIntact: VACUOUS CHECK -- only $receivedLength bytes were available to compare, below the $MinimumComparedLengthBytes-byte substantiality floor. Refusing to report byte-order continuity as proven on a trivial range. Source '$SourcePath', received '$ReceivedPath'."
    }

    # Every byte that DID arrive must be byte-exact and in order, from offset 0 -- this is
    # the actual D-04/D-13 property (never skip, never reorder). Test-ByteRangeEquality
    # throws on a short read, so this can no longer silently hash zero padding.
    return (Test-ByteRangeEquality -SourcePath $SourcePath -ReceivedPath $ReceivedPath -StartOffset 0 -Length $receivedLength)
}

function Invoke-FfmpegSrtFailureCapture {
    <#
    .SYNOPSIS
    Kills a local SRT listener mid-push and captures the real ffmpeg SRT-caller stderr
    tail from a genuine mid-push outage -- ground truth for RES-04's exit classifier
    (Assumption A2 / Open Question 1, 02-RESEARCH.md). Reuses New-SampleMpegtsFile,
    Start-SrtListener and Stop-SrtListener (DRY). Mirrors the stdin->SRT argument shape
    and the async-stderr-drain-before-feeding pattern from lib/FfmpegProcess.psm1's
    Build-FfmpegArguments/Start-FfmpegProcess (BeginErrorReadLine before any stdin write,
    matching D-17) without importing that production module, keeping this test-infra
    helper self-contained.

    .OUTPUTS
    PSCustomObject: StderrLines (string[], last MaxStderrTailLines lines) and ExitCode (int).

    .NOTES
    Empirically tuned (Wave 0 spike, 02-01): a short sample/push window kills the
    listener BEFORE ffmpeg finishes probing pipe:0 and opens the SRT output at all,
    producing a pre-connect "Connection to srt://... failed" message rather than a
    genuine mid-push failure. SampleDurationSeconds=20 / SustainedPushMilliseconds=6000
    reliably let ffmpeg reach "Output #0" (an actively streaming connection) before the
    listener dies, reproducing the real mid-push failure text: "Error submitting a
    packet to the muxer: I/O error" / "Task finished with error code: -5 (I/O error)".
    #>
    param(
        [int] $Port = (Get-Random -Minimum 20000 -Maximum 40000),
        [int] $SampleDurationSeconds = 20,
        [int] $ChunkPacketCount = 10,
        [int] $FeedIntervalMilliseconds = 100,
        [int] $SustainedPushMilliseconds = 6000,
        [int] $MaxStderrTailLines = 20,
        [int] $StdinWriteTimeoutMilliseconds = 5000,
        [int] $ExitWaitMilliseconds = 20000
    )

    $scratchDirectoryPath = Join-Path $env:TEMP ("gapless-srt-pusher-ffmpeg-failure-capture-{0}" -f ([Guid]::NewGuid()))
    New-Item -ItemType Directory -Path $scratchDirectoryPath -Force | Out-Null
    $sampleFilePath = Join-Path $scratchDirectoryPath 'sample.ts'
    $receivedFilePath = Join-Path $scratchDirectoryPath 'received.ts'

    $listenerProcess = $null
    $callerProcess = $null
    $errorSubscription = $null
    $stderrTailBuffer = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

    try {
        New-SampleMpegtsFile -OutputPath $sampleFilePath -DurationSeconds $SampleDurationSeconds | Out-Null
        $listenerProcess = Start-SrtListener -Port $Port -OutputPath $receivedFilePath

        # Explicit 127.0.0.1 host + linger= per the Wave 1 spike deviations documented at
        # the top of this module -- an empty host segment or missing linger behaves
        # differently on this ffmpeg/libsrt build than a genuine mid-push network death,
        # and would contaminate the captured fixture with an unrelated failure mode.
        # transtype=file mirrors Build-FfmpegArguments and MUST match Start-SrtListener's
        # mode -- SRT rejects a mode mismatch at handshake, which would replace this
        # fixture's genuine mid-push outage with a pre-connect failure and silently
        # contaminate the captured ground-truth stderr.
        $callerUrl = "srt://127.0.0.1:$Port`?mode=caller&transtype=file&latency=500000&pkt_size=1316&linger=4"
        $callerArguments = @(
            '-f', 'mpegts',
            '-i', 'pipe:0',
            '-c', 'copy',
            '-f', 'mpegts', $callerUrl
        )

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = 'ffmpeg'
        foreach ($argumentValue in $callerArguments) { $startInfo.ArgumentList.Add($argumentValue) }
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.UseShellExecute = $false

        $callerProcess = [System.Diagnostics.Process]::new()
        $callerProcess.StartInfo = $startInfo

        # Bounded ring buffer (T-02-CAPBUF): a chatty ffmpeg cannot grow this unboundedly --
        # same bound RES-04's production stderr-tail buffer will use.
        $errorSubscription = Register-ObjectEvent -InputObject $callerProcess -EventName ErrorDataReceived -Action {
            if ($EventArgs.Data) {
                $null = $Event.MessageData.Buffer.Add($EventArgs.Data)
                while ($Event.MessageData.Buffer.Count -gt $Event.MessageData.MaxLines) {
                    $Event.MessageData.Buffer.RemoveAt(0)
                }
            }
        } -MessageData ([PSCustomObject]@{ Buffer = $stderrTailBuffer; MaxLines = $MaxStderrTailLines })

        $callerProcess.Start() | Out-Null
        $callerProcess.BeginErrorReadLine()   # MUST be before any stdin write (mirrors D-17)

        $sampleBytes = [System.IO.File]::ReadAllBytes($sampleFilePath)
        $chunkSizeBytes = $ChunkPacketCount * $script:TransportStreamPacketSizeBytes
        $stdinStream = $callerProcess.StandardInput.BaseStream
        $listenerKilled = $false
        $pushStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        for ($offset = 0; $offset -lt $sampleBytes.Length; $offset += $chunkSizeBytes) {
            $length = [Math]::Min($chunkSizeBytes, $sampleBytes.Length - $offset)

            try {
                $writeTask = $stdinStream.WriteAsync($sampleBytes, $offset, $length)
                if (-not $writeTask.Wait($StdinWriteTimeoutMilliseconds)) {
                    break   # ffmpeg hung -- stop feeding, fall through to the exit-wait below
                }
            } catch {
                break   # pipe already closed -- ffmpeg already reacted to the killed listener
            }

            if (-not $listenerKilled -and $pushStopwatch.ElapsedMilliseconds -ge $SustainedPushMilliseconds) {
                Stop-SrtListener -Process $listenerProcess   # the mid-push outage
                $listenerKilled = $true
            }

            Start-Sleep -Milliseconds $FeedIntervalMilliseconds
        }

        if (-not $listenerKilled) {
            Stop-SrtListener -Process $listenerProcess
        }

        try { $callerProcess.StandardInput.Close() } catch { }
        if (-not $callerProcess.HasExited) {
            $callerProcess.WaitForExit($ExitWaitMilliseconds) | Out-Null
        }
        if (-not $callerProcess.HasExited) {
            $callerProcess.Kill($true)
            $callerProcess.WaitForExit(5000) | Out-Null
        }

        return [PSCustomObject]@{
            StderrLines = @($stderrTailBuffer)
            ExitCode    = $callerProcess.ExitCode
        }
    } finally {
        if ($errorSubscription) {
            Unregister-Event -SubscriptionId $errorSubscription.Id -ErrorAction SilentlyContinue
        }
        if ($callerProcess -and -not $callerProcess.HasExited) {
            try { $callerProcess.Kill($true) } catch { }
        }
        if ($listenerProcess -and -not $listenerProcess.HasExited) {
            Stop-SrtListener -Process $listenerProcess
        }
        if (Test-Path -LiteralPath $scratchDirectoryPath) {
            Remove-Item -LiteralPath $scratchDirectoryPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# An ffmpeg -c copy demux/remux hop does not re-emit the trailing TS container-framing
# packets when the input's cut point does not align with the muxer's output framing. This
# bound was MEASURED, not assumed: sweeping 61 consecutive 188-aligned cut points of the
# test sample through a pure local ffmpeg -c copy remux (no pusher, no SRT) lost 0 bytes at
# 42 of them, 188 bytes (1 packet) at 11, and 376 bytes (2 packets) at 8 -- never more than
# 2 packets, never negative, and always with an IDENTICAL elementary-stream packet count
# (783 video packets in and out), i.e. zero media content lost. See
# .planning/debug/rotation-byte-equality-blind-helper.md for the full measurements.
$script:MaximumContainerFramingTailBytes = 2 * $script:TransportStreamPacketSizeBytes   # 376

function Read-FileByteRange {
    <#
    .SYNOPSIS
    Reads exactly Length bytes from Path starting at StartOffset, LOOPING until the
    request is satisfied or the stream genuinely ends, and reports how many bytes were
    ACTUALLY read. Opened with FileShare.ReadWrite so a still-open/still-growing file
    can be read without a sharing violation (D-20).

    .NOTES
    The loop is the whole point. FileStream.Read is contractually allowed to return
    fewer bytes than requested and callers MUST honour its return value. A single
    unchecked Read leaves the buffer's tail as zeros on a short read -- which is
    indistinguishable, downstream, from a file whose content is genuinely wrong.

    .OUTPUTS
    PSCustomObject: Buffer (byte[], Length long, tail zero-filled on a short read),
    BytesRead (int, the ONLY trustworthy measure of what was really there), and
    StreamLength (long, the file's total length at read time).
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [long] $StartOffset,
        [Parameter(Mandatory)] [int] $Length
    )

    $fileStream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $fileStream.Seek($StartOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $buffer = New-Object byte[] $Length
        $totalBytesRead = 0
        while ($totalBytesRead -lt $Length) {
            $bytesRead = $fileStream.Read($buffer, $totalBytesRead, $Length - $totalBytesRead)
            if ($bytesRead -le 0) { break }   # genuine end of stream, not a short read
            $totalBytesRead += $bytesRead
        }
        return [PSCustomObject]@{
            Buffer       = $buffer
            BytesRead    = $totalBytesRead
            StreamLength = $fileStream.Length
        }
    } finally {
        $fileStream.Dispose()
    }
}

function Get-ByteRangeComparison {
    <#
    .SYNOPSIS
    Compares a byte range of two files and reports WHAT KIND of difference exists --
    "the received file is SHORTER than asked for" vs "both ranges are fully present but
    a byte differs" vs "identical" -- plus the exact offset of the first differing byte.

    .NOTES
    This exists because the boolean it replaces could not tell "missing" from
    "different", and those two findings have opposite consequences here. A received file
    that is shorter than the source range means the drain did not deliver everything --
    a product-relevant finding about byte loss. A received file of the correct length
    whose bytes differ means the content is wrong (or the comparison range itself is
    invalid, e.g. it crosses a point where the test fixture's own writer looped its
    sample and ffmpeg legitimately rewrote TS continuity counters). Reporting both as a
    bare $false made every failure this helper produced uninterpretable, and the
    difference was misread as "flakiness" for an entire phase.

    .OUTPUTS
    PSCustomObject: Status ('Equal' | 'LengthMismatch' | 'ContentMismatch'),
    RequestedLength, SourceBytesRead, ReceivedBytesRead, SourceStreamLength,
    ReceivedStreamLength, FirstDifferenceOffset (-1 when no differing byte exists
    within the overlapping range), ComparedLength, and Detail (a human-readable
    one-line summary carrying the measured numbers).
    #>
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $ReceivedPath,
        [Parameter(Mandatory)] [long] $StartOffset,
        [Parameter(Mandatory)] [long] $Length
    )

    $source = Read-FileByteRange -Path $SourcePath -StartOffset $StartOffset -Length $Length
    $received = Read-FileByteRange -Path $ReceivedPath -StartOffset $StartOffset -Length $Length

    # Only the overlap can be meaningfully compared -- past it, one buffer is zero padding
    # and any "difference" found there would be an artifact of the padding, not the data.
    $comparedLength = [Math]::Min($source.BytesRead, $received.BytesRead)
    $firstDifferenceOffset = -1
    for ($index = 0; $index -lt $comparedLength; $index++) {
        if ($source.Buffer[$index] -ne $received.Buffer[$index]) {
            $firstDifferenceOffset = $StartOffset + $index
            break
        }
    }

    $isShortRead = ($source.BytesRead -lt $Length) -or ($received.BytesRead -lt $Length)
    $status = if ($isShortRead) { 'LengthMismatch' } elseif ($firstDifferenceOffset -ge 0) { 'ContentMismatch' } else { 'Equal' }

    $detail = "requested $Length bytes from offset $StartOffset -- source read $($source.BytesRead) (file length $($source.StreamLength)), received read $($received.BytesRead) (file length $($received.StreamLength)), compared $comparedLength, first differing byte at $firstDifferenceOffset"

    return [PSCustomObject]@{
        Status                = $status
        RequestedLength       = $Length
        SourceBytesRead       = $source.BytesRead
        ReceivedBytesRead     = $received.BytesRead
        SourceStreamLength    = $source.StreamLength
        ReceivedStreamLength  = $received.StreamLength
        ComparedLength        = $comparedLength
        FirstDifferenceOffset = $firstDifferenceOffset
        Detail                = $detail
    }
}

function Test-ByteRangeEquality {
    <#
    .SYNOPSIS
    Asserts that a byte range of two files is identical. THROWS on a short read rather
    than silently hashing zero padding, and emits the measured numbers on any mismatch.

    .NOTES
    A short read is a throw, not a $false, because it means the question the caller
    asked cannot be answered: the requested range is not present in the file at all, so
    "are these bytes equal" has no truth value. Silently hashing the zero-padded tail --
    which is what this function used to do -- turns "you asked about bytes that were
    never delivered" into "byte order NOT preserved", a completely different and much
    scarier claim. Callers that legitimately expect a shorter file must pass a Length
    they can justify, not lean on a helper that quietly forgives them.
    #>
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $ReceivedPath,
        [Parameter(Mandatory)] [long] $StartOffset,
        [Parameter(Mandatory)] [long] $Length
    )

    $comparison = Get-ByteRangeComparison -SourcePath $SourcePath -ReceivedPath $ReceivedPath -StartOffset $StartOffset -Length $Length

    if ($comparison.Status -eq 'LengthMismatch') {
        throw "Test-ByteRangeEquality: SHORT READ, not a content difference -- $($comparison.Detail). Source '$SourcePath', received '$ReceivedPath'. The requested range is not fully present, so byte equality is unanswerable: fewer bytes were delivered than the caller asserted about."
    }

    if ($comparison.Status -eq 'ContentMismatch') {
        Write-Host "Test-ByteRangeEquality: CONTENT MISMATCH (both ranges fully present) -- $($comparison.Detail). Source '$SourcePath', received '$ReceivedPath'."
        return $false
    }

    return $true
}

function Set-TunedPusherVariable {
    <#
    .SYNOPSIS
    Rewrites exactly one top-of-script `$name = ...` assignment line in a pusher.ps1
    source string, and THROWS when no such line exists.

    The throw is the entire point. A plain -replace whose pattern matches nothing is a
    SILENT no-op: the tuned copy keeps whatever production value the variable already
    had, and the test then runs against production config while looking perfectly
    healthy. That is not hypothetical -- it is what actually happened here. This
    function never rewrote $relayHost at all, so every tuned pusher copy inherited the
    operator's real RELAY_HOST from the (gitignored) .env after Phase 4 UAT configured
    a live relay, pushed to that real relay instead of the loopback SRT listener the
    test had just started, looped on NetworkDeath forever, never reached end-detection,
    and never exited. Eight integration tests went red and were misfiled for a whole
    phase as "pre-existing real-ffmpeg/SRT failures worth their own debug session".
    They were a missing regex. Failing loudly on an unmatched rewrite makes that class
    of misdiagnosis impossible to repeat.
    #>
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $VariableName,
        [Parameter(Mandatory)] [string] $ValueLiteral
    )

    $assignmentPattern = "(?m)^\`$$VariableName\s*=.*$"
    if ($Source -notmatch $assignmentPattern) {
        throw "New-TestTunedPusherCopy: pusher.ps1 has no top-of-script '`$$VariableName = ...' line to rewrite. Refusing to return a tuned copy that silently keeps the production value -- that is how a test ends up asserting against production config."
    }

    return ($Source -replace $assignmentPattern, "`$$VariableName = $ValueLiteral")
}

function New-TestTunedPusherCopy {
    <#
    .SYNOPSIS
    Writes a scratch copy of pusher.ps1 into the repo root (so $PSScriptRoot still
    resolves lib/* correctly) with select top-of-script variables overridden for
    fast, deterministic tests. Caller must Remove-Item the returned path when done.

    -RelayHost and -ControlFilePath are NOT optional-by-omission: both default to a
    safe value and are rewritten unconditionally. Every caller starts its own local SRT
    listener on loopback, so a tuned copy must never inherit .env's real RELAY_HOST; and
    every caller runs against this repo's own root, so a tuned copy must never read the
    real state/control.json the operator's Start/Stop/Cut buttons write. Both leaks have
    already happened once each -- see Set-TunedPusherVariable's header for what the
    first one cost, and the -ControlFilePath note below for the second.

    Resolves the repo root / pusher source path internally from this module's own
    $PSScriptRoot (tests/, repo root is its parent) rather than requiring the
    caller's script-scoped $script:RepoRootPath/$script:PusherSourcePath -- moved
    here (Phase 3, 03-04) from Integration.KillAndResume.Tests.ps1's local BeforeAll
    so a second integration file (Plan 05) can reuse it without duplicating logic.

    Phase 3 (03-03) folder+glob refactor: pusher.ps1 no longer has a single
    $recordingFilePath -- it follows a folder + filename glob (D-01). Given a
    single -RecordingFilePath, this derives the parent folder + exact basename
    (unless -RecordingFilenameGlob is supplied) so the tuned copy tails exactly
    that one file, and pins an OBS-liveness override (default "always alive") so
    the two-signal end-of-service gate (D-07) never self-terminates a
    byte-continuity/hard-kill/outage resume test mid-run. Pass
    -ObsLivenessOverrideLiteral '{ $false }' to force "OBS is gone" deterministically
    for end-detection tests (Plan 05).

    The new end-detection knobs (-ObsProcessName, -GrowthStallSustainedWindowSeconds,
    -GrowthStallDegradedWindowSeconds) are opt-in: when not supplied, the pusher's own
    production default for that variable is left in place (no regex-replace emitted),
    so existing callers behave exactly as before.
    #>
    param(
        [Parameter(Mandatory)] [string] $RecordingFilePath,
        [Parameter(Mandatory)] [int] $RelayPort,
        [Parameter(Mandatory)] [string] $StateFilePath,
        [string] $RelayHost = '127.0.0.1',
        [double] $TargetLowSeconds = 1,
        [double] $TargetHighSeconds = 2,
        [int] $PollIntervalMilliseconds = 150,
        [string] $RecordingFilenameGlob,
        [string] $ObsProcessName,
        [double] $GrowthStallSustainedWindowSeconds,
        [double] $GrowthStallDegradedWindowSeconds,
        [double] $CatchUpMultiplier,
        # Task 2 (CHUR-01, 15-01): opt-in override for the EWMA record-rate estimator's
        # time constant (production default 30.0s, GROWTH_RATE_SMOOTHING_SECONDS). A
        # short-lived test's pre-Draining streaming phase (a handful of seconds) is far
        # shorter than a 30s time constant, so growthRateWindow.SmoothedBytesPerSecond
        # -- and therefore the frozen last-known-good record rate a ceiling-respecting
        # Draining now depends on -- never converges away from whatever noisy value the
        # first couple of ticks happened to seed; alpha = 1-exp(-dt/tau) with tau=30s
        # and a ~150ms poll interval barely nudges it (alpha ~0.005/tick). A test that
        # needs a DETERMINISTIC ceiling within a few seconds of real elapsed time must
        # pin a short tau so the estimate genuinely converges within the test's own
        # lifetime.
        [double] $GrowthRateSmoothingSeconds,
        [double] $SessionResumeStaleAfterSeconds,
        # START-STALE-01 (260809-ow9): lets a test pin a short, explicit staleness
        # window for the initial-file-pick guard so the stale/fresh boundary is
        # deterministic without a real five-minute wait or a dependency on the
        # ambient repo .env's RECORDING_START_STALE_AFTER_SECONDS (or the 300s code
        # default). Same opt-in shape as -SessionResumeStaleAfterSeconds above --
        # deliberately a separate knob, since it tunes a different guard.
        [double] $RecordingStartStaleAfterSeconds,
        [double] $SrtStallToleranceSeconds,
        [double] $EndOfServiceReconnectMaxDurationSeconds,
        [int] $EndOfServiceReconnectMaxAttempts,
        [int] $BackoffBaseMilliseconds,
        [int] $BackoffCeilingMilliseconds,
        [int] $WatchdogTimeoutMilliseconds,
        [string] $FfmpegPath,
        # Defaults to a scratch path that DOES NOT EXIST, and is rewritten
        # unconditionally -- exactly like -RelayHost, and for exactly the same reason.
        # The tuned copy lives in the repo root, so an unrewritten $controlFilePath
        # resolves to the REAL state/control.json this machine's supervisor uses: the
        # test would then read the operator's live control flag and could "pass" (or
        # fail) for a reason it never arranged. A non-existent path is the correct
        # default rather than merely a safe one -- a missing flag means the operator has
        # said nothing, which is precisely the state every test that is not about
        # stopping wants to be in.
        [string] $ControlFilePath = (Join-Path ([System.IO.Path]::GetTempPath()) ("pusher-test-control-{0}.json" -f ([Guid]::NewGuid()))),
        [string] $ObsLivenessOverrideLiteral = '{ $true }',
        # Fourth instance of the leak class this helper's header/Set-TunedPusherVariable's
        # own header document (CHUR-01, 15-01 Task 2): DIAL-01's live-tunable repoll
        # (pusher.ps1's hot loop) reads CatchUpMultiplier/SendCeilingBytesPerSecond back
        # from $envPath ('.env' beside the running script) roughly once a second. The
        # tuned copy lives in the repo root, so an unrewritten $envPath resolves to the
        # REAL, gitignored .env this machine's operator maintains -- silently overwriting
        # -CatchUpMultiplier/whatever absolute ceiling a test just pinned with the
        # operator's live production dials within the first second of every run. This was
        # invisible for as long as nothing downstream of these two dials was pacing-
        # sensitive during a short test; Task 2 (Draining now honors the SAME ceiling
        # dials as live) made it visible: Scenario 3 silently read the operator's live
        # SEND_CEILING_BYTES_PER_SECOND instead of the test's own -CatchUpMultiplier 0.5.
        # A scratch path that DOES NOT EXIST is the correct default -- Read-LiveTunableOverrides'
        # own contract already treats a missing file as "no override signal" (both
        # properties $null), which safely keeps the tuned copy's pinned values.
        [string] $EnvFilePath = (Join-Path ([System.IO.Path]::GetTempPath()) ("pusher-test-env-{0}.env" -f ([Guid]::NewGuid()))),
        # Fifth instance of the leak class: pusher.ps1 names its per-install Pusher mutex
        # from $pusherSingleInstanceScopeRoot (default: its own directory). The tuned copy
        # lives in the repo root, so an unrewritten scope would take the PRODUCTION Pusher
        # mutex whenever the suite runs from the live install, and the live supervisor's
        # orphan probe would then refuse to launch its pusher. Always rewritten to a unique
        # path that never needs to exist (the mutex name is only a hash of it).
        [string] $SingleInstanceScopeRoot = (Join-Path ([System.IO.Path]::GetTempPath()) ("pusher-test-scope-{0}" -f ([Guid]::NewGuid())))
    )

    $repoRootPathForCopy = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $pusherSourcePathForCopy = Join-Path $repoRootPathForCopy 'pusher.ps1'

    $recordingFolderForCopy = Split-Path -Parent $RecordingFilePath
    $recordingGlobForCopy = if ($PSBoundParameters.ContainsKey('RecordingFilenameGlob')) { $RecordingFilenameGlob } else { Split-Path -Leaf $RecordingFilePath }

    $pusherSource = Get-Content -LiteralPath $pusherSourcePathForCopy -Raw
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'recordingFolderPath' -ValueLiteral "'$recordingFolderForCopy'"
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'recordingFilenameGlob' -ValueLiteral "'$recordingGlobForCopy'"
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'obsLivenessOverride' -ValueLiteral $ObsLivenessOverrideLiteral
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'relayHost' -ValueLiteral "'$RelayHost'"
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'relayPort' -ValueLiteral $RelayPort
    # Third instance of the leak class this helper's header documents: every caller
    # starts a loopback SRT listener, so a tuned copy must never inherit the operator's
    # real RELAY_PROTOCOL (the 2026-07-26 escape path sets 'tcp' in the live .env, which
    # sent every tuned pusher to tcp://<srt-listener> and turned 14 integration tests
    # red). The transport knobs below are pinned to the SRT-listener defaults for the
    # same reason -- a live .env tuning SRT_MAXBW/SEND_CEILING/Tier-1 options must not
    # silently re-shape what a pacing or byte-continuity test measures.
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'relayProtocol' -ValueLiteral "'srt'"
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'absoluteSendCeilingBytesPerSecond' -ValueLiteral 0
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'srtMaxBandwidthBytesPerSecond' -ValueLiteral 0
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'srtSendBufferBytes' -ValueLiteral 0
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'srtFlightFlagSizeBytes' -ValueLiteral 0
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'srtLossMaxTtl' -ValueLiteral 0
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'srtNakReport' -ValueLiteral "''"
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'stateFilePath' -ValueLiteral "'$StateFilePath'"
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'targetLowSeconds' -ValueLiteral $TargetLowSeconds
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'targetHighSeconds' -ValueLiteral $TargetHighSeconds
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'pollIntervalMilliseconds' -ValueLiteral $PollIntervalMilliseconds

    if ($PSBoundParameters.ContainsKey('ObsProcessName')) {
        $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'obsProcessName' -ValueLiteral "'$ObsProcessName'"
    }
    if ($PSBoundParameters.ContainsKey('GrowthStallSustainedWindowSeconds')) {
        $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'growthStallSustainedWindowSeconds' -ValueLiteral $GrowthStallSustainedWindowSeconds
    }
    if ($PSBoundParameters.ContainsKey('GrowthStallDegradedWindowSeconds')) {
        $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'growthStallDegradedWindowSeconds' -ValueLiteral $GrowthStallDegradedWindowSeconds
    }
    if ($PSBoundParameters.ContainsKey('CatchUpMultiplier')) {
        $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'catchUpMultiplier' -ValueLiteral $CatchUpMultiplier
    }
    if ($PSBoundParameters.ContainsKey('GrowthRateSmoothingSeconds')) {
        # Task 2 (CHUR-01, 15-01) -- see -GrowthRateSmoothingSeconds' own parameter
        # comment above for why a short-lived test needs this pinned.
        $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'growthRateSmoothingSeconds' -ValueLiteral $GrowthRateSmoothingSeconds
    }
    if ($PSBoundParameters.ContainsKey('SessionResumeStaleAfterSeconds')) {
        # SESS-01 (05.1-02): lets a test pin a short, explicit staleness window instead of
        # depending on whatever SESSION_RESUME_STALE_AFTER_SECONDS the ambient repo .env
        # (or the 1800s code default) happens to have, so the stale-vs-same-session
        # boundary is deterministic without a real 13h/30min wait.
        $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'sessionResumeStaleAfterSeconds' -ValueLiteral $SessionResumeStaleAfterSeconds
    }
    if ($PSBoundParameters.ContainsKey('RecordingStartStaleAfterSeconds')) {
        # START-STALE-01 (260809-ow9) -- see -RecordingStartStaleAfterSeconds' own
        # parameter comment above for why a test needs this pinned.
        $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'recordingStartStaleAfterSeconds' -ValueLiteral $RecordingStartStaleAfterSeconds
    }
    if ($PSBoundParameters.ContainsKey('SrtStallToleranceSeconds')) {
        # Front A (260718-j58/Task 2): lets a test pin a tiny stall-tolerance ceiling so a
        # sustained-stall-past-tolerance escalation is deterministic and fast, instead of
        # waiting out the 30s production default.
        $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'srtStallToleranceSeconds' -ValueLiteral $SrtStallToleranceSeconds
    }
    if ($PSBoundParameters.ContainsKey('EndOfServiceReconnectMaxDurationSeconds')) {
        # Front C (260718-j58/Task 3/Task 4): lets a test pin a tiny end-of-service
        # reconnect give-up bound so the persistently-down-relay drain scenario gives up
        # deterministically and fast, instead of waiting out the 900s production default.
        $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'endOfServiceReconnectMaxDurationSeconds' -ValueLiteral $EndOfServiceReconnectMaxDurationSeconds
    }
    if ($PSBoundParameters.ContainsKey('EndOfServiceReconnectMaxAttempts')) {
        $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'endOfServiceReconnectMaxAttempts' -ValueLiteral $EndOfServiceReconnectMaxAttempts
    }
    if ($PSBoundParameters.ContainsKey('BackoffBaseMilliseconds')) {
        # Task 4: pins a small backoff base/ceiling so the relay-drop-during-drain
        # reconnect scenario runs fast and deterministically.
        $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'backoffBaseMilliseconds' -ValueLiteral $BackoffBaseMilliseconds
    }
    if ($PSBoundParameters.ContainsKey('BackoffCeilingMilliseconds')) {
        $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'backoffCeilingMilliseconds' -ValueLiteral $BackoffCeilingMilliseconds
    }
    if ($PSBoundParameters.ContainsKey('WatchdogTimeoutMilliseconds')) {
        # Front A (260718-j58/Task 2): a short per-poll stdin-write timeout makes the
        # backpressure-hold and tolerance-exceeded-escalation scenarios fast and
        # deterministic instead of waiting out the 5000ms production default on every poll.
        $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'watchdogTimeoutMilliseconds' -ValueLiteral $WatchdogTimeoutMilliseconds
    }
    if ($PSBoundParameters.ContainsKey('FfmpegPath')) {
        # Lets a test point the pusher at a stand-in "ffmpeg" (e.g. a wrapper batch file
        # that ignores its ffmpeg-shaped argv and runs a small pwsh stand-in script) to
        # deterministically drive stdin stall/backpressure scenarios without depending on
        # real SRT bond congestion (Front A, 260718-j58/Task 2).
        $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'ffmpegPath' -ValueLiteral "'$FfmpegPath'"
    }
    # ALWAYS rewritten, never opt-in -- see the -ControlFilePath parameter's note and
    # Set-TunedPusherVariable's header. This is the $relayHost leak's twin, and it was
    # not hypothetical either: leaving it opt-in made eight integration tests fail the
    # moment pusher.ps1 started reading the flag, because this repo's REAL
    # state/control.json still said {"desired":"stopped"} from an operator smoke test.
    # Every tuned copy that had not opted in read that as an explicit operator stop and
    # drained and exited within a tick -- "pause not stop" saw the pusher exit, "clean
    # finish" drained 112800 of 376000 bytes, and rotation was never detected because
    # the pusher was already gone.
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'controlFilePath' -ValueLiteral "'$ControlFilePath'"
    # ALWAYS rewritten, never opt-in -- see -EnvFilePath's own parameter comment above.
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'envPath' -ValueLiteral "'$EnvFilePath'"
    # ALWAYS rewritten, never opt-in -- see -SingleInstanceScopeRoot's own parameter comment above.
    $pusherSource = Set-TunedPusherVariable -Source $pusherSource -VariableName 'pusherSingleInstanceScopeRoot' -ValueLiteral "'$SingleInstanceScopeRoot'"

    $testPusherPath = Join-Path $repoRootPathForCopy (".pusher.integrationtest.{0}.ps1" -f ([Guid]::NewGuid()))
    Set-Content -LiteralPath $testPusherPath -Value $pusherSource -Encoding utf8
    return $testPusherPath
}

function Start-ValidMpegtsGrowthWriter {
    <#
    .SYNOPSIS
    Simulates a growing OBS recording with REAL decodable MPEG-TS content (not
    just aligned filler bytes): replays 188-aligned slices of SamplePath into
    TargetFilePath on a bounded interval while holding the write handle open,
    looping back to the start of the sample if it runs out before
    TotalDurationSeconds elapses. This lets the sender ffmpeg in the pusher
    actually find a PAT/PMT and produce real SRT output, unlike
    Start-SyntheticMpegtsWriter's 0x47-fill content.

    Moved here from Integration.KillAndResume.Tests.ps1 (Phase 3, 03-04) so a
    second integration file (Plan 05) can reuse it without duplicating logic.

    .PARAMETER PauseAfterSeconds
    Optional pause-not-stop capability (D-07/ROT-02 fixture, 03-04 Task 2): once
    this many elapsed seconds have passed, the writer stops appending/flushing
    bytes for -PauseDurationSeconds while keeping its FileStream handle OPEN and
    the writer process alive (never Dispose/exit during the pause) -- proving a
    brief growth stall does not itself terminate the writer, so a test can assert
    the pusher does NOT declare end-of-service during a brief stall while OBS
    liveness is forced true. Default 0 disables pausing entirely (existing callers
    are unaffected).

    .PARAMETER PauseDurationSeconds
    How long the pause (no writes, handle stays open) lasts. Ignored when
    -PauseAfterSeconds is 0.
    #>
    param(
        [Parameter(Mandatory)] [string] $SamplePath,
        [Parameter(Mandatory)] [string] $TargetFilePath,
        [int] $IntervalMilliseconds = 300,
        [int] $ChunkSizeBytes = 18800,   # 100 * 188
        [int] $TotalDurationSeconds = 30,
        [double] $PauseAfterSeconds = 0,
        [double] $PauseDurationSeconds = 0
    )

    $targetDirectory = Split-Path -Parent $TargetFilePath
    if ($targetDirectory -and -not (Test-Path -LiteralPath $targetDirectory)) {
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    }

    $scratchDirectoryPath = Join-Path $env:TEMP ("gapless-srt-pusher-valid-writer-{0}" -f ([Guid]::NewGuid()))
    New-Item -ItemType Directory -Path $scratchDirectoryPath -Force | Out-Null
    $writerScriptFilePath = Join-Path $scratchDirectoryPath 'Write-ValidMpegtsGrowth.ps1'

    $writerScriptContent = @'
param(
    [Parameter(Mandatory)] [string] $SamplePath,
    [Parameter(Mandatory)] [string] $TargetFilePath,
    [Parameter(Mandatory)] [int] $IntervalMilliseconds,
    [Parameter(Mandatory)] [int] $ChunkSizeBytes,
    [Parameter(Mandatory)] [int] $TotalDurationSeconds,
    [double] $PauseAfterSeconds = 0,
    [double] $PauseDurationSeconds = 0
)
$ErrorActionPreference = 'Stop'

$sourceStream = [System.IO.FileStream]::new($SamplePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
$targetStream = [System.IO.FileStream]::new($TargetFilePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
try {
    $buffer = New-Object byte[] $ChunkSizeBytes
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TotalDurationSeconds) {
        $elapsedSeconds = $stopwatch.Elapsed.TotalSeconds
        $withinPauseWindow = ($PauseAfterSeconds -gt 0) -and ($elapsedSeconds -ge $PauseAfterSeconds) -and ($elapsedSeconds -lt ($PauseAfterSeconds + $PauseDurationSeconds))
        if ($withinPauseWindow) {
            # Pause-not-stop (D-07/ROT-02 fixture): skip the write/flush entirely --
            # the FileStream handle stays open and this process stays alive, only
            # the file's length/LastWriteTime stop advancing for the pause window.
            Start-Sleep -Milliseconds $IntervalMilliseconds
            continue
        }
        $bytesRead = $sourceStream.Read($buffer, 0, $buffer.Length)
        if ($bytesRead -le 0) {
            $sourceStream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
            continue
        }
        $targetStream.Write($buffer, 0, $bytesRead)
        $targetStream.Flush($true)
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
        '-TotalDurationSeconds', $TotalDurationSeconds,
        '-PauseAfterSeconds', $PauseAfterSeconds,
        '-PauseDurationSeconds', $PauseDurationSeconds
    )
    $writerProcess = Start-Process -FilePath 'pwsh' -ArgumentList $processArguments -WindowStyle Hidden -PassThru

    return [PSCustomObject]@{ Process = $writerProcess; ScratchDirectory = $scratchDirectoryPath }
}

function Stop-ValidMpegtsGrowthWriter {
    <#
    .SYNOPSIS
    Stops a writer handle returned by Start-ValidMpegtsGrowthWriter (or
    Start-SecondValidMpegtsRecording, same handle shape) and cleans up its
    scratch directory. Moved here from Integration.KillAndResume.Tests.ps1
    (Phase 3, 03-04).
    #>
    param([Parameter(Mandatory)] [PSCustomObject] $Writer)

    if ($null -ne $Writer.Process -and -not $Writer.Process.HasExited) {
        try {
            $Writer.Process.Kill($true)
            $Writer.Process.WaitForExit(5000) | Out-Null
        } catch {
            # Process already exited between the check and the kill -- not an error.
        }
    }
    if ($Writer.ScratchDirectory -and (Test-Path -LiteralPath $Writer.ScratchDirectory)) {
        Remove-Item -LiteralPath $Writer.ScratchDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Start-SecondValidMpegtsRecording {
    <#
    .SYNOPSIS
    Thin wrapper (DRY) around Start-ValidMpegtsGrowthWriter that starts a SECOND
    valid-MPEG-TS growth writer at a distinct rotated TargetFilePath (e.g.
    'recording-002.ts' beside an already-running 'recording-001.ts'), simulating
    OBS starting a new recording while the first is still open/closing. Reuses the
    exact same real-sample-replay writer script -- no duplicated writer logic.

    Because the underlying writer opens TargetFilePath with FileMode.Create at the
    moment this is called, its LastWriteTime is naturally newer than any
    pre-existing first-recording file as long as this is called AFTER the first
    recording is already underway (D-02: rotation detection is a positive-signal,
    timing-dependent check on Get-NewestMatchingRecordingFile's
    Sort-Object LastWriteTime -Descending) -- callers do not need to manually touch
    file timestamps.

    Returns the same handle shape as Start-ValidMpegtsGrowthWriter (Process,
    ScratchDirectory) -- stop it with the existing Stop-ValidMpegtsGrowthWriter
    (no separate stop function needed, the shape matches exactly).
    #>
    param(
        [Parameter(Mandatory)] [string] $SamplePath,
        [Parameter(Mandatory)] [string] $TargetFilePath,
        [int] $IntervalMilliseconds = 300,
        [int] $ChunkSizeBytes = 18800,
        [int] $TotalDurationSeconds = 30,
        [double] $PauseAfterSeconds = 0,
        [double] $PauseDurationSeconds = 0
    )

    return Start-ValidMpegtsGrowthWriter -SamplePath $SamplePath -TargetFilePath $TargetFilePath `
        -IntervalMilliseconds $IntervalMilliseconds -ChunkSizeBytes $ChunkSizeBytes `
        -TotalDurationSeconds $TotalDurationSeconds -PauseAfterSeconds $PauseAfterSeconds `
        -PauseDurationSeconds $PauseDurationSeconds
}

function New-StdinStallStandinFfmpeg {
    <#
    .SYNOPSIS
    Writes a small pwsh stand-in "ffmpeg" plus a .cmd wrapper that deterministically
    drives Write-FfmpegStdin stall/recovery scenarios (Front A, 260718-j58/Task 2)
    without depending on real SRT bond congestion, which proved too fragile to induce
    reliably against this ffmpeg/libsrt build in isolation. Build-FfmpegArguments still
    produces a normal ffmpeg-shaped argv (-f mpegts -i pipe:0 -c copy -f mpegts <srt
    url>) -- the .cmd wrapper deliberately IGNORES all of it (batch scripts do not
    forward argv unless told to) and always runs this fixed stand-in script instead, so
    no real ffmpeg/SRT chain is ever involved in these tests.

    The stand-in holds its own stdin UNDRAINED for InitialStallSeconds (or forever, when
    its attempt number is listed in StallForeverOnAttempts) -- since nothing reads the
    redirected pipe, the OS pipe buffer genuinely fills and a large-enough
    Write-FfmpegStdin call genuinely times out exactly like a real backed-up/hung peer,
    with no fabrication inside FfmpegProcess.psm1 itself. AttemptCounterFilePath lets a
    reconnect scenario behave differently on the SECOND launch (e.g. attempt 1 never
    drains -- simulating a permanently stuck peer -- attempt 2 drains immediately, so a
    test can assert the pusher recovers cleanly after its one bounded reconnect). Once
    past its stall window, the stand-in drains stdin continuously, APPENDING to
    ReceivedFilePath (OpenOrCreate + seek-to-end) so bytes delivered across a reconnect
    accumulate in one file for a byte-continuity check.

    .OUTPUTS
    PSCustomObject: WrapperPath (pass this as New-TestTunedPusherCopy's -FfmpegPath),
    StandinScriptPath, ReceivedFilePath.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $ScratchDirectory,
        [Parameter(Mandatory)] [string] $ReceivedFilePath,
        [double] $InitialStallSeconds = 0,
        [string] $AttemptCounterFilePath,
        [int[]] $StallForeverOnAttempts = @()
    )

    if (-not (Test-Path -LiteralPath $ScratchDirectory)) {
        New-Item -ItemType Directory -Path $ScratchDirectory -Force | Out-Null
    }

    $standinScriptPath = Join-Path $ScratchDirectory ("standin-{0}.ps1" -f ([Guid]::NewGuid()))
    $standinScriptContent = @'
param(
    [Parameter(Mandatory)] [string] $ReceivedFilePath,
    [double] $InitialStallSeconds = 0,
    [string] $AttemptCounterFilePath = $null,
    [int[]] $StallForeverOnAttempts = @()
)
$ErrorActionPreference = 'Stop'

$attemptNumber = 1
if ($AttemptCounterFilePath) {
    $previousAttempt = 0
    if (Test-Path -LiteralPath $AttemptCounterFilePath) {
        $previousAttempt = [int](Get-Content -LiteralPath $AttemptCounterFilePath -Raw)
    }
    $attemptNumber = $previousAttempt + 1
    Set-Content -LiteralPath $AttemptCounterFilePath -Value $attemptNumber
}

$outStream = [System.IO.File]::Open($ReceivedFilePath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
try {
    $outStream.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
    if ($InitialStallSeconds -gt 0) { Start-Sleep -Seconds $InitialStallSeconds }
    if ($StallForeverOnAttempts -contains $attemptNumber) {
        # A permanently unresponsive peer: the process stays ALIVE (never exits) but
        # never reads stdin again -- every subsequent write stays stalled until the
        # caller's bounded tolerance gives up and reconnects to a fresh instance.
        Start-Sleep -Seconds 3600
        return
    }
    $inStream = [Console]::OpenStandardInput()
    $buffer = New-Object byte[] 65536
    while (($bytesRead = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $outStream.Write($buffer, 0, $bytesRead)
        $outStream.Flush()
    }
} finally {
    $outStream.Dispose()
}
'@
    Set-Content -LiteralPath $standinScriptPath -Value $standinScriptContent -Encoding utf8

    # Space-separated integers, NOT PowerShell's '@(1,2)' array-literal syntax -- this
    # command line is invoked via cmd.exe -> pwsh -File, so PowerShell's ARGUMENT
    # BINDER (not the language parser) receives these tokens; it happily binds several
    # space-separated simple values to an [int[]] parameter, but "@(1)" would arrive as
    # the literal, unparsed string "@(1)" and fail to coerce to [int[]] -- silently
    # crashing the stand-in at startup with a parameter-binding error (measured: the
    # process exited within ~100ms every time, masquerading as a permanently-dead peer
    # for EVERY attempt, not just the intended one).
    $stallForeverArgument = if ($StallForeverOnAttempts.Count -gt 0) { "-StallForeverOnAttempts $([string]::Join(' ', $StallForeverOnAttempts))" } else { '' }
    $attemptCounterArgument = if ($AttemptCounterFilePath) { "-AttemptCounterFilePath `"$AttemptCounterFilePath`"" } else { '' }
    $wrapperPath = Join-Path $ScratchDirectory ("standin-{0}.cmd" -f ([Guid]::NewGuid()))
    # A .cmd wrapper deliberately IGNORES its own argv (the ffmpeg-shaped args
    # Start-FfmpegProcess always appends) -- Windows' CreateProcess launches a .bat/.cmd
    # target via cmd.exe even with UseShellExecute=false, so this is directly usable as
    # -FfmpegPath without any real ffmpeg binary involved.
    $wrapperContent = "@echo off`r`npwsh -NoProfile -NonInteractive -File `"$standinScriptPath`" -ReceivedFilePath `"$ReceivedFilePath`" -InitialStallSeconds $InitialStallSeconds $attemptCounterArgument $stallForeverArgument`r`n"
    Set-Content -LiteralPath $wrapperPath -Value $wrapperContent -Encoding ascii

    return [PSCustomObject]@{
        WrapperPath       = $wrapperPath
        StandinScriptPath = $standinScriptPath
        ReceivedFilePath  = $ReceivedFilePath
    }
}

function New-FakePusherProcess {
    <#
    .SYNOPSIS
    A duck-typed stand-in for the System.Diagnostics.Process that
    Start-PusherProcess (supervisor.ps1) returns, so Invoke-Supervisor tests can
    mock the spawn and still run the REAL Wait-PusherProcessExit loop (261018).

    .DESCRIPTION
    Exposes only what Wait-PusherProcessExit touches: WaitForExit (timed and
    parameterless), ExitCode and Dispose. Kill exists purely so a test can assert
    it was NEVER called. AlivePollCount is how many timed waits report "still
    running" before the fake exits. MaximumTimedWaitCount turns a wait loop that
    never ends into a failing test instead of a hung Pester run.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [int] $ExitCode,
        [int] $AlivePollCount = 0,
        [int] $MaximumTimedWaitCount = 10000
    )

    $fakePusherProcess = [pscustomobject]@{
        ExitCode                      = $ExitCode
        RemainingAlivePollCount       = $AlivePollCount
        MaximumTimedWaitCount         = $MaximumTimedWaitCount
        TimedWaitTimeoutsMilliseconds = [System.Collections.Generic.List[int]]::new()
        HasExited                     = $false
        FinalWaitCount                = 0
        DisposeCount                  = 0
        KillCount                     = 0
    }
    $fakePusherProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
        if ($args.Count -eq 0) {
            $this.FinalWaitCount++
            return
        }
        if ($this.TimedWaitTimeoutsMilliseconds.Count -ge $this.MaximumTimedWaitCount) {
            throw 'fake pusher polled too many times -- the wait loop never ended'
        }
        $this.TimedWaitTimeoutsMilliseconds.Add([int] $args[0])
        if ($this.RemainingAlivePollCount -gt 0) {
            $this.RemainingAlivePollCount--
            return $false
        }
        $this.HasExited = $true
        return $true
    }
    $fakePusherProcess | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.DisposeCount++ }
    $fakePusherProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value { $this.KillCount++ }
    return $fakePusherProcess
}

Export-ModuleMember -Function New-SampleMpegtsFile, Start-SyntheticMpegtsWriter, Stop-SyntheticMpegtsWriter, Start-SrtListener, Stop-SrtListener, Read-FileByteRange, Get-ByteRangeComparison, Test-ByteRangeEquality, Test-DeliveredPrefixIntact, Invoke-FfmpegSrtFailureCapture, New-TestTunedPusherCopy, Start-ValidMpegtsGrowthWriter, Stop-ValidMpegtsGrowthWriter, Start-SecondValidMpegtsRecording, New-StdinStallStandinFfmpeg, New-FakePusherProcess

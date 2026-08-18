# PusherStats.Tests.ps1
# End-to-end proof for 05-06 (the D-15 rework's other half): pusher.ps1 actually
# publishes state/stats.json across the process boundary, at the payload/cadence/
# outage-survival contract lib/StatsStore.psm1 (05-02) fixed. Driven against the REAL
# wired pusher.ps1 (a test-tuned copy via TestHelpers.psm1's New-TestTunedPusherCopy;
# production pusher.ps1 is never modified), mirroring
# tests/Integration.KillAndResume.Tests.ps1's structure.
#
# Test 4 (outage survival) and Test 7 (a stats write can never kill the pusher) are
# the two that matter and are the reason this plan exists in its current shape --
# neither is reduced to a happy-path check, per this project's resilience-critical
# testing gate.
#
# GUID-suffixed work directories (Test-isolation note, 05-02-SUMMARY.md /
# Integration.KillAndResume.Tests.ps1 header): each It below gets its own
# GUID-suffixed subdirectory under $TestDrive, not just distinct filenames. This
# matters MORE here than in a plain offset test: $statsFilePath is resolved inside
# pusher.ps1 as a SIBLING of $stateFilePath's own directory (a fixed 'stats.json'
# filename, not parametrized) -- so two Its sharing one directory with differently
# named offset.json files would still collide on the exact same stats.json path.

BeforeAll {
    $script:RepoRootPath          = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:LoggingModulePath     = Join-Path $script:RepoRootPath 'lib/Logging.psm1'
    $script:OffsetStoreModulePath = Join-Path $script:RepoRootPath 'lib/OffsetStore.psm1'
    $script:ClockModulePath       = Join-Path $script:RepoRootPath 'lib/Clock.psm1'
    $script:StatsStoreModulePath  = Join-Path $script:RepoRootPath 'lib/StatsStore.psm1'
    $script:ControlFlagModulePath = Join-Path $script:RepoRootPath 'lib/ControlFlag.psm1'
    $script:TestHelpersModulePath = Join-Path $PSScriptRoot 'TestHelpers.psm1'

    function Start-TestPusherProcess {
        <#
        .SYNOPSIS
        Launches a test-tuned pusher.ps1 copy as a detached pwsh process with
        stdout/stderr redirected to temp files for post-mortem debugging. Same
        convention as Integration.KillAndResume.Tests.ps1 / Integration.ExplicitStop.Tests.ps1.
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

    function Wait-ForLogPatternInFiles {
        <#
        .SYNOPSIS
        Polls the given redirected-stdout/stderr files until one contains Pattern, or
        times out. Same convention as Integration.KillAndResume.Tests.ps1.
        #>
        param(
            [Parameter(Mandatory)] [string[]] $Paths,
            [Parameter(Mandatory)] [string] $Pattern,
            [int] $TimeoutMilliseconds = 30000,
            [int] $PollMilliseconds = 300
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

    function Stop-TestPusherProcessIfRunning {
        param($PusherHandle)
        if ($PusherHandle -and -not $PusherHandle.Process.HasExited) {
            Stop-Process -Id $PusherHandle.Process.Id -Force -ErrorAction SilentlyContinue
            $PusherHandle.Process.WaitForExit(5000) | Out-Null
        }
    }
}

Describe 'Publish-PusherStats forwarding (DASH-08 backend, Task 2)' -Tag 'Quick' {
    # Publish-PusherStats is a plain top-of-script function in pusher.ps1 (not a
    # module export), so it cannot be Import-Module'd or Mock'd -ModuleName. This
    # Describe extracts JUST that function's own source text (between its
    # `function Publish-PusherStats {` header and the next top-level `function`
    # declaration) and dot-sources it into this file's script scope -- the
    # production pusher.ps1 is never modified or executed (Start-Pusher at the
    # bottom of the real file is never reached), mirroring this suite's own
    # "production pusher.ps1 is never modified" convention used for the full
    # integration tests below via New-TestTunedPusherCopy.

    BeforeAll {
        $pusherSourceText = Get-Content -LiteralPath (Join-Path $script:RepoRootPath 'pusher.ps1') -Raw
        $functionStartIndex = $pusherSourceText.IndexOf('function Publish-PusherStats {')
        if ($functionStartIndex -lt 0) {
            throw 'Publish-PusherStats function definition not found in pusher.ps1 -- extraction anchor broke'
        }
        $nextFunctionIndex = $pusherSourceText.IndexOf("`nfunction Start-Pusher {", $functionStartIndex)
        if ($nextFunctionIndex -lt 0) {
            throw 'Start-Pusher function definition not found after Publish-PusherStats -- extraction anchor broke'
        }
        $script:PublishPusherStatsSourceText = $pusherSourceText.Substring($functionStartIndex, $nextFunctionIndex - $functionStartIndex)
    }

    BeforeEach {
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:StatsStoreModulePath -Force
        Import-Module $script:LoggingModulePath -Force
        . ([scriptblock]::Create($script:PublishPusherStatsSourceText))
    }

    AfterEach {
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
    }

    It 'forwards -LastSuccessfulSendEpochSeconds to Save-PusherStats unchanged' {
        Mock Save-PusherStats { }

        Publish-PusherStats -StatsFilePath 'C:\fake\stats.json' -PusherState 'Streaming' `
            -RecordingFilePath 'D:\recording.ts' -OffsetBytes 1000 -FileLengthBytes 2000 `
            -SendBytesPerSecond 500.0 -RecordBytesPerSecond 500.0 -SecondsBehindLive 5.0 `
            -BackoffAttemptNumber 0 -CumulativeReconnectCount 0 -CatchUpCapUtilization 0.0 -OutageActive $false `
            -LastSuccessfulSendEpochSeconds 123456.789

        Should -Invoke Save-PusherStats -Times 1 -Exactly -ParameterFilter {
            $LastSuccessfulSendEpochSeconds -eq 123456.789
        }
    }

    It 'forwards a $null -LastSuccessfulSendEpochSeconds (never sent yet) unchanged, never coerced to 0' {
        Mock Save-PusherStats { }

        Publish-PusherStats -StatsFilePath 'C:\fake\stats.json' -PusherState 'Streaming' `
            -RecordingFilePath 'D:\recording.ts' -OffsetBytes 0 -FileLengthBytes 188 `
            -SendBytesPerSecond 0.0 -RecordBytesPerSecond 0.0 -SecondsBehindLive 0.0 `
            -BackoffAttemptNumber 0 -CumulativeReconnectCount 0 -CatchUpCapUtilization 0.0 -OutageActive $false

        Should -Invoke Save-PusherStats -Times 1 -Exactly -ParameterFilter {
            $null -eq $LastSuccessfulSendEpochSeconds
        }
    }

    It 'still swallows a Save-PusherStats failure as a Warning (D-05/T-05-11) with LastSuccessfulSendEpochSeconds present' {
        Mock Save-PusherStats { throw 'simulated atomic-rename failure' }
        Mock Write-Log { }

        { Publish-PusherStats -StatsFilePath 'C:\fake\stats.json' -PusherState 'Streaming' `
            -RecordingFilePath 'D:\recording.ts' -OffsetBytes 1000 -FileLengthBytes 2000 `
            -SendBytesPerSecond 500.0 -RecordBytesPerSecond 500.0 -SecondsBehindLive 5.0 `
            -BackoffAttemptNumber 0 -CumulativeReconnectCount 0 -CatchUpCapUtilization 0.0 -OutageActive $false `
            -LastSuccessfulSendEpochSeconds 123456.789 } | Should -Not -Throw

        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' }
    }
}

Describe 'Smoothed-rate wiring regression (260718-h23/DASH-BRIEF-1/2)' -Tag 'Quick' {
    # This is deliberately a SOURCE/text assertion, not a behavioral one -- mirroring
    # tests/Supervisor.Tests.ps1's "Dashboard runspace param threading" Context (the
    # 05.1-05 precedent this plan cites). A runtime mock of Update-GrowthRateWindow or
    # Get-SecondsBehindLive can only prove the OUTER call site received SOME value; it
    # cannot see whether pusher.ps1 wired the SMOOTHED field through to pacing/cap/
    # display versus silently keeping the raw one (or vice versa for the resume
    # margin) -- exactly the kind of dropped-hop regression a future well-meaning edit
    # could introduce. Reading pusher.ps1 as raw text and asserting on the exact
    # field/param names at each of the 3 hops (smoothing threading, pacing/cap/display
    # consumption, resume-margin exemption) is the only way to pin this shape.

    BeforeAll {
        $script:PusherSourceText = Get-Content -LiteralPath (Join-Path $script:RepoRootPath 'pusher.ps1') -Raw
    }

    It 'Hop 1: both Update-GrowthRateWindow call sites (record + send windows) thread -SmoothingSeconds $growthRateSmoothingSeconds' {
        $growthWindowCallCount = ([regex]::Matches($script:PusherSourceText, [regex]::Escape('Update-GrowthRateWindow -Window $growthRateWindow -BytesTotal $currentLength -TimestampEpochSeconds $nowEpochSeconds -SmoothingSeconds $growthRateSmoothingSeconds'))).Count
        $sendWindowCallCount   = ([regex]::Matches($script:PusherSourceText, [regex]::Escape('Update-GrowthRateWindow -Window $sendRateWindow -BytesTotal $lastAcceptedPosition -TimestampEpochSeconds $nowEpochSeconds -SmoothingSeconds $growthRateSmoothingSeconds'))).Count

        $growthWindowCallCount | Should -Be 1 -Because 'the record-rate window call site must thread -SmoothingSeconds $growthRateSmoothingSeconds'
        $sendWindowCallCount | Should -Be 1 -Because 'the send-rate window call site must thread -SmoothingSeconds $growthRateSmoothingSeconds'
    }

    It 'Hop 1b: $growthRateSmoothingSeconds is unpacked from $config.GrowthRateSmoothingSeconds' {
        $script:PusherSourceText | Should -Match '\$growthRateSmoothingSeconds\s*=\s*\$config\.GrowthRateSmoothingSeconds'
    }

    It 'Hop 2: Get-SecondsBehindLive (hot-loop pacing/display) consumes the CHUR-01 frozen last-known-good rate, never the live-decaying growthRateWindow fields (15-01 Task 1 supersedes the 260718-h23 wiring)' {
        # CHUR-01 (15-01, Task 1) root-fixed the 2026-07-26 "30 min -> 8h21m in one
        # minute" incident: growthRateWindow.SmoothedBytesPerSecond is a valid live-rate
        # ESTIMATOR but decays toward zero the instant the recording stops growing, so it
        # is no longer a safe DIVISOR for the hot-loop's own Get-SecondsBehindLive call --
        # $lastKnownGoodRecordBytesPerSecond (Get-LastKnownGoodRecordRate, lib/Pacer.psm1)
        # replaces it there. This assertion is intentionally scoped to the HOT-LOOP call
        # site only (the one immediately following the two Update-GrowthRateWindow calls)
        # -- the Draining loop's own Get-SecondsBehindLive recompute (Task 3, CHUR-03) is a
        # SEPARATE call site with the SAME frozen-rate divisor, covered by Hop 2c below.
        if ($script:PusherSourceText -notmatch '(?s)\$sendRateWindow\s*=\s*Update-GrowthRateWindow -Window \$sendRateWindow(.*?)\$secondsBehindLive\s*=\s*Get-SecondsBehindLive([^\r\n]*)') {
            throw 'Could not locate the hot-loop Get-SecondsBehindLive call in pusher.ps1 (immediately after the send-rate window update) -- extraction anchor broke'
        }
        $hotLoopSecondsBehindLiveCallText = $Matches[2]

        $hotLoopSecondsBehindLiveCallText | Should -Match '-BytesPerSecond \$lastKnownGoodRecordBytesPerSecond' `
            -Because 'CHUR-01 (15-01 Task 1): the hot loop must divide by the frozen last-known-good rate, not a live-decaying one'
        $hotLoopSecondsBehindLiveCallText | Should -Not -Match '-BytesPerSecond \$growthRateWindow\.(Smoothed|Average)BytesPerSecond' `
            -Because 'the hot loop must never divide by growthRateWindow directly -- that is exactly the decaying-divisor bug CHUR-01 fixed'
    }

    It 'Hop 2c: the Draining loop''s own Get-SecondsBehindLive recompute (CHUR-03, 15-01 Task 3) ALSO consumes the frozen last-known-good rate' {
        if ($script:PusherSourceText -notmatch '(?s)while \(\(\$fileStream\.Position -lt \$fileStream\.Length\)(.*?)\$secondsBehindLive\s*=\s*Get-SecondsBehindLive([^\r\n]*)') {
            throw 'Could not locate the Draining loop''s own Get-SecondsBehindLive recompute in pusher.ps1 -- extraction anchor broke'
        }
        $drainSecondsBehindLiveCallText = $Matches[2]

        $drainSecondsBehindLiveCallText | Should -Match '-BytesPerSecond \$lastKnownGoodRecordBytesPerSecond' `
            -Because 'Task 3 (CHUR-03): the Draining loop must recompute secondsBehindLive live, divided by the SAME frozen rate the hot loop uses'
    }

    It 'Hop 2b: the mid-stream ReadFast branch''s Get-CatchUpSendCeiling call still consumes the LIVE SmoothedBytesPerSecond (D-03 boundary, 15-01 Task 1 explicitly does not move this call)' {
        # D-03 (15-01) locks the rate-freeze to engage ONLY in the official Draining
        # state -- the mid-stream ReadFast ceiling must keep consuming the live smoothed
        # rate unchanged. Scoped to the text AFTER the ReadFast branch's own
        # "elseif ($pacingDecision -eq 'ReadFast')" marker specifically, since Task 2 (D-02)
        # added TWO MORE Get-CatchUpSendCeiling calls earlier in the file (inside the
        # Draining loop) sharing the identical `-CatchUpMultiplier $catchUpMultiplier`
        # call-opening text -- an unscoped first-match search would now silently grab one
        # of those instead of this one.
        if ($script:PusherSourceText -notmatch "(?s)elseif \(\`$pacingDecision -eq 'ReadFast'\)(.*?)Get-CatchUpSendCeiling -CatchUpMultiplier \`$catchUpMultiplier ``(.*?)-ColdStartCeilingBytesPerSecond") {
            throw 'Could not locate the ReadFast branch''s Get-CatchUpSendCeiling call in pusher.ps1 -- extraction anchor broke'
        }
        $catchUpCallText = $Matches[2]

        $catchUpCallText | Should -Match '-ObservedBytesPerSecond \$growthRateWindow\.SmoothedBytesPerSecond' `
            -Because 'D-03 (15-01): the mid-stream ReadFast ceiling must keep consuming the LIVE smoothed rate, never the frozen one -- the rate freeze engages only in Draining (Task 2)'
        $catchUpCallText | Should -Not -Match '-ObservedBytesPerSecond \$growthRateWindow\.AverageBytesPerSecond'
    }

    It 'Hop 2d: both Draining-loop Get-CatchUpSendCeiling calls (Task 2, CHUR-01/D-02) consume the FROZEN last-known-good rate, never the live one' {
        $drainingBlockMatch = [regex]::Match($script:PusherSourceText, "(?s)if \(\`$pusherState -eq 'Draining'\)(.*?)elseif \(\`$pacingDecision -eq 'ReadFast'\)")
        $drainingBlockMatch.Success | Should -BeTrue -Because 'could not extract the Draining block in pusher.ps1 -- extraction anchor broke'
        $drainingBlockText = $drainingBlockMatch.Groups[1].Value

        $drainCeilingCallPattern = [regex]::Escape('Get-CatchUpSendCeiling -CatchUpMultiplier $catchUpMultiplier `') + '\s*' + [regex]::Escape('-ObservedBytesPerSecond $lastKnownGoodRecordBytesPerSecond')
        $drainCeilingCallCount = ([regex]::Matches($drainingBlockText, $drainCeilingCallPattern)).Count
        $drainCeilingCallCount | Should -Be 2 -Because 'Task 2 (D-02): both Draining success paths (pending-write-resolved and direct-write) must feed the frozen rate to Get-CatchUpSendCeiling'

        $drainingBlockText | Should -Not -Match 'Get-CatchUpSendCeiling[^\r\n]*\r?\n[^\r\n]*-ObservedBytesPerSecond \$growthRateWindow\.(Smoothed|Average)BytesPerSecond' `
            -Because 'D-03: the Draining loop must never feed the live-decaying growthRateWindow rate to its ceiling -- only the frozen one'
    }

    It 'Hop 3: all stats-publish sites that use the hot-loop-named windows ($sendRateWindow/$growthRateWindow) pass -Smoothed for both send and record windows' {
        # CHUR-03 (15-01, Task 3) added a FIFTH such call site (the Draining loop's new
        # time-based publish cadence, alongside the pre-existing byte-based one) --
        # superseding the original 260718-h23 count of 4 (top-of-loop, the two
        # pre-existing drain success-path publishes, and terminal). The shared
        # Invoke-PusherReconnectEscalation helper's own Publish-PusherStats call is
        # deliberately excluded from this count -- it uses its own parameter-scoped
        # $SendRateWindowValue/$GrowthRateWindowValue names, not these hot-loop variables,
        # so it can never match this pattern (by design, not an omission).
        $sendSmoothedCount   = ([regex]::Matches($script:PusherSourceText, [regex]::Escape('(Get-StatsWindowAverageBytesPerSecond -Window $sendRateWindow -Smoothed)'))).Count
        $recordSmoothedCount = ([regex]::Matches($script:PusherSourceText, [regex]::Escape('(Get-StatsWindowAverageBytesPerSecond -Window $growthRateWindow -Smoothed)'))).Count

        $sendSmoothedCount | Should -Be 5 -Because 'five stats-publish sites (top-of-loop, drain byte-triggered x2, drain time-triggered (Task 3), terminal) must request the smoothed send rate'
        $recordSmoothedCount | Should -Be 5 -Because 'five stats-publish sites (top-of-loop, drain byte-triggered x2, drain time-triggered (Task 3), terminal) must request the smoothed record rate'

        # No stats-publish site may still call the accessor WITHOUT -Smoothed (a
        # dropped hop would silently regress a single site back to raw/jittery).
        $anyUnsmoothedSendCall = ([regex]::Matches($script:PusherSourceText, '\(Get-StatsWindowAverageBytesPerSecond -Window \$sendRateWindow\)')).Count
        $anyUnsmoothedRecordCall = ([regex]::Matches($script:PusherSourceText, '\(Get-StatsWindowAverageBytesPerSecond -Window \$growthRateWindow\)')).Count
        $anyUnsmoothedSendCall | Should -Be 0
        $anyUnsmoothedRecordCall | Should -Be 0
    }

    It 'CONTENT-LOSS GUARD (T-h23-I1): Get-ResumeSafetyMarginBytes still reads the RAW AverageBytesPerSecond, never SmoothedBytesPerSecond' {
        # 260718-j58/Task 2: the dynamic-margin/outage-path call now lives ONCE, inside
        # the shared Invoke-PusherReconnectEscalation helper (Front A -- every
        # reconnect/escalation call site reuses this ONE function rather than a
        # parallel reconnect path), reading a -RawObservedBytesPerSecond PARAMETER
        # rather than $growthRateWindow.AverageBytesPerSecond directly at the
        # Get-ResumeSafetyMarginBytes call site itself. The guard is now two-part:
        # (1) that one shared function's own internal call must still read the
        # -RawObservedBytesPerSecond parameter (never a smoothed one), and (2) EVERY
        # call site that invokes the shared function must feed it
        # $growthRateWindow.AverageBytesPerSecond, never SmoothedBytesPerSecond.
        if ($script:PusherSourceText -notmatch '(?s)Get-ResumeSafetyMarginBytes -SrtLatencySeconds \$ResumeMarginLatencySecondsValue `\s*-ObservedBytesPerSecond (\$\w+)') {
            throw 'Could not locate Invoke-PusherReconnectEscalation''s own Get-ResumeSafetyMarginBytes call in pusher.ps1 -- extraction anchor broke'
        }
        $observedBytesPerSecondParameter = $Matches[1]
        $observedBytesPerSecondParameter | Should -Be '$RawObservedBytesPerSecond' -Because 'the crash-safe resume margin must never be fed the smoothed rate -- a lagging smoothed rate could theoretically shrink the one content-loss-critical safety window in this codebase (T-h23-I1)'

        $callSiteMatches = [regex]::Matches($script:PusherSourceText, '-RawObservedBytesPerSecond (\$growthRateWindow\.\w+)')
        $callSiteMatches.Count | Should -BeGreaterThan 0 -Because 'every reconnect/escalation call site must feed the shared helper the RAW rate -- extraction anchor broke if none matched'
        foreach ($callSiteMatch in $callSiteMatches) {
            $callSiteMatch.Groups[1].Value | Should -Be '$growthRateWindow.AverageBytesPerSecond' -Because 'no call site may ever pass the smoothed rate into the content-loss-critical resume margin (T-h23-I1)'
        }
    }

    It 'Get-StatsWindowAverageBytesPerSecond function definition: -Smoothed returns SmoothedBytesPerSecond, falls through to AverageBytesPerSecond/0.0 otherwise' {
        $functionStartIndex = $script:PusherSourceText.IndexOf('function Get-StatsWindowAverageBytesPerSecond {')
        if ($functionStartIndex -lt 0) {
            throw 'Get-StatsWindowAverageBytesPerSecond function definition not found in pusher.ps1 -- extraction anchor broke'
        }
        $nextFunctionIndex = $script:PusherSourceText.IndexOf("`nfunction Publish-PusherStats {", $functionStartIndex)
        if ($nextFunctionIndex -lt 0) {
            throw 'Publish-PusherStats function definition not found after Get-StatsWindowAverageBytesPerSecond -- extraction anchor broke'
        }
        $functionSourceText = $script:PusherSourceText.Substring($functionStartIndex, $nextFunctionIndex - $functionStartIndex)

        $functionSourceText | Should -Match '\[switch\]\s*\$Smoothed'
        $functionSourceText | Should -Match "if \(\`$Smoothed -and \`$Window -is \[hashtable\] -and \`$Window\.ContainsKey\('SmoothedBytesPerSecond'\)\)"
        $functionSourceText | Should -Match "return \`$Window\.SmoothedBytesPerSecond"
        $functionSourceText | Should -Match "if \(\`$Window -is \[hashtable\] -and \`$Window\.ContainsKey\('AverageBytesPerSecond'\)\)"
        $functionSourceText | Should -Match 'return 0\.0'
    }
}

Describe 'PusherStats' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Remove-Module OffsetStore -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:OffsetStoreModulePath -Force
        Import-Module $script:ClockModulePath -Force
        Import-Module $script:StatsStoreModulePath -Force
        Import-Module $script:ControlFlagModulePath -Force
        Import-Module $script:TestHelpersModulePath -Force
    }

    AfterEach {
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Remove-Module OffsetStore -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'publishes the full 15-key schema at the commit cadence, with offsetBytes/fileLengthBytes advancing, sendBytesPerSecond distinct from recordBytesPerSecond, cumulativeReconnectCount never decreasing, and a terminal Stopped record after a clean explicit stop (Tests 1/2/3/5/6/8)' {
        $workDirectory = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
        $samplePath    = Join-Path $workDirectory 'sample.ts'
        $recordingPath = Join-Path $workDirectory 'recording.ts'
        $receivedPath  = Join-Path $workDirectory 'received.ts'
        $statePath     = Join-Path $workDirectory 'offset.json'
        $controlPath   = Join-Path $workDirectory 'control.json'
        # $statsFilePath is resolved INSIDE pusher.ps1 as a sibling of $stateFilePath's
        # own directory (a fixed 'stats.json' filename) -- so it lands here without any
        # separate override, exactly mirroring the production sibling-of-offset.json path.
        $statsPath     = Join-Path $workDirectory 'stats.json'

        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 30 -VideoSize '320x240' -FrameRate 25 | Out-Null
        New-Item -ItemType File -Path $recordingPath -Force | Out-Null

        $listenPort = Get-Random -Minimum 20000 -Maximum 40000
        $writer     = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 25
        $listener   = Start-SrtListener -Port $listenPort -OutputPath $receivedPath

        Set-PusherDesiredState -ControlFilePath $controlPath -DesiredState 'streaming'

        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RelayPort $listenPort `
            -StateFilePath $statePath -ControlFilePath $controlPath
        $pusherHandle = $null
        try {
            Start-Sleep -Milliseconds 800
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            (Wait-ForFileToExist -Path $statsPath -TimeoutMilliseconds 15000) | Should -BeTrue

            $firstStats = Read-PusherStats -StatsFilePath $statsPath
            $firstStats | Should -Not -BeNullOrEmpty

            # Test 1: all 15 schema keys present, correctly typed.
            $expectedKeys = @(
                'schemaVersion', 'pusherState', 'recordingFilePath', 'offsetBytes', 'fileLengthBytes',
                'sendBytesPerSecond', 'recordBytesPerSecond', 'secondsBehindLive', 'backoffAttemptNumber',
                'cumulativeReconnectCount', 'lastClassificationCause', 'catchUpCapUtilization', 'outageActive',
                'updatedEpochSeconds', 'staleAfterEpochSeconds'
            )
            $actualKeys = @($firstStats.PSObject.Properties.Name)
            foreach ($expectedKey in $expectedKeys) {
                $actualKeys | Should -Contain $expectedKey
            }
            $firstStats.offsetBytes | Should -BeOfType [long]
            $firstStats.fileLengthBytes | Should -BeOfType [long]
            $firstStats.sendBytesPerSecond | Should -BeOfType [double]
            $firstStats.recordBytesPerSecond | Should -BeOfType [double]
            $firstStats.secondsBehindLive | Should -BeOfType [double]
            $firstStats.catchUpCapUtilization | Should -BeOfType [double]
            $firstStats.outageActive | Should -BeOfType [bool]
            $firstStats.updatedEpochSeconds | Should -BeOfType [double]
            $firstStats.staleAfterEpochSeconds | Should -BeOfType [double]

            # Sample repeatedly across a short streaming window: proves offset/length
            # advance (Test 2), pusherState is Streaming (Test 3), sendBytesPerSecond
            # diverges from recordBytesPerSecond at least once (Test 5, the pusher
            # deliberately buffers 1-2s behind live before its first accepted byte,
            # D-11/D-12 -- New-TestTunedPusherCopy's default TargetLow/HighSeconds is
            # 1/2s), and cumulativeReconnectCount never decreases (Test 6).
            $samples = [System.Collections.Generic.List[object]]::new()
            $samples.Add($firstStats)
            for ($i = 0; $i -lt 7; $i++) {
                Start-Sleep -Milliseconds 400
                $sample = Read-PusherStats -StatsFilePath $statsPath
                if ($sample) { $samples.Add($sample) }
            }
            $samples.Count | Should -BeGreaterThan 1

            # Test 3: pusherState is Streaming during a normal run.
            ($samples | Where-Object { $_.pusherState -eq 'Streaming' }).Count | Should -BeGreaterThan 0

            # Test 2: offsetBytes never exceeds fileLengthBytes, and both advance.
            foreach ($sample in $samples) {
                $sample.offsetBytes | Should -BeLessOrEqual $sample.fileLengthBytes
            }
            $samples[-1].offsetBytes | Should -BeGreaterOrEqual $samples[0].offsetBytes
            $samples[-1].fileLengthBytes | Should -BeGreaterThan $samples[0].fileLengthBytes

            # Test 5: sendBytesPerSecond is not merely a copy of recordBytesPerSecond.
            ($samples | Where-Object { $_.sendBytesPerSecond -ne $_.recordBytesPerSecond }).Count | Should -BeGreaterThan 0

            # Test 6: cumulativeReconnectCount is monotonic non-decreasing.
            for ($i = 1; $i -lt $samples.Count; $i++) {
                $samples[$i].cumulativeReconnectCount | Should -BeGreaterOrEqual $samples[$i - 1].cumulativeReconnectCount
            }

            # THE OPERATOR PRESSES STOP -- a genuinely clean exit (not a forceful kill),
            # so the pusher's own `finally` block (Publish-PusherStats site 4) actually
            # runs and Test 8 observes a real terminal record, not an artifact of the
            # test harness killing the process before it could write one.
            Set-PusherDesiredState -ControlFilePath $controlPath -DesiredState 'stopped'
            $exitedOnItsOwn = $pusherHandle.Process.WaitForExit(20000)
            $exitedOnItsOwn | Should -BeTrue -Because 'an explicit operator stop must drain and exit on its own so the finally block''s terminal stats publish actually runs'

            # Test 8: after a clean exit, the final stats.json carries pusherState = 'Stopped'.
            $finalStats = Read-PusherStats -StatsFilePath $statsPath
            $finalStats | Should -Not -BeNullOrEmpty
            $finalStats.pusherState | Should -Be 'Stopped'
        } finally {
            Stop-TestPusherProcessIfRunning -PusherHandle $pusherHandle
            Stop-ValidMpegtsGrowthWriter -Writer $writer
            if (-not $listener.HasExited) { Stop-SrtListener -Process $listener }
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'survives an unwritable stats path: the pusher keeps streaming and logs a Warning, never crashing on a stats write failure (Test 7, D-05/T-05-11)' {
        $workDirectory = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
        $samplePath    = Join-Path $workDirectory 'sample.ts'
        $recordingPath = Join-Path $workDirectory 'recording.ts'
        $receivedPath  = Join-Path $workDirectory 'received.ts'
        $statePath     = Join-Path $workDirectory 'offset.json'
        $statsPath     = Join-Path $workDirectory 'stats.json'

        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 20 -VideoSize '320x240' -FrameRate 25 | Out-Null
        New-Item -ItemType File -Path $recordingPath -Force | Out-Null

        # Make the stats path UNWRITABLE as a real file: pre-create a DIRECTORY at the
        # exact path Save-PusherStats' atomic rename will target. The temp file write
        # still succeeds (a distinct filename in the same directory); only the final
        # [System.IO.File]::Move(temp, stats.json, overwrite:true) fails, because its
        # destination is a directory, not a file -- a real IOException/
        # UnauthorizedAccessException, exercising Save-PusherStats' genuine 5-attempt
        # retry-then-rethrow path and Publish-PusherStats' swallowing catch around it.
        New-Item -ItemType Directory -Path $statsPath -Force | Out-Null

        $listenPort = Get-Random -Minimum 20000 -Maximum 40000
        $writer     = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 20
        $listener   = Start-SrtListener -Port $listenPort -OutputPath $receivedPath

        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RelayPort $listenPort -StateFilePath $statePath
        $pusherHandle = $null
        try {
            Start-Sleep -Milliseconds 800
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            # The pusher must still commit its OFFSET normally -- a stats write failure
            # is completely unrelated to the live-proven offset path (D-05's whole point).
            (Wait-ForFileToExist -Path $statePath -TimeoutMilliseconds 15000) | Should -BeTrue

            $warningLogged = Wait-ForLogPatternInFiles -Paths @($pusherHandle.StdOutPath, $pusherHandle.StdErrPath) `
                -Pattern 'Stats publish.*failed' -TimeoutMilliseconds 15000
            $warningLogged | Should -BeTrue -Because 'Publish-PusherStats must log a Warning on a genuine write failure, not fail silently'

            # The stream itself must be completely unaffected: still alive, and still
            # actively advancing its OFFSET (the live-proven, unrelated commit path,
            # D-05's whole point) -- checked via the persisted offset rather than the
            # SRT listener's received-bytes file, which trails behind by SRT's own
            # latency buffer and this test's tuned buffering window (D-11/D-12) and is
            # therefore a noisier signal of "still actively processing" than necessary.
            $pusherHandle.Process.HasExited | Should -BeFalse -Because 'a stats write failure must never reach the hot path (D-05/T-05-11)'
            $offsetBeforeWait = (Restore-PusherOffset -StateFilePath $statePath).byteOffset
            $offsetAdvanced = $false
            $deadline = [DateTime]::UtcNow.AddSeconds(8)
            while ([DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 500
                $offsetNow = (Restore-PusherOffset -StateFilePath $statePath).byteOffset
                if ($offsetNow -gt $offsetBeforeWait) { $offsetAdvanced = $true; break }
            }
            $offsetAdvanced | Should -BeTrue -Because 'the pusher must keep actively streaming (offset advancing) through a stats write failure, not merely stay alive'
            $pusherHandle.Process.HasExited | Should -BeFalse
        } finally {
            Stop-TestPusherProcessIfRunning -PusherHandle $pusherHandle
            Stop-ValidMpegtsGrowthWriter -Writer $writer
            if (-not $listener.HasExited) { Stop-SrtListener -Process $listener }
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'PusherStats outage-survival: stats keep flowing through a mid-push SRT listener kill (Test 4, D-06/T-05-24)' -Tag 'Integration' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Remove-Module OffsetStore -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:OffsetStoreModulePath -Force
        Import-Module $script:ClockModulePath -Force
        Import-Module $script:StatsStoreModulePath -Force
        Import-Module $script:TestHelpersModulePath -Force
    }

    AfterEach {
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Remove-Module OffsetStore -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'keeps updatedEpochSeconds advancing, flips outageActive true, and widens staleAfterEpochSeconds past 3s before the backoff sleep -- the exact blindness this plan exists to fix' {
        $workDirectory = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
        $samplePath    = Join-Path $workDirectory 'sample.ts'
        $recordingPath = Join-Path $workDirectory 'recording.ts'
        $receivedPath  = Join-Path $workDirectory 'received.ts'
        $statePath     = Join-Path $workDirectory 'offset.json'
        $statsPath     = Join-Path $workDirectory 'stats.json'
        New-SampleMpegtsFile -OutputPath $samplePath -DurationSeconds 60 -VideoSize '320x240' -FrameRate 25 | Out-Null
        New-Item -ItemType File -Path $recordingPath -Force | Out-Null

        $outagePort = Get-Random -Minimum 20000 -Maximum 40000
        $writer     = Start-ValidMpegtsGrowthWriter -SamplePath $samplePath -TargetFilePath $recordingPath -IntervalMilliseconds 300 -ChunkSizeBytes 18800 -TotalDurationSeconds 90
        $listener1  = Start-SrtListener -Port $outagePort -OutputPath $receivedPath

        $testPusherPath = New-TestTunedPusherCopy -RecordingFilePath $recordingPath -RelayPort $outagePort -StateFilePath $statePath
        $pusherHandle = $null
        try {
            Start-Sleep -Milliseconds 800
            $pusherHandle = Start-TestPusherProcess -PusherScriptPath $testPusherPath

            (Wait-ForFileToExist -Path $statsPath -TimeoutMilliseconds 15000) | Should -BeTrue

            # Sustained push before the outage, matching Invoke-FfmpegSrtFailureCapture's
            # empirically-tuned window (02-01-SUMMARY.md ground truth) -- a shorter window
            # kills the listener before ffmpeg's SRT caller has actually opened.
            Start-Sleep -Milliseconds 6000
            $pusherHandle.Process.HasExited | Should -BeFalse

            $statsBeforeOutage = Read-PusherStats -StatsFilePath $statsPath
            $statsBeforeOutage | Should -Not -BeNullOrEmpty
            $statsBeforeOutage.outageActive | Should -BeFalse

            # THE OUTAGE: kill the LISTENER, never the pusher (D-01) -- ffmpeg's own SRT
            # dial/submit now fails while the pusher process itself keeps running untouched.
            Stop-SrtListener -Process $listener1

            $networkDeathDetected = Wait-ForLogPatternInFiles -Paths @($pusherHandle.StdOutPath, $pusherHandle.StdErrPath) `
                -Pattern 'classified as NetworkDeath' -TimeoutMilliseconds 30000
            $networkDeathDetected | Should -BeTrue
            $pusherHandle.Process.HasExited | Should -BeFalse -Because 'the pusher must never exit on a network outage (D-10)'

            # Poll stats.json across the outage/backoff window: updatedEpochSeconds must
            # keep ADVANCING (the top-of-loop and pre-backoff-sleep publish sites both
            # reach the outage branch, unlike the offset commit gate which freezes) and
            # outageActive must flip true -- this is the regression gate for the
            # dashboard-blindness defect the top-of-loop/pre-backoff publish sites fix.
            $outageSamples = [System.Collections.Generic.List[object]]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            while ([DateTime]::UtcNow -lt $deadline) {
                $sample = Read-PusherStats -StatsFilePath $statsPath
                if ($sample) { $outageSamples.Add($sample) }
                Start-Sleep -Milliseconds 300
            }
            $outageSamples.Count | Should -BeGreaterThan 1 -Because 'stats.json must keep being written during the outage/backoff window, not go stale'

            $updatedTimestamps = @($outageSamples | ForEach-Object { $_.updatedEpochSeconds })
            ($updatedTimestamps[-1]) | Should -BeGreaterThan ($updatedTimestamps[0]) -Because 'updatedEpochSeconds must keep advancing across the outage -- a frozen timestamp is exactly the dashboard-blindness defect this plan fixes'

            ($outageSamples | Where-Object { $_.outageActive -eq $true }).Count | Should -BeGreaterThan 0 -Because 'outageActive must flip true once the write failure is classified'

            # The widened pre-backoff-sleep deadline: at least one sample during the
            # outage/backoff window must show a staleness margin comfortably past the
            # default 3.0s -- proof the outage-branch publish (site 2) actually widened
            # StaleWithinSeconds before sleeping, not just re-used the default.
            $wideStalenessMargins = @($outageSamples | ForEach-Object { $_.staleAfterEpochSeconds - $_.updatedEpochSeconds } | Where-Object { $_ -gt 3.0 })
            $wideStalenessMargins.Count | Should -BeGreaterThan 0 -Because 'the outage-branch publish must widen staleAfterEpochSeconds past the coming backoff sleep (D-06), or the dashboard would misreport a mid-backoff pusher as lost contact'
        } finally {
            Stop-TestPusherProcessIfRunning -PusherHandle $pusherHandle
            Stop-ValidMpegtsGrowthWriter -Writer $writer
            if (-not $listener1.HasExited) { Stop-SrtListener -Process $listener1 }
            Remove-Item -LiteralPath $testPusherPath -Force -ErrorAction SilentlyContinue
        }
    }
}

BeforeAll {
    $script:PacerModulePath = Join-Path $PSScriptRoot '../lib/Pacer.psm1'
    $script:ConfigModulePath = Join-Path $PSScriptRoot '../lib/Config.psm1'
    $script:LoggingModulePath = Join-Path $PSScriptRoot '../lib/Logging.psm1'
}

Describe 'Pacer' -Tag 'Quick' {

    BeforeEach {
        Remove-Module Pacer -ErrorAction SilentlyContinue
        Import-Module $script:PacerModulePath -Force
    }

    AfterEach {
        Remove-Module Pacer -ErrorAction SilentlyContinue
    }

    Context 'Get-PacingDecision' {

        It 'returns Wait when strictly below the low band (3s behind, band 5-10)' {
            Get-PacingDecision -SecondsBehindLive 3 -TargetLowSeconds 5 -TargetHighSeconds 10 | Should -Be 'Wait'
        }

        It 'returns Throttle when inside the band (7s behind, band 5-10)' {
            Get-PacingDecision -SecondsBehindLive 7 -TargetLowSeconds 5 -TargetHighSeconds 10 | Should -Be 'Throttle'
        }

        It 'returns ReadFast when strictly above the high band (15s behind, band 5-10)' {
            Get-PacingDecision -SecondsBehindLive 15 -TargetLowSeconds 5 -TargetHighSeconds 10 | Should -Be 'ReadFast'
        }

        It 'returns Throttle (not Wait) exactly at the low boundary (5s)' {
            Get-PacingDecision -SecondsBehindLive 5 -TargetLowSeconds 5 -TargetHighSeconds 10 | Should -Be 'Throttle'
        }

        It 'returns Throttle (not ReadFast) exactly at the high boundary (10s)' {
            Get-PacingDecision -SecondsBehindLive 10 -TargetLowSeconds 5 -TargetHighSeconds 10 | Should -Be 'Throttle'
        }
    }

    Context 'Get-SecondsBehindLive' {

        It 'converts bytes-behind to seconds using the observed growth rate' {
            Get-SecondsBehindLive -BytesBehind 2000000 -BytesPerSecond 1000000 | Should -Be 2.0
        }

        It 'returns a safe sentinel (0) without dividing by zero when BytesPerSecond is 0' {
            { Get-SecondsBehindLive -BytesBehind 2000000 -BytesPerSecond 0 } | Should -Not -Throw
            Get-SecondsBehindLive -BytesBehind 2000000 -BytesPerSecond 0 | Should -Be 0
        }

        It 'returns a safe sentinel (0) without dividing by zero when BytesPerSecond is negative' {
            Get-SecondsBehindLive -BytesBehind 2000000 -BytesPerSecond -5 | Should -Be 0
        }
    }

    Context 'Get-CatchUpSendCeiling' {

        It 'returns catchUpMultiplier x observedBytesPerSecond in the normal path (2.0x, 1,000,000 B/s)' {
            Get-CatchUpSendCeiling -CatchUpMultiplier 2.0 -ObservedBytesPerSecond 1000000 -ColdStartCeilingBytesPerSecond 500000 | Should -Be 2000000
        }

        It 'honors a configurable multiplier (1.5x, 4,000,000 B/s)' {
            Get-CatchUpSendCeiling -CatchUpMultiplier 1.5 -ObservedBytesPerSecond 4000000 -ColdStartCeilingBytesPerSecond 500000 | Should -Be 6000000
        }

        It 'falls back to the cold-start ceiling when observedBytesPerSecond is 0 (cold window, D-07)' {
            Get-CatchUpSendCeiling -CatchUpMultiplier 2.0 -ObservedBytesPerSecond 0 -ColdStartCeilingBytesPerSecond 500000 | Should -Be 500000
        }

        It 'falls back to the cold-start ceiling when observedBytesPerSecond is negative (le-0 guard, not just ==0)' {
            Get-CatchUpSendCeiling -CatchUpMultiplier 2.0 -ObservedBytesPerSecond -5 -ColdStartCeilingBytesPerSecond 500000 | Should -Be 500000
        }

        It 'does not throw and does not divide by zero when observedBytesPerSecond is 0' {
            { Get-CatchUpSendCeiling -CatchUpMultiplier 2.0 -ObservedBytesPerSecond 0 -ColdStartCeilingBytesPerSecond 500000 } | Should -Not -Throw
        }

        It 'a positive absolute ceiling replaces the multiplier x record-rate ceiling entirely (2026-07-26 decoupling)' {
            Get-CatchUpSendCeiling -CatchUpMultiplier 1.5 -ObservedBytesPerSecond 1000000 -ColdStartCeilingBytesPerSecond 500000 -AbsoluteCeilingBytesPerSecond 2000000 | Should -Be 2000000
        }

        It 'a positive absolute ceiling also overrides the cold-start fallback' {
            Get-CatchUpSendCeiling -CatchUpMultiplier 1.5 -ObservedBytesPerSecond 0 -ColdStartCeilingBytesPerSecond 500000 -AbsoluteCeilingBytesPerSecond 2000000 | Should -Be 2000000
        }

        It 'an absolute ceiling of 0 (the default) keeps the legacy multiplier behaviour byte-identical' {
            Get-CatchUpSendCeiling -CatchUpMultiplier 1.5 -ObservedBytesPerSecond 1000000 -ColdStartCeilingBytesPerSecond 500000 -AbsoluteCeilingBytesPerSecond 0 | Should -Be 1500000
        }

        # DIAL-02 (14.5-07): pins the D-03 ceiling-replaces-multiplier semantics the
        # live dials depend on, at the exact 0-vs-1-byte/s adjacency boundary. No
        # production code changes -- Get-CatchUpSendCeiling is already correct; these
        # cases exist so a future change to this function cannot silently regress the
        # boundary the dials (14.5-08/14.5-09) will rely on.
        It 'ceiling exactly 1 byte/s (the band floor, adjacent to 0=off) governs, fully ignoring the multiplier x observed-rate cap' {
            Get-CatchUpSendCeiling -CatchUpMultiplier 1.5 -ObservedBytesPerSecond 1000000 -ColdStartCeilingBytesPerSecond 500000 -AbsoluteCeilingBytesPerSecond 1 | Should -Be 1
        }

        It 'ceiling exactly 0 falls back to the multiplier cap even when observedBytesPerSecond would make a ceiling of 1 obviously smaller (adjacency contrast against the prior case)' {
            Get-CatchUpSendCeiling -CatchUpMultiplier 1.5 -ObservedBytesPerSecond 1000000 -ColdStartCeilingBytesPerSecond 500000 -AbsoluteCeilingBytesPerSecond 0 | Should -Be 1500000
        }

        It 'a mid-band absolute ceiling (16 Mbit/s = 2,000,000 bytes/s) governs regardless of a much larger multiplier x observed-rate cap' {
            Get-CatchUpSendCeiling -CatchUpMultiplier 3.0 -ObservedBytesPerSecond 10000000 -ColdStartCeilingBytesPerSecond 500000 -AbsoluteCeilingBytesPerSecond 2000000 | Should -Be 2000000
        }
    }

    Context 'Get-LastKnownGoodRecordRate' {
        # CHUR-01 (15-01, Task 1): the frozen last-known-good record rate that replaces
        # the decaying EWMA as Get-SecondsBehindLive's divisor once growth stops. See
        # lib/Pacer.psm1's own docstring for the carry-forward idiom this mirrors.

        It 'adopts the first genuine observation (cold start, 0 -> 3,000,000 B/s on growth)' {
            Get-LastKnownGoodRecordRate -CurrentLastKnownGoodBytesPerSecond 0 -ObservedBytesPerSecond 3000000 -RecordingFileGrew $true | Should -Be 3000000
        }

        It 'ignores a decaying EWMA on a non-growth tick, carrying the prior value forward' {
            Get-LastKnownGoodRecordRate -CurrentLastKnownGoodBytesPerSecond 3000000 -ObservedBytesPerSecond 12 -RecordingFileGrew $false | Should -Be 3000000
        }

        It 'treats exactly 0 observed as not usable even when RecordingFileGrew is true (boundary case)' {
            Get-LastKnownGoodRecordRate -CurrentLastKnownGoodBytesPerSecond 3000000 -ObservedBytesPerSecond 0 -RecordingFileGrew $true | Should -Be 3000000
        }

        It 'adopts an honest lower live rate on growth -- freeze-on-stall, never a high-water mark' {
            Get-LastKnownGoodRecordRate -CurrentLastKnownGoodBytesPerSecond 3000000 -ObservedBytesPerSecond 2500000 -RecordingFileGrew $true | Should -Be 2500000
        }

        It 'stays 0 at cold start when no rate has ever been observed (so Get-SecondsBehindLive keeps its sentinel)' {
            Get-LastKnownGoodRecordRate -CurrentLastKnownGoodBytesPerSecond 0 -ObservedBytesPerSecond 0 -RecordingFileGrew $false | Should -Be 0
        }

        It 'never adopts a negative observation' {
            Get-LastKnownGoodRecordRate -CurrentLastKnownGoodBytesPerSecond 3000000 -ObservedBytesPerSecond -5 -RecordingFileGrew $true | Should -Be 3000000
        }
    }

    Context 'Update-GrowthRateWindow' {

        It 'returns the average bytes/sec across a bounded rolling window of samples' {
            $window = @()
            $window = Update-GrowthRateWindow -Window $window -BytesTotal 0 -TimestampEpochSeconds 0
            $window = Update-GrowthRateWindow -Window $window -BytesTotal 1000000 -TimestampEpochSeconds 1
            $window = Update-GrowthRateWindow -Window $window -BytesTotal 2000000 -TimestampEpochSeconds 2

            $window.AverageBytesPerSecond | Should -Be 1000000
        }

        It 'bounds the sample list to a maximum window size (older samples evicted)' {
            $window = @()
            for ($i = 0; $i -le 20; $i++) {
                $window = Update-GrowthRateWindow -Window $window -BytesTotal ($i * 1000000) -TimestampEpochSeconds $i -MaxSamples 5
            }

            $window.Samples.Count | Should -BeLessOrEqual 5
        }
    }

    Context 'Update-GrowthRateWindow SmoothedBytesPerSecond (EWMA, 260718-h23/DASH-BRIEF-1/2)' {

        It 'passes SmoothedBytesPerSecond through as AverageBytesPerSecond exactly when SmoothingSeconds is omitted (default 0, disabled)' {
            $window = @()
            $window = Update-GrowthRateWindow -Window $window -BytesTotal 0 -TimestampEpochSeconds 0
            $window = Update-GrowthRateWindow -Window $window -BytesTotal 1000000 -TimestampEpochSeconds 1
            $window = Update-GrowthRateWindow -Window $window -BytesTotal 5000000 -TimestampEpochSeconds 5

            $window.SmoothedBytesPerSecond | Should -Be $window.AverageBytesPerSecond
        }

        It 'passes SmoothedBytesPerSecond through as AverageBytesPerSecond exactly when SmoothingSeconds is explicitly 0' {
            $window = @()
            $window = Update-GrowthRateWindow -Window $window -BytesTotal 0 -TimestampEpochSeconds 0 -SmoothingSeconds 0
            $window = Update-GrowthRateWindow -Window $window -BytesTotal 2000000 -TimestampEpochSeconds 2 -SmoothingSeconds 0

            $window.SmoothedBytesPerSecond | Should -Be $window.AverageBytesPerSecond
        }

        It 'passes SmoothedBytesPerSecond through as AverageBytesPerSecond exactly when SmoothingSeconds is negative' {
            $window = @()
            $window = Update-GrowthRateWindow -Window $window -BytesTotal 0 -TimestampEpochSeconds 0 -SmoothingSeconds -5
            $window = Update-GrowthRateWindow -Window $window -BytesTotal 1000000 -TimestampEpochSeconds 1 -SmoothingSeconds -5

            $window.SmoothedBytesPerSecond | Should -Be $window.AverageBytesPerSecond
        }

        It 'seeds SmoothedBytesPerSecond from the stable window AverageBytesPerSecond on the first update that establishes a rate (no ramp-from-zero)' {
            $window = @()
            $window = Update-GrowthRateWindow -Window $window -BytesTotal 0 -TimestampEpochSeconds 0 -SmoothingSeconds 30
            $window.SmoothedBytesPerSecond | Should -Be 0

            $window = Update-GrowthRateWindow -Window $window -BytesTotal 1000000 -TimestampEpochSeconds 1 -SmoothingSeconds 30
            $window.AverageBytesPerSecond | Should -Be 1000000
            $window.SmoothedBytesPerSecond | Should -Be $window.AverageBytesPerSecond
            $window.SmoothedBytesPerSecond | Should -Be 1000000
        }

        It 'computes SmoothedBytesPerSecond = alpha*instantRate + (1-alpha)*priorSmoothed for a fixed tau/dt (EWMA math)' {
            $smoothingTauSeconds = 30.0
            $deltaSeconds = 0.25
            $priorSmoothedBytesPerSecond = 3000000.0
            $instantBytesPerSecond = 4000000.0
            $alpha = 1 - [Math]::Exp(-$deltaSeconds / $smoothingTauSeconds)
            $expectedSmoothedBytesPerSecond = ($alpha * $instantBytesPerSecond) + ((1 - $alpha) * $priorSmoothedBytesPerSecond)

            # A window with >=2 existing samples (so the EWMA branch runs, not the
            # first-establish seed branch) and a prior smoothed value already primed.
            $window = @{
                Samples = @(
                    @{ Bytes = 0; TimestampEpochSeconds = -0.25 }
                    @{ Bytes = 0; TimestampEpochSeconds = 0 }
                )
                SmoothedBytesPerSecond = $priorSmoothedBytesPerSecond
            }
            $newBytesTotal = [long] ($instantBytesPerSecond * $deltaSeconds)

            $window = Update-GrowthRateWindow -Window $window -BytesTotal $newBytesTotal -TimestampEpochSeconds $deltaSeconds -SmoothingSeconds $smoothingTauSeconds

            $window.SmoothedBytesPerSecond | Should -BeGreaterThan ($expectedSmoothedBytesPerSecond - 1)
            $window.SmoothedBytesPerSecond | Should -BeLessThan ($expectedSmoothedBytesPerSecond + 1)
        }

        It 'keeps the prior smoothed value when the instantaneous delta goes backwards (rotation/truncation glitch, defensive guard)' {
            $window = @{
                Samples = @(
                    @{ Bytes = 1000000; TimestampEpochSeconds = 0 }
                    @{ Bytes = 2000000; TimestampEpochSeconds = 1 }
                )
                SmoothedBytesPerSecond = 1500000.0
            }

            $window = Update-GrowthRateWindow -Window $window -BytesTotal 100 -TimestampEpochSeconds 2 -SmoothingSeconds 30

            $window.SmoothedBytesPerSecond | Should -Be 1500000.0
        }

        It 'keeps the prior smoothed value when dt is zero between the immediately-previous and new sample' {
            $window = @{
                Samples = @(
                    @{ Bytes = 1000000; TimestampEpochSeconds = 5 }
                )
                SmoothedBytesPerSecond = 999999.0
            }

            $window = Update-GrowthRateWindow -Window $window -BytesTotal 2000000 -TimestampEpochSeconds 5 -SmoothingSeconds 30

            $window.SmoothedBytesPerSecond | Should -Be 999999.0
        }

        It 'leaves Samples and AverageBytesPerSecond byte-for-byte unchanged regardless of SmoothingSeconds' {
            $windowWithSmoothing = @()
            $windowWithoutSmoothing = @()
            foreach ($i in 0..10) {
                $windowWithSmoothing = Update-GrowthRateWindow -Window $windowWithSmoothing -BytesTotal ($i * 1000000) -TimestampEpochSeconds $i -SmoothingSeconds 30
                $windowWithoutSmoothing = Update-GrowthRateWindow -Window $windowWithoutSmoothing -BytesTotal ($i * 1000000) -TimestampEpochSeconds $i
            }

            $windowWithSmoothing.AverageBytesPerSecond | Should -Be $windowWithoutSmoothing.AverageBytesPerSecond
            $windowWithSmoothing.Samples.Count | Should -Be $windowWithoutSmoothing.Samples.Count
        }

        It 'MANDATORY (resilience-critical): smooths a bursty growth-rate estimate into a tight band around the true mean, while the raw window spread is demonstrably wider (DASH-BRIEF-1/2 regression gate)' {
            $meanBytesPerSecond = 3250000.0
            $pollIntervalSeconds = 0.25
            $meanBytesPerPoll = $meanBytesPerSecond * $pollIntervalSeconds   # 812,500 B/poll
            $smoothingTauSeconds = 30
            # Long enough that the EWMA (tau=30s) has genuinely settled before the
            # measurement window starts -- 480 polls = 120s = 4 tau (error ~1.8%),
            # comfortably inside the +/-15% tight-band assertion below. A shorter
            # warm-up (e.g. half of a 60s run) still shows the filter's transient
            # RISE toward the mean, not its steady-state behavior -- that transient
            # is not the defect this test proves, so it must be warmed past.
            $warmupPolls = 480    # 120s of settling before measuring
            $totalPolls = 800     # 200s total: 120s warm-up + 80s measurement window

            $window = @()
            $cumulativeBytes = 0.0
            $smoothedHistory = [System.Collections.Generic.List[double]]::new()
            $averageHistory  = [System.Collections.Generic.List[double]]::new()

            for ($pollIndex = 1; $pollIndex -le $totalPolls; $pollIndex++) {
                # A 4x flush every 4th poll, nothing on the others -- a bursty arrival
                # pattern whose deltas alternate around the 26 Mbit-equivalent mean.
                $deltaThisPoll = if (($pollIndex % 4) -eq 0) { 4 * $meanBytesPerPoll } else { 0 }
                $cumulativeBytes += $deltaThisPoll
                $timestampEpochSeconds = $pollIndex * $pollIntervalSeconds

                $window = Update-GrowthRateWindow -Window $window -BytesTotal ([long] $cumulativeBytes) -TimestampEpochSeconds $timestampEpochSeconds -SmoothingSeconds $smoothingTauSeconds

                $smoothedHistory.Add($window.SmoothedBytesPerSecond)
                $averageHistory.Add($window.AverageBytesPerSecond)
            }

            # Warm-up: skip the settling period so both series are measured only
            # once the EWMA has reached its genuine steady-state behavior.
            $warmedUpSmoothed = @($smoothedHistory | Select-Object -Skip $warmupPolls)
            $warmedUpAverage  = @($averageHistory  | Select-Object -Skip $warmupPolls)

            # (a) SmoothedBytesPerSecond stays within a tight band of the true mean.
            foreach ($smoothedValue in $warmedUpSmoothed) {
                $smoothedValue | Should -BeGreaterThan ($meanBytesPerSecond * 0.85)
                $smoothedValue | Should -BeLessThan ($meanBytesPerSecond * 1.15)
            }

            # (b) the raw AverageBytesPerSecond spread is demonstrably WIDER than the
            # smoothed spread -- proves the fix is not a no-op.
            $smoothedSpreadFraction = (($warmedUpSmoothed | Measure-Object -Maximum).Maximum - ($warmedUpSmoothed | Measure-Object -Minimum).Minimum) / $meanBytesPerSecond
            $averageSpreadFraction  = (($warmedUpAverage  | Measure-Object -Maximum).Maximum - ($warmedUpAverage  | Measure-Object -Minimum).Minimum) / $meanBytesPerSecond
            $averageSpreadFraction | Should -BeGreaterThan $smoothedSpreadFraction

            # (c) a derived Get-SecondsBehindLive with a FIXED bytesBehind stays in a
            # tight band divided by smoothed, but swings wide divided by raw.
            $fixedBytesBehind = [long] ($meanBytesPerSecond * 8)   # a fixed 8s-behind-live snapshot
            $smoothedSecondsBehind = @($warmedUpSmoothed | ForEach-Object { Get-SecondsBehindLive -BytesBehind $fixedBytesBehind -BytesPerSecond $_ })
            $averageSecondsBehind  = @($warmedUpAverage  | ForEach-Object { Get-SecondsBehindLive -BytesBehind $fixedBytesBehind -BytesPerSecond $_ })
            $smoothedSecondsSpread = ($smoothedSecondsBehind | Measure-Object -Maximum).Maximum - ($smoothedSecondsBehind | Measure-Object -Minimum).Minimum
            $averageSecondsSpread  = ($averageSecondsBehind  | Measure-Object -Maximum).Maximum - ($averageSecondsBehind  | Measure-Object -Minimum).Minimum
            $averageSecondsSpread | Should -BeGreaterThan $smoothedSecondsSpread
            ($smoothedSecondsBehind | Measure-Object -Maximum).Maximum | Should -BeLessThan 9.2
            ($smoothedSecondsBehind | Measure-Object -Minimum).Minimum | Should -BeGreaterThan 6.8

            # (d) the catch-up cap fed the smoothed rate never spikes on a burst.
            $catchUpCeilings = @($warmedUpSmoothed | ForEach-Object { Get-CatchUpSendCeiling -CatchUpMultiplier 1.5 -ObservedBytesPerSecond $_ -ColdStartCeilingBytesPerSecond 750000 })
            $maxAllowedCeiling = 1.5 * $meanBytesPerSecond * 1.15
            ($catchUpCeilings | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual $maxAllowedCeiling
        }
    }

    Context 'Update-LiveTunableDialValues (DIAL-01 pure repoll-and-apply seam)' {
        # 14.5-08: the cross-process live-apply half of the dials. This is the pure
        # compare-and-apply core of pusher.ps1's hot-loop repoll -- given the CURRENT
        # in-memory dial values and a Read-LiveTunableOverrides result (14.5-07,
        # $null-per-property = "no override"), decide the (possibly updated) working
        # values plus a per-dial Changed flag so the caller (pusher.ps1) logs the
        # old->new transition ONLY on an actual change (T-14.5-08-03, no per-tick
        # log-spam). No .env I/O, no Write-Log call -- kept 100% pure so this seam is
        # Pester-testable independent of the hot loop (D-08 pattern, matches every
        # other function in this module).

        It 'exports Update-LiveTunableDialValues' {
            Get-Command -Module Pacer -Name Update-LiveTunableDialValues | Should -Not -BeNullOrEmpty
        }

        It 'applies a changed CatchUpMultiplier override and flags it changed, with the previous value recorded' {
            $overrides = [pscustomobject]@{ CatchUpMultiplier = 2.5; SendCeilingBytesPerSecond = $null }

            $result = Update-LiveTunableDialValues -CurrentCatchUpMultiplier 1.5 -CurrentAbsoluteSendCeilingBytesPerSecond 0 -Overrides $overrides

            $result.CatchUpMultiplier | Should -Be 2.5
            $result.CatchUpMultiplierChanged | Should -BeTrue
            $result.PreviousCatchUpMultiplier | Should -Be 1.5
        }

        It 'leaves CatchUpMultiplier unchanged (and unflagged) when the override equals the current value' {
            $overrides = [pscustomobject]@{ CatchUpMultiplier = 1.5; SendCeilingBytesPerSecond = $null }

            $result = Update-LiveTunableDialValues -CurrentCatchUpMultiplier 1.5 -CurrentAbsoluteSendCeilingBytesPerSecond 0 -Overrides $overrides

            $result.CatchUpMultiplier | Should -Be 1.5
            $result.CatchUpMultiplierChanged | Should -BeFalse
        }

        It 'keeps the current CatchUpMultiplier unchanged when the override is null (no-signal safe default)' {
            $overrides = [pscustomobject]@{ CatchUpMultiplier = $null; SendCeilingBytesPerSecond = $null }

            $result = Update-LiveTunableDialValues -CurrentCatchUpMultiplier 1.5 -CurrentAbsoluteSendCeilingBytesPerSecond 0 -Overrides $overrides

            $result.CatchUpMultiplier | Should -Be 1.5
            $result.CatchUpMultiplierChanged | Should -BeFalse
        }

        It 'applies a changed SendCeilingBytesPerSecond override and flags it changed, with the previous value recorded' {
            $overrides = [pscustomobject]@{ CatchUpMultiplier = $null; SendCeilingBytesPerSecond = 4000000 }

            $result = Update-LiveTunableDialValues -CurrentCatchUpMultiplier 1.5 -CurrentAbsoluteSendCeilingBytesPerSecond 0 -Overrides $overrides

            $result.AbsoluteSendCeilingBytesPerSecond | Should -Be 4000000
            $result.AbsoluteSendCeilingBytesPerSecondChanged | Should -BeTrue
            $result.PreviousAbsoluteSendCeilingBytesPerSecond | Should -Be 0
        }

        It 'leaves SendCeilingBytesPerSecond unchanged (and unflagged) when the override equals the current value, including the 0=off case' {
            $overrides = [pscustomobject]@{ CatchUpMultiplier = $null; SendCeilingBytesPerSecond = 0 }

            $result = Update-LiveTunableDialValues -CurrentCatchUpMultiplier 1.5 -CurrentAbsoluteSendCeilingBytesPerSecond 0 -Overrides $overrides

            $result.AbsoluteSendCeilingBytesPerSecond | Should -Be 0
            $result.AbsoluteSendCeilingBytesPerSecondChanged | Should -BeFalse
        }

        It 'keeps the current SendCeilingBytesPerSecond unchanged when the override is null (no-signal safe default)' {
            $overrides = [pscustomobject]@{ CatchUpMultiplier = $null; SendCeilingBytesPerSecond = $null }

            $result = Update-LiveTunableDialValues -CurrentCatchUpMultiplier 1.5 -CurrentAbsoluteSendCeilingBytesPerSecond 3000000 -Overrides $overrides

            $result.AbsoluteSendCeilingBytesPerSecond | Should -Be 3000000
            $result.AbsoluteSendCeilingBytesPerSecondChanged | Should -BeFalse
        }

        It 'a fully-null override (simulated torn .env read) retains BOTH current values exactly, neither flagged changed (T-14.5-08-02 safe default)' {
            $overrides = [pscustomobject]@{ CatchUpMultiplier = $null; SendCeilingBytesPerSecond = $null }

            $result = Update-LiveTunableDialValues -CurrentCatchUpMultiplier 1.8 -CurrentAbsoluteSendCeilingBytesPerSecond 5000000 -Overrides $overrides

            $result.CatchUpMultiplier | Should -Be 1.8
            $result.CatchUpMultiplierChanged | Should -BeFalse
            $result.AbsoluteSendCeilingBytesPerSecond | Should -Be 5000000
            $result.AbsoluteSendCeilingBytesPerSecondChanged | Should -BeFalse
        }

        It 'applies each dial independently -- one changing does not affect or flag the other' {
            $overrides = [pscustomobject]@{ CatchUpMultiplier = 2.0; SendCeilingBytesPerSecond = $null }

            $result = Update-LiveTunableDialValues -CurrentCatchUpMultiplier 1.5 -CurrentAbsoluteSendCeilingBytesPerSecond 6000000 -Overrides $overrides

            $result.CatchUpMultiplier | Should -Be 2.0
            $result.CatchUpMultiplierChanged | Should -BeTrue
            $result.AbsoluteSendCeilingBytesPerSecond | Should -Be 6000000
            $result.AbsoluteSendCeilingBytesPerSecondChanged | Should -BeFalse
        }
    }
}

Describe 'Live dial repoll-and-apply full pipeline (DIAL-01, Config.psm1 -> Pacer.psm1)' -Tag 'Quick' {
    # 14.5-08 Task 2: proves the WHOLE cross-process chain the hot loop actually runs
    # each ~1s tick -- a real fixture .env read via Read-LiveTunableOverrides
    # (lib/Config.psm1, 14.5-07's scope-fenced two-key reader), fed through
    # Update-LiveTunableDialValues (this plan's pure compare-and-apply seam), whose
    # result then changes Get-CatchUpSendCeiling's effective cap -- deterministically,
    # with no live stream/dashboard process involved. The full cross-process
    # end-to-end proof (moving the dashboard slider mid-stream and watching the Send
    # bitrate change) is recorded separately as an operator human-check (see SUMMARY).

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Pacer -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:ConfigModulePath -Force
        Import-Module $script:PacerModulePath -Force
    }

    AfterEach {
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Pacer -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It '(a) a changed CatchUpMultiplier in a fixture .env is applied and feeds Get-CatchUpSendCeiling to a DIFFERENT effective cap' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "CATCH_UP_MULTIPLIER=2.5`n")

        $currentCatchUpMultiplier = 1.5
        $currentAbsoluteSendCeilingBytesPerSecond = 0
        $observedBytesPerSecond = 1000000
        $coldStartCeilingBytesPerSecond = 500000

        $ceilingBeforeRepoll = Get-CatchUpSendCeiling -CatchUpMultiplier $currentCatchUpMultiplier -ObservedBytesPerSecond $observedBytesPerSecond -ColdStartCeilingBytesPerSecond $coldStartCeilingBytesPerSecond -AbsoluteCeilingBytesPerSecond $currentAbsoluteSendCeilingBytesPerSecond

        $overrides = Read-LiveTunableOverrides -Path $envPath
        $applyResult = Update-LiveTunableDialValues -CurrentCatchUpMultiplier $currentCatchUpMultiplier -CurrentAbsoluteSendCeilingBytesPerSecond $currentAbsoluteSendCeilingBytesPerSecond -Overrides $overrides

        $ceilingAfterRepoll = Get-CatchUpSendCeiling -CatchUpMultiplier $applyResult.CatchUpMultiplier -ObservedBytesPerSecond $observedBytesPerSecond -ColdStartCeilingBytesPerSecond $coldStartCeilingBytesPerSecond -AbsoluteCeilingBytesPerSecond $applyResult.AbsoluteSendCeilingBytesPerSecond

        $applyResult.CatchUpMultiplierChanged | Should -BeTrue
        $ceilingBeforeRepoll | Should -Be 1500000
        $ceilingAfterRepoll | Should -Be 2500000
        $ceilingAfterRepoll | Should -Not -Be $ceilingBeforeRepoll
    }

    It '(a) a changed SendCeilingBytesPerSecond in a fixture .env is applied and feeds Get-CatchUpSendCeiling to a DIFFERENT effective cap' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "SEND_CEILING_BYTES_PER_SECOND=4000000`n")

        $currentCatchUpMultiplier = 1.5
        $currentAbsoluteSendCeilingBytesPerSecond = 0
        $observedBytesPerSecond = 1000000
        $coldStartCeilingBytesPerSecond = 500000

        $overrides = Read-LiveTunableOverrides -Path $envPath
        $applyResult = Update-LiveTunableDialValues -CurrentCatchUpMultiplier $currentCatchUpMultiplier -CurrentAbsoluteSendCeilingBytesPerSecond $currentAbsoluteSendCeilingBytesPerSecond -Overrides $overrides

        $ceilingAfterRepoll = Get-CatchUpSendCeiling -CatchUpMultiplier $applyResult.CatchUpMultiplier -ObservedBytesPerSecond $observedBytesPerSecond -ColdStartCeilingBytesPerSecond $coldStartCeilingBytesPerSecond -AbsoluteCeilingBytesPerSecond $applyResult.AbsoluteSendCeilingBytesPerSecond

        $applyResult.AbsoluteSendCeilingBytesPerSecondChanged | Should -BeTrue
        $ceilingAfterRepoll | Should -Be 4000000
    }

    It '(b) an unchanged fixture .env value produces no change (and would emit no log transition)' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "CATCH_UP_MULTIPLIER=1.5`n")

        $overrides = Read-LiveTunableOverrides -Path $envPath
        $applyResult = Update-LiveTunableDialValues -CurrentCatchUpMultiplier 1.5 -CurrentAbsoluteSendCeilingBytesPerSecond 0 -Overrides $overrides

        $applyResult.CatchUpMultiplierChanged | Should -BeFalse
        $applyResult.CatchUpMultiplier | Should -Be 1.5
    }

    It '(c) a non-dial key change in the fixture .env (RELAY_HOST) is ignored -- the running target is unaffected (scope fence)' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "RELAY_HOST=10.0.0.99`nRELAY_PORT=9999`n")

        $overrides = Read-LiveTunableOverrides -Path $envPath
        $applyResult = Update-LiveTunableDialValues -CurrentCatchUpMultiplier 1.5 -CurrentAbsoluteSendCeilingBytesPerSecond 3000000 -Overrides $overrides

        $overrides.PSObject.Properties.Name | Should -Not -Contain 'RelayHost'
        $applyResult.CatchUpMultiplierChanged | Should -BeFalse
        $applyResult.CatchUpMultiplier | Should -Be 1.5
        $applyResult.AbsoluteSendCeilingBytesPerSecondChanged | Should -BeFalse
        $applyResult.AbsoluteSendCeilingBytesPerSecond | Should -Be 3000000
    }

    It '(d) a torn/locked .env read retains the current values through the whole pipeline (never throws)' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "CATCH_UP_MULTIPLIER=2.0`nSEND_CEILING_BYTES_PER_SECOND=5000000`n")

        $lockedStream = [System.IO.File]::Open($envPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            { $script:overrides = Read-LiveTunableOverrides -Path $envPath } | Should -Not -Throw
            $applyResult = Update-LiveTunableDialValues -CurrentCatchUpMultiplier 1.8 -CurrentAbsoluteSendCeilingBytesPerSecond 6000000 -Overrides $script:overrides

            $applyResult.CatchUpMultiplierChanged | Should -BeFalse
            $applyResult.CatchUpMultiplier | Should -Be 1.8
            $applyResult.AbsoluteSendCeilingBytesPerSecondChanged | Should -BeFalse
            $applyResult.AbsoluteSendCeilingBytesPerSecond | Should -Be 6000000
        } finally {
            $lockedStream.Close()
        }
    }
}

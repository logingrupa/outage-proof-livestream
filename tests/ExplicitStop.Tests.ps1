# ExplicitStop.Tests.ps1
# Unit tests for the THIRD way into the Streaming -> Draining -> Stopped lifecycle:
# the operator's explicit stop (locked design extension, item 6).
#
# WHY A THIRD SIGNAL. Phase 3 gave Get-EndOfServiceDecision two ways in, both
# heuristic: (a) OBS confirmed dead AND growth stalled past the sustained window
# (D-07), and (b) growth stalled past the longer degraded window when OBS liveness
# is uninspectable (D-09). Both are the pusher GUESSING that the service ended.
# stop.ps1 is not a guess -- it is the operator saying so. It is therefore strictly
# MORE trustworthy than either heuristic and must need none of their evidence: no
# sustained window, no degraded window, no growth stall, no OBS inspection at all.
#
# WHY IT DRAINS RATHER THAN KILLS. During catch-up the pusher is BEHIND LIVE (7689s
# behind in the phase-4 outage test). Killing it there abandons the entire un-sent
# backlog -- deliberate content loss in the one system whose whole reason to exist is
# zero content loss. So the explicit signal enters the SAME Draining path the two
# heuristics already enter (pusher.ps1's final-drain loop), sends the remaining bytes,
# and exits 0. That end-to-end behaviour is proven in
# tests/Integration.ExplicitStop.Tests.ps1; this file pins the pure decision.
#
# The regression Context below is not filler: Get-EndOfServiceDecision is the sole
# terminal-stop authority for a live church service, and the two heuristics must keep
# behaving EXACTLY as they did before a third signal was threaded through them.

BeforeAll {
    $script:LoggingModulePath = Join-Path $PSScriptRoot '../lib/Logging.psm1'
    $script:RotationModulePath = Join-Path $PSScriptRoot '../lib/Rotation.psm1'
}

Describe 'ExplicitStop' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Rotation -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:RotationModulePath -Force
    }

    AfterEach {
        Remove-Module Rotation -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    Context 'Get-EndOfServiceDecision -ExplicitStopRequested (the operator outranks both heuristics)' {

        It 'returns Draining on an explicit stop even though OBS is alive and growth has not stalled at all (needs neither heuristic signal)' {
            # The exact gap this extension closes: OBS is still recording, the file is
            # still growing, so BOTH heuristics say Continue forever -- and today the
            # operator's Stop therefore stops nothing. GrowthStalledSeconds 0 + OBS
            # alive is the strongest possible statement of "no heuristic evidence".
            Get-EndOfServiceDecision -GrowthStalledSeconds 0 -ObsLivenessResult $true `
                -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 -ExplicitStopRequested $true |
                Should -Be 'Draining'
        }

        It 'returns Draining on an explicit stop without waiting for the sustained window (the operator has already decided)' {
            # A live OBS is deliberately never end-of-service (D-07/D-08). The explicit
            # signal must not be filtered through that rule -- pinned separately from
            # the case above because "OBS alive" is exactly the input that makes
            # Get-EndOfServiceDecision return Continue no matter how long the stall is.
            Get-EndOfServiceDecision -GrowthStalledSeconds 0.001 -ObsLivenessResult $true `
                -SustainedWindowSeconds 3600 -DegradedWindowSeconds 7200 -ExplicitStopRequested $true |
                Should -Be 'Draining' -Because 'an explicit operator stop must never wait out a heuristic window'
        }

        It 'returns Draining on an explicit stop even when OBS liveness is uninspectable and the degraded window has not elapsed (D-09 needs no consulting)' {
            Get-EndOfServiceDecision -GrowthStalledSeconds 0 -ObsLivenessResult $null `
                -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 -ExplicitStopRequested $true |
                Should -Be 'Draining'
        }

        It 'returns Draining on an explicit stop when OBS is confirmed dead too (the signals agreeing must not somehow un-stop it)' {
            Get-EndOfServiceDecision -GrowthStalledSeconds 0 -ObsLivenessResult $false `
                -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 -ExplicitStopRequested $true |
                Should -Be 'Draining'
        }
    }

    Context 'Get-EndOfServiceDecision regression: the two Phase 3 heuristics behave identically (D-07/D-09 unchanged)' {

        It 'still returns Draining when both signals agree and no explicit stop was requested (D-07 path (a) intact)' {
            Get-EndOfServiceDecision -GrowthStalledSeconds 31 -ObsLivenessResult $false `
                -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 -ExplicitStopRequested $false |
                Should -Be 'Draining'
        }

        It 'still returns Draining on the degraded single signal when no explicit stop was requested (D-09 path (b) intact)' {
            Get-EndOfServiceDecision -GrowthStalledSeconds 91 -ObsLivenessResult $null `
                -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 -ExplicitStopRequested $false |
                Should -Be 'Draining'
        }

        It 'still returns Continue for a live OBS with a long stall when no explicit stop was requested (pause-not-stop intact)' {
            # The single most important negative: a church service pauses (nobody
            # speaking, OBS still recording) and the pusher must NOT stop.
            Get-EndOfServiceDecision -GrowthStalledSeconds 6000 -ObsLivenessResult $true `
                -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 -ExplicitStopRequested $false |
                Should -Be 'Continue'
        }

        It 'still returns Continue when OBS is dead but the stall is shorter than the sustained window and no explicit stop was requested' {
            Get-EndOfServiceDecision -GrowthStalledSeconds 10 -ObsLivenessResult $false `
                -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 -ExplicitStopRequested $false |
                Should -Be 'Continue'
        }

        It 'still returns Continue on the degraded path short of the degraded window when no explicit stop was requested' {
            Get-EndOfServiceDecision -GrowthStalledSeconds 60 -ObsLivenessResult $null `
                -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 -ExplicitStopRequested $false |
                Should -Be 'Continue'
        }

        It 'keeps ExplicitStopRequested optional so every Phase 3 call shape still binds and still decides identically' {
            # tests/EndDetection.Tests.ps1 and pusher.ps1's own call sites pass no such
            # parameter. Making it Mandatory would break the automatic path at runtime
            # -- i.e. break end-of-service detection for every real service -- while
            # this file's other tests stayed green. Pinned so that cannot happen.
            Get-EndOfServiceDecision -GrowthStalledSeconds 31 -ObsLivenessResult $false `
                -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 | Should -Be 'Draining'
            Get-EndOfServiceDecision -GrowthStalledSeconds 60 -ObsLivenessResult $true `
                -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 | Should -Be 'Continue'
            Get-EndOfServiceDecision -GrowthStalledSeconds 91 -ObsLivenessResult $null `
                -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 | Should -Be 'Draining'
        }

        It 'defaults an omitted ExplicitStopRequested to "no stop requested" rather than to a stop' {
            # If the default ever flipped to $true, EVERY call site would drain
            # instantly and every church service would end the moment it started.
            Get-EndOfServiceDecision -GrowthStalledSeconds 0 -ObsLivenessResult $true `
                -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 | Should -Be 'Continue'
        }
    }
}

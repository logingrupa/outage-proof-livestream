# ProbeHost.Tests.ps1
# Unit + real-timing tests for lib/ProbeHost.psm1 -- the isolation engine that makes
# MON-05 structural rather than hopeful (06-04-PLAN.md). Covers: per-probe hard
# timeout (Invoke-ProbeWithTimeout), discovery + enable-flag gating (D-03,
# Get-EnabledProbeModulePaths), and the scheduler loop (Invoke-ProbeHostLoop) that
# persists each result via ProbeStore.psm1's Save-ProbeResult.
#
# Mirrors tests/Supervisor.Tests.ps1's fault-isolation/mocked-runspace test style
# (06-PATTERNS.md). The hanging-fixture real-timing test is tagged 'Integration'
# (real wall-clock, not mocked) -- `Invoke-Pester -Tag Quick` never runs it, matching
# how this repo already keeps real-ffmpeg/SRT tests out of the fast loop.

BeforeAll {
    $script:LoggingModulePath = Join-Path $PSScriptRoot '../lib/Logging.psm1'
    $script:ClockModulePath = Join-Path $PSScriptRoot '../lib/Clock.psm1'
    $script:ProbeStoreModulePath = Join-Path $PSScriptRoot '../lib/ProbeStore.psm1'
    $script:ProbeHostModulePath = Join-Path $PSScriptRoot '../lib/ProbeHost.psm1'
    $script:HangingProbeFixturePath = Join-Path $PSScriptRoot 'fixtures/HangingProbe.psm1'
    $script:MalformedProbeFixturePath = Join-Path $PSScriptRoot 'fixtures/MalformedProbe.psm1'
}

Describe 'Get-EnabledProbeModulePaths (D-03 discovery + enable-flag gate)' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module ProbeHost -ErrorAction SilentlyContinue
        Remove-Module ProbeStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:ClockModulePath -Force
        Import-Module $script:ProbeStoreModulePath -Force
        Import-Module $script:ProbeHostModulePath -Force

        $script:ProbeHostTestRoot = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:ProbeHostTestRoot -Force | Out-Null
        $script:TestProbesDirectory = Join-Path $script:ProbeHostTestRoot 'probes'
        New-Item -ItemType Directory -Path $script:TestProbesDirectory -Force | Out-Null
    }

    AfterEach {
        Remove-Module ProbeHost -ErrorAction SilentlyContinue
        Remove-Module ProbeStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'returns only a discovered module whose mapped Config enable property is true' {
        Copy-Item -LiteralPath $script:HangingProbeFixturePath -Destination (Join-Path $script:TestProbesDirectory 'vps.psm1')
        $fakeConfig = [pscustomobject]@{ ProbeVpsEnabled = $true }

        $enabledPaths = Get-EnabledProbeModulePaths -ProbesDirectory $script:TestProbesDirectory -Config $fakeConfig

        $enabledPaths.Count | Should -Be 1
        $enabledPaths[0] | Should -Match ([regex]::Escape('vps.psm1'))
    }

    It 'excludes a discovered module whose mapped Config enable property is false' {
        Copy-Item -LiteralPath $script:HangingProbeFixturePath -Destination (Join-Path $script:TestProbesDirectory 'vps.psm1')
        $fakeConfig = [pscustomobject]@{ ProbeVpsEnabled = $false }

        $enabledPaths = Get-EnabledProbeModulePaths -ProbesDirectory $script:TestProbesDirectory -Config $fakeConfig

        $enabledPaths.Count | Should -Be 0
    }

    It 'defaults an unrecognized module stem to disabled -- a probe type the Config object has no matching property for is never silently activated' {
        Copy-Item -LiteralPath $script:HangingProbeFixturePath -Destination (Join-Path $script:TestProbesDirectory 'unrecognized.psm1')
        $fakeConfig = [pscustomobject]@{ ProbeVpsEnabled = $true }

        $enabledPaths = Get-EnabledProbeModulePaths -ProbesDirectory $script:TestProbesDirectory -Config $fakeConfig

        $enabledPaths.Count | Should -Be 0
    }

    It 'returns an empty array, never $null, when the probes directory does not exist (MON-04 zero-probe baseline)' {
        $missingDirectory = Join-Path $script:ProbeHostTestRoot 'does-not-exist'
        $fakeConfig = [pscustomobject]@{ ProbeVpsEnabled = $true }

        $enabledPaths = Get-EnabledProbeModulePaths -ProbesDirectory $missingDirectory -Config $fakeConfig

        ($null -eq $enabledPaths) | Should -BeFalse
        $enabledPaths.Count | Should -Be 0
    }

    It 'returns an empty array, never $null, when the probes directory exists but is empty' {
        $fakeConfig = [pscustomobject]@{ ProbeVpsEnabled = $true }

        $enabledPaths = Get-EnabledProbeModulePaths -ProbesDirectory $script:TestProbesDirectory -Config $fakeConfig

        ($null -eq $enabledPaths) | Should -BeFalse
        $enabledPaths.Count | Should -Be 0
    }
}

Describe 'Invoke-ProbeWithTimeout (completed-in-time branch)' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module ProbeHost -ErrorAction SilentlyContinue
        Remove-Module ProbeStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:ClockModulePath -Force
        Import-Module $script:ProbeStoreModulePath -Force
        Import-Module $script:ProbeHostModulePath -Force

        $script:FastProbeModulePath = Join-Path $TestDrive ('FastProbe-{0}.psm1' -f ([Guid]::NewGuid()))
        Set-Content -LiteralPath $script:FastProbeModulePath -Encoding utf8 -Value @'
Set-StrictMode -Version Latest
function Invoke-Probe {
    param($Config)
    return [pscustomobject]@{ name = 'fast'; title = 'Fast Probe'; status = 'ok'; metrics = @(); detail = $null }
}
Export-ModuleMember -Function Invoke-Probe
'@
    }

    AfterEach {
        Remove-Module ProbeHost -ErrorAction SilentlyContinue
        Remove-Module ProbeStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'returns the probe result object unchanged when it completes well before the hard timeout' {
        $result = Invoke-ProbeWithTimeout -ProbeModulePath $script:FastProbeModulePath -ProbeConfig ([pscustomobject]@{}) -HardTimeoutMilliseconds 5000

        $result.name | Should -Be 'fast'
        $result.title | Should -Be 'Fast Probe'
        $result.status | Should -Be 'ok'
        $result.detail | Should -BeNullOrEmpty
    }
}

# Real-timing test: proves the abandonment actually happens within the configured
# hard timeout (not the fixture's 60s sleep) -- not mocked, real wall-clock.
Describe 'Invoke-ProbeWithTimeout (MON-05 hard-timeout abandonment)' -Tag 'Integration' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module ProbeHost -ErrorAction SilentlyContinue
        Remove-Module ProbeStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:ClockModulePath -Force
        Import-Module $script:ProbeStoreModulePath -Force
        Import-Module $script:ProbeHostModulePath -Force
    }

    AfterEach {
        Remove-Module ProbeHost -ErrorAction SilentlyContinue
        Remove-Module ProbeStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'abandons a deliberately-hanging probe within its hard timeout (NOT the fixtures 60s sleep) and returns status=unknown with a timeout detail' {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $result = Invoke-ProbeWithTimeout -ProbeModulePath $script:HangingProbeFixturePath -ProbeConfig ([pscustomobject]@{}) -HardTimeoutMilliseconds 500

        $stopwatch.Stop()

        $result.status | Should -Be 'unknown'
        $result.detail | Should -Match 'timed out'
        # Generous margin above the 500ms hard timeout, but nowhere near the
        # fixture's 60-second sleep -- proves the WaitOne/.Stop() abandonment
        # mechanism actually fired rather than blocking until the fixture returned.
        $stopwatch.Elapsed.TotalMilliseconds | Should -BeLessThan 10000
    }
}

Describe 'Invoke-ProbeHostLoop (scheduler + persistence)' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module ProbeHost -ErrorAction SilentlyContinue
        Remove-Module ProbeStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:ClockModulePath -Force
        Import-Module $script:ProbeStoreModulePath -Force
        Import-Module $script:ProbeHostModulePath -Force

        $script:ProbeHostLoopTestRoot = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:ProbeHostLoopTestRoot -Force | Out-Null
        $script:TestProbesDirectory = Join-Path $script:ProbeHostLoopTestRoot 'probes'
        New-Item -ItemType Directory -Path $script:TestProbesDirectory -Force | Out-Null
        $script:TestStateProbesDirectory = Join-Path $script:ProbeHostLoopTestRoot 'state/probes'

        $script:FastProbeModulePath = Join-Path $TestDrive ('FastProbe-{0}.psm1' -f ([Guid]::NewGuid()))
        Set-Content -LiteralPath $script:FastProbeModulePath -Encoding utf8 -Value @'
Set-StrictMode -Version Latest
function Invoke-Probe {
    param($Config)
    return [pscustomobject]@{ name = 'fast'; title = 'Fast Probe'; status = 'ok'; metrics = @(); detail = $null }
}
Export-ModuleMember -Function Invoke-Probe
'@
    }

    AfterEach {
        Remove-Module ProbeHost -ErrorAction SilentlyContinue
        Remove-Module ProbeStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'calls Save-ProbeResult exactly once for a single enabled probe over one cycle, with the normalized fields' {
        Copy-Item -LiteralPath $script:FastProbeModulePath -Destination (Join-Path $script:TestProbesDirectory 'vps.psm1')
        $fakeConfig = [pscustomobject]@{ ProbeVpsEnabled = $true }
        Mock -ModuleName ProbeHost Save-ProbeResult { }

        Invoke-ProbeHostLoop -ProbesDirectory $script:TestProbesDirectory -Config $fakeConfig `
            -HardTimeoutMilliseconds 2000 -PollIntervalSeconds 0 -StateProbesDirectory $script:TestStateProbesDirectory -MaxCycles 1

        Should -Invoke -ModuleName ProbeHost Save-ProbeResult -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'fast' -and $Title -eq 'Fast Probe' -and $Status -eq 'ok'
        }
    }

    It 'MON-05 isolation: a cycle containing both a hung probe and a fast probe still persists the fast probes result' {
        Copy-Item -LiteralPath $script:HangingProbeFixturePath -Destination (Join-Path $script:TestProbesDirectory 'vps.psm1')
        Copy-Item -LiteralPath $script:FastProbeModulePath -Destination (Join-Path $script:TestProbesDirectory 'fast.psm1')
        $fakeConfig = [pscustomobject]@{ ProbeVpsEnabled = $true; ProbeFastEnabled = $true }
        Mock -ModuleName ProbeHost Save-ProbeResult { }

        Invoke-ProbeHostLoop -ProbesDirectory $script:TestProbesDirectory -Config $fakeConfig `
            -HardTimeoutMilliseconds 500 -PollIntervalSeconds 0 -StateProbesDirectory $script:TestStateProbesDirectory -MaxCycles 1

        Should -Invoke -ModuleName ProbeHost Save-ProbeResult -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'fast' -and $Status -eq 'ok'
        }
    }

    It 'T-06-08: a malformed probe result (missing status, non-array metrics) is normalized to a safe status rather than crashing the cycle' {
        Copy-Item -LiteralPath $script:MalformedProbeFixturePath -Destination (Join-Path $script:TestProbesDirectory 'vps.psm1')
        $fakeConfig = [pscustomobject]@{ ProbeVpsEnabled = $true }
        Mock -ModuleName ProbeHost Save-ProbeResult { }

        { Invoke-ProbeHostLoop -ProbesDirectory $script:TestProbesDirectory -Config $fakeConfig `
            -HardTimeoutMilliseconds 2000 -PollIntervalSeconds 0 -StateProbesDirectory $script:TestStateProbesDirectory -MaxCycles 1 } | Should -Not -Throw

        Should -Invoke -ModuleName ProbeHost Save-ProbeResult -Times 1 -Exactly -ParameterFilter {
            $Status -in @('ok', 'degraded', 'down', 'unknown') -and ($Metrics -is [array])
        }
    }
}

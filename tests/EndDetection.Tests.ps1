BeforeAll {
    $script:LoggingModulePath = Join-Path $PSScriptRoot '../lib/Logging.psm1'
    $script:RotationModulePath = Join-Path $PSScriptRoot '../lib/Rotation.psm1'
}

Describe 'EndDetection' -Tag 'Quick' {

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

    Context 'Get-EndOfServiceDecision' {

        It 'returns Continue when OBS is alive even if growth has stalled past the sustained window (D-07/D-08 two-signal AND)' {
            Get-EndOfServiceDecision -GrowthStalledSeconds 60 -ObsLivenessResult $true -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 | Should -Be 'Continue'
        }

        It 'returns Draining when both signals agree (OBS dead AND growth stalled past sustained window, D-07)' {
            Get-EndOfServiceDecision -GrowthStalledSeconds 31 -ObsLivenessResult $false -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 | Should -Be 'Draining'
        }

        It 'returns Continue when OBS is dead but the stall is shorter than the sustained window' {
            Get-EndOfServiceDecision -GrowthStalledSeconds 10 -ObsLivenessResult $false -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 | Should -Be 'Continue'
        }

        It 'degrades to the longer degraded window when liveness is uninspectable ($null, D-09) -- stall short of the degraded window returns Continue' {
            Get-EndOfServiceDecision -GrowthStalledSeconds 60 -ObsLivenessResult $null -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 | Should -Be 'Continue'
        }

        It 'degrades to the longer degraded window when liveness is uninspectable ($null, D-09) -- stall past the degraded window returns Draining' {
            Get-EndOfServiceDecision -GrowthStalledSeconds 91 -ObsLivenessResult $null -SustainedWindowSeconds 30 -DegradedWindowSeconds 90 | Should -Be 'Draining'
        }
    }

    Context 'Test-ObsProcessLiveness' {

        It 'returns $false for a confirmed-absent process name and never throws' {
            $randomProcessName = "obs-process-$([guid]::NewGuid().ToString('N'))"

            { Test-ObsProcessLiveness -ProcessName $randomProcessName } | Should -Not -Throw
            Test-ObsProcessLiveness -ProcessName $randomProcessName | Should -Be $false
        }

        It 'returns $true for a present process' {
            $currentProcessName = (Get-Process -Id $PID).ProcessName

            Test-ObsProcessLiveness -ProcessName $currentProcessName | Should -Be $true
        }
    }
}

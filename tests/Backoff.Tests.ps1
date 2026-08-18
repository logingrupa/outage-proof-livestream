BeforeAll {
    $script:BackoffModulePath = Join-Path $PSScriptRoot '../lib/Backoff.psm1'
}

Describe 'Backoff' -Tag 'Quick' {

    BeforeEach {
        Remove-Module Backoff -ErrorAction SilentlyContinue
        Import-Module $script:BackoffModulePath -Force
    }

    AfterEach {
        Remove-Module Backoff -ErrorAction SilentlyContinue
    }

    Context 'Get-NextBackoffDelayMilliseconds' {

        It 'returns the base delay at attempt 0 with max jitter (RandomValue 1.0)' {
            Get-NextBackoffDelayMilliseconds -AttemptNumber 0 -RandomValue 1.0 -BaseMilliseconds 1000 -CeilingMilliseconds 30000 | Should -Be 1000
        }

        It 'returns 0 (the floor) at attempt 0 with min jitter (RandomValue 0.0)' {
            Get-NextBackoffDelayMilliseconds -AttemptNumber 0 -RandomValue 0.0 -BaseMilliseconds 1000 -CeilingMilliseconds 30000 | Should -Be 0
        }

        It 'grows exponentially with attempt number (attempt 3, base 1000 -> 8000)' {
            Get-NextBackoffDelayMilliseconds -AttemptNumber 3 -RandomValue 1.0 -BaseMilliseconds 1000 -CeilingMilliseconds 30000 | Should -Be 8000
        }

        It 'clamps at the ceiling for high attempt numbers (never exceeds the ceiling)' {
            Get-NextBackoffDelayMilliseconds -AttemptNumber 20 -RandomValue 1.0 -BaseMilliseconds 1000 -CeilingMilliseconds 30000 | Should -Be 30000
        }

        It 'applies jitter proportionally (attempt 4, RandomValue 0.5 -> half of min(30000, 16000))' {
            Get-NextBackoffDelayMilliseconds -AttemptNumber 4 -RandomValue 0.5 -BaseMilliseconds 1000 -CeilingMilliseconds 30000 | Should -Be 8000
        }

        It 'returns an [int] and does not throw when RandomValue is omitted (real jitter fires within bounds)' {
            { Get-NextBackoffDelayMilliseconds -AttemptNumber 2 -BaseMilliseconds 1000 -CeilingMilliseconds 30000 } | Should -Not -Throw

            $cap = [Math]::Min(30000, 1000 * [Math]::Pow(2, 2))
            $result = Get-NextBackoffDelayMilliseconds -AttemptNumber 2 -BaseMilliseconds 1000 -CeilingMilliseconds 30000
            $result | Should -BeOfType [int]
            $result | Should -BeGreaterOrEqual 0
            $result | Should -BeLessOrEqual $cap
        }
    }
}

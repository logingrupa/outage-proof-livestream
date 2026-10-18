# Integration.ProbeVps.Tests.ps1
# Proves the D-08 SRT-induction reachability mechanic end-to-end against a REAL local
# ffmpeg SRT listener (closing MON-03's integration row) -- reusing
# tests/TestHelpers.psm1's Start-SrtListener/Stop-SrtListener idiom (the exact same
# fixture lib/FfmpegProcess.psm1's own integration tests use), not a hand-rolled
# listener. Skips cleanly (Set-ItResult -Skipped) when ffmpeg is unavailable so the
# suite stays green on a box without it (matching 06-01-SUMMARY.md's own convention).

BeforeAll {
    $script:VpsProbeModulePath = Join-Path $PSScriptRoot '../probes/vps.psm1'
    $script:TestHelpersModulePath = Join-Path $PSScriptRoot 'TestHelpers.psm1'
    $script:FfmpegAvailable = $null -ne (Get-Command 'ffmpeg' -ErrorAction SilentlyContinue)
}

Describe 'Invoke-Probe (probes/vps.psm1) against a real local SRT listener' -Tag 'Integration' {

    BeforeEach {
        Remove-Module vps -ErrorAction SilentlyContinue
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
        Import-Module $script:VpsProbeModulePath -Force
        Import-Module $script:TestHelpersModulePath -Force
    }

    AfterEach {
        Remove-Module vps -ErrorAction SilentlyContinue
        Remove-Module TestHelpers -ErrorAction SilentlyContinue
    }

    It 'returns status=ok with a plausible latency metric when the relay listener is real and reachable' {
        if (-not $script:FfmpegAvailable) {
            Set-ItResult -Skipped -Because 'ffmpeg is not available on this box -- cannot start a real SRT listener'
            return
        }

        $listenPort = Get-Random -Minimum 20000 -Maximum 40000
        $receivedPath = Join-Path $TestDrive 'integration-probe-received.ts'
        $listenerProcess = Start-SrtListener -Port $listenPort -OutputPath $receivedPath

        try {
            Start-Sleep -Seconds 2   # let the listener bind before the probe fires (mirrors FfmpegProcess.Tests.ps1)

            $config = [pscustomobject]@{
                RelayHost          = '127.0.0.1'
                RelayPort          = $listenPort
                ProbeVpsSshHost    = ''
                ProbeVpsSshUser    = ''
                ProbeVpsSshKeyPath = ''
            }

            $result = Invoke-Probe -Config $config

            $result.status | Should -Be 'ok'
            $result.detail | Should -Be 'SSH not configured'
            $latencyMetric = $result.metrics | Where-Object { $_.label -match 'Latency' }
            $latencyMetric | Should -Not -BeNullOrEmpty
            $latencyMetric.unit | Should -Be 'ms'
            [double] $latencyMetric.value | Should -BeGreaterOrEqual 0
            [double] $latencyMetric.value | Should -BeLessThan 2000
        } finally {
            if (-not $listenerProcess.HasExited) { Stop-SrtListener -Process $listenerProcess }
        }
    }

    It 'returns status=down (never throws) when the target port has nothing listening' {
        if (-not $script:FfmpegAvailable) {
            Set-ItResult -Skipped -Because 'ffmpeg is not available on this box -- the positive leg above could not run either, keep this negative leg consistent with it'
            return
        }

        # A closed loopback port -- no listener ever started here.
        $closedPort = Get-Random -Minimum 40001 -Maximum 50000

        $config = [pscustomobject]@{
            RelayHost          = '127.0.0.1'
            RelayPort          = $closedPort
            ProbeVpsSshHost    = ''
            ProbeVpsSshUser    = ''
            ProbeVpsSshKeyPath = ''
        }

        { $script:downResult = Invoke-Probe -Config $config } | Should -Not -Throw

        $script:downResult.status | Should -Be 'down'
        # Every return path carries the fixed indicator rows (probes/vps.psm1 contract), so
        # 'down' is proven by the absence of a measured Latency row, not by empty metrics.
        ($script:downResult.metrics | Where-Object { $_.label -match 'Latency' }) | Should -BeNullOrEmpty
        ($script:downResult.metrics | Where-Object { $_.label -eq 'Port' }).value | Should -Be 'closed'
    }
}

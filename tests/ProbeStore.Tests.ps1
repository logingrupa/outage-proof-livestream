# ProbeStore.Tests.ps1
# Unit tests for lib/ProbeStore.psm1 -- the fourth copy of the atomic
# write-temp-then-rename + silent-safe-default idiom in this repo (D-06/D-07),
# scoped to probe results. Save-ProbeResult/Read-ProbeResult mirror
# Save-PusherStats/Read-PusherStats (StatsStore.psm1) almost verbatim: a
# missing/corrupt/empty probe result file is NOT an error -- it means "not
# polled yet / disabled" -- and Read-ProbeResult is deliberately SILENT (no
# logger call on any path), matching StatsStore.Tests.ps1's own convention.

BeforeAll {
    $script:ClockModulePath = Join-Path $PSScriptRoot '../lib/Clock.psm1'
    $script:ProbeStoreModulePath = Join-Path $PSScriptRoot '../lib/ProbeStore.psm1'
}

Describe 'ProbeStore' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module ProbeStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Import-Module $script:ClockModulePath -Force
        Import-Module $script:ProbeStoreModulePath -Force

        $script:StateDirectory = Join-Path $TestDrive 'state/probes'
        $script:ProbeResultFilePath = Join-Path $script:StateDirectory 'vps-relay.json'
        New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
    }

    AfterEach {
        Remove-Module ProbeStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'round-trips name/title/status/metrics/detail faithfully (metrics is an array of {label,value,unit})' {
        $metrics = @(
            @{ label = 'Latency'; value = 42; unit = 'ms' },
            @{ label = 'Packet Loss'; value = 0.5; unit = '%' }
        )

        Save-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath -Name 'vps-relay' `
            -Title 'VPS Relay' -Status 'ok' -Metrics $metrics -Detail 'reachable'

        $restored = Read-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath

        $restored.schemaVersion | Should -Be 1
        $restored.name | Should -Be 'vps-relay'
        $restored.title | Should -Be 'VPS Relay'
        $restored.status | Should -Be 'ok'
        $restored.detail | Should -Be 'reachable'
        $restored.metrics.Count | Should -Be 2
        $restored.metrics[0].label | Should -Be 'Latency'
        $restored.metrics[0].value | Should -Be 42
        $restored.metrics[0].unit | Should -Be 'ms'
        $restored.metrics[1].label | Should -Be 'Packet Loss'
        $restored.metrics[1].value | Should -Be 0.5
        $restored.metrics[1].unit | Should -Be '%'
    }

    It 'stamps updatedEpochSeconds and staleAfterEpochSeconds == updatedEpochSeconds + StaleWithinSeconds (writer-owned, D-07)' {
        Save-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath -Name 'vps-relay' `
            -Title 'VPS Relay' -Status 'ok' -Metrics @() -StaleWithinSeconds 45

        $restored = Read-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath

        $restored.updatedEpochSeconds | Should -BeOfType [double]
        $restored.staleAfterEpochSeconds | Should -BeOfType [double]
        ($restored.staleAfterEpochSeconds - $restored.updatedEpochSeconds) | Should -BeGreaterThan 44.999
        ($restored.staleAfterEpochSeconds - $restored.updatedEpochSeconds) | Should -BeLessThan 45.001
    }

    It 'defaults StaleWithinSeconds to 30.0 when not specified (probes poll far less often than the 1s stats cadence)' {
        Save-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath -Name 'vps-relay' `
            -Title 'VPS Relay' -Status 'ok' -Metrics @()

        $restored = Read-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath

        ($restored.staleAfterEpochSeconds - $restored.updatedEpochSeconds) | Should -BeGreaterThan 29.999
        ($restored.staleAfterEpochSeconds - $restored.updatedEpochSeconds) | Should -BeLessThan 30.001
    }

    It 'accepts only status in {ok,degraded,down,unknown} -- an out-of-set status is rejected' {
        { Save-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath -Name 'vps-relay' `
            -Title 'VPS Relay' -Status 'totally-fine' -Metrics @() } | Should -Throw
    }

    It 'accepts every value in the ValidateSet without throwing' {
        foreach ($validStatus in @('ok', 'degraded', 'down', 'unknown')) {
            { Save-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath -Name 'vps-relay' `
                -Title 'VPS Relay' -Status $validStatus -Metrics @() } | Should -Not -Throw
        }
    }

    It 'returns $null with NO warning and NO error when the probe result file does not exist (not polled yet / disabled)' {
        Remove-Item -LiteralPath $script:ProbeResultFilePath -ErrorAction SilentlyContinue
        Test-Path -LiteralPath $script:ProbeResultFilePath | Should -BeFalse

        $restored = Read-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath -WarningAction SilentlyContinue -WarningVariable capturedWarnings -ErrorAction SilentlyContinue -ErrorVariable capturedErrors

        $restored | Should -BeNullOrEmpty
        $capturedWarnings.Count | Should -Be 0
        $capturedErrors.Count | Should -Be 0
    }

    It 'returns $null silently and never throws when the probe result file contains malformed JSON' {
        [System.IO.File]::WriteAllText($script:ProbeResultFilePath, '{"status":')

        { Read-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath } | Should -Not -Throw

        $restored = Read-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath -ErrorAction SilentlyContinue
        $restored | Should -BeNullOrEmpty
    }

    It 'returns $null silently when the probe result file is empty (zero-byte)' {
        [System.IO.File]::WriteAllText($script:ProbeResultFilePath, '')

        $restored = Read-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath -WarningAction SilentlyContinue -WarningVariable capturedWarnings -ErrorAction SilentlyContinue -ErrorVariable capturedErrors

        $restored | Should -BeNullOrEmpty
        $capturedWarnings.Count | Should -Be 0
        $capturedErrors.Count | Should -Be 0
    }

    It 'returns $null silently when the probe result file is whitespace-only' {
        [System.IO.File]::WriteAllText($script:ProbeResultFilePath, "   `n  `t  ")

        $restored = Read-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath

        $restored | Should -BeNullOrEmpty
    }

    It 'writes atomically -- a temp file is used and the destination is replaced via File.Move(overwrite); no probes-*.tmp file is left behind' {
        Save-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath -Name 'vps-relay' `
            -Title 'VPS Relay' -Status 'ok' -Metrics @()

        (Get-ChildItem -Path $script:StateDirectory -Filter 'probes-*.tmp').Count | Should -Be 0
        Test-Path -LiteralPath $script:ProbeResultFilePath | Should -BeTrue
    }

    It 'never leaves a partial/corrupt destination observable -- the destination is always a single valid JSON object, even after repeated overwrites' {
        Save-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath -Name 'vps-relay' `
            -Title 'VPS Relay' -Status 'ok' -Metrics @()
        Save-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath -Name 'vps-relay' `
            -Title 'VPS Relay' -Status 'degraded' -Metrics @() -Detail 'high latency'

        $rawFileText = [System.IO.File]::ReadAllText($script:ProbeResultFilePath)
        ($rawFileText | ConvertFrom-Json) | Should -Not -BeNullOrEmpty
        $restored = Read-ProbeResult -ProbeResultFilePath $script:ProbeResultFilePath
        $restored.status | Should -Be 'degraded'
        $restored.detail | Should -Be 'high latency'
    }
}

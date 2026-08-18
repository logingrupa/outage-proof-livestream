# NicTelemetry.Tests.ps1
# Unit tests for lib/NicTelemetry.psm1 (260722-xbr/NIC-TELEMETRY-01): pure rate math,
# rotation decision, JSONL append + rotation, and the edge-testability seams
# (Get-NicSentBytes/Resolve-SrtNicName) via Mock.

BeforeAll {
    $script:NicTelemetryModulePath = Join-Path $PSScriptRoot '../lib/NicTelemetry.psm1'
}

Describe 'Get-NicUploadBytesPerSecond' -Tag 'Quick' {

    BeforeEach {
        Remove-Module NicTelemetry -ErrorAction SilentlyContinue
        Import-Module $script:NicTelemetryModulePath -Force
    }

    AfterEach {
        Remove-Module NicTelemetry -ErrorAction SilentlyContinue
    }

    It 'computes bytes/sec from a rising counter over a 1 second interval' {
        Get-NicUploadBytesPerSecond -PreviousSentBytes 1000 -CurrentSentBytes 1000000 -IntervalSeconds 1.0 | Should -Be 999000.0
    }

    It 'computes bytes/sec from a rising counter over a 2 second interval' {
        Get-NicUploadBytesPerSecond -PreviousSentBytes 1000 -CurrentSentBytes 2000 -IntervalSeconds 2.0 | Should -Be 500.0
    }

    It 'returns $null when IntervalSeconds is zero (never divide by zero)' {
        Get-NicUploadBytesPerSecond -PreviousSentBytes 1000 -CurrentSentBytes 2000 -IntervalSeconds 0 | Should -BeNullOrEmpty
    }

    It 'returns $null when IntervalSeconds is negative' {
        Get-NicUploadBytesPerSecond -PreviousSentBytes 1000 -CurrentSentBytes 2000 -IntervalSeconds -1.0 | Should -BeNullOrEmpty
    }

    It 'returns $null when CurrentSentBytes is less than PreviousSentBytes (counter reset/rollover, never a negative rate)' {
        Get-NicUploadBytesPerSecond -PreviousSentBytes 5000 -CurrentSentBytes 1000 -IntervalSeconds 1.0 | Should -BeNullOrEmpty
    }
}

Describe 'Test-NicUploadLogShouldRotate' -Tag 'Quick' {

    BeforeEach {
        Remove-Module NicTelemetry -ErrorAction SilentlyContinue
        Import-Module $script:NicTelemetryModulePath -Force
    }

    AfterEach {
        Remove-Module NicTelemetry -ErrorAction SilentlyContinue
    }

    It 'returns $true when CurrentSizeBytes exceeds MaxSizeBytes' {
        Test-NicUploadLogShouldRotate -CurrentSizeBytes 5242881 -MaxSizeBytes 5242880 | Should -BeTrue
    }

    It 'returns $false when CurrentSizeBytes is under MaxSizeBytes' {
        Test-NicUploadLogShouldRotate -CurrentSizeBytes 100 -MaxSizeBytes 5242880 | Should -BeFalse
    }

    It 'returns $false when MaxSizeBytes is non-positive (rotation disabled)' {
        Test-NicUploadLogShouldRotate -CurrentSizeBytes 100 -MaxSizeBytes 0 | Should -BeFalse
    }
}

Describe 'Add-NicUploadSample' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module NicTelemetry -ErrorAction SilentlyContinue
        Import-Module $script:NicTelemetryModulePath -Force
    }

    AfterEach {
        Remove-Module NicTelemetry -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'appends exactly one compact JSON line carrying timestampUtc, nicName, uploadBps, pusherSendBitrateBps' {
        $logFilePath = Join-Path $TestDrive 'append-test/nic-upload.jsonl'

        Add-NicUploadSample -LogFilePath $logFilePath -TimestampUtc '2026-07-22T12:00:00Z' -NicName 'Ethernet' -UploadBps 3625000.0 -PusherSendBitrateBps 3200000.0

        $lines = @(Get-Content -LiteralPath $logFilePath)
        $lines.Count | Should -Be 1
        # Raw text match, not ConvertFrom-Json -- PowerShell's JSON parser auto-coerces
        # an ISO-8601-shaped string property into a [datetime], so the honest check that
        # the exact string was written is a raw substring match, not a round-trip compare.
        $lines[0] | Should -Match '"timestampUtc":"2026-07-22T12:00:00Z"'
        $parsed = $lines[0] | ConvertFrom-Json
        $parsed.nicName | Should -Be 'Ethernet'
        $parsed.uploadBps | Should -Be 3625000.0
        $parsed.pusherSendBitrateBps | Should -Be 3200000.0
    }

    It 'serializes a $null PusherSendBitrateBps as JSON null, never the string "null" or 0' {
        $logFilePath = Join-Path $TestDrive 'null-field-test/nic-upload.jsonl'

        Add-NicUploadSample -LogFilePath $logFilePath -TimestampUtc '2026-07-22T12:00:00Z' -NicName 'Ethernet' -UploadBps 100.0 -PusherSendBitrateBps $null

        $rawLine = @(Get-Content -LiteralPath $logFilePath)[0]
        $rawLine | Should -Not -Match '"pusherSendBitrateBps":"null"'
        $rawLine | Should -Not -Match '"pusherSendBitrateBps":0(?!\.)'
        $parsed = $rawLine | ConvertFrom-Json
        $null -eq $parsed.pusherSendBitrateBps | Should -BeTrue
    }

    It 'creates the parent directory if missing' {
        $logFilePath = Join-Path $TestDrive 'nested/logs/nic-upload.jsonl'

        Add-NicUploadSample -LogFilePath $logFilePath -TimestampUtc '2026-07-22T12:00:00Z' -NicName 'Ethernet' -UploadBps 100.0 -PusherSendBitrateBps 50.0

        Test-Path -LiteralPath $logFilePath | Should -BeTrue
    }

    It 'rotates the existing file to a sibling .1 generation file (overwriting any prior one) BEFORE writing the new line, keeping only one generation' {
        $logFilePath = Join-Path $TestDrive 'rotation-test/nic-upload.jsonl'
        New-Item -ItemType Directory -Path (Split-Path -Parent $logFilePath) -Force | Out-Null
        $rotatedLogFilePath = "$logFilePath.1"

        # Pre-create a file already over a small MaxSizeBytes, and a stale .1 that
        # must be overwritten, not merged with.
        [System.IO.File]::WriteAllText($rotatedLogFilePath, "stale-generation`n")
        [System.IO.File]::WriteAllText($logFilePath, [string]::new('x', 200) + "`n")

        Add-NicUploadSample -LogFilePath $logFilePath -TimestampUtc '2026-07-22T12:00:00Z' -NicName 'Ethernet' -UploadBps 100.0 -PusherSendBitrateBps 50.0 -MaxSizeBytes 100

        $rotatedContent = Get-Content -LiteralPath $rotatedLogFilePath -Raw
        $rotatedContent | Should -Not -Match 'stale-generation'
        $rotatedContent | Should -Match 'xxxxx'

        $primaryLines = @(Get-Content -LiteralPath $logFilePath)
        $primaryLines.Count | Should -Be 1
        ($primaryLines[0] | ConvertFrom-Json).nicName | Should -Be 'Ethernet'
    }

    It 'never throws on an unwritable path (best-effort)' {
        # A path under a filename (not a directory) as its parent cannot be created
        # as a directory -- New-Item -Force against that segment fails, which must
        # be swallowed, not raised.
        $blockerFilePath = Join-Path $TestDrive 'blocker-file'
        [System.IO.File]::WriteAllText($blockerFilePath, 'not a directory')
        $impossibleLogFilePath = Join-Path $blockerFilePath 'nic-upload.jsonl'

        { Add-NicUploadSample -LogFilePath $impossibleLogFilePath -TimestampUtc '2026-07-22T12:00:00Z' -NicName 'Ethernet' -UploadBps 100.0 -PusherSendBitrateBps 50.0 } | Should -Not -Throw
    }
}

Describe 'Get-NicSentBytes' -Tag 'Quick' {

    BeforeEach {
        Remove-Module NicTelemetry -ErrorAction SilentlyContinue
        Import-Module $script:NicTelemetryModulePath -Force
    }

    AfterEach {
        Remove-Module NicTelemetry -ErrorAction SilentlyContinue
    }

    It 'returns SentBytes as a long when Get-NetAdapterStatistics succeeds' {
        Mock -ModuleName NicTelemetry Get-NetAdapterStatistics { return [pscustomobject]@{ SentBytes = 123456789 } }

        $result = Get-NicSentBytes -NicName 'Ethernet'

        $result | Should -Be 123456789
        $result | Should -BeOfType [long]
    }

    It 'returns $null (never throws) when Get-NetAdapterStatistics fails' {
        Mock -ModuleName NicTelemetry Get-NetAdapterStatistics { throw 'adapter not found' }

        { $script:result = Get-NicSentBytes -NicName 'GhostAdapter' } | Should -Not -Throw
        $script:result | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-SrtNicName' -Tag 'Quick' {

    BeforeEach {
        Remove-Module NicTelemetry -ErrorAction SilentlyContinue
        Import-Module $script:NicTelemetryModulePath -Force
    }

    AfterEach {
        Remove-Module NicTelemetry -ErrorAction SilentlyContinue
    }

    It 'returns OverrideNicName verbatim when non-blank, without consulting Find-NetRoute' {
        Mock -ModuleName NicTelemetry Find-NetRoute { throw 'must not be called' }

        Resolve-SrtNicName -RelayHost '203.0.113.10' -OverrideNicName 'Ethernet2' | Should -Be 'Ethernet2'
    }

    It 'auto-detects via Find-NetRoute + Get-NetAdapter when OverrideNicName is blank' {
        Mock -ModuleName NicTelemetry Find-NetRoute { return @([pscustomobject]@{ InterfaceIndex = 8 }) }
        Mock -ModuleName NicTelemetry Get-NetAdapter { return [pscustomobject]@{ Name = 'Ethernet' } }

        Resolve-SrtNicName -RelayHost '203.0.113.10' -OverrideNicName '' | Should -Be 'Ethernet'
    }

    It 'returns $null (never throws) when Find-NetRoute fails' {
        Mock -ModuleName NicTelemetry Find-NetRoute { throw 'no route' }

        { $script:result = Resolve-SrtNicName -RelayHost '203.0.113.10' -OverrideNicName '' } | Should -Not -Throw
        $script:result | Should -BeNullOrEmpty
    }
}

# StatsStore.Tests.ps1
# Unit tests for lib/StatsStore.psm1 -- the D-15 rework: pusher.ps1's process-local
# $resilienceState metrics cross the process boundary through state/stats.json to
# supervisor.ps1's dashboard. Read-PusherStats is deliberately SILENT (unlike
# OffsetStore.Tests.ps1's loud-logging assertions) -- missing/corrupt/stale stats.json
# is the normal idle state (D-04), never an error.

BeforeAll {
    $script:ClockModulePath = Join-Path $PSScriptRoot '../lib/Clock.psm1'
    $script:StatsStoreModulePath = Join-Path $PSScriptRoot '../lib/StatsStore.psm1'
}

Describe 'StatsStore' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Import-Module $script:ClockModulePath -Force
        Import-Module $script:StatsStoreModulePath -Force

        $script:StateDirectory = Join-Path $TestDrive 'state'
        $script:StatsFilePath = Join-Path $script:StateDirectory 'stats.json'
        New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
    }

    AfterEach {
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'round-trips every payload field with values intact and correct types (long stays long, double stays double, bool stays bool)' {
        Save-PusherStats -StatsFilePath $script:StatsFilePath -PusherState 'Streaming' `
            -RecordingFilePath 'D:\recording.ts' -OffsetBytes 4000000000 -FileLengthBytes 5000000000 `
            -SendBytesPerSecond 5017148.5 -RecordBytesPerSecond 3200000.25 -SecondsBehindLive 33.9 `
            -BackoffAttemptNumber 3 -CumulativeReconnectCount 7 -LastClassificationCause 'NetworkDeath' `
            -CatchUpCapUtilization 1.0 -OutageActive $true

        $restored = Read-PusherStats -StatsFilePath $script:StatsFilePath

        $restored.schemaVersion | Should -Be 1
        $restored.pusherState | Should -Be 'Streaming'
        $restored.recordingFilePath | Should -Be 'D:\recording.ts'
        $restored.offsetBytes | Should -Be 4000000000
        $restored.offsetBytes | Should -BeOfType [long]
        $restored.fileLengthBytes | Should -Be 5000000000
        $restored.fileLengthBytes | Should -BeOfType [long]
        $restored.sendBytesPerSecond | Should -Be 5017148.5
        $restored.sendBytesPerSecond | Should -BeOfType [double]
        $restored.recordBytesPerSecond | Should -Be 3200000.25
        $restored.recordBytesPerSecond | Should -BeOfType [double]
        $restored.secondsBehindLive | Should -Be 33.9
        $restored.secondsBehindLive | Should -BeOfType [double]
        $restored.backoffAttemptNumber | Should -Be 3
        $restored.cumulativeReconnectCount | Should -Be 7
        $restored.lastClassificationCause | Should -Be 'NetworkDeath'
        $restored.catchUpCapUtilization | Should -Be 1.0
        $restored.catchUpCapUtilization | Should -BeOfType [double]
        $restored.outageActive | Should -Be $true
        $restored.outageActive | Should -BeOfType [bool]
        $restored.updatedEpochSeconds | Should -BeOfType [double]
        $restored.staleAfterEpochSeconds | Should -BeOfType [double]
    }

    It 'round-trips a numeric lastSuccessfulSendEpochSeconds as a double (DASH-08)' {
        Save-PusherStats -StatsFilePath $script:StatsFilePath -PusherState 'Streaming' `
            -RecordingFilePath 'D:\recording.ts' -OffsetBytes 4000000000 -FileLengthBytes 5000000000 `
            -SendBytesPerSecond 5017148.5 -RecordBytesPerSecond 3200000.25 -SecondsBehindLive 33.9 `
            -BackoffAttemptNumber 3 -CumulativeReconnectCount 7 -LastClassificationCause 'NetworkDeath' `
            -CatchUpCapUtilization 1.0 -OutageActive $true -LastSuccessfulSendEpochSeconds 123456.789

        $restored = Read-PusherStats -StatsFilePath $script:StatsFilePath

        $restored.lastSuccessfulSendEpochSeconds | Should -Be 123456.789
        $restored.lastSuccessfulSendEpochSeconds | Should -BeOfType [double]
    }

    It 'round-trips a $null lastSuccessfulSendEpochSeconds (never-sent-yet, D-13) as $null, never a fabricated 0' {
        Save-PusherStats -StatsFilePath $script:StatsFilePath -PusherState 'Streaming' `
            -RecordingFilePath 'D:\recording.ts' -OffsetBytes 0 -FileLengthBytes 188 `
            -SendBytesPerSecond 0.0 -RecordBytesPerSecond 0.0 -SecondsBehindLive 0.0 `
            -BackoffAttemptNumber 0 -CumulativeReconnectCount 0 -CatchUpCapUtilization 0.0 -OutageActive $false

        $restored = Read-PusherStats -StatsFilePath $script:StatsFilePath

        $restored.lastSuccessfulSendEpochSeconds | Should -BeNullOrEmpty
    }

    It 'round-trips a numeric sessionStartEpochSeconds as a double (260718-epo/FEAT-B)' {
        Save-PusherStats -StatsFilePath $script:StatsFilePath -PusherState 'Streaming' `
            -RecordingFilePath 'D:\recording.ts' -OffsetBytes 4000000000 -FileLengthBytes 5000000000 `
            -SendBytesPerSecond 5017148.5 -RecordBytesPerSecond 3200000.25 -SecondsBehindLive 33.9 `
            -BackoffAttemptNumber 3 -CumulativeReconnectCount 7 -LastClassificationCause 'NetworkDeath' `
            -CatchUpCapUtilization 1.0 -OutageActive $true -SessionStartEpochSeconds 100.5

        $restored = Read-PusherStats -StatsFilePath $script:StatsFilePath

        $restored.sessionStartEpochSeconds | Should -Be 100.5
        $restored.sessionStartEpochSeconds | Should -BeOfType [double]
    }

    It 'round-trips a $null sessionStartEpochSeconds (no session started yet, D-13) as $null, never a fabricated 0' {
        Save-PusherStats -StatsFilePath $script:StatsFilePath -PusherState 'Streaming' `
            -RecordingFilePath 'D:\recording.ts' -OffsetBytes 0 -FileLengthBytes 188 `
            -SendBytesPerSecond 0.0 -RecordBytesPerSecond 0.0 -SecondsBehindLive 0.0 `
            -BackoffAttemptNumber 0 -CumulativeReconnectCount 0 -CatchUpCapUtilization 0.0 -OutageActive $false

        $restored = Read-PusherStats -StatsFilePath $script:StatsFilePath

        $restored.sessionStartEpochSeconds | Should -BeNullOrEmpty
    }

    It 'returns $null with NO warning and NO error when the stats file does not exist' {
        # Per-It cleanup: $TestDrive (and $script:StatsFilePath within it) is shared
        # across every It in this Describe's run, and the round-trip test above already
        # wrote a real stats.json here -- mirrors OffsetStore.Tests.ps1's own
        # Remove-Item-before-missing-file-assertion convention.
        Remove-Item -LiteralPath $script:StatsFilePath -ErrorAction SilentlyContinue
        Test-Path -LiteralPath $script:StatsFilePath | Should -BeFalse

        $restored = Read-PusherStats -StatsFilePath $script:StatsFilePath -WarningAction SilentlyContinue -WarningVariable capturedWarnings -ErrorAction SilentlyContinue -ErrorVariable capturedErrors

        $restored | Should -BeNullOrEmpty
        $capturedWarnings.Count | Should -Be 0
        $capturedErrors.Count | Should -Be 0
    }

    It 'returns $null silently and never throws when the stats file contains malformed JSON' {
        [System.IO.File]::WriteAllText($script:StatsFilePath, '{"pusherState":')

        # Called directly (not just inside a Should -Not -Throw scriptblock) so the
        # return value is inspectable in this scope too. Note: unlike the
        # does-not-exist case above, this path DOES invoke ConvertFrom-Json, whose
        # internal CmdletInvocationException is caught inside Read-PusherStats (never
        # escapes, never surfaces via Write-Log) but is still recorded to PowerShell's
        # own automatic error bookkeeping for the advanced-function call, per engine
        # behavior independent of this module's silent-reader contract -- the
        # assertion this test makes is "never throws to the caller", not "the PS
        # engine's internal $Error stays empty".
        { Read-PusherStats -StatsFilePath $script:StatsFilePath } | Should -Not -Throw

        $restored = Read-PusherStats -StatsFilePath $script:StatsFilePath -ErrorAction SilentlyContinue
        $restored | Should -BeNullOrEmpty
    }

    It 'returns $null silently when the stats file is empty (zero-byte)' {
        [System.IO.File]::WriteAllText($script:StatsFilePath, '')

        $restored = Read-PusherStats -StatsFilePath $script:StatsFilePath -WarningAction SilentlyContinue -WarningVariable capturedWarnings -ErrorAction SilentlyContinue -ErrorVariable capturedErrors

        $restored | Should -BeNullOrEmpty
        $capturedWarnings.Count | Should -Be 0
        $capturedErrors.Count | Should -Be 0
    }

    It 'leaves no stats.*.tmp files behind in the state directory after a successful write' {
        Save-PusherStats -StatsFilePath $script:StatsFilePath -PusherState 'Streaming' `
            -RecordingFilePath 'D:\recording.ts' -OffsetBytes 188 -FileLengthBytes 376 `
            -SendBytesPerSecond 1000.0 -RecordBytesPerSecond 1000.0 -SecondsBehindLive 0.0 `
            -BackoffAttemptNumber 0 -CumulativeReconnectCount 0 -CatchUpCapUtilization 0.0 -OutageActive $false

        (Get-ChildItem -Path $script:StateDirectory -Filter 'stats.*.tmp').Count | Should -Be 0
    }

    It 'overwrites an existing stats.json in place -- the second writes values win, the file is never appended to' {
        Save-PusherStats -StatsFilePath $script:StatsFilePath -PusherState 'Streaming' `
            -RecordingFilePath 'D:\recording.ts' -OffsetBytes 188 -FileLengthBytes 376 `
            -SendBytesPerSecond 1000.0 -RecordBytesPerSecond 1000.0 -SecondsBehindLive 5.0 `
            -BackoffAttemptNumber 0 -CumulativeReconnectCount 0 -CatchUpCapUtilization 0.0 -OutageActive $false

        Save-PusherStats -StatsFilePath $script:StatsFilePath -PusherState 'Draining' `
            -RecordingFilePath 'D:\recording.ts' -OffsetBytes 376 -FileLengthBytes 376 `
            -SendBytesPerSecond 2000.0 -RecordBytesPerSecond 2000.0 -SecondsBehindLive 0.0 `
            -BackoffAttemptNumber 0 -CumulativeReconnectCount 0 -CatchUpCapUtilization 0.0 -OutageActive $false

        $restored = Read-PusherStats -StatsFilePath $script:StatsFilePath

        $restored.pusherState | Should -Be 'Draining'
        $restored.offsetBytes | Should -Be 376
        $rawFileText = [System.IO.File]::ReadAllText($script:StatsFilePath)
        # A single JSON object, not two concatenated payloads -- ConvertFrom-Json would
        # throw on an appended (invalid) double-object file, so parsing succeeding at
        # all is part of this assertion too.
        ($rawFileText | ConvertFrom-Json) | Should -Not -BeNullOrEmpty
    }

    It 'sets staleAfterEpochSeconds to updatedEpochSeconds + StaleWithinSeconds, honoring an explicit override (the deep-backoff case)' {
        Save-PusherStats -StatsFilePath $script:StatsFilePath -PusherState 'Stopped' `
            -RecordingFilePath 'D:\recording.ts' -OffsetBytes 0 -FileLengthBytes 0 `
            -SendBytesPerSecond 0.0 -RecordBytesPerSecond 0.0 -SecondsBehindLive 0.0 `
            -BackoffAttemptNumber 5 -CumulativeReconnectCount 2 -CatchUpCapUtilization 0.0 -OutageActive $true `
            -StaleWithinSeconds 31

        $restored = Read-PusherStats -StatsFilePath $script:StatsFilePath

        ($restored.staleAfterEpochSeconds - $restored.updatedEpochSeconds) | Should -BeGreaterThan 30.999
        ($restored.staleAfterEpochSeconds - $restored.updatedEpochSeconds) | Should -BeLessThan 31.001
    }

    It 'defaults StaleWithinSeconds to 3.0 when not specified' {
        Save-PusherStats -StatsFilePath $script:StatsFilePath -PusherState 'Streaming' `
            -RecordingFilePath 'D:\recording.ts' -OffsetBytes 188 -FileLengthBytes 376 `
            -SendBytesPerSecond 1000.0 -RecordBytesPerSecond 1000.0 -SecondsBehindLive 0.0 `
            -BackoffAttemptNumber 0 -CumulativeReconnectCount 0 -CatchUpCapUtilization 0.0 -OutageActive $false

        $restored = Read-PusherStats -StatsFilePath $script:StatsFilePath

        ($restored.staleAfterEpochSeconds - $restored.updatedEpochSeconds) | Should -BeGreaterThan 2.999
        ($restored.staleAfterEpochSeconds - $restored.updatedEpochSeconds) | Should -BeLessThan 3.001
    }

    It 'is readable cross-process -- a stats.json written by a CHILD pwsh process is read back correctly by Read-PusherStats in the PARENT' {
        $writerScriptFilePath = Join-Path $TestDrive ("Write-ChildStats-{0}.ps1" -f ([Guid]::NewGuid()))

        $writerScriptContent = @'
param(
    [Parameter(Mandatory)] [string] $ClockModulePath,
    [Parameter(Mandatory)] [string] $StatsStoreModulePath,
    [Parameter(Mandatory)] [string] $StatsFilePath
)

$ErrorActionPreference = 'Stop'
Import-Module $ClockModulePath -Force
Import-Module $StatsStoreModulePath -Force

Save-PusherStats -StatsFilePath $StatsFilePath -PusherState 'Streaming' `
    -RecordingFilePath 'D:\recording.ts' -OffsetBytes 700000000 -FileLengthBytes 800000000 `
    -SendBytesPerSecond 5017148.0 -RecordBytesPerSecond 3200000.0 -SecondsBehindLive 50.4 `
    -BackoffAttemptNumber 1 -CumulativeReconnectCount 4 -LastClassificationCause 'FfmpegCrash' `
    -CatchUpCapUtilization 1.0 -OutageActive $false
'@
        Set-Content -LiteralPath $writerScriptFilePath -Value $writerScriptContent -Encoding utf8

        $writerProcess = Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-File', $writerScriptFilePath,
            '-ClockModulePath', $script:ClockModulePath, '-StatsStoreModulePath', $script:StatsStoreModulePath,
            '-StatsFilePath', $script:StatsFilePath
        ) -PassThru -NoNewWindow
        $writerProcess.WaitForExit()

        $restored = Read-PusherStats -StatsFilePath $script:StatsFilePath

        $restored | Should -Not -BeNullOrEmpty
        $restored.pusherState | Should -Be 'Streaming'
        $restored.offsetBytes | Should -Be 700000000
        $restored.lastClassificationCause | Should -Be 'FfmpegCrash'
        $restored.secondsBehindLive | Should -Be 50.4
    }
}

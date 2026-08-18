# SessionState.Tests.ps1
# Unit tests for lib/SessionState.psm1 -- the supervisor-owned durable record of "how
# did the last pusher run end, and is a new recording waiting?" (260718-epo). Read-
# SessionState is deliberately SILENT (mirrors StatsStore.Tests.ps1's own precedent) --
# missing/corrupt session.json is the normal "no session record" state, never an error.

BeforeAll {
    $script:ClockModulePath = Join-Path $PSScriptRoot '../lib/Clock.psm1'
    $script:SessionStateModulePath = Join-Path $PSScriptRoot '../lib/SessionState.psm1'
}

Describe 'SessionState' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module SessionState -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Import-Module $script:ClockModulePath -Force
        Import-Module $script:SessionStateModulePath -Force

        $script:StateDirectory = Join-Path $TestDrive 'state'
        $script:SessionStateFilePath = Join-Path $script:StateDirectory 'session.json'
        New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
    }

    AfterEach {
        Remove-Module SessionState -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Pop-Location
    }

    Context 'Save-SessionState / Read-SessionState roundtrip' {

        It 'round-trips every field with values intact (clean-end-of-service, a real finished file)' {
            $finishedLastWriteUtc = [datetime]::new(2026, 7, 18, 10, 30, 0, [System.DateTimeKind]::Utc)

            Save-SessionState -SessionStateFilePath $script:SessionStateFilePath `
                -LastExitReason 'clean-end-of-service' -LastExitEpochSeconds 12345.678 `
                -FinishedRecordingFilePath 'D:\obs_streaming\service.ts' `
                -FinishedRecordingLastWriteUtc $finishedLastWriteUtc `
                -NewRecordingDetectedFilePath $null

            $restored = Read-SessionState -SessionStateFilePath $script:SessionStateFilePath

            $restored.schemaVersion | Should -Be 1
            $restored.lastExitReason | Should -Be 'clean-end-of-service'
            $restored.lastExitEpochSeconds | Should -Be 12345.678
            $restored.finishedRecordingFilePath | Should -Be 'D:\obs_streaming\service.ts'
            ([datetime] $restored.finishedRecordingLastWriteUtc) | Should -Be $finishedLastWriteUtc
            $restored.newRecordingDetectedFilePath | Should -BeNullOrEmpty
        }

        It 'round-trips a NewRecordingDetectedFilePath when set' {
            Save-SessionState -SessionStateFilePath $script:SessionStateFilePath `
                -LastExitReason 'clean-end-of-service' -LastExitEpochSeconds 1.0 `
                -FinishedRecordingFilePath 'D:\obs_streaming\old.ts' `
                -FinishedRecordingLastWriteUtc ([datetime]::UtcNow) `
                -NewRecordingDetectedFilePath 'D:\obs_streaming\new.ts'

            $restored = Read-SessionState -SessionStateFilePath $script:SessionStateFilePath

            $restored.newRecordingDetectedFilePath | Should -Be 'D:\obs_streaming\new.ts'
        }

        It 'round-trips a $null FinishedRecordingFilePath/LastWriteUtc (crash exit, no finished file recorded)' {
            Save-SessionState -SessionStateFilePath $script:SessionStateFilePath `
                -LastExitReason 'crash' -LastExitEpochSeconds 999.0 `
                -FinishedRecordingFilePath $null -FinishedRecordingLastWriteUtc $null `
                -NewRecordingDetectedFilePath $null

            $restored = Read-SessionState -SessionStateFilePath $script:SessionStateFilePath

            $restored.lastExitReason | Should -Be 'crash'
            $restored.finishedRecordingFilePath | Should -BeNullOrEmpty
            $restored.finishedRecordingLastWriteUtc | Should -BeNullOrEmpty
        }

        It 'round-trips a $null LastExitReason (no exit ever recorded yet), never fabricated' {
            Save-SessionState -SessionStateFilePath $script:SessionStateFilePath `
                -LastExitReason $null -LastExitEpochSeconds $null `
                -FinishedRecordingFilePath $null -FinishedRecordingLastWriteUtc $null `
                -NewRecordingDetectedFilePath $null

            $restored = Read-SessionState -SessionStateFilePath $script:SessionStateFilePath

            $restored.lastExitReason | Should -BeNullOrEmpty
            $restored.lastExitEpochSeconds | Should -BeNullOrEmpty
        }

        It 'creates the state/ directory if it does not yet exist' {
            $freshStateDirectory = Join-Path $TestDrive ([Guid]::NewGuid())
            $freshSessionStateFilePath = Join-Path $freshStateDirectory 'session.json'
            Test-Path -LiteralPath $freshStateDirectory | Should -BeFalse

            Save-SessionState -SessionStateFilePath $freshSessionStateFilePath `
                -LastExitReason 'clean-end-of-service' -LastExitEpochSeconds 1.0

            Test-Path -LiteralPath $freshSessionStateFilePath | Should -BeTrue
        }

        It 'leaves no session.*.tmp files behind in the state directory after a successful write' {
            Save-SessionState -SessionStateFilePath $script:SessionStateFilePath `
                -LastExitReason 'clean-end-of-service' -LastExitEpochSeconds 1.0

            (Get-ChildItem -Path $script:StateDirectory -Filter 'session.*.tmp').Count | Should -Be 0
        }

        It 'overwrites an existing session.json in place -- the second write''s values win' {
            Save-SessionState -SessionStateFilePath $script:SessionStateFilePath `
                -LastExitReason 'crash' -LastExitEpochSeconds 1.0

            Save-SessionState -SessionStateFilePath $script:SessionStateFilePath `
                -LastExitReason 'clean-end-of-service' -LastExitEpochSeconds 2.0

            $restored = Read-SessionState -SessionStateFilePath $script:SessionStateFilePath
            $restored.lastExitReason | Should -Be 'clean-end-of-service'
            $restored.lastExitEpochSeconds | Should -Be 2.0
        }
    }

    Context 'Read-SessionState silent-safe defaults' {

        It 'returns $null with NO warning and NO error when the session file does not exist' {
            Test-Path -LiteralPath $script:SessionStateFilePath | Should -BeFalse

            $restored = Read-SessionState -SessionStateFilePath $script:SessionStateFilePath `
                -WarningAction SilentlyContinue -WarningVariable capturedWarnings -ErrorAction SilentlyContinue -ErrorVariable capturedErrors

            $restored | Should -BeNullOrEmpty
            $capturedWarnings.Count | Should -Be 0
            $capturedErrors.Count | Should -Be 0
        }

        It 'returns $null silently and never throws when the session file contains malformed JSON' {
            [System.IO.File]::WriteAllText($script:SessionStateFilePath, '{"lastExitReason":')

            { Read-SessionState -SessionStateFilePath $script:SessionStateFilePath } | Should -Not -Throw

            $restored = Read-SessionState -SessionStateFilePath $script:SessionStateFilePath -ErrorAction SilentlyContinue
            $restored | Should -BeNullOrEmpty
        }

        It 'returns $null silently when the session file is empty (zero-byte)' {
            [System.IO.File]::WriteAllText($script:SessionStateFilePath, '')

            $restored = Read-SessionState -SessionStateFilePath $script:SessionStateFilePath `
                -WarningAction SilentlyContinue -WarningVariable capturedWarnings -ErrorAction SilentlyContinue -ErrorVariable capturedErrors

            $restored | Should -BeNullOrEmpty
            $capturedWarnings.Count | Should -Be 0
            $capturedErrors.Count | Should -Be 0
        }
    }

    Context 'Get-NewRecordingPickupDecision (pure truth table)' {

        BeforeAll {
            $script:OlderMtime = [datetime]::new(2026, 7, 18, 10, 0, 0, [System.DateTimeKind]::Utc)
            $script:NewerMtime = [datetime]::new(2026, 7, 18, 11, 0, 0, [System.DateTimeKind]::Utc)
        }

        It 'detects a strictly-newer file at a different path' {
            $decision = Get-NewRecordingPickupDecision -FinishedRecordingFilePath 'D:\obs\old.ts' `
                -FinishedRecordingLastWriteUtc $script:OlderMtime `
                -NewestRecordingFilePath 'D:\obs\new.ts' -NewestRecordingLastWriteUtc $script:NewerMtime `
                -AutoPickupEnabled $false

            $decision.NewRecordingDetected | Should -BeTrue
            $decision.NewRecordingFilePath | Should -Be 'D:\obs\new.ts'
        }

        It 'SAFETY: does NOT detect when the newest file path equals the finished path (same file re-observed)' {
            $decision = Get-NewRecordingPickupDecision -FinishedRecordingFilePath 'D:\obs\same.ts' `
                -FinishedRecordingLastWriteUtc $script:OlderMtime `
                -NewestRecordingFilePath 'D:\obs\same.ts' -NewestRecordingLastWriteUtc $script:NewerMtime `
                -AutoPickupEnabled $true

            $decision.NewRecordingDetected | Should -BeFalse
            $decision.ShouldAutoStart | Should -BeFalse
        }

        It 'treats an equal path as equal case-insensitively (OrdinalIgnoreCase)' {
            $decision = Get-NewRecordingPickupDecision -FinishedRecordingFilePath 'D:\obs\Same.ts' `
                -FinishedRecordingLastWriteUtc $script:OlderMtime `
                -NewestRecordingFilePath 'd:\obs\same.ts' -NewestRecordingLastWriteUtc $script:NewerMtime `
                -AutoPickupEnabled $true

            $decision.NewRecordingDetected | Should -BeFalse
        }

        It 'SAFETY: does NOT detect when the newest file has an EQUAL mtime to the finished file' {
            $decision = Get-NewRecordingPickupDecision -FinishedRecordingFilePath 'D:\obs\old.ts' `
                -FinishedRecordingLastWriteUtc $script:OlderMtime `
                -NewestRecordingFilePath 'D:\obs\new.ts' -NewestRecordingLastWriteUtc $script:OlderMtime `
                -AutoPickupEnabled $true

            $decision.NewRecordingDetected | Should -BeFalse
        }

        It 'SAFETY: does NOT detect when the newest file has an OLDER mtime than the finished file' {
            $decision = Get-NewRecordingPickupDecision -FinishedRecordingFilePath 'D:\obs\old.ts' `
                -FinishedRecordingLastWriteUtc $script:NewerMtime `
                -NewestRecordingFilePath 'D:\obs\new.ts' -NewestRecordingLastWriteUtc $script:OlderMtime `
                -AutoPickupEnabled $true

            $decision.NewRecordingDetected | Should -BeFalse
        }

        It 'does NOT detect when NewestRecordingFilePath is $null' {
            $decision = Get-NewRecordingPickupDecision -FinishedRecordingFilePath 'D:\obs\old.ts' `
                -FinishedRecordingLastWriteUtc $script:OlderMtime `
                -NewestRecordingFilePath $null -NewestRecordingLastWriteUtc $script:NewerMtime `
                -AutoPickupEnabled $true

            $decision.NewRecordingDetected | Should -BeFalse
        }

        It 'does NOT detect when FinishedRecordingFilePath is $null' {
            $decision = Get-NewRecordingPickupDecision -FinishedRecordingFilePath $null `
                -FinishedRecordingLastWriteUtc $null `
                -NewestRecordingFilePath 'D:\obs\new.ts' -NewestRecordingLastWriteUtc $script:NewerMtime `
                -AutoPickupEnabled $true

            $decision.NewRecordingDetected | Should -BeFalse
        }

        It 'does NOT detect when a mtime is missing on either side' {
            $decision = Get-NewRecordingPickupDecision -FinishedRecordingFilePath 'D:\obs\old.ts' `
                -FinishedRecordingLastWriteUtc $null `
                -NewestRecordingFilePath 'D:\obs\new.ts' -NewestRecordingLastWriteUtc $script:NewerMtime `
                -AutoPickupEnabled $true

            $decision.NewRecordingDetected | Should -BeFalse
        }

        It 'ShouldAutoStart gate: detected AND AutoPickupEnabled=$true -> $true' {
            $decision = Get-NewRecordingPickupDecision -FinishedRecordingFilePath 'D:\obs\old.ts' `
                -FinishedRecordingLastWriteUtc $script:OlderMtime `
                -NewestRecordingFilePath 'D:\obs\new.ts' -NewestRecordingLastWriteUtc $script:NewerMtime `
                -AutoPickupEnabled $true

            $decision.ShouldAutoStart | Should -BeTrue
        }

        It 'ShouldAutoStart gate: detected AND AutoPickupEnabled=$false -> $false (default-off safety, T-epo-01)' {
            $decision = Get-NewRecordingPickupDecision -FinishedRecordingFilePath 'D:\obs\old.ts' `
                -FinishedRecordingLastWriteUtc $script:OlderMtime `
                -NewestRecordingFilePath 'D:\obs\new.ts' -NewestRecordingLastWriteUtc $script:NewerMtime `
                -AutoPickupEnabled $false

            $decision.NewRecordingDetected | Should -BeTrue -Because 'detection must still surface the notice even with auto-pickup off'
            $decision.ShouldAutoStart | Should -BeFalse
        }

        It 'never throws on entirely $null input' {
            { Get-NewRecordingPickupDecision -FinishedRecordingFilePath $null -FinishedRecordingLastWriteUtc $null `
                -NewestRecordingFilePath $null -NewestRecordingLastWriteUtc $null -AutoPickupEnabled $false } | Should -Not -Throw
        }
    }
}

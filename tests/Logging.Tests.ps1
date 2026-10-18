BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '../lib/Logging.psm1'
}

Describe 'Write-Log' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:ModulePath -Force
        # D-15: default anchors to the module root, not CWD -- redirect into
        # $TestDrive explicitly so these tests stay filesystem-isolated.
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
    }

    AfterEach {
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'creates state/logs/pusher.log if the directory is missing' {
        $expectedLogPath = Join-Path $TestDrive 'state/logs/pusher.log'
        Test-Path -LiteralPath (Split-Path -Parent $expectedLogPath) | Should -BeFalse

        Write-Log -Level Info -Message 'directory auto-create check'

        Test-Path -LiteralPath $expectedLogPath | Should -BeTrue
    }

    It 'writes an Info line to the log file' {
        $expectedLogPath = Join-Path $TestDrive 'state/logs/pusher.log'

        Write-Log -Level Info -Message 'info level line'

        $logContent = Get-Content -LiteralPath $expectedLogPath -Raw
        $logContent | Should -Match '\[Info\] info level line'
    }

    It 'routes Error level through the error stream and still logs to file' {
        $expectedLogPath = Join-Path $TestDrive 'state/logs/pusher.log'

        $errorRecords = Write-Log -Level Error -Message 'loud failure' -ErrorAction SilentlyContinue -ErrorVariable capturedErrors 2>&1

        $capturedErrors.Count | Should -BeGreaterThan 0
        $capturedErrors[0].ToString() | Should -Match 'loud failure'

        $logContent = Get-Content -LiteralPath $expectedLogPath -Raw
        $logContent | Should -Match '\[Error\] loud failure'
    }
}

Describe 'Write-Log path anchoring (D-15)' -Tag 'Quick' {

    BeforeEach {
        # Simulate Session-0 (CWD = some directory that is NOT the repo/module
        # root, mirroring a Scheduled Task launching with CWD = System32).
        Push-Location $TestDrive
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:ModulePath -Force
    }

    AfterEach {
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'anchors the default log path to the module root, not the process CWD' {
        $moduleDirectory = Split-Path -Parent $script:ModulePath
        $expectedRepoRoot = [System.IO.Path]::GetFullPath((Join-Path $moduleDirectory '..'))
        $expectedPath = [System.IO.Path]::GetFullPath((Join-Path $expectedRepoRoot 'state/logs/pusher.log'))

        # Inspect the module's internal default without triggering the
        # directory-auto-create side effect (no Get-LogFilePath/Write-Log call).
        $actualPath = InModuleScope Logging { $script:LogFilePath }

        $actualPath | Should -Be $expectedPath
        $actualPath | Should -Not -Match ([regex]::Escape($TestDrive))
    }
}

Describe 'Set-LogDirectory' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:ModulePath -Force
    }

    AfterEach {
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'anchors a relative directory under the module root, not CWD (WR-03 parity)' {
        Set-LogDirectory 'custom-logs'

        $moduleDirectory = Split-Path -Parent $script:ModulePath
        $expectedRepoRoot = [System.IO.Path]::GetFullPath((Join-Path $moduleDirectory '..'))
        $expectedPath = [System.IO.Path]::GetFullPath((Join-Path $expectedRepoRoot 'custom-logs/pusher.log'))

        $actualPath = InModuleScope Logging { $script:LogFilePath }

        $actualPath | Should -Be $expectedPath
    }

    It 'uses an already-rooted directory verbatim' {
        $absoluteDirectory = Join-Path $TestDrive 'abs-logs'
        Set-LogDirectory $absoluteDirectory

        $actualPath = InModuleScope Logging { $script:LogFilePath }

        $actualPath | Should -Be (Join-Path $absoluteDirectory 'pusher.log')
    }

    It 'still auto-creates the parent directory on the next write (existing Get-LogFilePath contract)' {
        $relocatedLogDirectory = Join-Path $TestDrive 'relocated-logs'
        Set-LogDirectory $relocatedLogDirectory
        Test-Path -LiteralPath $relocatedLogDirectory | Should -BeFalse

        Write-Log -Level Info -Message 'after relocation'

        Test-Path -LiteralPath (Join-Path $relocatedLogDirectory 'pusher.log') | Should -BeTrue
    }
}

Describe 'Write-Log log rotation' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:ModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
    }

    AfterEach {
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'defaults MaxSizeBytes to 10485760 and RetentionCount to 5' {
        $defaults = InModuleScope Logging {
            [pscustomobject]@{
                MaxSizeBytes   = $script:LogMaxSizeBytes
                RetentionCount = $script:LogRetentionCount
            }
        }

        $defaults.MaxSizeBytes | Should -Be 10485760
        $defaults.RetentionCount | Should -Be 5
    }

    It 'does not rotate when the active log is below the size cap' {
        Set-LogRotationPolicy -MaxSizeBytes 1048576 -RetentionCount 5

        1..5 | ForEach-Object { Write-Log -Level Info -Message "line $_" }

        # Get-ChildItem -Filter uses legacy Win32 8.3 matching, where a
        # trailing ".*" pattern also matches a file with NO extension
        # (e.g. 'pusher.log' itself) -- use PowerShell's own -like operator
        # via Where-Object instead for an exact, non-legacy match.
        $rotatedFiles = Get-ChildItem -Path (Join-Path $TestDrive 'state/logs') -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'pusher.log.*' }
        @($rotatedFiles).Count | Should -Be 0
    }

    It 'rotates and bounds total pusher.log* file count at RetentionCount + 1 over sustained volume' {
        Set-LogRotationPolicy -MaxSizeBytes 500 -RetentionCount 3

        1..200 | ForEach-Object { Write-Log -Level Info -Message "sustained volume line $_ padding padding padding padding" }

        $allLogFiles = Get-ChildItem -Path (Join-Path $TestDrive 'state/logs') |
            Where-Object { $_.Name -like 'pusher.log*' }
        @($allLogFiles).Count | Should -BeLessOrEqual 4
        Test-Path -LiteralPath (Join-Path $TestDrive 'state/logs/pusher.log.1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $TestDrive 'state/logs/pusher.log.4') | Should -BeFalse
    }

    It 'writes successfully immediately after a rotation (A2)' {
        Set-LogRotationPolicy -MaxSizeBytes 100 -RetentionCount 2

        1..20 | ForEach-Object { Write-Log -Level Info -Message "line $_ padding to exceed the tiny cap" }

        { Write-Log -Level Info -Message 'post-rotation write' } | Should -Not -Throw

        $activeLogContent = Get-Content -LiteralPath (Join-Path $TestDrive 'state/logs/pusher.log') -Raw
        $activeLogContent | Should -Match 'post-rotation write'
    }

    It 'retries a transient IOException during rotation instead of throwing (AV/indexer lock, A2)' {
        Set-LogRotationPolicy -MaxSizeBytes 10 -RetentionCount 2
        Write-Log -Level Info -Message 'seed line to create the active log file well over the tiny cap'

        $script:moveAttemptCount = 0
        Mock -CommandName Move-Item -ModuleName Logging -MockWith {
            $script:moveAttemptCount++
            if ($script:moveAttemptCount -eq 1) {
                throw [System.IO.IOException]::new('simulated transient AV/indexer lock')
            }
        }

        { Write-Log -Level Info -Message 'trigger rotation against the mocked lock' } | Should -Not -Throw
        $script:moveAttemptCount | Should -BeGreaterThan 1
    }
}

# 261018: Write-Log runs on the supervisor's main thread under $ErrorActionPreference =
# 'Stop'. A log-file I/O failure (AV/indexer lock, a torn rotation, disk full) used to
# throw out of Write-Log and end the supervisor with no log line -- the silent-death
# signature of 2026-10-04. File I/O in Write-Log is now best-effort and never throws;
# the console/error-stream emit still happens so the line is not lost entirely.
Describe 'Write-Log never throws on log-file I/O (261018)' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:ModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
    }

    AfterEach {
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'does not throw at Info when Add-Content throws an IOException, and still emits to the console' {
        Mock -ModuleName Logging Add-Content { throw [System.IO.IOException]::new('locked') }
        Mock -ModuleName Logging Write-Host { }

        { Write-Log -Level Info -Message 'log file is locked' } | Should -Not -Throw

        Should -Invoke -ModuleName Logging Write-Host -Times 1 -Exactly
    }

    It 'does not throw at Error under ErrorActionPreference Stop when Add-Content throws an IOException' {
        Mock -ModuleName Logging Add-Content { throw [System.IO.IOException]::new('locked') }

        $ErrorActionPreference = 'Stop'

        { Write-Log -Level Error -Message 'log file is locked' -ErrorAction Stop 2>$null } | Should -Not -Throw
    }

    It 'still appends the line when rotation fails (rotation and append are independent best-effort steps)' {
        Set-LogRotationPolicy -MaxSizeBytes 10 -RetentionCount 2
        Write-Log -Level Info -Message 'seed line to push the active log well over the tiny cap'
        Mock -ModuleName Logging Move-Item { throw [System.IO.IOException]::new('rotation locked') }
        Mock -ModuleName Logging Start-Sleep { }

        Write-Log -Level Info -Message 'appended despite a failed rotation'

        Get-Content -LiteralPath (Get-LogFilePath) -Raw | Should -BeLike '*appended despite a failed rotation*'
    }

    It 'does not throw when every rotation Move-Item fails' {
        Set-LogRotationPolicy -MaxSizeBytes 10 -RetentionCount 2
        Write-Log -Level Info -Message 'seed line to push the active log well over the tiny cap'
        Mock -ModuleName Logging Move-Item { throw [System.IO.IOException]::new('rotation locked') }
        Mock -ModuleName Logging Start-Sleep { }

        { Write-Log -Level Info -Message 'trigger rotation against a permanently locked chain' } | Should -Not -Throw
    }
}

Describe 'Get-ProcessIdentityLogText (261018)' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:ModulePath -Force
    }

    AfterEach {
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'names the pid, ppid, user, session and start time of this process' {
        $identityText = Get-ProcessIdentityLogText

        $identityText | Should -BeLike "*pid=$PID*"
        $identityText | Should -BeLike '*ppid=*'
        $identityText | Should -BeLike '*user=*'
        $identityText | Should -BeLike '*session=*'
        $identityText | Should -BeLike '*started=*'
    }

    It 'falls back to exactly the pid and does not throw when the process lookup fails' {
        Mock -ModuleName Logging Get-Process { throw 'simulated process lookup failure' }

        $identityText = Get-ProcessIdentityLogText

        $identityText | Should -Be "pid=$PID"
    }

    It 'renders an unreadable parent process as ppid=unknown, never ppid=none' {
        Mock -ModuleName Logging Get-Process {
            [pscustomobject]@{ Parent = $null; SessionId = 0; StartTime = [datetime]::Now }
        }

        $identityText = Get-ProcessIdentityLogText

        $identityText | Should -BeLike '*ppid=unknown*'
        $identityText | Should -Not -BeLike '*ppid=none*'
    }
}

# Startup.Tests.ps1
# Proves the pusher.ps1 exit-code contract (D-12/SVC-01) and the redacted
# startup log line (D-07/T-04-12) end-to-end, by spawning a real pwsh process
# against a scratch .env fixture -- config load + validate happens BEFORE any
# hot-path module import, so both cases here resolve fast and bounded (no
# ffmpeg spawn on the invalid path; a quick uncaught "no recording file yet"
# exception on the valid path, well before any real streaming would start).
#
# The scratch pusher copy is written into the repo root (sibling of lib/), the
# same $PSScriptRoot trick tests/TestHelpers.psm1's New-TestTunedPusherCopy
# already uses, so lib/Config.psm1 etc still resolve correctly from the copy.
# Only the single top-of-script `$envPath = ...` assignment line is rewritten
# to point at a per-test .env fixture, leaving every other tuning variable at
# its real Config.psm1-sourced default.

BeforeAll {
    $script:RepoRootPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:PusherSourcePath = Join-Path $script:RepoRootPath 'pusher.ps1'

    function New-TestTunedStartupPusherCopy {
        <#
        .SYNOPSIS
        Writes a scratch copy of pusher.ps1 into the repo root with the
        top-of-script `$envPath = ...` line rewritten to EnvFilePath, mirroring
        TestHelpers.psm1's New-TestTunedPusherCopy regex-rewrite convention.
        #>
        param(
            [Parameter(Mandatory)] [string] $EnvFilePath
        )

        $pusherSource = Get-Content -LiteralPath $script:PusherSourcePath -Raw
        $pusherSource = $pusherSource -replace "(?m)^\`$envPath\s*=.*$", "`$envPath = '$EnvFilePath'"

        $testPusherPath = Join-Path $script:RepoRootPath (".pusher.startuptest.{0}.ps1" -f ([Guid]::NewGuid()))
        Set-Content -LiteralPath $testPusherPath -Value $pusherSource -Encoding utf8
        return $testPusherPath
    }

    function Invoke-PusherProcessBounded {
        <#
        .SYNOPSIS
        Spawns pwsh -NoProfile -File ScriptPath, waits up to TimeoutMilliseconds,
        and force-kills + fails loudly on timeout so a startup-contract bug can
        never hang the test suite. Returns ExitCode/StdOut/StdErr.

        -WaitForLogPattern (260809-ow9, START-STALE-01): since the stale-file Start
        guard, a pusher pointed at an EMPTY recording folder no longer dies quickly
        on a loud FileNotFound (WR-05's old behavior) -- it parks in the bounded
        wait loop instead, so a caller that only cares about the config-load/
        validate contract (not the guard's own wait behavior) must poll the
        redirected output for a log line instead of waiting on process exit. When
        supplied, this polls StdOut/StdErr for Pattern up to TimeoutMilliseconds,
        force-kills the still-running (deliberately waiting) process either way,
        and returns the captured StdOut/StdErr plus a PatternSeen boolean.
        ExitCode is always $null in this mode -- the process is killed while still
        alive by design, so its exit code carries no contract meaning here.
        #>
        param(
            [Parameter(Mandatory)] [string] $ScriptPath,
            [int] $TimeoutMilliseconds = 15000,
            [string] $WaitForLogPattern
        )

        $stdoutPath = [System.IO.Path]::GetTempFileName()
        $stderrPath = [System.IO.Path]::GetTempFileName()
        try {
            $process = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $ScriptPath) `
                -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

            if ($PSBoundParameters.ContainsKey('WaitForLogPattern')) {
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $patternSeen = $false
                while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
                    $combinedOutput = (Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue) + "`n" + `
                        (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue)
                    if ($combinedOutput -match $WaitForLogPattern) {
                        $patternSeen = $true
                        break
                    }
                    if ($process.HasExited) { break }
                    Start-Sleep -Milliseconds 100
                }

                if (-not $process.HasExited) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    $process.WaitForExit(5000) | Out-Null
                }

                return @{
                    ExitCode    = $null
                    StdOut      = Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
                    StdErr      = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
                    PatternSeen = $patternSeen
                }
            }

            $exitedInTime = $process.WaitForExit($TimeoutMilliseconds)
            if (-not $exitedInTime) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                throw "pusher process at '$ScriptPath' did not exit within ${TimeoutMilliseconds}ms -- killed to keep the test bounded"
            }

            return @{
                ExitCode = $process.ExitCode
                StdOut   = Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
                StdErr   = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
            }
        } finally {
            Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'pusher.ps1 startup config contract' -Tag 'Quick' {

    BeforeEach {
        $script:TestPusherPath = $null
    }

    AfterEach {
        if ($script:TestPusherPath -and (Test-Path -LiteralPath $script:TestPusherPath)) {
            Remove-Item -LiteralPath $script:TestPusherPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exits with the config-error code (2) and spawns no ffmpeg process on an out-of-range RELAY_PORT' {
        $recordingFolder = Join-Path $TestDrive 'recording'
        New-Item -ItemType Directory -Path $recordingFolder -Force | Out-Null

        # RELAY_PORT=99999 coerces successfully to [int] (so it is NOT silently
        # replaced by the schema default, unlike a non-numeric value would be --
        # ConvertTo-CoercedConfigValue only falls back to the default on a coercion
        # FAILURE) but is out of the valid 1-65535 range, so Test-PusherConfig
        # reports it as a genuine deployment-critical problem (D-08).
        $envContent = @(
            "RECORDING_FOLDER_PATH=$recordingFolder"
            'RELAY_PORT=99999'
        ) -join "`n"
        $envFilePath = Join-Path $TestDrive '.env.invalid-port'
        Set-Content -LiteralPath $envFilePath -Value $envContent -Encoding utf8

        $script:TestPusherPath = New-TestTunedStartupPusherCopy -EnvFilePath $envFilePath

        $ffmpegCountBefore = @(Get-Process -Name ffmpeg -ErrorAction SilentlyContinue).Count

        $result = Invoke-PusherProcessBounded -ScriptPath $script:TestPusherPath

        $result.ExitCode | Should -Be 2
        $result.StdErr | Should -Match 'RELAY_PORT'
        $result.StdErr | Should -Match 'not a valid port number'

        $ffmpegCountAfter = @(Get-Process -Name ffmpeg -ErrorAction SilentlyContinue).Count
        $ffmpegCountAfter | Should -Be $ffmpegCountBefore
    }

    It 'does not exit with the config-error code when all critical config is valid' {
        $recordingFolder = Join-Path $TestDrive 'recording'
        New-Item -ItemType Directory -Path $recordingFolder -Force | Out-Null

        # Every deployment-critical key (RelayHost/RelayPort/RecordingFolderPath)
        # is valid here -- Test-PusherConfig's problems list is empty, so the
        # config-error exit path (2) must never fire. Since the START-STALE-01
        # stale-file Start guard (260809-ow9), the process no longer dies quickly
        # on the empty recording folder (WR-05's old loud FileNotFound is
        # superseded by the guard's bounded wait) -- it parks waiting instead, so
        # this test polls for the config-OK log line rather than process exit.
        # Reaching that line while still alive proves the contract being tested
        # ("valid config never takes the exit-2 path") at least as strongly as an
        # exit-code assertion would.
        $envContent = @(
            "RECORDING_FOLDER_PATH=$recordingFolder"
            'RELAY_HOST=127.0.0.1'
            'RELAY_PORT=8890'
        ) -join "`n"
        $envFilePath = Join-Path $TestDrive '.env.valid'
        Set-Content -LiteralPath $envFilePath -Value $envContent -Encoding utf8

        $script:TestPusherPath = New-TestTunedStartupPusherCopy -EnvFilePath $envFilePath

        $result = Invoke-PusherProcessBounded -ScriptPath $script:TestPusherPath -WaitForLogPattern 'Config loaded and validated'

        $result.PatternSeen | Should -BeTrue
        $result.StdOut | Should -Match 'Config loaded and validated'
        $result.StdErr | Should -Not -Match 'Config validation failed'
        # Exact-value check on the SrtPassphrase JSON property, rather than a
        # generic negative-lookahead scan: \W* is greedy and, on a blank
        # `"SrtPassphrase":""` value, happily consumes past the empty pair of
        # quotes into the FOLLOWING property's leading `"` -- satisfying the
        # lookahead against the wrong text and producing a false positive
        # match (confirmed: matches into `,"StateFilePath` on the blank case).
        # Asserting the exact safe values (blank or the redaction marker)
        # sidesteps that backtracking entirely.
        $result.StdOut | Should -Match '"SrtPassphrase":""|"SrtPassphrase":"\*\*\*REDACTED\*\*\*"'
    }

    It 'never emits the SRT passphrase in the startup summary log line, even when one is set' {
        $recordingFolder = Join-Path $TestDrive 'recording'
        New-Item -ItemType Directory -Path $recordingFolder -Force | Out-Null

        $secretPassphrase = 'super-secret-church-passphrase-01'
        $envContent = @(
            "RECORDING_FOLDER_PATH=$recordingFolder"
            'RELAY_HOST=127.0.0.1'
            'RELAY_PORT=8890'
            "SRT_PASSPHRASE=$secretPassphrase"
        ) -join "`n"
        $envFilePath = Join-Path $TestDrive '.env.passphrase'
        Set-Content -LiteralPath $envFilePath -Value $envContent -Encoding utf8

        $script:TestPusherPath = New-TestTunedStartupPusherCopy -EnvFilePath $envFilePath

        # Same START-STALE-01 wait-instead-of-exit reason as the valid-config case
        # above -- poll for the config-OK log line rather than process exit.
        $result = Invoke-PusherProcessBounded -ScriptPath $script:TestPusherPath -WaitForLogPattern 'Config loaded and validated'

        $result.PatternSeen | Should -BeTrue
        $result.StdOut | Should -Not -Match ([regex]::Escape($secretPassphrase))
        $result.StdErr | Should -Not -Match ([regex]::Escape($secretPassphrase))
        $result.StdOut | Should -Match 'REDACTED'
    }

    It 'binds every -FileLastWriteTimeUtc argument in pusher.ps1 to a UTC-valued expression (260816-g70, START-STALE-02)' {
        # The 2026-08-16 investigation into the stale-file Start guard holding for 8
        # minutes suspected a local-vs-UTC mismatch at this call site: if
        # -FileLastWriteTimeUtc were ever bound to a plain (local-time) property, the
        # wall-clock freshness arm would compute a bogus multi-hour elapsed time and
        # never fire (this box is UTC+3). Investigation found the binding already
        # correct (pusher.ps1's sole call site passes a Utc-named expression) -- no
        # production fix was needed for that specific suspicion (the real bug was the
        # stale NTFS directory-entry read, fixed separately in lib/Rotation.psm1). This
        # test pins the already-correct binding so a future edit can never regress it
        # unnoticed.
        $pusherSourceText = Get-Content -LiteralPath $script:PusherSourcePath -Raw

        # Drop full-line comments before matching so header/prose mentioning the
        # parameter name in passing can never satisfy (or break) this gate -- only a
        # real argument-binding occurrence counts.
        $pusherSourceLines = $pusherSourceText -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }
        $pusherSourceWithoutComments = $pusherSourceLines -join "`n"

        $bindingPattern = '-FileLastWriteTimeUtc\s+(\$[A-Za-z_][A-Za-z0-9_.]*Utc)\b'
        $bindingMatches = [regex]::Matches($pusherSourceWithoutComments, $bindingPattern)

        # A zero-match regex must not silently pass -- assert at least one real
        # occurrence exists before asserting anything about its shape.
        $bindingMatches.Count | Should -BeGreaterThan 0 -Because 'pusher.ps1 must still call Test-RecordingFileFresh with -FileLastWriteTimeUtc at least once, or this test is vacuously true'

        foreach ($bindingMatch in $bindingMatches) {
            $boundExpression = $bindingMatch.Groups[1].Value
            $boundExpression | Should -Match 'Utc$' -Because "the -FileLastWriteTimeUtc argument '$boundExpression' must be bound to a UTC-named expression, never a local-time property"
        }
    }
}

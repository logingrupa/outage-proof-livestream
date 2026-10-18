# Install.Tests.ps1
# Unit tests for install.ps1 (SVC-01, SVC-02) -- Test-InstallPrerequisites,
# Get-OperatorAccountProblem, ConvertTo-WallClockStartBoundary,
# Register-SupervisorScheduledTask (the 'GaplessSupervisor' S4U operator task),
# Remove-LegacySupervisorScheduledTask (retires the legacy 'GaplessSrtPusher'
# SYSTEM task only after a successful registration), Register-TunnelScheduledTask,
# Invoke-Install, Initialize-PusherEnvFile. install.ps1 is a
# top-level script, not a module (04-PATTERNS.md), so it is dot-sourced here
# (never invoked directly) so its functions are mockable via plain `Mock` in
# this file's own scope -- the `if ($MyInvocation.InvocationName -ne '.')`
# guard at the bottom of install.ps1 keeps Invoke-Install from actually
# running (and exiting the test process) on dot-source.
#
# Real Scheduled Task registration needs elevation + a real Windows box and is
# NEVER exercised here. The real reboot/Session-0 verification is deferred
# manual UAT (see 04-04-PLAN.md user_setup).

BeforeAll {
    $script:InstallScriptPath = Join-Path $PSScriptRoot '../install.ps1'
    $script:LoggingModulePath = Join-Path $PSScriptRoot '../lib/Logging.psm1'
}

Describe 'install.ps1' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force

        # Dot-source (not `&`) so install.ps1's functions land in THIS scope.
        . $script:InstallScriptPath

        # AFTER the dot-source on purpose: install.ps1 runs `Import-Module lib/Logging.psm1
        # -Force`, which resets the log directory to the checkout's real state/logs. Set
        # before it, an unmocked Write-Log would append to the real pusher.log.
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')

        # Read-only on a real machine, but a mock keeps every test off the live task list.
        Mock Get-ScheduledTaskInfo { $null }

        # Fail-closed defaults (D-10): a test that reaches a MUTATING Scheduled
        # Task cmdlet without mocking it must fail loudly instead of touching the
        # machine's real tasks. Context- and It-level mocks defined later override
        # these.
        Mock Register-ScheduledTask { throw 'unmocked Register-ScheduledTask reached -- every test that reaches a Scheduled Task cmdlet must mock it' }
        Mock Unregister-ScheduledTask { throw 'unmocked Unregister-ScheduledTask reached -- every test that reaches a Scheduled Task cmdlet must mock it' }
        Mock Disable-ScheduledTask { throw 'unmocked Disable-ScheduledTask reached -- every test that reaches a Scheduled Task cmdlet must mock it' }
        Mock Enable-ScheduledTask { throw 'unmocked Enable-ScheduledTask reached -- every test that reaches a Scheduled Task cmdlet must mock it' }
        Mock Start-ScheduledTask { throw 'unmocked Start-ScheduledTask reached -- every test that reaches a Scheduled Task cmdlet must mock it' }
        Mock Stop-ScheduledTask { throw 'unmocked Stop-ScheduledTask reached -- every test that reaches a Scheduled Task cmdlet must mock it' }
        Mock Set-ScheduledTask { throw 'unmocked Set-ScheduledTask reached -- every test that reaches a Scheduled Task cmdlet must mock it' }
    }

    AfterEach {
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    Context 'Test-InstallPrerequisites' {

        BeforeEach {
            # Every It below is independent of the runner's own Windows identity.
            Mock Get-OperatorAccountProblem { '' }
        }

        It 'returns an actionable "re-run as Administrator" problem when not elevated' {
            Mock Test-IsElevatedProcess { $false }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\pwsh\pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh.exe' }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\ffmpeg\ffmpeg.exe' } } -ParameterFilter { $Name -eq 'ffmpeg' }
            Mock Get-FfmpegProtocolsOutput { 'Supported protocols: ... srt ...' }

            $problems = Test-InstallPrerequisites

            ($problems | Where-Object { $_ -match 'Administrator' }) | Should -Not -BeNullOrEmpty
        }

        It 'returns a specific problem when pwsh is not found' {
            Mock Test-IsElevatedProcess { $true }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'pwsh.exe' }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\ffmpeg\ffmpeg.exe' } } -ParameterFilter { $Name -eq 'ffmpeg' }
            Mock Get-FfmpegProtocolsOutput { 'Supported protocols: ... srt ...' }

            $problems = Test-InstallPrerequisites

            ($problems | Where-Object { $_ -match 'pwsh' }) | Should -Not -BeNullOrEmpty
        }

        It 'returns a specific problem when ffmpeg is not found' {
            Mock Test-IsElevatedProcess { $true }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\pwsh\pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh.exe' }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'ffmpeg' }

            $problems = Test-InstallPrerequisites

            ($problems | Where-Object { $_ -match 'ffmpeg' }) | Should -Not -BeNullOrEmpty
        }

        It 'returns a specific problem when ffmpeg lists no srt protocol support' {
            Mock Test-IsElevatedProcess { $true }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\pwsh\pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh.exe' }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\ffmpeg\ffmpeg.exe' } } -ParameterFilter { $Name -eq 'ffmpeg' }
            Mock Get-FfmpegProtocolsOutput { 'Supported protocols: file, http, rtmp' }

            $problems = Test-InstallPrerequisites

            ($problems | Where-Object { $_ -match 'srt' }) | Should -Not -BeNullOrEmpty
        }

        It 'returns an empty problems list for a fully valid mocked environment' {
            Mock Test-IsElevatedProcess { $true }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\pwsh\pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh.exe' }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\ffmpeg\ffmpeg.exe' } } -ParameterFilter { $Name -eq 'ffmpeg' }
            Mock Get-FfmpegProtocolsOutput { 'Supported protocols: ... srt ...' }

            # Plain assignment, no @() wrapper around the call (unary-comma contract).
            $problems = Test-InstallPrerequisites

            @($problems).Count | Should -Be 0
            # No-arg call: OperatorUserName defaults to the running identity.
            Should -Invoke Get-OperatorAccountProblem -Times 1 -Exactly -ParameterFilter {
                $OperatorUserName -eq [Security.Principal.WindowsIdentity]::GetCurrent().Name
            }
        }

        It 'includes the operator-account problem when Get-OperatorAccountProblem reports one' {
            Mock Test-IsElevatedProcess { $true }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\pwsh\pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh.exe' }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\ffmpeg\ffmpeg.exe' } } -ParameterFilter { $Name -eq 'ffmpeg' }
            Mock Get-FfmpegProtocolsOutput { 'Supported protocols: ... srt ...' }
            Mock Get-OperatorAccountProblem { 'operator problem' }

            $problems = Test-InstallPrerequisites -OperatorUserName 'TESTPC\operator'

            $problems | Should -Contain 'operator problem'
        }
    }

    Context 'Get-OperatorAccountProblem' {
        # Real NTAccount translation: safe non-elevated, touches no task.

        It 'reports a problem naming SYSTEM for NT AUTHORITY\SYSTEM' {
            $problem = Get-OperatorAccountProblem -OperatorUserName 'NT AUTHORITY\SYSTEM'

            $problem | Should -Not -BeNullOrEmpty
            $problem | Should -Match 'SYSTEM'
        }

        It 'reports a problem for an account that cannot be resolved' {
            $unresolvableName = "NoSuchDomain-$([Guid]::NewGuid())\nobody-$([Guid]::NewGuid())"

            $problem = Get-OperatorAccountProblem -OperatorUserName $unresolvableName

            $problem | Should -Not -BeNullOrEmpty
            $problem | Should -Match 'cannot be resolved'
        }

        It 'returns an empty string for the current identity' {
            $currentIdentityName = [Security.Principal.WindowsIdentity]::GetCurrent().Name

            Get-OperatorAccountProblem -OperatorUserName $currentIdentityName | Should -Be ''
        }

        It 'reports a service-account-or-group problem for <AccountName>' -ForEach @(
            @{ AccountName = 'NT AUTHORITY\LOCAL SERVICE' }
            @{ AccountName = 'NT AUTHORITY\NETWORK SERVICE' }
            @{ AccountName = 'BUILTIN\Administrators' }
        ) {
            $problem = Get-OperatorAccountProblem -OperatorUserName $AccountName

            $problem | Should -Not -BeNullOrEmpty
            $problem | Should -Match 'service account or group, not a user'
        }

        It 'reports a blank-account problem instead of throwing when the name is "<AccountName>"' -ForEach @(
            @{ AccountName = '' }
            @{ AccountName = '   ' }
        ) {
            # A direct call: a throw from parameter binding fails this test on its own.
            $problem = Get-OperatorAccountProblem -OperatorUserName $AccountName

            $problem | Should -Match 'blank'
            $problem | Should -Match '-OperatorUserName'
        }

        It 'Test-InstallPrerequisites keeps its never-throws contract and lists the blank account as a problem' {
            Mock Test-IsElevatedProcess { $true }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\pwsh\pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh.exe' }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\ffmpeg\ffmpeg.exe' } } -ParameterFilter { $Name -eq 'ffmpeg' }
            Mock Get-FfmpegProtocolsOutput { 'Supported protocols: ... srt ...' }

            $problems = Test-InstallPrerequisites -OperatorUserName ''

            @($problems).Count | Should -Be 1
            $problems[0] | Should -Match 'blank'
        }
    }

    Context 'ConvertTo-WallClockStartBoundary' {

        It 'builds an offset-free local wall-clock boundary for the given day' {
            $boundary = ConvertTo-WallClockStartBoundary -TimeOfDay '04:05' -Today ([datetime]'2026-10-25')

            $boundary | Should -BeExactly '2026-10-25T04:05:00'
            $boundary | Should -Not -Match '([+-]\d\d:\d\d|Z)$'
        }
    }

    Context 'Invoke-Install (main flow, every prerequisite passing)' {
        # The all-prerequisites-PASS path is the ONLY path that reaches
        # registration, and it was never driven end-to-end before -- every earlier
        # test stopped at Test-InstallPrerequisites. That gap hid a real installer
        # crash: an empty problems list collapsed to $null, so `$problems.Count`
        # threw under Set-StrictMode -Version Latest and install.ps1 died before
        # Register-SupervisorScheduledTask ever ran. The installer therefore worked
        # only when prerequisites FAILED. These tests assert the flow itself, not
        # the shape of the problems list, and must never wrap the result in @() --
        # @($null).Count is 0, which is exactly what masked the bug.

        BeforeEach {
            Mock Test-IsElevatedProcess { $true }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\pwsh\pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh.exe' }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\ffmpeg\ffmpeg.exe' } } -ParameterFilter { $Name -eq 'ffmpeg' }
            Mock Get-FfmpegProtocolsOutput { 'Supported protocols: ... srt ...' }
            Mock Get-ScheduledTask { $null }
            Mock Register-ScheduledTask { }
            Mock Get-OperatorAccountProblem { '' }
            Mock Remove-LegacySupervisorScheduledTask { }
            # Invoke-Install passes install.ps1's own $PSScriptRoot (the real repo
            # root) to Initialize-PusherEnvFile -- mock it so the operator's real
            # .env is never a participant in this test.
            Mock Initialize-PusherEnvFile { }
        }

        It 'does not throw when every prerequisite passes' {
            { Invoke-Install -OperatorUserName 'TESTPC\operator' } | Should -Not -Throw
        }

        It 'registers the Scheduled Task when every prerequisite passes' {
            Invoke-Install -OperatorUserName 'TESTPC\operator'

            Should -Invoke Register-ScheduledTask -Times 1 -Exactly
        }

        It 'registers the supervisor task under the name GaplessSupervisor' {
            Invoke-Install -OperatorUserName 'TESTPC\operator'

            Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'GaplessSupervisor' }
        }

        It 'performs the first-run .env copy before registering' {
            Invoke-Install -OperatorUserName 'TESTPC\operator'

            Should -Invoke Initialize-PusherEnvFile -Times 1 -Exactly
        }

        It 'returns the success exit code when every prerequisite passes' {
            Invoke-Install -OperatorUserName 'TESTPC\operator' | Should -Be 0
        }

        It 'removes the legacy task only after the new registration, and still returns 0' {
            $script:callOrder = [System.Collections.Generic.List[string]]::new()
            Mock Register-SupervisorScheduledTask { $script:callOrder.Add('register') }
            Mock Remove-LegacySupervisorScheduledTask { $script:callOrder.Add('remove-legacy') }

            $exitCode = Invoke-Install -OperatorUserName 'TESTPC\operator'

            @($script:callOrder) | Should -Be @('register', 'remove-legacy')
            $exitCode | Should -Be 0
        }

        It 'returns the distinct exit code 3 and logs "Install incomplete" instead of "Install complete" when the legacy task was left running' {
            Mock Remove-LegacySupervisorScheduledTask { $true }
            $script:capturedLogLines = [System.Collections.Generic.List[string]]::new()
            Mock Write-Log { $script:capturedLogLines.Add("$Level|$Message") }

            $exitCode = Invoke-Install -OperatorUserName 'TESTPC\operator'

            $exitCode | Should -Be 3
            @($script:capturedLogLines | Where-Object { $_ -like 'Error|Install incomplete -- action required*' }).Count | Should -Be 1
            @($script:capturedLogLines | Where-Object { $_ -like '*Install complete*' }).Count | Should -Be 0
        }

        It 'returns 0 when the legacy task removal reports it was not left running' {
            Mock Remove-LegacySupervisorScheduledTask { $false }

            Invoke-Install -OperatorUserName 'TESTPC\operator' | Should -Be 0
        }

        It 'never reaches legacy removal when the registration throws (never zero supervisor tasks)' {
            Mock Register-SupervisorScheduledTask { throw 'simulated registration failure' }

            { Invoke-Install -OperatorUserName 'TESTPC\operator' } | Should -Throw

            Should -Invoke Remove-LegacySupervisorScheduledTask -Times 0 -Exactly
        }
    }

    Context 'Invoke-Install (prerequisite failure aborts before any change)' {

        BeforeEach {
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\pwsh\pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh.exe' }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\ffmpeg\ffmpeg.exe' } } -ParameterFilter { $Name -eq 'ffmpeg' }
            Mock Get-FfmpegProtocolsOutput { 'Supported protocols: ... srt ...' }
            Mock Get-ScheduledTask { $null }
            Mock Register-ScheduledTask { }
            Mock Get-OperatorAccountProblem { '' }
            Mock Remove-LegacySupervisorScheduledTask { }
            Mock Initialize-PusherEnvFile { }
        }

        It 'returns the prerequisite-failure exit code and registers nothing when a single prerequisite fails' {
            # Exactly ONE problem is the sibling collapse case: a one-element array
            # returned bare collapses to a scalar string, whose .Count is 1 by
            # PowerShell's scalar-unification rule -- accidentally correct here, but
            # never relied upon. Pin the real contract: abort, register nothing.
            Mock Test-IsElevatedProcess { $false }

            Invoke-Install -OperatorUserName 'TESTPC\operator' | Should -Be 1

            Should -Invoke Register-ScheduledTask -Times 0 -Exactly
            Should -Invoke Remove-LegacySupervisorScheduledTask -Times 0 -Exactly
            Should -Invoke Initialize-PusherEnvFile -Times 0 -Exactly
        }
    }

    Context 'Register-SupervisorScheduledTask' {

        BeforeEach {
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\Program Files\PowerShell\7\pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh.exe' }
            Mock Get-ScheduledTask { $null }
            Mock Register-ScheduledTask { }
        }

        It 'registers exactly one task on a fresh install (no existing task)' {
            Register-SupervisorScheduledTask -ScriptRoot $TestDrive -OperatorUserName 'TESTPC\operator'

            Should -Invoke Register-ScheduledTask -Times 1 -Exactly
        }

        It 'still results in exactly one registration per call when an existing task of the same name is found (idempotent rerun, no duplicate, no throw)' {
            Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'GaplessSupervisor' } }

            { Register-SupervisorScheduledTask -ScriptRoot $TestDrive -OperatorUserName 'TESTPC\operator' } | Should -Not -Throw
            { Register-SupervisorScheduledTask -ScriptRoot $TestDrive -OperatorUserName 'TESTPC\operator' } | Should -Not -Throw

            Should -Invoke Register-ScheduledTask -Times 2 -Exactly
        }

        It 'is registered under the fixed TaskName GaplessSupervisor' {
            Register-SupervisorScheduledTask -ScriptRoot $TestDrive -OperatorUserName 'TESTPC\operator'

            Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'GaplessSupervisor' }
        }

        It 'builds the Action with the absolute resolved pwsh path, explicit WorkingDirectory, and -ExecutionPolicy Bypass -NoProfile -File (absolute supervisor.ps1 path)' {
            # The task launches supervisor.ps1, NOT pusher.ps1. Two reasons, both
            # load-bearing: boot must be IDLE (a reboot must never start pushing to a
            # LIVE YouTube audience with nobody in the room -- only start.ps1 or the
            # dashboard's Start button may), and the supervisor is the actual
            # process-death restart mechanism, since these task settings were proven
            # not to restart the action on a non-zero exit at all.
            $script:capturedAction = $null
            Mock Register-ScheduledTask -MockWith { $script:capturedAction = $Action }

            Register-SupervisorScheduledTask -ScriptRoot $TestDrive -OperatorUserName 'TESTPC\operator'

            $expectedScriptPath = Join-Path $TestDrive 'supervisor.ps1'
            $script:capturedAction.Execute | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
            $script:capturedAction.Arguments.Contains($expectedScriptPath) | Should -BeTrue
            $script:capturedAction.Arguments.Contains('-ExecutionPolicy Bypass') | Should -BeTrue
            $script:capturedAction.Arguments.Contains('-NoProfile') | Should -BeTrue
            $script:capturedAction.WorkingDirectory | Should -Be $TestDrive
        }

        It 'uses a boot trigger plus an offset-free daily 04:05 watchdog trigger' {
            Register-SupervisorScheduledTask -ScriptRoot $TestDrive -OperatorUserName 'TESTPC\operator'

            Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                $Trigger.Count -eq 2 -and
                $Trigger[0].CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' -and
                $Trigger[1].CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger' -and
                $Trigger[1].DaysInterval -eq 1 -and
                $Trigger[1].StartBoundary -match 'T04:05:00$' -and
                $Trigger[1].StartBoundary -notmatch '([+-]\d\d:\d\d|Z)$'
            }
        }

        It 'repeats the daily watchdog trigger every 5 minutes for 1 day and never stops a running supervisor at the end of the repetition (Tier 2, 261018)' {
            Register-SupervisorScheduledTask -ScriptRoot $TestDrive -OperatorUserName 'TESTPC\operator'

            Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                $Trigger[1].Repetition.Interval -eq 'PT5M' -and
                $Trigger[1].Repetition.Duration -eq 'P1D' -and
                $Trigger[1].Repetition.StopAtDurationEnd -eq $false
            }
        }

        It 'runs as the operator account with S4U logon and Limited run level' {
            Register-SupervisorScheduledTask -ScriptRoot $TestDrive -OperatorUserName 'TESTPC\operator'

            Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                $Principal.UserId -eq 'TESTPC\operator' -and
                $Principal.LogonType -eq 'S4U' -and
                $Principal.RunLevel -eq 'Limited'
            }
        }

        It 'sets no execution time limit, battery-proof flags, restart settings and MultipleInstances IgnoreNew' {
            Register-SupervisorScheduledTask -ScriptRoot $TestDrive -OperatorUserName 'TESTPC\operator'

            Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                $Settings.ExecutionTimeLimit -eq 'PT0S' -and
                $Settings.DisallowStartIfOnBatteries -eq $false -and
                $Settings.StopIfGoingOnBatteries -eq $false -and
                $Settings.StartWhenAvailable -and
                $Settings.RestartCount -eq 999 -and
                $Settings.MultipleInstances -eq 'IgnoreNew'
            }
        }

        It 'passes the -Force switch for idempotent overwrite (SVC-02)' {
            Register-SupervisorScheduledTask -ScriptRoot $TestDrive -OperatorUserName 'TESTPC\operator'

            Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                $Force -eq $true
            }
        }
    }

    Context 'Remove-LegacySupervisorScheduledTask' {

        It 'touches nothing when the legacy task is absent' {
            Mock Get-ScheduledTask { $null }
            Mock Disable-ScheduledTask { }
            Mock Unregister-ScheduledTask { }

            Remove-LegacySupervisorScheduledTask

            Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
            Should -Invoke Disable-ScheduledTask -Times 0 -Exactly
        }

        It 'unregisters the legacy task once when it is <State>' -ForEach @(
            @{ State = 'Ready' }
            @{ State = 'Disabled' }
        ) {
            $legacyState = $State
            Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'GaplessSrtPusher'; State = $legacyState } }
            Mock Disable-ScheduledTask { }
            Mock Unregister-ScheduledTask { }

            Remove-LegacySupervisorScheduledTask

            Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter {
                $TaskName -eq 'GaplessSrtPusher' -and $Confirm -eq $false
            }
            Should -Invoke Disable-ScheduledTask -Times 0 -Exactly
        }

        It 'disables (never unregisters, never stops) a running legacy task and warns that the process was left alone' {
            Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'GaplessSrtPusher'; State = 'Running' } }
            Mock Disable-ScheduledTask { }
            Mock Unregister-ScheduledTask { }
            $script:capturedWarnings = [System.Collections.Generic.List[string]]::new()
            Mock Write-Log -ParameterFilter { $Level -eq 'Warning' } -MockWith { $script:capturedWarnings.Add($Message) }

            $null = Remove-LegacySupervisorScheduledTask

            Should -Invoke Disable-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'GaplessSrtPusher' }
            Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
            Should -Invoke Stop-ScheduledTask -Times 0 -Exactly
            $script:capturedWarnings.Count | Should -Be 1
            $script:capturedWarnings[0] | Should -Match 'GaplessSrtPusher'
            $script:capturedWarnings[0] | Should -Match 'left alone'
        }

        It 'reports that a legacy task was left running, and only then' {
            Mock Disable-ScheduledTask { }
            Mock Unregister-ScheduledTask { }
            Mock Write-Log { }

            Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'GaplessSrtPusher'; State = 'Running' } }
            @(Remove-LegacySupervisorScheduledTask) | Should -Contain $true

            Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'GaplessSrtPusher'; State = 'Ready' } }
            @(Remove-LegacySupervisorScheduledTask) | Should -Not -Contain $true

            Mock Get-ScheduledTask { $null }
            @(Remove-LegacySupervisorScheduledTask) | Should -Not -Contain $true
        }

        It 'logs the last run time, the scheduler kill deadline and an actionable remedy for a running legacy task, without calling it a second supervisor' {
            Mock Get-ScheduledTask {
                [pscustomobject]@{
                    TaskName = 'GaplessSrtPusher'
                    State    = 'Running'
                    Settings = [pscustomobject]@{ ExecutionTimeLimit = 'PT72H' }
                }
            }
            Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime = [datetime]'2026-10-17T04:05:00' } }
            Mock Disable-ScheduledTask { }
            Mock Unregister-ScheduledTask { }
            $script:capturedWarnings = [System.Collections.Generic.List[string]]::new()
            Mock Write-Log -ParameterFilter { $Level -eq 'Warning' } -MockWith { $script:capturedWarnings.Add($Message) }

            $null = Remove-LegacySupervisorScheduledTask

            $script:capturedWarnings.Count | Should -Be 1
            $script:capturedWarnings[0] | Should -Match '2026-10-17 04:05:00'
            $script:capturedWarnings[0] | Should -Match '2026-10-20 04:05:00'
            $script:capturedWarnings[0] | Should -Match 'reboot'
            $script:capturedWarnings[0] | Should -Match 'no-stream window'
            $script:capturedWarnings[0] | Should -Match 'then re-run install.ps1 to delete the task'
            $script:capturedWarnings[0] | Should -Match 'is still running a supervisor \(possibly the only one\)'
            $script:capturedWarnings[0] | Should -Not -Match 'second supervisor'
            $script:capturedWarnings[0] | Should -Not -Match 'after the service'
        }

        It 'still warns when the run details cannot be read' {
            Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'GaplessSrtPusher'; State = 'Running' } }
            Mock Get-ScheduledTaskInfo { throw 'simulated task info failure' }
            Mock Disable-ScheduledTask { }
            $script:capturedWarnings = [System.Collections.Generic.List[string]]::new()
            Mock Write-Log -ParameterFilter { $Level -eq 'Warning' } -MockWith { $script:capturedWarnings.Add($Message) }

            { $null = Remove-LegacySupervisorScheduledTask } | Should -Not -Throw

            $script:capturedWarnings.Count | Should -Be 1
            $script:capturedWarnings[0] | Should -Match 'unknown'
        }
    }

    Context 'Register-TunnelScheduledTask (AO-01/D-09, 14.5-06)' {

        BeforeEach {
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\Program Files\PowerShell\7\pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh.exe' }
            Mock Get-ScheduledTask { $null }
            Mock Register-ScheduledTask { }

            # The guard added for QH6-01 requires the tunnel helper script to exist
            # before a task is registered -- seed a trivial stub at the exact path
            # Register-TunnelScheduledTask builds so the 6 pre-existing tests below
            # (which all assert a registration HAPPENS) keep passing.
            $tunnelHelperDirectory = Join-Path $TestDrive 'tools/bin'
            New-Item -ItemType Directory -Path $tunnelHelperDirectory -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $tunnelHelperDirectory 'tcp-relay-tunnel.ps1') -Value '# stub, never executed'
        }

        It 'registers exactly one task on a fresh install (no existing task)' {
            Register-TunnelScheduledTask -ScriptRoot $TestDrive

            Should -Invoke Register-ScheduledTask -Times 1 -Exactly
        }

        It 'is registered under its own fixed TaskName, distinct from the pusher task' {
            Register-TunnelScheduledTask -ScriptRoot $TestDrive

            Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'GaplessTcpRelayTunnel' }
        }

        It 'still results in exactly one registration per call when an existing task of the same name is found (idempotent rerun, no duplicate, no throw)' {
            Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'GaplessTcpRelayTunnel' } }

            { Register-TunnelScheduledTask -ScriptRoot $TestDrive } | Should -Not -Throw
            { Register-TunnelScheduledTask -ScriptRoot $TestDrive } | Should -Not -Throw

            Should -Invoke Register-ScheduledTask -Times 2 -Exactly
        }

        It 'builds the Action targeting tools/bin/tcp-relay-tunnel.ps1 with the absolute resolved pwsh path and explicit WorkingDirectory' {
            $script:capturedAction = $null
            Mock Register-ScheduledTask -MockWith { $script:capturedAction = $Action }

            Register-TunnelScheduledTask -ScriptRoot $TestDrive

            $expectedScriptPath = Join-Path $TestDrive 'tools/bin/tcp-relay-tunnel.ps1'
            $script:capturedAction.Execute | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
            $script:capturedAction.Arguments.Contains($expectedScriptPath) | Should -BeTrue
            $script:capturedAction.WorkingDirectory | Should -Be $TestDrive
        }

        It 'uses an -AtStartup trigger' {
            Register-TunnelScheduledTask -ScriptRoot $TestDrive

            Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                $Trigger[0].CimClass.CimClassName -eq 'MSFT_TaskBootTrigger'
            }
        }

        It 'adds an offset-free daily 04:00 watchdog trigger after the boot trigger' {
            Register-TunnelScheduledTask -ScriptRoot $TestDrive

            Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                $Trigger.Count -eq 2 -and
                $Trigger[0].CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' -and
                $Trigger[1].CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger' -and
                $Trigger[1].StartBoundary -match 'T04:00:00$' -and
                $Trigger[1].StartBoundary -notmatch '([+-]\d\d:\d\d|Z)$'
            }
        }

        It 'does not repeat its daily trigger (the five-minute watchdog belongs to the supervisor task only, 261018)' {
            Register-TunnelScheduledTask -ScriptRoot $TestDrive

            Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                ($null -eq $Trigger[1].Repetition) -or [string]::IsNullOrEmpty($Trigger[1].Repetition.Interval)
            }
        }

        It 'has no execution time limit and survives battery power (regression lock for the 2026-08-02 72 h kill)' {
            Register-TunnelScheduledTask -ScriptRoot $TestDrive

            Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                $Settings.ExecutionTimeLimit -eq 'PT0S' -and
                $Settings.DisallowStartIfOnBatteries -eq $false -and
                $Settings.StopIfGoingOnBatteries -eq $false
            }
        }

        It 'uses SYSTEM/ServiceAccount/Highest principal' {
            Register-TunnelScheduledTask -ScriptRoot $TestDrive

            Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                $Principal.UserId -eq 'SYSTEM' -and
                $Principal.LogonType -eq 'ServiceAccount' -and
                $Principal.RunLevel -eq 'Highest'
            }
        }

        It 'sets bounded RestartCount/RestartInterval and MultipleInstances IgnoreNew, and passes -Force' {
            Register-TunnelScheduledTask -ScriptRoot $TestDrive

            Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                $Settings.RestartCount -gt 0 -and
                $Settings.MultipleInstances -eq 'IgnoreNew' -and
                $Force -eq $true
            }
        }

        It 'does not throw, registers no task, and logs a Warning naming the resolved path when the tunnel helper script is missing (QH6-01)' {
            $missingScriptPath = Join-Path $TestDrive 'tools/bin/tcp-relay-tunnel.ps1'
            Remove-Item -LiteralPath $missingScriptPath -Force
            $script:capturedWarning = $null
            Mock Write-Log -ParameterFilter { $Level -eq 'Warning' } -MockWith { $script:capturedWarning = $Message }

            { Register-TunnelScheduledTask -ScriptRoot $TestDrive } | Should -Not -Throw

            Should -Invoke Register-ScheduledTask -Times 0 -Exactly
            $script:capturedWarning | Should -Match ([regex]::Escape($missingScriptPath))
        }

        It 'explains in the Warning that no tunnel task was registered and why it is safe when the helper script is missing (QH6-01)' {
            $missingScriptPath = Join-Path $TestDrive 'tools/bin/tcp-relay-tunnel.ps1'
            Remove-Item -LiteralPath $missingScriptPath -Force
            $script:capturedWarning = $null
            Mock Write-Log -ParameterFilter { $Level -eq 'Warning' } -MockWith { $script:capturedWarning = $Message }

            Register-TunnelScheduledTask -ScriptRoot $TestDrive

            $script:capturedWarning | Should -Match 'no.*Scheduled Task.*registered|no Scheduled Task was registered'
            $script:capturedWarning | Should -Match 'does not ship'
            $script:capturedWarning | Should -Match 'directly reachable'
        }
    }

    Context 'Find-RouteNextHopInterfaceIndex (route-only scoping, prohibition guard)' {

        It 'returns the interface index whose IPv4 address is on the next hop''s /24' {
            Mock Get-NetIPAddress {
                @(
                    [pscustomobject]@{ IPAddress = '10.0.0.5'; InterfaceIndex = 3 }
                    [pscustomobject]@{ IPAddress = '192.0.2.42'; InterfaceIndex = 15 }
                )
            }

            Find-RouteNextHopInterfaceIndex -NextHop '192.0.2.1' | Should -Be 15
        }

        It 'returns $null (never guesses/falls back) when no interface is on-link with the next hop' {
            Mock Get-NetIPAddress { @([pscustomobject]@{ IPAddress = '10.0.0.5'; InterfaceIndex = 3 }) }

            Find-RouteNextHopInterfaceIndex -NextHop '192.0.2.1' | Should -BeNullOrEmpty
        }

        It 'returns $null for a malformed next hop (never throws, never guesses)' {
            Find-RouteNextHopInterfaceIndex -NextHop 'not-an-ip' | Should -BeNullOrEmpty
        }
    }

    Context 'ConvertTo-DottedSubnetMask' {

        It 'converts a /32 prefix length to 255.255.255.255' {
            ConvertTo-DottedSubnetMask -PrefixLength 32 | Should -Be '255.255.255.255'
        }

        It 'converts a /24 prefix length to 255.255.255.0' {
            ConvertTo-DottedSubnetMask -PrefixLength 24 | Should -Be '255.255.255.0'
        }
    }

    Context 'Get-VpsRouteConfiguration (mockable seam -- no test ever reads the real .env)' {

        It 'returns blank/blank when the env file path does not exist' {
            $missingPath = Join-Path $TestDrive ([Guid]::NewGuid().ToString() + '.env')

            $result = Get-VpsRouteConfiguration -EnvFilePath $missingPath

            $result.DestinationPrefix | Should -BeNullOrEmpty
            $result.NextHop | Should -BeNullOrEmpty
        }

        It 'never throws (returns blank/blank) when the underlying config read throws' {
            Mock Read-PusherConfig { throw 'simulated read failure' }

            { $script:result = Get-VpsRouteConfiguration -EnvFilePath (Join-Path $TestDrive '.env') } | Should -Not -Throw
            $script:result.DestinationPrefix | Should -BeNullOrEmpty
            $script:result.NextHop | Should -BeNullOrEmpty
        }

        It 'returns the configured values verbatim when set' {
            $envPath = Join-Path $TestDrive ([Guid]::NewGuid().ToString() + '.env')
            [System.IO.File]::WriteAllText($envPath, "VPS_ROUTE_PREFIX=203.0.113.10/32`nVPS_ROUTE_NEXT_HOP=192.0.2.1`n")

            $result = Get-VpsRouteConfiguration -EnvFilePath $envPath

            $result.DestinationPrefix | Should -Be '203.0.113.10/32'
            $result.NextHop | Should -Be '192.0.2.1'
        }
    }

    Context 'Test-VpsRoutePersistent / Set-VpsRoutePersistent (config-driven, loud-skip-when-unconfigured)' {
        # Add-PersistentNetRoute (route.exe -p add) is mocked here rather than
        # New-NetRoute -- New-NetRoute -PolicyStore PersistentStore was proven
        # live to fail on the actual target church PC (Rule 1 environment-bug
        # fix, 14.5-06 Task 2); Add-PersistentNetRoute is the replacement
        # write path and the one this suite must pin. Every route test mocks
        # Get-VpsRouteConfiguration -- no test may reach a real .env file. RFC
        # 5737 documentation addresses (203.0.113.10/32, 192.0.2.1) stand in for
        # the real destination/next-hop throughout.

        It 'Test-VpsRoutePersistent returns $true when a PersistentStore route already exists' {
            Mock Get-NetRoute { [pscustomobject]@{ DestinationPrefix = '203.0.113.10/32' } } -ParameterFilter { $PolicyStore -eq 'PersistentStore' }

            Test-VpsRoutePersistent -DestinationPrefix '203.0.113.10/32' | Should -BeTrue
        }

        It 'Test-VpsRoutePersistent returns $false when no PersistentStore route exists' {
            Mock Get-NetRoute { $null } -ParameterFilter { $PolicyStore -eq 'PersistentStore' }

            Test-VpsRoutePersistent -DestinationPrefix '203.0.113.10/32' | Should -BeFalse
        }

        It 'Set-VpsRoutePersistent never calls Add-PersistentNetRoute or resolves an interface, does not throw, and logs a Warning naming both env keys when the destination prefix is blank' {
            Mock Get-VpsRouteConfiguration { [pscustomobject]@{ DestinationPrefix = ''; NextHop = '192.0.2.1' } }
            Mock Add-PersistentNetRoute { 0 }
            Mock Get-NetIPAddress { throw 'must not be called' }
            $script:capturedWarning = $null
            Mock Write-Log -ParameterFilter { $Level -eq 'Warning' } -MockWith { $script:capturedWarning = $Message }

            { Set-VpsRoutePersistent } | Should -Not -Throw

            Should -Invoke Add-PersistentNetRoute -Times 0 -Exactly
            $script:capturedWarning | Should -Match 'VPS_ROUTE_PREFIX'
            $script:capturedWarning | Should -Match 'VPS_ROUTE_NEXT_HOP'
        }

        It 'Set-VpsRoutePersistent never calls Add-PersistentNetRoute, does not throw, and logs a Warning naming both env keys when the next hop is blank' {
            Mock Get-VpsRouteConfiguration { [pscustomobject]@{ DestinationPrefix = '203.0.113.10/32'; NextHop = '' } }
            Mock Add-PersistentNetRoute { 0 }
            Mock Get-NetIPAddress { throw 'must not be called' }
            $script:capturedWarning = $null
            Mock Write-Log -ParameterFilter { $Level -eq 'Warning' } -MockWith { $script:capturedWarning = $Message }

            { Set-VpsRoutePersistent } | Should -Not -Throw

            Should -Invoke Add-PersistentNetRoute -Times 0 -Exactly
            $script:capturedWarning | Should -Match 'VPS_ROUTE_PREFIX'
            $script:capturedWarning | Should -Match 'VPS_ROUTE_NEXT_HOP'
        }

        It 'Set-VpsRoutePersistent is a no-op (never calls Add-PersistentNetRoute) when the route is already persistent' {
            Mock Get-VpsRouteConfiguration { [pscustomobject]@{ DestinationPrefix = '203.0.113.10/32'; NextHop = '192.0.2.1' } }
            Mock Get-NetRoute { [pscustomobject]@{ DestinationPrefix = '203.0.113.10/32' } } -ParameterFilter { $PolicyStore -eq 'PersistentStore' }
            Mock Add-PersistentNetRoute { 0 }

            Set-VpsRoutePersistent

            Should -Invoke Add-PersistentNetRoute -Times 0 -Exactly
        }

        It 'Set-VpsRoutePersistent adds the route scoped to the resolved interface only when not yet persistent' {
            Mock Get-VpsRouteConfiguration { [pscustomobject]@{ DestinationPrefix = '203.0.113.10/32'; NextHop = '192.0.2.1' } }
            Mock Get-NetRoute { $null } -ParameterFilter { $PolicyStore -eq 'PersistentStore' }
            Mock Get-NetIPAddress { @([pscustomobject]@{ IPAddress = '192.0.2.42'; InterfaceIndex = 15 }) }
            Mock Add-PersistentNetRoute { 0 }

            Set-VpsRoutePersistent

            Should -Invoke Add-PersistentNetRoute -Times 1 -ParameterFilter {
                $DestinationIp -eq '203.0.113.10' -and
                $SubnetMask -eq '255.255.255.255' -and
                $NextHop -eq '192.0.2.1' -and
                $InterfaceIndex -eq 15
            }
        }

        It 'Set-VpsRoutePersistent throws (never guesses an interface) when the next hop''s on-link interface cannot be identified' {
            Mock Get-VpsRouteConfiguration { [pscustomobject]@{ DestinationPrefix = '203.0.113.10/32'; NextHop = '192.0.2.1' } }
            Mock Get-NetRoute { $null } -ParameterFilter { $PolicyStore -eq 'PersistentStore' }
            Mock Get-NetIPAddress { @([pscustomobject]@{ IPAddress = '10.0.0.5'; InterfaceIndex = 3 }) }
            Mock Add-PersistentNetRoute { 0 }

            { Set-VpsRoutePersistent } | Should -Throw

            Should -Invoke Add-PersistentNetRoute -Times 0 -Exactly
        }

        It 'Set-VpsRoutePersistent throws when route.exe reports a non-zero exit code' {
            Mock Get-VpsRouteConfiguration { [pscustomobject]@{ DestinationPrefix = '203.0.113.10/32'; NextHop = '192.0.2.1' } }
            Mock Get-NetRoute { $null } -ParameterFilter { $PolicyStore -eq 'PersistentStore' }
            Mock Get-NetIPAddress { @([pscustomobject]@{ IPAddress = '192.0.2.42'; InterfaceIndex = 15 }) }
            Mock Add-PersistentNetRoute { 1 }

            { Set-VpsRoutePersistent } | Should -Throw
        }
    }

    Context 'Invoke-TunnelRegistration (AO-01/D-09 live-apply, operator-gated)' {

        BeforeEach {
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\pwsh\pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh.exe' }
            Mock Register-TunnelScheduledTask { }
            Mock Set-VpsRoutePersistent { }
        }

        It 'aborts and registers nothing when not elevated' {
            Mock Test-IsElevatedProcess { $false }

            Invoke-TunnelRegistration | Should -Be 1

            Should -Invoke Register-TunnelScheduledTask -Times 0 -Exactly
            Should -Invoke Set-VpsRoutePersistent -Times 0 -Exactly
        }

        It 'aborts and registers nothing when pwsh.exe is not found' {
            Mock Test-IsElevatedProcess { $true }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'pwsh.exe' }

            Invoke-TunnelRegistration | Should -Be 1

            Should -Invoke Register-TunnelScheduledTask -Times 0 -Exactly
            Should -Invoke Set-VpsRoutePersistent -Times 0 -Exactly
        }

        It 'registers the tunnel task and persists the route when prerequisites pass' {
            Mock Test-IsElevatedProcess { $true }

            Invoke-TunnelRegistration | Should -Be 0

            Should -Invoke Register-TunnelScheduledTask -Times 1 -Exactly
            Should -Invoke Set-VpsRoutePersistent -Times 1 -Exactly
        }
    }

    Context 'Initialize-PusherEnvFile (first-run .env copy)' {

        BeforeEach {
            # Each It gets its own GUID-suffixed work directory under $TestDrive --
            # $TestDrive is shared across every It in this file's run, so writing
            # '.env'/'.env.example' directly under it would leak across tests
            # (mirrors the Phase 3 Integration-test fix logged in STATE.md).
            $script:EnvTestRoot = Join-Path $TestDrive ([Guid]::NewGuid())
            New-Item -ItemType Directory -Path $script:EnvTestRoot -Force | Out-Null
        }

        It 'copies .env.example to .env when .env is absent' {
            $exampleContent = "RELAY_HOST=127.0.0.1`n"
            [System.IO.File]::WriteAllText((Join-Path $script:EnvTestRoot '.env.example'), $exampleContent)
            Test-Path -LiteralPath (Join-Path $script:EnvTestRoot '.env') | Should -BeFalse

            Initialize-PusherEnvFile -ScriptRoot $script:EnvTestRoot

            Test-Path -LiteralPath (Join-Path $script:EnvTestRoot '.env') | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $script:EnvTestRoot '.env') -Raw) | Should -Be $exampleContent
        }

        It 'skips the copy and never overwrites an existing operator .env' {
            [System.IO.File]::WriteAllText((Join-Path $script:EnvTestRoot '.env.example'), "RELAY_HOST=127.0.0.1`n")
            $operatorEditedContent = "RELAY_HOST=203.0.113.9`nRELAY_PORT=9999`n"
            [System.IO.File]::WriteAllText((Join-Path $script:EnvTestRoot '.env'), $operatorEditedContent)

            Initialize-PusherEnvFile -ScriptRoot $script:EnvTestRoot

            (Get-Content -LiteralPath (Join-Path $script:EnvTestRoot '.env') -Raw) | Should -Be $operatorEditedContent
        }

        It 'does not throw and skips the copy when .env.example is also missing' {
            Test-Path -LiteralPath (Join-Path $script:EnvTestRoot '.env.example') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:EnvTestRoot '.env') | Should -BeFalse

            { Initialize-PusherEnvFile -ScriptRoot $script:EnvTestRoot } | Should -Not -Throw

            Test-Path -LiteralPath (Join-Path $script:EnvTestRoot '.env') | Should -BeFalse
        }
    }
}

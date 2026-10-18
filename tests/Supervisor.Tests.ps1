# Supervisor.Tests.ps1
# Unit tests for supervisor.ps1 -- the process-death mechanism that Task Scheduler
# was wrongly believed to provide.
#
# WHY THIS FILE EXISTS: install.ps1's task settings (RestartCount 999 /
# RestartInterval 1 min) were empirically proven against real Task Scheduler to
# fire ONLY on abnormal TASK termination, never on the action process exiting
# non-zero -- a probe with `pwsh -Command "exit 1"` left lastRun frozen and rerun
# False across 160s. tests/Install.Tests.ps1 stayed green throughout, because it
# asserts the task's REGISTERED SHAPE against mocks, and that shape was correct;
# only the runtime behaviour it implied was false. So the exit-code branching that
# actually keeps the stream alive is asserted HERE, against real code, with no
# real Task Scheduler anywhere in the loop (locked design item 5).
#
# supervisor.ps1 is a top-level script, not a module (matching install.ps1 and
# 04-PATTERNS.md), so it is dot-sourced here and never invoked -- its bottom
# `if ($MyInvocation.InvocationName -ne '.')` guard keeps Invoke-Supervisor from
# running (and hanging the test process) on dot-source.
#
# The control flag is exercised for REAL against $TestDrive files rather than
# mocked: "exit 0 flips desired to stopped" is the whole point of the design (a
# relaunch tick after a clean exit 0 re-sends the 2MB D-05 resume margin as
# duplicate bytes to YouTube), so asserting it against a mock would assert
# nothing. Only Start-PusherProcess (spawns a real pwsh) and Start-Sleep (real
# wall-clock backoff) are mocked.
#
# Start-PusherProcess is spawn-only (261018): the mock returns New-FakePusherProcess
# (tests/TestHelpers.psm1), so every test below also runs the REAL
# Wait-PusherProcessExit loop and the real exit-code pass-through.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:SupervisorScriptPath = Join-Path $PSScriptRoot '../supervisor.ps1'
    $script:ControlFlagModulePath = Join-Path $PSScriptRoot '../lib/ControlFlag.psm1'
    $script:LoggingModulePath = Join-Path $PSScriptRoot '../lib/Logging.psm1'
    $script:SessionStateModulePath = Join-Path $PSScriptRoot '../lib/SessionState.psm1'
}

Describe 'supervisor.ps1' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:ControlFlagModulePath -Force

        # Dot-source (not `&`) so supervisor.ps1's functions land in THIS scope
        # and are mockable by plain `Mock` (same convention as Install.Tests.ps1).
        . $script:SupervisorScriptPath

        $script:SupervisorTestRoot = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:SupervisorTestRoot -Force | Out-Null
        $script:ControlFilePath = Join-Path $script:SupervisorTestRoot 'control.json'
    }

    AfterEach {
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    Context 'Get-SupervisorExitDecision (the exit-code branching, pure)' {
        # pusher.ps1's exit-code contract (D-12): exit 0 at :669 = clean
        # end-of-service after Start-Pusher returns; exit 2 at :68 = config
        # validation failure; any other non-zero = an uncaught throw under
        # $ErrorActionPreference = 'Stop' (i.e. a crash).

        It 'stays down on exit 0 (clean end-of-service -- a relaunch would re-send the D-05 resume margin as duplicate bytes)' {
            (Get-SupervisorExitDecision -ExitCode 0).Action | Should -Be 'StayDown'
        }

        It 'stays down on exit 2 (config error -- D-12 stay-down contract, preserved exactly)' {
            (Get-SupervisorExitDecision -ExitCode 2).Action | Should -Be 'StayDown'
        }

        It 'stays down on exit 3 (Front C, 260718-j58: bounded end-of-service give-up with undelivered backlog)' {
            $decision = Get-SupervisorExitDecision -ExitCode 3
            $decision.Action | Should -Be 'StayDown'
            $decision.ExitReasonToken | Should -Be 'finished-with-undelivered-backlog'
            $decision.Reason | Should -Not -BeNullOrEmpty
        }

        It 'waits on exit 4 (another pusher for this install holds the Pusher mutex -- this launch stood down, which is neither a crash nor a finish)' {
            $decision = Get-SupervisorExitDecision -ExitCode 4

            $decision.Action | Should -Be 'WaitForRunningPusher'
            $decision.ExitReasonToken | Should -Be 'another-pusher-running'
            $decision.Reason | Should -Not -BeNullOrEmpty
        }

        It 'relaunches on exit 1 (crash)' {
            (Get-SupervisorExitDecision -ExitCode 1).Action | Should -Be 'Relaunch'
        }

        It 'relaunches on any other non-zero exit code (crash), excluding exit 3 which is now a documented StayDown token' {
            foreach ($crashExitCode in @(5, 42, 255, -1, -1073741819)) {
                (Get-SupervisorExitDecision -ExitCode $crashExitCode).Action |
                    Should -Be 'Relaunch' -Because "exit $crashExitCode is an uncaught throw, not a documented clean/config/undelivered-backlog exit"
            }
        }

        It 'gives every decision an operator-readable reason (this is what a church volunteer reads in the log at 10:55 on a Sunday)' {
            foreach ($anyExitCode in @(0, 1, 2, 255)) {
                (Get-SupervisorExitDecision -ExitCode $anyExitCode).Reason | Should -Not -BeNullOrEmpty
            }
        }

        It 'ExitReasonToken (260718-epo): exit 0 -> clean-end-of-service' {
            (Get-SupervisorExitDecision -ExitCode 0).ExitReasonToken | Should -Be 'clean-end-of-service'
        }

        It 'ExitReasonToken (260718-epo): exit 2 -> config-fail' {
            (Get-SupervisorExitDecision -ExitCode 2).ExitReasonToken | Should -Be 'config-fail'
        }

        It 'ExitReasonToken (260718-j58, Front C): exit 3 -> finished-with-undelivered-backlog' {
            (Get-SupervisorExitDecision -ExitCode 3).ExitReasonToken | Should -Be 'finished-with-undelivered-backlog'
        }

        It 'ExitReasonToken (260718-epo): any other exit code -> crash (3 excluded -- it is now a documented StayDown token)' {
            foreach ($crashExitCode in @(1, 5, 42, 255, -1)) {
                (Get-SupervisorExitDecision -ExitCode $crashExitCode).ExitReasonToken | Should -Be 'crash'
            }
        }
    }

    Context 'Invoke-Supervisor (boot = idle)' {

        BeforeEach {
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 0 }
            Mock Start-Sleep { }
        }

        It 'never launches the pusher when no control file exists yet (a fresh boot must not stream to LIVE YouTube unattended)' {
            Test-Path -LiteralPath $script:ControlFilePath | Should -BeFalse

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 5

            Should -Invoke Start-PusherProcess -Times 0 -Exactly
        }

        It 'never launches the pusher while desired is stopped' {
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'stopped'

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 5

            Should -Invoke Start-PusherProcess -Times 0 -Exactly
        }

        It 'launches the pusher once the operator flips desired to streaming' {
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 1

            Should -Invoke Start-PusherProcess -Times 1 -Exactly
        }
    }

    Context 'Supervisor start identity line (261018)' {
        # On 2026-10-04 two supervisors ran side by side and nothing in the log said
        # which was which. The start line now carries pid/ppid/user/session/started
        # (Get-ProcessIdentityLogText) so the next incident is readable from the log.

        BeforeEach {
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 0 }
            Mock Start-Sleep { }
            $script:capturedStartLogMessages = [System.Collections.Generic.List[string]]::new()
            Mock Write-Log { $script:capturedStartLogMessages.Add([string] $Message) }
        }

        It 'the Supervisor starting line contains pid, ppid, user, session and started' {
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'stopped'

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 1

            $startLines = @($script:capturedStartLogMessages | Where-Object { $_ -like 'Supervisor starting*' })
            $startLines.Count | Should -Be 1
            $startLines[0] | Should -BeLike "*pid=$PID*"
            $startLines[0] | Should -BeLike '*ppid=*'
            $startLines[0] | Should -BeLike '*user=*'
            $startLines[0] | Should -BeLike '*session=*'
            $startLines[0] | Should -BeLike '*started=*'
        }

        It 'still starts and still names its pid when the process lookup inside the logging module throws' {
            Mock -ModuleName Logging Get-Process { throw 'simulated process lookup failure' }
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'stopped'

            $exitCode = Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 1

            $exitCode | Should -Be 0
            $startLines = @($script:capturedStartLogMessages | Where-Object { $_ -like 'Supervisor starting*' })
            $startLines.Count | Should -Be 1
            $startLines[0] | Should -BeLike "*pid=$PID*"
        }
    }

    Context 'Invoke-Supervisor (exit 0 -- clean end-of-service stays down)' {

        BeforeEach {
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 0 }
            Mock Start-Sleep { }
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'
        }

        It 'launches the pusher exactly once across many ticks and never relaunches after a clean exit 0' {
            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 10

            Should -Invoke Start-PusherProcess -Times 1 -Exactly
        }

        It 'flips desired to stopped on exit 0, so a later supervisor restart also stays down (the drained .ts file is still on disk)' {
            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 10

            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
        }
    }

    Context 'Invoke-Supervisor (exit 2 -- config error stays down, D-12 preserved)' {

        BeforeEach {
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 2 }
            Mock Start-Sleep { }
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'
        }

        It 'launches exactly once and never retries a config error (a bad .env cannot fix itself -- retrying is a restart storm)' {
            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 10

            Should -Invoke Start-PusherProcess -Times 1 -Exactly
        }

        It 'flips desired to stopped on exit 2' {
            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 10

            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
        }
    }

    Context 'Invoke-Supervisor (crash -- relaunch with backoff)' {

        BeforeEach {
            Mock Start-Sleep { }
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'
        }

        It 'relaunches the pusher on every crash tick (this is the auto-restart that never existed)' {
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 1 }

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 3

            Should -Invoke Start-PusherProcess -Times 3 -Exactly
        }

        It 'leaves desired at streaming across crashes (a crash is not an operator stop)' {
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 1 }

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 3

            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'streaming'
        }

        It 'backs off between crash relaunches rather than hot-looping (Open-TailerFileStream throws when no recording file exists -- an un-delayed relaunch would spin at full CPU)' {
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 1 }

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 3

            # `-Times 1` WITHOUT `-Exactly` is Pester's "at least once" -- there is no
            # -AtLeast switch, and passing one binds it positionally as ActualValue,
            # so the assertion throws "Should -Invoke does not take pipeline input"
            # instead of asserting anything at all. Same family of vacuous-assertion
            # bug as the -ErrorId pin in ControlFlag.Tests.ps1: a test that cannot
            # pass is as useless as one that cannot fail.
            Should -Invoke Start-Sleep -Times 1
        }

        It 'stops relaunching the moment the operator flips desired to stopped mid-crash-loop' {
            # A crash loop must remain interruptible: the operator's stop.ps1 (or
            # Phase 5's dashboard Stop button) writes the flag while the
            # supervisor is mid-backoff, and the very next tick must obey it.
            $script:crashLaunchCount = 0
            Mock Start-PusherProcess {
                $script:crashLaunchCount++
                if ($script:crashLaunchCount -eq 2) {
                    Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'stopped'
                }
                return (New-FakePusherProcess -ExitCode 1)
            }

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 10

            Should -Invoke Start-PusherProcess -Times 2 -Exactly
        }

        It 'resumes launching when the operator flips desired back to streaming after a stay-down exit (a second service needs no reboot)' {
            # exit 0 flips the flag to stopped. The operator starting the NEXT
            # service must not require a reboot -- the same idle supervisor must
            # pick it straight back up. The flip is staged from the idle-tick
            # Start-Sleep mock because that is exactly when a real operator would
            # press Start: while the supervisor sits idle between services.
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 0 }
            $script:idleTickCount = 0
            Mock Start-Sleep {
                $script:idleTickCount++
                if ($script:idleTickCount -eq 1) {
                    Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'
                }
            }

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 4

            Should -Invoke Start-PusherProcess -Times 2 -Exactly
        }
    }

    Context 'Orphan pusher guard (261018)' {
        # A five-minute watchdog can relaunch a supervisor whose pusher outlived it. Two
        # pushers on one recording replay old content to YouTube (2026-09-13). The pusher
        # takes a per-install Pusher mutex and exits 4 if it cannot; the supervisor never
        # launches while that mutex is held and maps exit 4 to a wait, with no flag write,
        # no session.json write and no crash count.

        BeforeEach {
            Mock Start-Sleep { }
            $script:orphanGuardLogEntries = [System.Collections.Generic.List[object]]::new()
            Mock Write-Log { $script:orphanGuardLogEntries.Add([pscustomobject]@{ Level = $Level; Message = [string] $Message }) }
            # The starting flag is written for real BEFORE the counting mock exists, so the
            # mock counts only the supervisor's own writes.
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'
            # Counts REAL flag writes. The real function is captured as a command object
            # BEFORE the mock exists and invoked through that object. A module-qualified
            # call (ControlFlag\Set-PusherDesiredState) does NOT bypass the mock under
            # Pester 6: it resolves back to the mock and recurses until call-depth
            # overflow, which the supervisor then catches as a failed flag write.
            # Explicit parameters: $PSBoundParameters is EMPTY inside a Pester mock body, so
            # splatting it would call the real function without its mandatory parameters.
            $script:RealSetPusherDesiredState = Get-Command -Name Set-PusherDesiredState -Module ControlFlag -CommandType Function
            Mock Set-PusherDesiredState { & $script:RealSetPusherDesiredState -ControlFilePath $ControlFilePath -DesiredState $DesiredState }
            Mock Start-ProbeHost { $null }
        }

        It 'does not launch while the pusher mutex is held, then launches exactly once when it is free' {
            $script:pusherMutexProbeCount = 0
            Mock Test-SingleInstanceMutexHeld {
                $script:pusherMutexProbeCount++
                return ($script:pusherMutexProbeCount -le 3)
            }
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 0 }

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 4

            Should -Invoke Start-PusherProcess -Times 1 -Exactly
            # The only flag write is the StayDown after that one launch.
            Should -Invoke Set-PusherDesiredState -Times 1 -Exactly
            @($script:orphanGuardLogEntries | Where-Object { $_.Level -eq 'Warning' -and $_.Message -like '*Another pusher for this install is still running*' }).Count | Should -Be 1
            @($script:orphanGuardLogEntries | Where-Object { $_.Level -eq 'Info' -and $_.Message -like '*earlier pusher has exited*' }).Count | Should -Be 1
            @($script:orphanGuardLogEntries | Where-Object { $_.Message -like 'Relaunching the pusher in*' }).Count | Should -Be 0
            # A swallowed flag-write failure must not be able to make this test pass.
            @($script:orphanGuardLogEntries | Where-Object { $_.Level -eq 'Error' }).Count | Should -Be 0
        }

        It 'exit 4 while the mutex is held waits instead of crashing: no crash count, no backoff, session state is written only for the real exit, and the flag ends stopped' {
            $script:orphanGuardLaunchCount = 0
            Mock Start-PusherProcess {
                $script:orphanGuardLaunchCount++
                if ($script:orphanGuardLaunchCount -eq 1) { return (New-FakePusherProcess -ExitCode 4) }
                return (New-FakePusherProcess -ExitCode 0)
            }
            # Probe 1: before the first launch (free). Probes 2 and 3: after exit 4 and on the
            # next tick (the holder is there). Probe 4: free again, so the second launch runs.
            $script:pusherMutexProbeCount = 0
            Mock Test-SingleInstanceMutexHeld {
                $script:pusherMutexProbeCount++
                return ($script:pusherMutexProbeCount -in 2, 3)
            }
            Mock Save-SessionState { }
            $sessionStateFilePath = Join-Path $script:SupervisorTestRoot 'session.json'

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 3 -SessionStateFilePath $sessionStateFilePath

            Should -Invoke Start-PusherProcess -Times 2 -Exactly
            @($script:orphanGuardLogEntries | Where-Object { $_.Level -eq 'Warning' -and $_.Message -like 'Pusher exited 4 -- *' }).Count | Should -Be 1
            @($script:orphanGuardLogEntries | Where-Object { $_.Message -like 'Relaunching the pusher in*' }).Count | Should -Be 0
            Should -Invoke Save-SessionState -Times 1 -Exactly
            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
        }

        It 'repeated exit 4 while the mutex is NOT held is a failed guard, not a holder: crash-class backoff applies and the exit-4 warning is logged once' {
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 4 }
            Mock Test-SingleInstanceMutexHeld { $false }
            Mock Save-SessionState { }
            $sessionStateFilePath = Join-Path $script:SupervisorTestRoot 'session.json'

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 4 -SessionStateFilePath $sessionStateFilePath

            Should -Invoke Start-PusherProcess -Times 4 -Exactly
            @($script:orphanGuardLogEntries | Where-Object { $_.Level -eq 'Warning' -and $_.Message -like 'Pusher exited 4 -- *' }).Count | Should -Be 1
            $relaunchLogMessages = @($script:orphanGuardLogEntries | Where-Object { $_.Message -like 'Relaunching the pusher in*' } | ForEach-Object { $_.Message })
            $relaunchLogMessages.Count | Should -Be 3
            $relaunchLogMessages[2] | Should -BeLike '*consecutive crashes: 3*'
            Should -Invoke Save-SessionState -Times 0 -Exactly
            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'streaming'
        }

        It 'a normal exit after failed-guard exit-4 launches ends the pacing: backoff only before the retries, one warning, and the flag ends stopped' {
            $script:orphanGuardLaunchCount = 0
            Mock Start-PusherProcess {
                $script:orphanGuardLaunchCount++
                if ($script:orphanGuardLaunchCount -le 2) { return (New-FakePusherProcess -ExitCode 4) }
                return (New-FakePusherProcess -ExitCode 0)
            }
            Mock Test-SingleInstanceMutexHeld { $false }
            Mock Save-SessionState { }
            $sessionStateFilePath = Join-Path $script:SupervisorTestRoot 'session.json'

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 3 -SessionStateFilePath $sessionStateFilePath

            Should -Invoke Start-PusherProcess -Times 3 -Exactly
            @($script:orphanGuardLogEntries | Where-Object { $_.Level -eq 'Warning' -and $_.Message -like 'Pusher exited 4 -- *' }).Count | Should -Be 1
            @($script:orphanGuardLogEntries | Where-Object { $_.Message -like 'Relaunching the pusher in*' }).Count | Should -Be 2
            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
        }

        It 'a failed stay-down flag write no longer ends the supervisor: it is retried every tick and no pusher is relaunched meanwhile' {
            $script:stayDownWriteCount = 0
            Mock Set-PusherDesiredState {
                $script:stayDownWriteCount++
                if ($script:stayDownWriteCount -eq 1) { throw [System.IO.IOException]::new('locked') }
                & $script:RealSetPusherDesiredState -ControlFilePath $ControlFilePath -DesiredState $DesiredState
            }
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 0 }
            Mock Test-SingleInstanceMutexHeld { $false }

            $exitCode = $null
            { $script:exitCode = Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 3 } | Should -Not -Throw

            $script:exitCode | Should -Be 0
            Should -Invoke Start-PusherProcess -Times 1 -Exactly
            Should -Invoke Set-PusherDesiredState -Times 2 -Exactly
            @($script:orphanGuardLogEntries | Where-Object { $_.Level -eq 'Error' }).Count | Should -Be 1
            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
        }
    }

    Context 'Session state persistence (260718-epo)' {

        BeforeEach {
            Mock Start-Sleep { }
            $script:SessionStateFilePath = Join-Path $script:SupervisorTestRoot 'session.json'
            $script:AutoPickupRecordingFolderPath = Join-Path $script:SupervisorTestRoot 'recordings'
            New-Item -ItemType Directory -Path $script:AutoPickupRecordingFolderPath -Force | Out-Null
        }

        It 'writes lastExitReason=clean-end-of-service and the finished recording file on exit 0' {
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 0 }
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'
            $recordingFilePath = Join-Path $script:AutoPickupRecordingFolderPath 'service.ts'
            Set-Content -LiteralPath $recordingFilePath -Value 'x' -Encoding utf8

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 1 `
                -RecordingFolderPath $script:AutoPickupRecordingFolderPath -RecordingFilenameGlob '*.ts' `
                -SessionStateFilePath $script:SessionStateFilePath

            $sessionState = Read-SessionState -SessionStateFilePath $script:SessionStateFilePath
            $sessionState.lastExitReason | Should -Be 'clean-end-of-service'
            $sessionState.finishedRecordingFilePath | Should -Be $recordingFilePath
            $sessionState.finishedRecordingLastWriteUtc | Should -Not -BeNullOrEmpty
        }

        It 'writes lastExitReason=config-fail with NO finished recording file on exit 2' {
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 2 }
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 1 `
                -RecordingFolderPath $script:AutoPickupRecordingFolderPath -RecordingFilenameGlob '*.ts' `
                -SessionStateFilePath $script:SessionStateFilePath

            $sessionState = Read-SessionState -SessionStateFilePath $script:SessionStateFilePath
            $sessionState.lastExitReason | Should -Be 'config-fail'
            $sessionState.finishedRecordingFilePath | Should -BeNullOrEmpty
        }

        It 'writes lastExitReason=crash with NO finished recording file on an unexpected exit code' {
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 1 }
            Mock Start-Sleep { }
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 1 `
                -RecordingFolderPath $script:AutoPickupRecordingFolderPath -RecordingFilenameGlob '*.ts' `
                -SessionStateFilePath $script:SessionStateFilePath

            $sessionState = Read-SessionState -SessionStateFilePath $script:SessionStateFilePath
            $sessionState.lastExitReason | Should -Be 'crash'
            $sessionState.finishedRecordingFilePath | Should -BeNullOrEmpty
        }

        It 'a session-state write failure never stops the supervisor (guarded like Publish-PusherStats)' {
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 0 }
            Mock Save-SessionState { throw 'simulated session-state write failure' }
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'

            { Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 1 `
                -SessionStateFilePath $script:SessionStateFilePath } | Should -Not -Throw
        }
    }

    Context 'Invoke-AutoPickupTick (260718-epo/FEAT-C, T-epo-01: default-off, strictly-newer-only, never-re-pick)' {

        BeforeEach {
            $script:AutoPickupTestRoot = Join-Path $TestDrive ([Guid]::NewGuid())
            New-Item -ItemType Directory -Path $script:AutoPickupTestRoot -Force | Out-Null
            $script:AutoPickupControlFilePath = Join-Path $script:AutoPickupTestRoot 'control.json'
            $script:AutoPickupSessionStateFilePath = Join-Path $script:AutoPickupTestRoot 'session.json'
            $script:AutoPickupStateFilePath = Join-Path $script:AutoPickupTestRoot 'offset.json'
            Set-Content -LiteralPath $script:AutoPickupStateFilePath -Value '{"byteOffset":100}' -Encoding utf8

            $script:OlderFinishedMtime = [datetime]::UtcNow.AddMinutes(-10)
            $script:NewerFileMtime = [datetime]::UtcNow.AddMinutes(10)

            Save-SessionState -SessionStateFilePath $script:AutoPickupSessionStateFilePath -LastExitReason 'clean-end-of-service' `
                -LastExitEpochSeconds 1.0 -FinishedRecordingFilePath 'D:\obs\old.ts' `
                -FinishedRecordingLastWriteUtc $script:OlderFinishedMtime
        }

        It '(a) AUTO_PICKUP OFF: a strictly-newer file is detected/recorded but Set-PusherDesiredState streaming is NEVER called' {
            Mock Get-NewestMatchingRecordingFile { [pscustomobject]@{ FullName = 'D:\obs\new.ts'; LastWriteTimeUtc = $script:NewerFileMtime } }

            Invoke-AutoPickupTick -ControlFilePath $script:AutoPickupControlFilePath -RecordingFolderPath 'D:\obs' `
                -RecordingFilenameGlob '*.ts' -StateFilePath $script:AutoPickupStateFilePath `
                -SessionStateFilePath $script:AutoPickupSessionStateFilePath -AutoPickupEnabled $false

            Get-PusherDesiredState -ControlFilePath $script:AutoPickupControlFilePath | Should -Be 'stopped'
            Test-Path -LiteralPath $script:AutoPickupStateFilePath | Should -BeTrue -Because 'offset.json must survive when auto-start never fires'
            (Read-SessionState -SessionStateFilePath $script:AutoPickupSessionStateFilePath).newRecordingDetectedFilePath | Should -Be 'D:\obs\new.ts'
        }

        It '(b) AUTO_PICKUP ON: a strictly-newer file sets streaming AND removes state/offset.json' {
            Mock Get-NewestMatchingRecordingFile { [pscustomobject]@{ FullName = 'D:\obs\new.ts'; LastWriteTimeUtc = $script:NewerFileMtime } }

            Invoke-AutoPickupTick -ControlFilePath $script:AutoPickupControlFilePath -RecordingFolderPath 'D:\obs' `
                -RecordingFilenameGlob '*.ts' -StateFilePath $script:AutoPickupStateFilePath `
                -SessionStateFilePath $script:AutoPickupSessionStateFilePath -AutoPickupEnabled $true

            Get-PusherDesiredState -ControlFilePath $script:AutoPickupControlFilePath | Should -Be 'streaming'
            Test-Path -LiteralPath $script:AutoPickupStateFilePath | Should -BeFalse -Because 'the pusher must resolve the new file at offset 0, never re-open the finished file'
            (Read-SessionState -SessionStateFilePath $script:AutoPickupSessionStateFilePath).lastExitReason | Should -BeNullOrEmpty -Because 'the pickup must fire exactly once'
        }

        It '(c) the just-finished file re-observed at the SAME path never triggers detection or auto-start, even with AUTO_PICKUP on' {
            Mock Get-NewestMatchingRecordingFile { [pscustomobject]@{ FullName = 'D:\obs\old.ts'; LastWriteTimeUtc = $script:NewerFileMtime } }

            Invoke-AutoPickupTick -ControlFilePath $script:AutoPickupControlFilePath -RecordingFolderPath 'D:\obs' `
                -RecordingFilenameGlob '*.ts' -StateFilePath $script:AutoPickupStateFilePath `
                -SessionStateFilePath $script:AutoPickupSessionStateFilePath -AutoPickupEnabled $true

            Get-PusherDesiredState -ControlFilePath $script:AutoPickupControlFilePath | Should -Be 'stopped'
            Test-Path -LiteralPath $script:AutoPickupStateFilePath | Should -BeTrue
            (Read-SessionState -SessionStateFilePath $script:AutoPickupSessionStateFilePath).newRecordingDetectedFilePath | Should -BeNullOrEmpty
        }

        It '(c) a same/older mtime for a DIFFERENT path never triggers detection or auto-start, even with AUTO_PICKUP on' {
            Mock Get-NewestMatchingRecordingFile { [pscustomobject]@{ FullName = 'D:\obs\new.ts'; LastWriteTimeUtc = $script:OlderFinishedMtime } }

            Invoke-AutoPickupTick -ControlFilePath $script:AutoPickupControlFilePath -RecordingFolderPath 'D:\obs' `
                -RecordingFilenameGlob '*.ts' -StateFilePath $script:AutoPickupStateFilePath `
                -SessionStateFilePath $script:AutoPickupSessionStateFilePath -AutoPickupEnabled $true

            Get-PusherDesiredState -ControlFilePath $script:AutoPickupControlFilePath | Should -Be 'stopped'
            Test-Path -LiteralPath $script:AutoPickupStateFilePath | Should -BeTrue
        }

        It 'no-op when RecordingFolderPath/RecordingFilenameGlob/SessionStateFilePath are empty (inert defaults)' {
            { Invoke-AutoPickupTick -ControlFilePath $script:AutoPickupControlFilePath -AutoPickupEnabled $true } | Should -Not -Throw

            Get-PusherDesiredState -ControlFilePath $script:AutoPickupControlFilePath | Should -Be 'stopped'
        }

        It 'no-op when the last exit was not clean-end-of-service (e.g. crash)' {
            Save-SessionState -SessionStateFilePath $script:AutoPickupSessionStateFilePath -LastExitReason 'crash' -LastExitEpochSeconds 1.0
            Mock Get-NewestMatchingRecordingFile { [pscustomobject]@{ FullName = 'D:\obs\new.ts'; LastWriteTimeUtc = $script:NewerFileMtime } }

            Invoke-AutoPickupTick -ControlFilePath $script:AutoPickupControlFilePath -RecordingFolderPath 'D:\obs' `
                -RecordingFilenameGlob '*.ts' -StateFilePath $script:AutoPickupStateFilePath `
                -SessionStateFilePath $script:AutoPickupSessionStateFilePath -AutoPickupEnabled $true

            Get-PusherDesiredState -ControlFilePath $script:AutoPickupControlFilePath | Should -Be 'stopped'
        }

        It 'never throws when Get-NewestMatchingRecordingFile itself throws (degrades to no-op)' {
            Mock Get-NewestMatchingRecordingFile { throw 'simulated filesystem enumeration failure' }

            { Invoke-AutoPickupTick -ControlFilePath $script:AutoPickupControlFilePath -RecordingFolderPath 'D:\obs' `
                -RecordingFilenameGlob '*.ts' -StateFilePath $script:AutoPickupStateFilePath `
                -SessionStateFilePath $script:AutoPickupSessionStateFilePath -AutoPickupEnabled $true } | Should -Not -Throw

            Get-PusherDesiredState -ControlFilePath $script:AutoPickupControlFilePath | Should -Be 'stopped'
        }
    }
}

# Supervisor dashboard host (05-09): proves 05-01's HOST DECISION is safe to rely on
# from Invoke-Supervisor's own call site -- not merely that Start-DashboardHost/
# Test-DashboardHostFaulted individually never throw (already their own contract),
# but that the SUPERVISOR keeps supervising AND keeps streaming through a dashboard
# that cannot start (Test 3) or that faults mid-run (Test 4, Test 5 -- the one that
# matters, D-03). A separate top-level Describe from 'supervisor.ps1' above so the
# pre-existing regression gate for Task 1's edits stays completely untouched.
Describe 'Supervisor dashboard host' -Tag 'Quick' {

    BeforeAll {
        function Get-SupervisorDashboardTestEphemeralPort {
            <#
            .SYNOPSIS
            Discovers a free TCP port at runtime by binding a TcpListener to port 0
            (OS-assigned), reading the assigned port, then releasing it -- mirrors
            tests/Dashboard.Tests.ps1's identical helper. Never hardcode a fixed port:
            a leaked test listener must never collide with the real dashboard's
            configured port or a developer's own open dashboard tab.
            #>
            $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            try {
                $tcpListener.Start()
                return ([System.Net.IPEndPoint] $tcpListener.LocalEndpoint).Port
            } finally {
                $tcpListener.Stop()
            }
        }

        function New-FakeDashboardHandle {
            <#
            .SYNOPSIS
            A duck-typed stand-in for Start-DashboardHost's real return shape
            (Listener/PowerShell) -- lets a test drive Test-DashboardHostFaulted and
            Invoke-Supervisor's finally-block cleanup without a real runspace. The
            fake PowerShell object exposes only InvocationStateInfo.State, which is
            all Test-DashboardHostFaulted ever reads; it deliberately has no
            Stop()/Dispose() methods, matching the real object's shape closely enough
            while proving the finally block's own try/catch around those calls is
            load-bearing, not decorative.
            #>
            param(
                [string] $InvocationState = 'Running',
                # Lets a recovery test tell which start produced which handle.
                [int] $Sequence = 0
            )
            return [pscustomobject]@{
                Listener   = $null
                PowerShell = [pscustomobject]@{ InvocationStateInfo = [pscustomobject]@{ State = $InvocationState } }
                Sequence   = $Sequence
            }
        }
    }

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Remove-Module Dashboard -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module PusherProcess -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Config -ErrorAction SilentlyContinue

        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:ControlFlagModulePath -Force

        # Dot-source (not `&`) so supervisor.ps1's functions -- including
        # Start-DashboardHost/Test-DashboardHostFaulted, and every module it imports
        # (lib/Dashboard.psm1 etc.) -- land in THIS scope and are mockable by plain
        # `Mock`, same convention as the 'supervisor.ps1' Describe above.
        . $script:SupervisorScriptPath

        $script:DashboardHostTestRoot = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:DashboardHostTestRoot -Force | Out-Null
        $script:DashboardHostControlFilePath = Join-Path $script:DashboardHostTestRoot 'control.json'

        Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 0 }
        Mock Start-Sleep { }
        # Frozen clock by default (261011-ugi): with time standing still, a retry that
        # is scheduled in the future can never fall due by accident, so Tests 1-7 keep
        # asserting exactly what they always asserted. Tests that need time to pass
        # override this mock inside their own It.
        Mock Get-MonotonicSeconds { 1000.0 }
    }

    AfterEach {
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Remove-Module Dashboard -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module PusherProcess -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Config -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'Test 1: DashboardPort 0 never calls Start-DashboardHost -- the default is genuinely inert' {
        Mock Start-DashboardHost { New-FakeDashboardHandle }

        Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 3 -DashboardPort 0

        Should -Invoke Start-DashboardHost -Times 0 -Exactly
    }

    It 'Test 2: a non-zero DashboardPort calls Start-DashboardHost exactly once, not once per tick' {
        Mock Start-DashboardHost { New-FakeDashboardHandle }
        Mock Stop-DashboardListener { }
        $port = Get-SupervisorDashboardTestEphemeralPort

        Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 3 -DashboardPort $port

        Should -Invoke Start-DashboardHost -Times 1 -Exactly
    }

    It 'Test 3 (D-03): the supervisor completes all ticks and returns 0 even when Start-DashboardHost throws' {
        Mock Start-DashboardHost { throw 'simulated dashboard host start failure' }
        $port = Get-SupervisorDashboardTestEphemeralPort

        $exitCode = Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 3 -DashboardPort $port

        $exitCode | Should -Be 0
        # `-Times 1` WITHOUT `-Exactly` is Pester's "at least once" (no -AtLeast
        # switch exists) -- matches this file's own precedent above. Still polling
        # the flag (idle Start-Sleep) across all 3 ticks is the proof the loop kept
        # running rather than dying when the dashboard host blew up.
        Should -Invoke Start-Sleep -Times 1
    }

    It 'Test 4: a faulted dashboard host is logged exactly once across 5 ticks, not once per tick' {
        Mock Start-DashboardHost { New-FakeDashboardHandle }
        Mock Test-DashboardHostFaulted { $true }
        Mock Stop-DashboardListener { }
        Mock Write-Log { }
        $port = Get-SupervisorDashboardTestEphemeralPort

        Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 5 -DashboardPort $port

        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'Error' -and $Message -like '*Dashboard host has faulted*'
        }
        # A fault schedules a retry; it never retries immediately in the same tick.
        Should -Invoke Start-DashboardHost -Times 1 -Exactly
    }

    It 'Test 5 (D-03, the property that actually matters): the pusher is still launched while the dashboard is faulted' {
        Mock Start-DashboardHost { New-FakeDashboardHandle }
        Mock Test-DashboardHostFaulted { $true }
        Mock Stop-DashboardListener { }
        Set-PusherDesiredState -ControlFilePath $script:DashboardHostControlFilePath -DesiredState 'streaming'
        $port = Get-SupervisorDashboardTestEphemeralPort

        Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 1 -DashboardPort $port

        Should -Invoke Start-PusherProcess -Times 1 -Exactly
    }

    It 'Test 6: a real listener is stopped and no port remains bound when the loop exits via -MaxTicks' {
        $port = Get-SupervisorDashboardTestEphemeralPort
        $realListener = Start-DashboardListener -DashboardPort $port
        Mock Start-DashboardHost {
            [pscustomobject]@{
                Listener   = $realListener
                PowerShell = [pscustomobject]@{ InvocationStateInfo = [pscustomobject]@{ State = 'Running' } }
            }
        }

        try {
            Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 2 -DashboardPort $port

            $realListener.IsListening | Should -BeFalse
        } finally {
            try { Stop-DashboardListener -Listener $realListener } catch { }
        }
    }

    It 'Test 7: Start-DashboardHost returns $null and logs an Error naming the port when the port is already bound -- it does not throw' {
        $port = Get-SupervisorDashboardTestEphemeralPort
        $blockingListener = [System.Net.HttpListener]::new()
        $blockingListener.Prefixes.Add("http://localhost:$port/")
        $blockingListener.Start()

        try {
            Mock Write-Log { }

            $handle = Start-DashboardHost -ScriptRoot $script:DashboardHostTestRoot -DashboardPort $port -ControlFilePath $script:DashboardHostControlFilePath

            $handle | Should -BeNullOrEmpty
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -like "*$port*"
            }
        } finally {
            $blockingListener.Stop()
            $blockingListener.Close()
        }
    }

    It 'Test 7b (261011-ugi): Start-DashboardHost -SuppressFailureLog returns $null on a taken port, does not throw, and writes zero log lines' {
        $port = Get-SupervisorDashboardTestEphemeralPort
        $blockingListener = [System.Net.HttpListener]::new()
        $blockingListener.Prefixes.Add("http://localhost:$port/")
        $blockingListener.Start()

        try {
            Mock Write-Log { }

            $handle = Start-DashboardHost -ScriptRoot $script:DashboardHostTestRoot -DashboardPort $port -ControlFilePath $script:DashboardHostControlFilePath -SuppressFailureLog

            $handle | Should -BeNullOrEmpty
            Should -Invoke Write-Log -Times 0 -Exactly
        } finally {
            $blockingListener.Stop()
            $blockingListener.Close()
        }
    }

    Context 'Dashboard host recovery decisions (pure)' {

        It 'Get-DashboardRestartSchedule: fast delays double from 2s up to a 60s ceiling and never enter the slow tail' {
            # Explicit pairs, not a dictionary: an int key on an ordered dictionary is
            # read as a position, not a key.
            $attemptCountAndExpectedDelaySeconds = @(
                @(0, 2), @(1, 4), @(2, 8), @(4, 32), @(5, 60), @(9, 60)
            )

            foreach ($pair in $attemptCountAndExpectedDelaySeconds) {
                $schedule = Get-DashboardRestartSchedule -RetryAttemptCount $pair[0] -MaximumFastAttempts 10 -SlowIntervalSeconds 600

                $schedule.DelaySeconds | Should -Be $pair[1] -Because "attempt count $($pair[0])"
                $schedule.EntersSlowRetry | Should -BeFalse -Because "attempt count $($pair[0]) is still inside the fast burst"
            }
        }

        It 'Get-DashboardRestartSchedule: the attempt that exhausts the fast burst enters the slow tail exactly once' {
            $atCap = Get-DashboardRestartSchedule -RetryAttemptCount 10 -MaximumFastAttempts 10 -SlowIntervalSeconds 600
            $pastCap = Get-DashboardRestartSchedule -RetryAttemptCount 11 -MaximumFastAttempts 10 -SlowIntervalSeconds 600
            $farPastCap = Get-DashboardRestartSchedule -RetryAttemptCount 30 -MaximumFastAttempts 10 -SlowIntervalSeconds 600

            $atCap.DelaySeconds | Should -Be 600
            $atCap.EntersSlowRetry | Should -BeTrue
            $pastCap.DelaySeconds | Should -Be 600
            $pastCap.EntersSlowRetry | Should -BeFalse
            $farPastCap.DelaySeconds | Should -Be 600
            $farPastCap.EntersSlowRetry | Should -BeFalse
        }

        It 'Get-DashboardRestartSchedule: honours a custom slow interval and is deterministic (no jitter)' {
            $custom = Get-DashboardRestartSchedule -RetryAttemptCount 10 -MaximumFastAttempts 10 -SlowIntervalSeconds 900
            $custom.DelaySeconds | Should -Be 900

            $first = Get-DashboardRestartSchedule -RetryAttemptCount 3 -MaximumFastAttempts 10 -SlowIntervalSeconds 600
            $second = Get-DashboardRestartSchedule -RetryAttemptCount 3 -MaximumFastAttempts 10 -SlowIntervalSeconds 600
            $second.DelaySeconds | Should -Be $first.DelaySeconds
        }

        It 'Test-DashboardRestartDue: no scheduled attempt is never due; otherwise due at or after the scheduled time' {
            Test-DashboardRestartDue -NextAttemptAtSeconds $null -NowSeconds 5000 | Should -BeFalse
            Test-DashboardRestartDue -NextAttemptAtSeconds 1002.0 -NowSeconds 1001.9 | Should -BeFalse
            Test-DashboardRestartDue -NextAttemptAtSeconds 1002.0 -NowSeconds 1002.0 | Should -BeTrue
            Test-DashboardRestartDue -NextAttemptAtSeconds 1002.0 -NowSeconds 1500.0 | Should -BeTrue
        }

        It 'Test-DashboardRecoveryConfirmed: only an open outage whose restarted dashboard stayed up for the full stable window is confirmed' {
            Test-DashboardRecoveryConfirmed -FaultLogged $true -HandleUptimeSeconds 600 -StableUptimeSeconds 600 | Should -BeTrue
            Test-DashboardRecoveryConfirmed -FaultLogged $true -HandleUptimeSeconds 599 -StableUptimeSeconds 600 | Should -BeFalse
            Test-DashboardRecoveryConfirmed -FaultLogged $false -HandleUptimeSeconds 9999 -StableUptimeSeconds 600 | Should -BeFalse
        }

        It 'production defaults are pinned: 2s base, 60s ceiling, 10 fast attempts, 600s slow interval' {
            $script:DashboardRestartBaseDelayMilliseconds | Should -Be 2000
            $script:DashboardRestartCeilingDelayMilliseconds | Should -Be 60000
            $script:DashboardRestartMaximumAttempts | Should -Be 10
            $script:DashboardRestartSlowIntervalSeconds | Should -Be 600
        }
    }

    It 'R1 (261011-ugi): a dashboard whose first two starts fail is retried on the fast backoff, runs on the third attempt, and logs one unavailable line and one recovered line' {
        # Fake clock: call n returns 1000 + 120n, so the start before the loop reads
        # 1120 and tick k reads 1120 + 120k. The restarted dashboard (tick 2, 1360s)
        # reaches the 600s stable window at tick 7.
        $script:fakeMonotonicSeconds = 1000.0
        Mock Get-MonotonicSeconds { $script:fakeMonotonicSeconds += 120.0; $script:fakeMonotonicSeconds }
        $script:startDashboardHostCallCount = 0
        Mock Start-DashboardHost {
            $script:startDashboardHostCallCount++
            if ($script:startDashboardHostCallCount -lt 3) { return $null }
            return New-FakeDashboardHandle -Sequence $script:startDashboardHostCallCount
        }
        Mock Write-Log { }
        Mock Stop-DashboardHostHandle { }
        Set-PusherDesiredState -ControlFilePath $script:DashboardHostControlFilePath -DesiredState 'streaming'
        Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 1 }
        $port = Get-SupervisorDashboardTestEphemeralPort

        Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 8 -DashboardPort $port

        Should -Invoke Start-DashboardHost -Times 3 -Exactly
        Should -Invoke Start-DashboardHost -Times 1 -Exactly -ParameterFilter { -not $SuppressFailureLog }
        Should -Invoke Start-DashboardHost -Times 2 -Exactly -ParameterFilter { $SuppressFailureLog }
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host is unavailable*' }
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host recovered*' }
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Message -like '*fast retries exhausted*' }
        Should -Invoke Start-PusherProcess -Times 8 -Exactly
        Should -Invoke Stop-DashboardHostHandle -Times 1 -Exactly -ParameterFilter { $null -ne $DashboardHandle }
    }

    It 'Get-DashboardFaultOutcome (261011-ugi): a first fault opens an outage, a flap inside an open outage is silent and keeps its attempt count, a dashboard that survived the window starts a new outage' {
        $healthyFirstFault = Get-DashboardFaultOutcome -FaultLogged $false -HandleUptimeSeconds 120 -StableUptimeSeconds 600 -RetryAttemptCount 0
        $healthyFirstFault.LogFaultLine | Should -BeTrue
        $healthyFirstFault.RetryAttemptCount | Should -Be 0

        $flapInsideOutage = Get-DashboardFaultOutcome -FaultLogged $true -HandleUptimeSeconds 120 -StableUptimeSeconds 600 -RetryAttemptCount 3
        $flapInsideOutage.LogFaultLine | Should -BeFalse
        $flapInsideOutage.RetryAttemptCount | Should -Be 3

        $survivedWindow = Get-DashboardFaultOutcome -FaultLogged $true -HandleUptimeSeconds 600 -StableUptimeSeconds 600 -RetryAttemptCount 7
        $survivedWindow.LogFaultLine | Should -BeTrue
        $survivedWindow.RetryAttemptCount | Should -Be 0

        $longRunningThenFault = Get-DashboardFaultOutcome -FaultLogged $false -HandleUptimeSeconds 900 -StableUptimeSeconds 600 -RetryAttemptCount 0
        $longRunningThenFault.LogFaultLine | Should -BeTrue
        $longRunningThenFault.RetryAttemptCount | Should -Be 0
    }

    It 'R2 (261011-ugi, locked decision 1): a dashboard that never starts gets 10 fast attempts, one exhausted line, then silent retries every 600s -- three log lines in total' {
        $script:fakeMonotonicSeconds = 1000.0
        Mock Get-MonotonicSeconds { $script:fakeMonotonicSeconds += 120.0; $script:fakeMonotonicSeconds }
        $script:startDashboardHostCallTimes = [System.Collections.Generic.List[double]]::new()
        Mock Start-DashboardHost {
            $script:startDashboardHostCallTimes.Add($script:fakeMonotonicSeconds)
            throw 'simulated dashboard host start failure'
        }
        Mock Write-Log { }
        Set-PusherDesiredState -ControlFilePath $script:DashboardHostControlFilePath -DesiredState 'streaming'
        Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 1 }
        $port = Get-SupervisorDashboardTestEphemeralPort

        $exitCode = Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 20 -DashboardPort $port

        $exitCode | Should -Be 0
        # 1 before the loop, 10 fast attempts (ticks 1-10), then slow attempts at ticks 15 and 20.
        Should -Invoke Start-DashboardHost -Times 13 -Exactly
        $lastThreeCallTimes = $script:startDashboardHostCallTimes | Select-Object -Last 3
        ($lastThreeCallTimes[1] - $lastThreeCallTimes[0]) | Should -Be 600
        ($lastThreeCallTimes[2] - $lastThreeCallTimes[1]) | Should -Be 600
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host fast retries exhausted*' }
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host is unavailable*' }
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host start raised an unexpected exception*' }
        Should -Invoke Write-Log -Times 3 -Exactly -ParameterFilter { $Message -like '*Dashboard host*' }
        Should -Invoke Start-PusherProcess -Times 20 -Exactly
    }

    It 'R7 (261011-ugi, locked decision 1): a dashboard that recovers on a slow attempt is confirmed after 600s and a later fault is logged again' {
        $script:fakeMonotonicSeconds = 1000.0
        Mock Get-MonotonicSeconds { $script:fakeMonotonicSeconds += 120.0; $script:fakeMonotonicSeconds }
        $script:startDashboardHostCallCount = 0
        Mock Start-DashboardHost {
            $script:startDashboardHostCallCount++
            if ($script:startDashboardHostCallCount -lt 12) { return $null }
            return New-FakeDashboardHandle -Sequence $script:startDashboardHostCallCount
        }
        # Healthy until the fake clock reaches 3640 (tick 21), then faulted.
        Mock Test-DashboardHostFaulted { $script:fakeMonotonicSeconds -ge 3640 }
        Mock Stop-DashboardHostHandle { }
        Mock Write-Log { }
        $port = Get-SupervisorDashboardTestEphemeralPort

        Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 21 -DashboardPort $port

        Should -Invoke Start-DashboardHost -Times 12 -Exactly
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host recovered*' }
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host has faulted*' }
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host fast retries exhausted*' }
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host is unavailable*' }
        Should -Invoke Stop-DashboardHostHandle -Times 1 -Exactly -ParameterFilter { $null -ne $DashboardHandle -and $DashboardHandle.Sequence -eq 12 }
    }

    It 'R3 (261011-ugi): a dashboard that faults mid-run is stopped, cleared, retried, confirmed, and a second fault is logged again' {
        $script:fakeMonotonicSeconds = 1000.0
        Mock Get-MonotonicSeconds { $script:fakeMonotonicSeconds += 120.0; $script:fakeMonotonicSeconds }
        $script:startDashboardHostCallCount = 0
        Mock Start-DashboardHost {
            $script:startDashboardHostCallCount++
            return New-FakeDashboardHandle -Sequence $script:startDashboardHostCallCount
        }
        Mock Test-DashboardHostFaulted {
            $DashboardHandle.Sequence -eq 1 -or ($DashboardHandle.Sequence -eq 2 -and $script:fakeMonotonicSeconds -ge 2200)
        }
        Mock Stop-DashboardHostHandle { }
        Mock Write-Log { }
        $port = Get-SupervisorDashboardTestEphemeralPort

        Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 10 -DashboardPort $port

        Should -Invoke Start-DashboardHost -Times 3 -Exactly
        Should -Invoke Write-Log -Times 2 -Exactly -ParameterFilter { $Message -like '*Dashboard host has faulted*' }
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host recovered*' }
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Message -like '*fast retries exhausted*' }
        # Handles 1 and 2 are stopped by the fault path, handle 3 by the finally cleanup.
        Should -Invoke Stop-DashboardHostHandle -Times 1 -Exactly -ParameterFilter { $null -ne $DashboardHandle -and $DashboardHandle.Sequence -eq 1 }
        Should -Invoke Stop-DashboardHostHandle -Times 1 -Exactly -ParameterFilter { $null -ne $DashboardHandle -and $DashboardHandle.Sequence -eq 2 }
        Should -Invoke Stop-DashboardHostHandle -Times 1 -Exactly -ParameterFilter { $null -ne $DashboardHandle -and $DashboardHandle.Sequence -eq 3 }
    }

    It 'R5 (261011-ugi, locked decision 1): a dashboard that flaps on every cycle still writes a constant two log lines, and the slow-tail retries keep coming' {
        $script:fakeMonotonicSeconds = 1000.0
        Mock Get-MonotonicSeconds { $script:fakeMonotonicSeconds += 120.0; $script:fakeMonotonicSeconds }
        $script:exhaustedAtSeconds = $null
        $script:startCallTimesAfterExhausted = [System.Collections.Generic.List[double]]::new()
        Mock Start-DashboardHost {
            if ($null -ne $script:exhaustedAtSeconds) { $script:startCallTimesAfterExhausted.Add($script:fakeMonotonicSeconds) }
            return New-FakeDashboardHandle
        }
        Mock Test-DashboardHostFaulted { $true }
        Mock Stop-DashboardHostHandle { }
        Mock Write-Log {
            if ($Message -like '*fast retries exhausted*') { $script:exhaustedAtSeconds = $script:fakeMonotonicSeconds }
        }
        $port = Get-SupervisorDashboardTestEphemeralPort

        Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 30 -DashboardPort $port -DashboardRestartMaximumAttempts 3

        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host has faulted*' }
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host fast retries exhausted*' }
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Message -like '*Dashboard host recovered*' }
        Should -Invoke Write-Log -Times 2 -Exactly -ParameterFilter { $Message -like '*Dashboard host*' }
        $script:startCallTimesAfterExhausted.Count | Should -BeGreaterOrEqual 3
        for ($index = 1; $index -lt $script:startCallTimesAfterExhausted.Count; $index++) {
            ($script:startCallTimesAfterExhausted[$index] - $script:startCallTimesAfterExhausted[$index - 1]) | Should -BeGreaterOrEqual 600
        }
    }

    It 'R4 (261011-ugi): DashboardPort 0 is fully inert -- no start, no clock read, no dashboard log line' {
        Mock Start-DashboardHost { New-FakeDashboardHandle }
        Mock Get-MonotonicSeconds { 1000.0 }
        Mock Write-Log { }

        Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 5 -DashboardPort 0

        Should -Invoke Start-DashboardHost -Times 0 -Exactly
        Should -Invoke Get-MonotonicSeconds -Times 0 -Exactly
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Message -like '*Dashboard host*' }
    }

    It 'R6 (261011-ugi, D-03): an exception inside the recovery step is logged once, switches recovery off, and never reaches streaming' {
        Mock Start-DashboardHost { $null }
        Mock Test-DashboardRestartDue { throw 'simulated recovery decision failure' }
        Mock Write-Log { }
        Set-PusherDesiredState -ControlFilePath $script:DashboardHostControlFilePath -DesiredState 'streaming'
        Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 1 }
        $port = Get-SupervisorDashboardTestEphemeralPort

        $exitCode = Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 5 -DashboardPort $port

        $exitCode | Should -Be 0
        Should -Invoke Start-PusherProcess -Times 5 -Exactly
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host recovery step raised an unexpected exception*' }
        Should -Invoke Test-DashboardRestartDue -Times 1 -Exactly
    }

    Context 'Dashboard maintenance while a pusher is streaming (261018)' {
        # On 2026-10-04 the dashboard was dead for 14 days. The 261011-ugi retry ran
        # only in the tick loop, and the tick loop is blocked for the whole service
        # while a pusher streams. Wait-PusherProcessExit now polls the pusher in 1 s
        # waits and runs Invoke-DashboardHostMaintenance between polls. These tests pin
        # that the retry schedule runs INSIDE one pusher run, that the pusher's exit
        # code passes through unchanged, and that nothing on this path can kill or
        # delay the pusher. New-FakePusherProcess (tests/TestHelpers.psm1) is the
        # pusher; AlivePollCount is how many 1 s polls it stays alive for.

        BeforeEach {
            $script:inertRecoveryParameters = @{
                ScriptRoot           = $script:DashboardHostTestRoot
                DashboardPort        = 0
                ControlFilePath      = $script:DashboardHostControlFilePath
                MaximumRetryAttempts = 10
                SlowIntervalSeconds  = 600
            }
            $script:fakeMonotonicSeconds = 1000.0
        }

        It 'S1: a dashboard fault mid-stream is stopped, restarted and confirmed while the pusher is still alive' {
            Mock Get-MonotonicSeconds { $script:fakeMonotonicSeconds += 120.0; $script:fakeMonotonicSeconds }
            $script:fakePusherProcess = New-FakePusherProcess -ExitCode 0 -AlivePollCount 6
            Mock Start-PusherProcess { $script:fakePusherProcess }
            $script:startCount = 0
            $script:startsWhilePusherAlive = 0
            Mock Start-DashboardHost {
                $script:startCount++
                if ($script:fakePusherProcess.TimedWaitTimeoutsMilliseconds.Count -ge 1 -and -not $script:fakePusherProcess.HasExited) {
                    $script:startsWhilePusherAlive++
                }
                New-FakeDashboardHandle -Sequence $script:startCount
            }
            Mock Test-DashboardHostFaulted {
                $DashboardHandle.Sequence -eq 1 -and $script:fakePusherProcess.TimedWaitTimeoutsMilliseconds.Count -ge 1
            }
            Mock Stop-DashboardHostHandle { }
            Mock Write-Log { }
            Set-PusherDesiredState -ControlFilePath $script:DashboardHostControlFilePath -DesiredState 'streaming'
            $port = Get-SupervisorDashboardTestEphemeralPort

            Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 2 -DashboardPort $port

            Should -Invoke Start-DashboardHost -Times 2 -Exactly
            Should -Invoke Start-DashboardHost -Times 1 -Exactly -ParameterFilter { $SuppressFailureLog }
            $script:startsWhilePusherAlive | Should -Be 1
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host has faulted*' }
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host recovered*' }
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like 'Pusher exited 0 -- *' }
            Should -Invoke Start-PusherProcess -Times 1 -Exactly
            Get-PusherDesiredState -ControlFilePath $script:DashboardHostControlFilePath | Should -Be 'stopped'
            # Handle 1 is stopped by the fault path (mid-stream); handle 2 by the final
            # cleanup, which only sees it because the state left the wait.
            Should -Invoke Stop-DashboardHostHandle -Times 1 -Exactly -ParameterFilter { $null -ne $DashboardHandle -and $DashboardHandle.Sequence -eq 1 }
            Should -Invoke Stop-DashboardHostHandle -Times 1 -Exactly -ParameterFilter { $null -ne $DashboardHandle -and $DashboardHandle.Sequence -eq 2 }
            $script:fakePusherProcess.TimedWaitTimeoutsMilliseconds.Count | Should -Be 7
            @($script:fakePusherProcess.TimedWaitTimeoutsMilliseconds | Sort-Object -Unique) | Should -Be @(1000)
            $script:fakePusherProcess.FinalWaitCount | Should -Be 1
            $script:fakePusherProcess.DisposeCount | Should -Be 1
            $script:fakePusherProcess.KillCount | Should -Be 0
        }

        It 'S1b: the whole fast-then-slow retry schedule runs inside ONE pusher run and writes exactly three dashboard log lines' {
            Mock Get-MonotonicSeconds { $script:fakeMonotonicSeconds += 120.0; $script:fakeMonotonicSeconds }
            $script:fakePusherProcess = New-FakePusherProcess -ExitCode 0 -AlivePollCount 20
            Mock Start-PusherProcess { $script:fakePusherProcess }
            $script:startAttemptsWhilePusherAlive = 0
            $script:startAttemptSeconds = [System.Collections.Generic.List[double]]::new()
            Mock Start-DashboardHost {
                $script:startAttemptSeconds.Add($script:fakeMonotonicSeconds)
                if ($script:fakePusherProcess.TimedWaitTimeoutsMilliseconds.Count -ge 1 -and -not $script:fakePusherProcess.HasExited) {
                    $script:startAttemptsWhilePusherAlive++
                }
                throw 'simulated dashboard host start failure'
            }
            Mock Write-Log { }
            Set-PusherDesiredState -ControlFilePath $script:DashboardHostControlFilePath -DesiredState 'streaming'
            $port = Get-SupervisorDashboardTestEphemeralPort

            Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 1 -DashboardPort $port

            # 1 initial, 1 top-of-tick, polls 1-9 fast, poll 14 and poll 19 slow.
            Should -Invoke Start-DashboardHost -Times 13 -Exactly
            $script:startAttemptsWhilePusherAlive | Should -Be 11
            $lastTwoAttemptSeconds = @($script:startAttemptSeconds | Select-Object -Last 2)
            ($lastTwoAttemptSeconds[1] - $lastTwoAttemptSeconds[0]) | Should -Be 600
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host fast retries exhausted*' }
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host is unavailable*' }
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host start raised an unexpected exception*' }
            Should -Invoke Write-Log -Times 3 -Exactly -ParameterFilter { $Message -like '*Dashboard host*' }
            Should -Invoke Start-PusherProcess -Times 1 -Exactly
        }

        It 'S2: exit code <ExitCode> passes through unchanged while retries fire (<Launches> launch, desired <Desired>)' -ForEach @(
            @{ ExitCode = 0; Desired = 'stopped'; Launches = 1 }
            @{ ExitCode = 2; Desired = 'stopped'; Launches = 1 }
            @{ ExitCode = 3; Desired = 'stopped'; Launches = 1 }
            @{ ExitCode = 1; Desired = 'streaming'; Launches = 3 }
            @{ ExitCode = -1; Desired = 'streaming'; Launches = 3 }
        ) {
            Mock Get-MonotonicSeconds { $script:fakeMonotonicSeconds += 120.0; $script:fakeMonotonicSeconds }
            Mock Start-DashboardHost { $null }
            Mock Write-Log { }
            $script:caseExitCode = $ExitCode
            $script:fakes = [System.Collections.Generic.List[object]]::new()
            Mock Start-PusherProcess {
                $fakeProcess = New-FakePusherProcess -ExitCode $script:caseExitCode -AlivePollCount 5
                $script:fakes.Add($fakeProcess)
                $fakeProcess
            }
            Set-PusherDesiredState -ControlFilePath $script:DashboardHostControlFilePath -DesiredState 'streaming'
            $port = Get-SupervisorDashboardTestEphemeralPort
            $expectedExitLine = "Pusher exited $ExitCode -- *"

            $supervisorExitCode = Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 3 -DashboardPort $port

            $supervisorExitCode | Should -Be 0
            Should -Invoke Start-PusherProcess -Times $Launches -Exactly
            Get-PusherDesiredState -ControlFilePath $script:DashboardHostControlFilePath | Should -Be $Desired
            Should -Invoke Write-Log -Times $Launches -Exactly -ParameterFilter { $Message -like $expectedExitLine }
            # At least: the initial start plus retries that fired during polls.
            Should -Invoke Start-DashboardHost -Times 2
            $script:fakes.Count | Should -Be $Launches
            foreach ($fakeProcess in $script:fakes) {
                $fakeProcess.KillCount | Should -Be 0
                $fakeProcess.DisposeCount | Should -Be 1
            }
        }

        It 'S3a: Wait-PusherProcessExit polls in 1000 ms timed waits, maintains only after a poll that timed out, and never sleeps' {
            Mock Invoke-DashboardHostMaintenance { $DashboardHostState }
            Mock Start-Sleep { }
            $fakeProcess = New-FakePusherProcess -ExitCode 7 -AlivePollCount 3

            $result = Wait-PusherProcessExit -PusherProcess $fakeProcess -DashboardHostState (New-DashboardHostState) -DashboardRecoveryParameters $script:inertRecoveryParameters

            $result.ExitCode | Should -Be 7
            $fakeProcess.TimedWaitTimeoutsMilliseconds.Count | Should -Be 4
            @($fakeProcess.TimedWaitTimeoutsMilliseconds | Sort-Object -Unique) | Should -Be @(1000)
            Should -Invoke Invoke-DashboardHostMaintenance -Times 3 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
            $fakeProcess.FinalWaitCount | Should -Be 1
            $fakeProcess.DisposeCount | Should -Be 1
            $fakeProcess.KillCount | Should -Be 0
        }

        It 'S3b: a pusher that has already exited at the first poll gets one timed wait and zero maintenance calls' {
            Mock Invoke-DashboardHostMaintenance { $DashboardHostState }
            $fakeProcess = New-FakePusherProcess -ExitCode 2 -AlivePollCount 0

            $result = Wait-PusherProcessExit -PusherProcess $fakeProcess -DashboardHostState (New-DashboardHostState) -DashboardRecoveryParameters $script:inertRecoveryParameters

            $result.ExitCode | Should -Be 2
            $fakeProcess.TimedWaitTimeoutsMilliseconds.Count | Should -Be 1
            Should -Invoke Invoke-DashboardHostMaintenance -Times 0 -Exactly
        }

        It 'S3c: the dashboard state is threaded through every poll and handed back (0,1,2,3 in, 4 out)' {
            $script:seenRetryAttemptCounts = [System.Collections.Generic.List[int]]::new()
            Mock Invoke-DashboardHostMaintenance {
                $script:seenRetryAttemptCounts.Add([int] $DashboardHostState.RetryAttemptCount)
                Copy-DashboardHostState -DashboardHostState $DashboardHostState -Changes @{ RetryAttemptCount = $DashboardHostState.RetryAttemptCount + 1 }
            }
            $fakeProcess = New-FakePusherProcess -ExitCode 0 -AlivePollCount 4

            $result = Wait-PusherProcessExit -PusherProcess $fakeProcess -DashboardHostState (New-DashboardHostState) -DashboardRecoveryParameters $script:inertRecoveryParameters

            @($script:seenRetryAttemptCounts) | Should -Be @(0, 1, 2, 3)
            $result.DashboardHostState.RetryAttemptCount | Should -Be 4
        }

        It 'S3d: the poll interval constant is pinned at 1000 ms' {
            $script:PusherExitPollIntervalMilliseconds | Should -Be 1000
        }

        It 'S5: DashboardPort 0 stays fully inert while a pusher streams (no start, no clock read, no dashboard log line)' {
            Mock Start-DashboardHost { New-FakeDashboardHandle }
            Mock Get-MonotonicSeconds { 1000.0 }
            Mock Write-Log { }
            $script:fakePusherProcess = New-FakePusherProcess -ExitCode 3 -AlivePollCount 5
            Mock Start-PusherProcess { $script:fakePusherProcess }
            Set-PusherDesiredState -ControlFilePath $script:DashboardHostControlFilePath -DesiredState 'streaming'

            Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 1 -DashboardPort 0

            Should -Invoke Start-DashboardHost -Times 0 -Exactly
            Should -Invoke Get-MonotonicSeconds -Times 0 -Exactly
            Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Message -like '*Dashboard host*' }
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like 'Pusher exited 3 -- *' }
            Get-PusherDesiredState -ControlFilePath $script:DashboardHostControlFilePath | Should -Be 'stopped'
            $script:fakePusherProcess.TimedWaitTimeoutsMilliseconds.Count | Should -Be 6
        }

        It 'S6: an exception escaping the recovery step during polls is logged once and switches maintenance off without touching the pusher' {
            $script:fakePusherProcess = New-FakePusherProcess -ExitCode 1 -AlivePollCount 10
            Mock Start-PusherProcess { $script:fakePusherProcess }
            Mock Start-DashboardHost { New-FakeDashboardHandle }
            Mock Stop-DashboardHostHandle { }
            Mock Invoke-DashboardHostRecoveryTick {
                if ($script:fakePusherProcess.TimedWaitTimeoutsMilliseconds.Count -ge 1) { throw 'simulated parameter bind failure' }
                $DashboardHostState
            }
            Mock Write-Log { }
            Set-PusherDesiredState -ControlFilePath $script:DashboardHostControlFilePath -DesiredState 'streaming'
            $port = Get-SupervisorDashboardTestEphemeralPort

            $exitCode = Invoke-Supervisor -ControlFilePath $script:DashboardHostControlFilePath -ScriptRoot $script:DashboardHostTestRoot -MaxTicks 1 -DashboardPort $port

            $exitCode | Should -Be 0
            # Top-of-tick plus the first poll; the other nine polls skip it because
            # RecoveryDisabled is set after the first escape.
            Should -Invoke Invoke-DashboardHostRecoveryTick -Times 2 -Exactly
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Dashboard host recovery step raised an unexpected exception*' }
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like 'Pusher exited 1 -- *' }
            $script:fakePusherProcess.TimedWaitTimeoutsMilliseconds.Count | Should -Be 11
            $script:fakePusherProcess.KillCount | Should -Be 0
        }

        Context 'S7: source structure (AST, so comments cannot satisfy or break it)' {
            BeforeAll {
                $parseErrors = $null
                $script:StreamingSyntaxTree = [System.Management.Automation.Language.Parser]::ParseFile(
                    (Resolve-Path $script:SupervisorScriptPath).Path, [ref]$null, [ref]$parseErrors)

                $script:FindStreamingFunctionAst = {
                    param([string] $FunctionName)
                    $script:StreamingSyntaxTree.Find({
                        param($node)
                        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
                    }, $true)
                }
                $script:FindStreamingCommandNames = {
                    param($Ast)
                    @($Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst]
                    }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
                }
            }

            It 'S7a: exactly one CommandAst calls Invoke-DashboardHostRecoveryTick and it sits inside Invoke-DashboardHostMaintenance' {
                $tickCalls = @($script:StreamingSyntaxTree.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-DashboardHostRecoveryTick'
                }, $true))

                $tickCalls.Count | Should -Be 1
                $enclosingNode = $tickCalls[0].Parent
                while ($null -ne $enclosingNode -and $enclosingNode -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    $enclosingNode = $enclosingNode.Parent
                }
                $enclosingNode.Name | Should -Be 'Invoke-DashboardHostMaintenance'
            }

            It 'S7b: Invoke-DashboardHostMaintenance is called exactly once in Invoke-Supervisor and exactly once in Wait-PusherProcessExit' {
                foreach ($callerName in 'Invoke-Supervisor', 'Wait-PusherProcessExit') {
                    $callerAst = & $script:FindStreamingFunctionAst $callerName
                    $callerAst | Should -Not -BeNullOrEmpty -Because "$callerName must exist"
                    @(& $script:FindStreamingCommandNames $callerAst | Where-Object { $_ -eq 'Invoke-DashboardHostMaintenance' }).Count |
                        Should -Be 1 -Because "$callerName is one of the two maintenance call sites"
                }
            }

            It 'S7c: the maintenance path never kills or stops a process, never cuts, and never touches the probe host' {
                $forbiddenCommandNames = @('Stop-Process', 'Stop-PusherProcesses', 'Stop-PusherProcess', 'Invoke-Cut', 'Start-ProbeHost', 'Test-ProbeHostFaulted')
                foreach ($functionName in 'Wait-PusherProcessExit', 'Invoke-DashboardHostMaintenance', 'Invoke-DashboardHostRecoveryTick') {
                    $functionAst = & $script:FindStreamingFunctionAst $functionName
                    $functionAst | Should -Not -BeNullOrEmpty -Because "$functionName must exist"

                    $killCalls = @($functionAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Extent.Text -eq 'Kill'
                    }, $true))
                    $killCalls.Count | Should -Be 0 -Because "$functionName must never call .Kill()"

                    $forbiddenCalls = @(& $script:FindStreamingCommandNames $functionAst | Where-Object { $forbiddenCommandNames -contains $_ })
                    $forbiddenCalls.Count | Should -Be 0 -Because "$functionName must not call $($forbiddenCalls -join ', ')"
                }
            }

            It 'S7d: Start-PusherProcess only spawns -- its body contains no WaitForExit' {
                $spawnAst = & $script:FindStreamingFunctionAst 'Start-PusherProcess'
                $spawnAst | Should -Not -BeNullOrEmpty
                $waitCalls = @($spawnAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Extent.Text -eq 'WaitForExit'
                }, $true))
                $waitCalls.Count | Should -Be 0
            }

            It 'S7e: Start-PusherProcess reads .Handle so ExitCode stays readable on PowerShell 7.4.0 (#20400 workaround)' {
                $spawnAst = & $script:FindStreamingFunctionAst 'Start-PusherProcess'
                $spawnAst | Should -Not -BeNullOrEmpty
                $handleReads = @($spawnAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.MemberExpressionAst] -and
                    $node -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $node.Member.Extent.Text -eq 'Handle'
                }, $true))
                $handleReads.Count | Should -BeGreaterOrEqual 1
            }
        }
    }

    Context 'Dashboard runspace param threading (SESS-03/04, Pitfall 5)' {
        # This is deliberately a SOURCE/text assertion, not a behavioral one: the
        # dashboard's script block runs in a SEPARATE runspace that inherits
        # nothing (05-01's HOST DECISION), so a missing hop leaves the new routes
        # with a runtime $null, not a compile-time error or a mock-detectable call
        # difference (05.1-RESEARCH.md Pitfall 5, lines 397-415). A behavioral
        # mock of Invoke-DashboardListenerLoop would only prove the OUTER call
        # site passed the right values -- it can't see whether the script block's
        # OWN param() list or the AddArgument chain actually carries them across
        # the runspace boundary. Reading supervisor.ps1 as raw text and asserting
        # on the exact shape of all three hops is the only way to pin this.
        BeforeAll {
            $script:SupervisorSourceText = Get-Content -LiteralPath $script:SupervisorScriptPath -Raw
        }

        It 'Hop 1: the $listenerLoopScriptBlock param() list declares all three new params' {
            if ($script:SupervisorSourceText -notmatch '(?s)\$listenerLoopScriptBlock\s*=\s*\{\s*param\s*\((.*?)\)') {
                throw 'Could not locate $listenerLoopScriptBlock param() block in supervisor.ps1'
            }
            $paramBlockText = $Matches[1]

            $paramBlockText | Should -Match '\$RecordingFolderPath\b'
            $paramBlockText | Should -Match '\$RecordingFilenameGlob\b'
            $paramBlockText | Should -Match '\$StateFilePath\b'
        }

        It 'Hop 2: the AddArgument chain passes $recordingFolderPath / $recordingFilenameGlob / $stateFilePath' {
            if ($script:SupervisorSourceText -notmatch '(?s)\$powershell\.AddScript\(\$listenerLoopScriptBlock\)\.(.*?)\r?\n\r?\n') {
                throw 'Could not locate the AddArgument chain in supervisor.ps1'
            }
            $addArgumentChainText = $Matches[1]

            # No leading-dot requirement: a chain call that wraps onto a new line
            # starts with "AddArgument(...)" with the "." left dangling on the
            # PREVIOUS line -- the presence of the call itself is what matters here.
            $addArgumentChainText | Should -Match 'AddArgument\(\$recordingFolderPath\)'
            $addArgumentChainText | Should -Match 'AddArgument\(\$recordingFilenameGlob\)'
            $addArgumentChainText | Should -Match 'AddArgument\(\$stateFilePath\)'
        }

        It 'Hop 3: the inner Invoke-DashboardListenerLoop call passes -RecordingFolderPath/-RecordingFilenameGlob/-StateFilePath' {
            if ($script:SupervisorSourceText -notmatch '(?s)Invoke-DashboardListenerLoop(.*?)-MaxRequests') {
                throw 'Could not locate the inner Invoke-DashboardListenerLoop call in supervisor.ps1'
            }
            $innerCallText = $Matches[1]

            $innerCallText | Should -Match '-RecordingFolderPath \$RecordingFolderPath'
            $innerCallText | Should -Match '-RecordingFilenameGlob \$RecordingFilenameGlob'
            $innerCallText | Should -Match '-StateFilePath \$StateFilePath'
        }

        It 'Config is read and anchored via Resolve-PusherConfigPaths before threading, and lib/Rotation.psm1 is imported inside the runspace block' {
            # Single-quoted patterns throughout -- a double-quoted string here would
            # interpolate $ScriptRoot/$dashboardConfig as PowerShell variables (which
            # are not set in this test scope) rather than treating them as literal
            # regex text, the exact bug this test itself would otherwise hide.
            $script:SupervisorSourceText | Should -Match 'Resolve-PusherConfigPaths -Config \$dashboardConfig -ScriptRoot \$ScriptRoot'
            $script:SupervisorSourceText | Should -Match 'Import-Module \(Join-Path \$ScriptRoot ''lib/Rotation\.psm1''\)'
        }

        It 'Every param() entry has a matching AddArgument call, in the same order (a dropped hop would desync the two lists)' {
            if ($script:SupervisorSourceText -notmatch '(?s)\$listenerLoopScriptBlock\s*=\s*\{\s*param\s*\((.*?)\)') {
                throw 'Could not locate $listenerLoopScriptBlock param() block in supervisor.ps1'
            }
            $paramNames = ($Matches[1] -split ',') | ForEach-Object {
                ($_ -replace '\$', '').Trim()
            } | Where-Object { $_ }

            if ($script:SupervisorSourceText -notmatch '(?s)\$powershell\.AddScript\(\$listenerLoopScriptBlock\)\.(.*?)\r?\n\r?\n') {
                throw 'Could not locate the AddArgument chain in supervisor.ps1'
            }
            $addArgumentCallCount = ([regex]::Matches($Matches[1], 'AddArgument\(')).Count

            $addArgumentCallCount | Should -Be $paramNames.Count
        }
    }
}

# Supervisor probe host (06-07): proves MON-05/D-04's isolation guarantee holds
# from Invoke-Supervisor's own call site -- not merely that Start-ProbeHost/
# Test-ProbeHostFaulted individually never throw (already their own contract, see
# supervisor.ps1's own doc comments), but that the SUPERVISOR keeps supervising
# AND keeps streaming through a probe host that cannot start (Test 2/3) or that
# faults mid-run (Test 4 -- the one that matters). Mirrors the 'Supervisor
# dashboard host' Describe above test-for-test, with one deliberate difference:
# the probe host is NEVER gated on DashboardPort (or any other flag) -- it is
# unconditionally started once per Invoke-Supervisor call, per D-04's "probes
# are a wholly separate concern from the dashboard" -- so there is no twin of
# dashboard Test 1 (DashboardPort 0 is genuinely inert); every legacy Context in
# the top-level 'supervisor.ps1' Describe above already proves Start-ProbeHost's
# real, unmocked body runs safely (never throws, degrades gracefully) even
# against a scratch root with no lib/ of its own.
Describe 'Supervisor probe host' -Tag 'Quick' {

    BeforeAll {
        function New-FakeProbeHostHandle {
            <#
            .SYNOPSIS
            A duck-typed stand-in for Start-ProbeHost's real return shape
            (PowerShell/AsyncResult) -- lets a test drive Test-ProbeHostFaulted
            and Invoke-Supervisor's finally-block cleanup without a real
            runspace, mirroring New-FakeDashboardHandle above exactly (minus
            the Listener field the probe host has no analog for).
            #>
            param([string] $InvocationState = 'Running')
            return [pscustomobject]@{
                PowerShell = [pscustomobject]@{ InvocationStateInfo = [pscustomobject]@{ State = $InvocationState } }
            }
        }
    }

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Remove-Module Config -ErrorAction SilentlyContinue

        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:ControlFlagModulePath -Force

        # Dot-source (not `&`) so supervisor.ps1's functions -- including
        # Start-ProbeHost/Test-ProbeHostFaulted -- land in THIS scope and are
        # mockable by plain `Mock`, same convention as every other Describe in
        # this file.
        . $script:SupervisorScriptPath

        $script:ProbeHostTestRoot = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:ProbeHostTestRoot -Force | Out-Null
        $script:ProbeHostControlFilePath = Join-Path $script:ProbeHostTestRoot 'control.json'

        Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 0 }
        Mock Start-Sleep { }
    }

    AfterEach {
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Remove-Module Config -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'Test 1: the probe host is started exactly once before the tick loop, not once per tick' {
        Mock Start-ProbeHost { New-FakeProbeHostHandle }

        Invoke-Supervisor -ControlFilePath $script:ProbeHostControlFilePath -ScriptRoot $script:ProbeHostTestRoot -MaxTicks 5

        Should -Invoke Start-ProbeHost -Times 1 -Exactly
    }

    It 'Test 2: the supervisor completes all ticks and returns 0 even when Start-ProbeHost throws' {
        Mock Start-ProbeHost { throw 'simulated probe host start failure' }

        $exitCode = Invoke-Supervisor -ControlFilePath $script:ProbeHostControlFilePath -ScriptRoot $script:ProbeHostTestRoot -MaxTicks 3

        $exitCode | Should -Be 0
        # `-Times 1` WITHOUT `-Exactly` is Pester's "at least once" (no -AtLeast
        # switch exists) -- matches this file's own precedent above. Still
        # polling the flag (idle Start-Sleep) across all 3 ticks is the proof
        # the loop kept running rather than dying when the probe host blew up.
        Should -Invoke Start-Sleep -Times 1
    }

    It 'Test 3: a $null probe-host handle (start failure) does not stop supervision or streaming across multiple crash ticks' {
        Mock Start-ProbeHost { $null }
        Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 1 }
        Set-PusherDesiredState -ControlFilePath $script:ProbeHostControlFilePath -DesiredState 'streaming'

        Invoke-Supervisor -ControlFilePath $script:ProbeHostControlFilePath -ScriptRoot $script:ProbeHostTestRoot -MaxTicks 3

        Should -Invoke Start-PusherProcess -Times 3 -Exactly
    }

    It 'Test 4 (the property that actually matters): a faulted probe host is logged exactly once across 5 ticks and never auto-restarted, while the pusher keeps launching' {
        Mock Start-ProbeHost { New-FakeProbeHostHandle }
        Mock Test-ProbeHostFaulted { $true }
        Mock Write-Log { }
        # A crash (exit 1) on every tick, not the default exit 0 mock -- exit 0
        # flips desired to stopped after the first launch (D-12's stay-down
        # contract), which would collapse this into a single-launch test and
        # hide whether the pusher keeps launching THROUGH a faulted probe host
        # across multiple ticks, the actual property this test exists to prove.
        Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 1 }
        Set-PusherDesiredState -ControlFilePath $script:ProbeHostControlFilePath -DesiredState 'streaming'

        Invoke-Supervisor -ControlFilePath $script:ProbeHostControlFilePath -ScriptRoot $script:ProbeHostTestRoot -MaxTicks 5

        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'Error' -and $Message -like '*Probe host has faulted*'
        }
        Should -Invoke Start-ProbeHost -Times 1 -Exactly
        Should -Invoke Start-PusherProcess -Times 5 -Exactly
    }

    It 'Test 5: the probe-host fault check fires while the loop is still idle (proves the check runs before the idle `continue`)' {
        Mock Start-ProbeHost { New-FakeProbeHostHandle }
        Mock Test-ProbeHostFaulted { $true }
        Mock Write-Log { }
        # Desired state is deliberately left unset (the idle default) -- if the
        # fault check ran only after the idle branch's `continue`, it would
        # never fire here, and this test would fail.

        Invoke-Supervisor -ControlFilePath $script:ProbeHostControlFilePath -ScriptRoot $script:ProbeHostTestRoot -MaxTicks 3

        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'Error' -and $Message -like '*Probe host has faulted*'
        }
    }
}

# Supervisor single-instance entry point (261011-ugi): the mutex is taken in
# Invoke-SupervisorEntryPoint -- the script's process edge -- and never inside
# Invoke-Supervisor, which Pester calls many times in one process. The mutex module
# functions are mocked here; the real mutex behavior is tested in
# tests/SupervisorSingleInstance.Tests.ps1 with unique test names.
Describe 'Supervisor single-instance entry point' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:ControlFlagModulePath -Force

        . $script:SupervisorScriptPath

        $script:EntryPointTestRoot = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:EntryPointTestRoot -Force | Out-Null

        Mock Set-LogDirectory { }
        Mock Write-Log { }
        # Throws so the acquired path takes the entry point's own config-read fallback
        # (no .env is ever read); the losing-instance test asserts it is called 0 times.
        Mock Read-PusherConfig { throw 'simulated unreadable config' }
    }

    AfterEach {
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'a second instance (mutex not available) logs one line and returns 0 without reading config or starting the supervisor' {
        Mock Enter-SupervisorSingleInstance { $null }
        Mock Exit-SupervisorSingleInstance { }
        Mock Invoke-Supervisor { 0 }

        $exitCode = Invoke-SupervisorEntryPoint -ScriptRoot $script:EntryPointTestRoot -SingleInstanceMutexName 'Global\GaplessSupervisorTest-fake' -SingleInstanceWaitSeconds 1

        $exitCode | Should -Be 0
        Should -Invoke Invoke-Supervisor -Times 0 -Exactly
        Should -Invoke Read-PusherConfig -Times 0 -Exactly
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*Another supervisor instance is already running*' }
        # 261018: the loser says WHO it is, so a duplicate launch is attributable.
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
            $Message -like '*Another supervisor instance is already running*' -and $Message -like '*pid=*' -and $Message -like '*user=*'
        }
    }

    It 'the instance that gets the mutex runs the supervisor, passes its exit code through, and releases the mutex once' {
        Mock Enter-SupervisorSingleInstance { [pscustomobject]@{ Name = 'fake' } }
        Mock Exit-SupervisorSingleInstance { }
        Mock Invoke-Supervisor { 7 }

        $exitCode = Invoke-SupervisorEntryPoint -ScriptRoot $script:EntryPointTestRoot -SingleInstanceMutexName 'Global\GaplessSupervisorTest-fake' -SingleInstanceWaitSeconds 1

        $exitCode | Should -Be 7
        Should -Invoke Invoke-Supervisor -Times 1 -Exactly
        Should -Invoke Exit-SupervisorSingleInstance -Times 1 -Exactly
    }

    It 'returns 1, writes one last-gasp Error line and releases the mutex when Invoke-Supervisor throws' {
        Mock Enter-SupervisorSingleInstance { [pscustomobject]@{ Name = 'fake' } }
        Mock Exit-SupervisorSingleInstance { }
        Mock Invoke-Supervisor { throw [System.IO.IOException]::new('simulated supervisor crash') }

        $exitCode = Invoke-SupervisorEntryPoint -ScriptRoot $script:EntryPointTestRoot -SingleInstanceMutexName 'Global\GaplessSupervisorTest-fake' -SingleInstanceWaitSeconds 1

        $exitCode | Should -Be 1
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'Error' -and $Message -like '*terminating on unhandled exception*' -and
            $Message -like '*System.IO.IOException*' -and $Message -like "*pid $PID*"
        }
        Should -Invoke Exit-SupervisorSingleInstance -Times 1 -Exactly
    }

    It 'still returns 1, releases the mutex and falls back to the last-gasp file when Write-Log itself throws' {
        Mock Enter-SupervisorSingleInstance { [pscustomobject]@{ Name = 'fake' } }
        Mock Exit-SupervisorSingleInstance { }
        Mock Invoke-Supervisor { throw [System.IO.IOException]::new('simulated supervisor crash') }
        # Filtered, so the BeforeEach's default Write-Log mock still serves every other line
        # and the run reaches Invoke-Supervisor (an unfiltered throw plus the BeforeEach's
        # Read-PusherConfig throw used to short-circuit before it).
        Mock Write-Log { throw [System.IO.IOException]::new('log locked') } -ParameterFilter { $Message -like '*terminating on unhandled exception*' }

        $exitCode = Invoke-SupervisorEntryPoint -ScriptRoot $script:EntryPointTestRoot -SingleInstanceMutexName 'Global\GaplessSupervisorTest-fake' -SingleInstanceWaitSeconds 1

        $exitCode | Should -Be 1
        Should -Invoke Invoke-Supervisor -Times 1 -Exactly
        Should -Invoke Exit-SupervisorSingleInstance -Times 1 -Exactly
        $lastGaspLogPath = Join-Path $script:EntryPointTestRoot 'state/logs/supervisor-last-gasp.log'
        Test-Path -LiteralPath $lastGaspLogPath | Should -BeTrue
        Get-Content -LiteralPath $lastGaspLogPath -Raw | Should -BeLike '*Supervisor terminating on unhandled exception*'
    }

    It 'writes exactly one line to the last-gasp file on every unhandled-exception exit, also when Write-Log works' {
        Mock Enter-SupervisorSingleInstance { [pscustomobject]@{ Name = 'fake' } }
        Mock Exit-SupervisorSingleInstance { }
        Mock Invoke-Supervisor { throw [System.IO.IOException]::new('simulated supervisor crash') }

        $exitCode = Invoke-SupervisorEntryPoint -ScriptRoot $script:EntryPointTestRoot -SingleInstanceMutexName 'Global\GaplessSupervisorTest-fake' -SingleInstanceWaitSeconds 1

        $exitCode | Should -Be 1
        Should -Invoke Invoke-Supervisor -Times 1 -Exactly
        # Write-Log can no longer throw (261018), so the file cannot be a try/catch-only
        # fallback: the death must reach a file Write-Log's own I/O cannot take down.
        $lastGaspLogPath = Join-Path $script:EntryPointTestRoot 'state/logs/supervisor-last-gasp.log'
        Test-Path -LiteralPath $lastGaspLogPath | Should -BeTrue
        $lastGaspLines = @(Get-Content -LiteralPath $lastGaspLogPath | Where-Object { $_ })
        $lastGaspLines.Count | Should -Be 1
        $lastGaspLines[0] | Should -BeLike '*[[]Error[]] Supervisor terminating on unhandled exception*System.IO.IOException*'
    }

    It 'a normal run writes one Supervisor exiting line with the exit code and no last-gasp Error line' {
        Mock Enter-SupervisorSingleInstance { [pscustomobject]@{ Name = 'fake' } }
        Mock Exit-SupervisorSingleInstance { }
        Mock Invoke-Supervisor { 0 }

        $exitCode = Invoke-SupervisorEntryPoint -ScriptRoot $script:EntryPointTestRoot -SingleInstanceMutexName 'Global\GaplessSupervisorTest-fake' -SingleInstanceWaitSeconds 1

        $exitCode | Should -Be 0
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'Info' -and $Message -like '*Supervisor exiting (pid=*code=0)*'
        }
        # The BeforeEach's simulated config-read failure logs its own Error line; only
        # the last-gasp wording is excluded here.
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter {
            $Level -eq 'Error' -and $Message -like '*terminating on unhandled exception*'
        }
        Test-Path -LiteralPath (Join-Path $script:EntryPointTestRoot 'state/logs/supervisor-last-gasp.log') | Should -BeFalse
    }

    Context 'source structure' {
        # Text/AST assertions, like the param-threading Context above: the properties
        # that matter here (where the mutex is taken, what the script's process edge
        # does) are about the SHAPE of supervisor.ps1, not about a call's result.
        BeforeAll {
            $parseErrors = $null
            $script:SupervisorSyntaxTree = [System.Management.Automation.Language.Parser]::ParseFile(
                (Resolve-Path $script:SupervisorScriptPath).Path, [ref]$null, [ref]$parseErrors)
        }

        It 'Invoke-Supervisor never references Enter-SupervisorSingleInstance (Pester calls it many times in one process)' {
            $invokeSupervisorAst = $script:SupervisorSyntaxTree.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Supervisor'
            }, $true)

            $invokeSupervisorAst | Should -Not -BeNullOrEmpty
            $invokeSupervisorAst.Body.Extent.Text | Should -Not -Match 'Enter-SupervisorSingleInstance'
        }

        It 'the bottom guard still starts with the dot-source check and its only statement is exit (Invoke-SupervisorEntryPoint -ScriptRoot $PSScriptRoot)' {
            $bottomGuardAst = $script:SupervisorSyntaxTree.EndBlock.Statements |
                Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] } |
                Select-Object -Last 1

            $bottomGuardAst | Should -Not -BeNullOrEmpty
            $bottomGuardAst.Clauses[0].Item1.Extent.Text | Should -Be "`$MyInvocation.InvocationName -ne '.'"
            $guardStatements = @($bottomGuardAst.Clauses[0].Item2.Statements)
            $guardStatements.Count | Should -Be 1
            $guardStatements[0].Extent.Text | Should -Be 'exit (Invoke-SupervisorEntryPoint -ScriptRoot $PSScriptRoot)'
        }
    }
}

# Real end-to-end host test (Test 8): a genuine runspace, a genuine HttpListener, a
# genuine HTTP client. Segregated into its own 'Integration'-tagged Describe --
# `Invoke-Pester -Tag Quick` never runs it -- matching how this repo's real-ffmpeg/SRT
# integration tests are already kept out of the fast loop (tests/PusherStats.Tests.ps1,
# tests/Integration.*.Tests.ps1).
Describe 'Supervisor dashboard host (real end-to-end)' -Tag 'Integration' {

    BeforeAll {
        # The repo root, resolved the same way tests/TestHelpers.psm1's
        # New-TestTunedPusherCopy documents: "tests/, repo root is its parent".
        $script:RealHostRepoRootPath = Resolve-Path (Join-Path $PSScriptRoot '..')

        function Get-SupervisorDashboardIntegrationEphemeralPort {
            $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            try {
                $tcpListener.Start()
                return ([System.Net.IPEndPoint] $tcpListener.LocalEndpoint).Port
            } finally {
                $tcpListener.Stop()
            }
        }
    }

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Remove-Module Dashboard -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module PusherProcess -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Config -ErrorAction SilentlyContinue

        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:ControlFlagModulePath -Force

        . $script:SupervisorScriptPath

        # Start-DashboardHost's runspace script block resolves lib/*.psm1 and cut.ps1
        # from -ScriptRoot itself (production reality: supervisor.ps1's own
        # $PSScriptRoot, where the whole repo lives side by side). A throwaway
        # $TestDrive directory has no lib/ of its own, so -ScriptRoot must point at a
        # scratch root that MIRRORS the repo layout -- copying lib/ and cut.ps1 in,
        # exactly the "$PSScriptRoot still resolves lib/* correctly" technique
        # tests/TestHelpers.psm1's New-TestTunedPusherCopy already uses for pusher.ps1
        # scratch copies -- rather than pointing at the real repo root directly, which
        # would read this box's real .env and write into its real state/stats.json.
        $script:RealHostTestRoot = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:RealHostTestRoot 'state') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:RealHostTestRoot 'dashboard') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RealHostRepoRootPath 'lib') -Destination (Join-Path $script:RealHostTestRoot 'lib') -Recurse
        Copy-Item -LiteralPath (Join-Path $script:RealHostRepoRootPath 'cut.ps1') -Destination (Join-Path $script:RealHostTestRoot 'cut.ps1')
        Set-Content -LiteralPath (Join-Path $script:RealHostTestRoot 'dashboard/index.html') -Value '<html>real-host</html>' -Encoding utf8 -NoNewline
        $script:RealHostControlFilePath = Join-Path $script:RealHostTestRoot 'control.json'
    }

    AfterEach {
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Remove-Module Dashboard -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module PusherProcess -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Config -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'Test 8: a real dashboard host serves /api/stats over an ephemeral port with a real stats.json fixture' {
        $port = Get-SupervisorDashboardIntegrationEphemeralPort

        $now = Get-MonotonicSeconds
        $statsPayload = [ordered]@{
            schemaVersion            = 1
            pusherState              = 'Streaming'
            recordingFilePath        = 'D:\recording.ts'
            offsetBytes              = 1000
            fileLengthBytes          = 2000
            sendBytesPerSecond       = 500.0
            recordBytesPerSecond     = 500.0
            secondsBehindLive        = 5.0
            backoffAttemptNumber     = 0
            cumulativeReconnectCount = 0
            lastClassificationCause  = $null
            catchUpCapUtilization    = 0.0
            outageActive             = $false
            updatedEpochSeconds      = $now
            staleAfterEpochSeconds   = $now + 60
        }
        ($statsPayload | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $script:RealHostTestRoot 'state/stats.json') -Encoding utf8

        $handle = Start-DashboardHost -ScriptRoot $script:RealHostTestRoot -DashboardPort $port -ControlFilePath $script:RealHostControlFilePath
        try {
            $handle | Should -Not -BeNullOrEmpty

            $response = Invoke-RestMethod -Uri "http://localhost:$port/api/stats" -Method Get -TimeoutSec 10

            $response.ConnectionState | Should -Not -BeNullOrEmpty
        } finally {
            if ($handle) {
                try { Stop-DashboardListener -Listener $handle.Listener } catch { }
                try { $handle.PowerShell.Stop() } catch { }
                try { $handle.PowerShell.Dispose() } catch { }
            }
        }
    }
}

# Pusher-exit wait against a REAL child process (S8, 261018). Proves what the fakes
# cannot: the real Start-PusherProcess + Wait-PusherProcessExit hand back the real
# exit code through Start-Process -PassThru, and a 1 s poll adds no detection
# latency (WaitForExit(ms) is a kernel wait that returns the instant the child exits).
# Integration-tagged: it spawns pwsh and has a wall-clock assertion, so it must never
# run during a live service and can flake under heavy load. Run it alone.
Describe 'Supervisor pusher-exit wait (real process)' -Tag 'Integration' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:ControlFlagModulePath -Force

        . $script:SupervisorScriptPath

        $script:RealWaitStubRoot = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:RealWaitStubRoot -Force | Out-Null
        Mock Invoke-DashboardHostMaintenance { $DashboardHostState }
    }

    AfterEach {
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'S8: exit code <ExitCode> after <RunMs> ms survives the real polling wait and is detected in under 900 ms' -ForEach @(
        @{ ExitCode = 0; RunMs = 2500 }
        @{ ExitCode = 2; RunMs = 0 }
        @{ ExitCode = 3; RunMs = 1200 }
        @{ ExitCode = 7; RunMs = 2500 }
    ) {
        $markerPath = Join-Path $script:RealWaitStubRoot 'exit-marker.txt'
        $quotedMarkerPath = $markerPath.Replace("'", "''")
        $stubPusherSource = "Start-Sleep -Milliseconds $RunMs; [IO.File]::WriteAllText('$quotedMarkerPath', [Diagnostics.Stopwatch]::GetTimestamp().ToString()); exit $ExitCode"
        Set-Content -LiteralPath (Join-Path $script:RealWaitStubRoot 'pusher.ps1') -Value $stubPusherSource -Encoding utf8
        $inertRecoveryParameters = @{
            ScriptRoot           = $script:RealWaitStubRoot
            DashboardPort        = 0
            ControlFilePath      = (Join-Path $script:RealWaitStubRoot 'control.json')
            MaximumRetryAttempts = 10
            SlowIntervalSeconds  = 600
        }

        $pusherProcess = Start-PusherProcess -ScriptRoot $script:RealWaitStubRoot
        $waitResult = Wait-PusherProcessExit -PusherProcess $pusherProcess -DashboardHostState (New-DashboardHostState) -DashboardRecoveryParameters $inertRecoveryParameters
        $detectedTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()

        $waitResult.ExitCode | Should -Be $ExitCode
        $exitMarkerTimestamp = [long] (Get-Content -LiteralPath $markerPath -Raw).Trim()
        $detectionLatencyMilliseconds = ($detectedTimestamp - $exitMarkerTimestamp) * 1000.0 / [Diagnostics.Stopwatch]::Frequency
        $detectionLatencyMilliseconds | Should -BeLessThan 900
    }
}

# Orphan-pusher guard against REAL processes (B6/B7, 261018). The scenario the five-minute
# watchdog creates: the supervisor dies, its pusher keeps streaming, and a new supervisor
# is launched for the same install. The new supervisor must NOT start a second pusher
# until the orphan is gone, and must then start exactly one. Integration-tagged: it spawns
# real pwsh supervisors and takes the real per-install Pusher mutex of a throwaway copy of
# the repo (unique path, so a unique mutex name). Never run it during a live service;
# run it alone.
Describe 'Supervisor orphan-pusher guard (real processes)' -Tag 'Integration' {

    BeforeAll {
        $script:OrphanGuardRepoRootPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:OrphanGuardSpawnedProcessIds = [System.Collections.Generic.List[int]]::new()

        function Read-OrphanGuardSharedText {
            param([Parameter(Mandatory)] [string] $Path)

            if (-not (Test-Path -LiteralPath $Path)) { return '' }
            try {
                $fileStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    $streamReader = [System.IO.StreamReader]::new($fileStream)
                    return $streamReader.ReadToEnd()
                } finally {
                    $fileStream.Dispose()
                }
            } catch {
                return ''
            }
        }

        function Get-OrphanGuardStubStartCount {
            param([Parameter(Mandatory)] [string] $InstallRoot)

            $startLines = (Read-OrphanGuardSharedText -Path (Join-Path $InstallRoot 'pusher-starts.log')) -split "`r?`n" | Where-Object { $_ -match '^\d+$' }
            return @($startLines).Count
        }

        function Wait-OrphanGuardCondition {
            param([Parameter(Mandatory)] [scriptblock] $Condition, [int] $TimeoutSeconds = 30)

            $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            while (-not (& $Condition)) {
                if ([DateTime]::UtcNow -ge $deadline) { return $false }
                Start-Sleep -Milliseconds 250
            }
            return $true
        }

        function Start-OrphanGuardSupervisor {
            param([Parameter(Mandatory)] [string] $InstallRoot)

            $supervisorProcess = Start-Process -FilePath (Get-Process -Id $PID).Path `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $InstallRoot 'supervisor.ps1')) `
                -WorkingDirectory $InstallRoot -WindowStyle Hidden -PassThru
            $script:OrphanGuardSpawnedProcessIds.Add($supervisorProcess.Id)
            return $supervisorProcess
        }
    }

    BeforeEach {
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Import-Module $script:ControlFlagModulePath -Force

        # A throwaway install: its own path, so its own Supervisor and Pusher mutex names,
        # and a throwaway .env that pins DASHBOARD_PORT=0 so no dashboard listener is started.
        # Without that line the config defaults apply and DashboardPort is 8787, the
        # production dashboard port, which this test must never touch.
        $script:OrphanGuardInstallRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:OrphanGuardInstallRoot 'state') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:OrphanGuardInstallRoot '.env') -Value 'DASHBOARD_PORT=0' -Encoding utf8
        Copy-Item -LiteralPath (Join-Path $script:OrphanGuardRepoRootPath 'lib') -Destination (Join-Path $script:OrphanGuardInstallRoot 'lib') -Recurse
        foreach ($fileName in @('supervisor.ps1', 'cut.ps1')) {
            Copy-Item -LiteralPath (Join-Path $script:OrphanGuardRepoRootPath $fileName) -Destination (Join-Path $script:OrphanGuardInstallRoot $fileName)
        }

        $stubPusherSource = @'
Import-Module (Join-Path $PSScriptRoot 'lib/SupervisorSingleInstance.psm1')
$pusherMutex = Enter-SupervisorSingleInstance -MutexName (Get-SupervisorSingleInstanceMutexName -ScriptRoot $PSScriptRoot -Role 'Pusher') -WaitSeconds 15
if ($null -eq $pusherMutex) { exit 4 }
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'pusher-starts.log') -Value $PID
$releaseFlagPath = Join-Path $PSScriptRoot 'release-pusher.flag'
while (-not (Test-Path -LiteralPath $releaseFlagPath)) { Start-Sleep -Milliseconds 200 }
Remove-Item -LiteralPath $releaseFlagPath -Force
Exit-SupervisorSingleInstance -Mutex $pusherMutex
exit 0
'@
        Set-Content -LiteralPath (Join-Path $script:OrphanGuardInstallRoot 'pusher.ps1') -Value $stubPusherSource -Encoding utf8
        Set-PusherDesiredState -ControlFilePath (Get-PusherControlFilePath -ScriptRoot $script:OrphanGuardInstallRoot) -DesiredState 'streaming'
    }

    AfterEach {
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
    }

    AfterAll {
        # Kills only PIDs this Describe spawned: the supervisors it started and the stub
        # pushers recorded in the pusher-starts.log files under $TestDrive.
        $startsLogs = Get-ChildItem -LiteralPath $TestDrive -Filter 'pusher-starts.log' -Recurse -ErrorAction SilentlyContinue
        foreach ($startsLog in $startsLogs) {
            New-Item -ItemType File -Path (Join-Path $startsLog.DirectoryName 'release-pusher.flag') -Force -ErrorAction SilentlyContinue | Out-Null
            foreach ($recordedLine in ((Read-OrphanGuardSharedText -Path $startsLog.FullName) -split "`r?`n")) {
                if ($recordedLine -match '^\d+$') { $script:OrphanGuardSpawnedProcessIds.Add([int] $recordedLine) }
            }
        }
        foreach ($spawnedProcessId in $script:OrphanGuardSpawnedProcessIds) {
            Stop-Process -Id $spawnedProcessId -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a replacement supervisor starts no second pusher while the orphaned one runs, then starts exactly one after it exits' {
        $installRoot = $script:OrphanGuardInstallRoot

        $supervisorA = Start-OrphanGuardSupervisor -InstallRoot $installRoot
        (Wait-OrphanGuardCondition -Condition { (Get-OrphanGuardStubStartCount -InstallRoot $installRoot) -eq 1 }) | Should -BeTrue -Because 'supervisor A must launch the first stub pusher'

        # Kill ONLY the supervisor: its stub pusher survives as the orphan.
        Stop-Process -Id $supervisorA.Id -Force
        Wait-Process -Id $supervisorA.Id -Timeout 30

        $supervisorB = Start-OrphanGuardSupervisor -InstallRoot $installRoot
        $supervisorLogPath = Join-Path $installRoot 'state/logs/pusher.log'
        (Wait-OrphanGuardCondition -Condition { (Read-OrphanGuardSharedText -Path $supervisorLogPath) -match 'Another pusher for this install is still running' } -TimeoutSeconds 30) | Should -BeTrue -Because 'supervisor B must report the running orphan before it does anything else'

        Get-OrphanGuardStubStartCount -InstallRoot $installRoot | Should -Be 1
        $supervisorLogText = Read-OrphanGuardSharedText -Path $supervisorLogPath
        ([regex]::Matches($supervisorLogText, 'Another pusher for this install is still running')).Count | Should -Be 1

        # Let the orphan finish: the flag is its only exit signal.
        New-Item -ItemType File -Path (Join-Path $installRoot 'release-pusher.flag') -Force | Out-Null

        (Wait-OrphanGuardCondition -Condition { (Get-OrphanGuardStubStartCount -InstallRoot $installRoot) -eq 2 } -TimeoutSeconds 20) | Should -BeTrue -Because 'supervisor B must launch exactly one new pusher once the orphan is gone'
        Start-Sleep -Seconds 3
        Get-OrphanGuardStubStartCount -InstallRoot $installRoot | Should -Be 2
        $supervisorB.HasExited | Should -BeFalse
    }
}

# Cut.Tests.ps1
# Unit tests for cut.ps1 (locked design extension, item 7) and for the supervisor
# behaviour the cut button depends on to not undo itself.
#
# WHAT CUT IS. Stop = drain then stop: it sends the remaining backlog before exiting
# (stop.ps1 + the explicit end-of-service signal, see ExplicitStop.Tests.ps1). Cut =
# stop NOW, accepting the lost backlog -- the "this must not be going out" button for
# wrong content live. The recording file on disk is never touched, so nothing is
# destroyed and a later start.ps1 resumes from the persisted offset.
#
# WHY THE ORDER IS THE WHOLE DESIGN. Killing the pusher makes it exit non-zero, and
# Get-SupervisorExitDecision classifies any non-zero-but-not-2 exit as a CRASH ->
# Relaunch. If cut.ps1 killed first and set the flag second, the supervisor could
# relaunch the very stream the operator just cut -- back on air, at the worst possible
# moment. Setting desired=stopped FIRST means the crash path sleeps its backoff, loops,
# re-reads the flag at the top of the tick, sees 'stopped', and idles: the relaunch is
# decided but never happens. That re-read-at-top-of-tick ordering in Invoke-Supervisor
# is load-bearing for the cut button, so it is pinned here rather than left implicit.
#
# Both scripts are top-level (never modules), matching install.ps1/supervisor.ps1, so
# they are dot-sourced here and never invoked -- the bottom
# `if ($MyInvocation.InvocationName -ne '.')` guard keeps the real entry point from
# running on dot-source. The control flag is exercised for REAL against $TestDrive
# files: "the flag was already stopped at the instant of the kill" is the entire
# correctness claim, so asserting it against a mocked flag would assert nothing.

BeforeAll {
    # New-FakePusherProcess: Start-PusherProcess is spawn-only (261018), so the
    # mocks below return a fake process and the real Wait-PusherProcessExit reads it.
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:CutScriptPath = Join-Path $PSScriptRoot '../cut.ps1'
    $script:SupervisorScriptPath = Join-Path $PSScriptRoot '../supervisor.ps1'
    $script:ControlFlagModulePath = Join-Path $PSScriptRoot '../lib/ControlFlag.psm1'
    $script:LoggingModulePath = Join-Path $PSScriptRoot '../lib/Logging.psm1'
}

Describe 'cut.ps1' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Remove-Module PusherProcess -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:ControlFlagModulePath -Force

        . $script:CutScriptPath

        $script:CutTestRoot = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:CutTestRoot -Force | Out-Null
        $script:ControlFilePath = Join-Path $script:CutTestRoot 'control.json'
    }

    AfterEach {
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Remove-Module PusherProcess -ErrorAction SilentlyContinue
        Pop-Location
    }

    Context 'Invoke-Cut (flag BEFORE kill -- the correctness argument, not a style point)' {

        It 'has already written desired=stopped at the instant it kills the pusher' {
            # The assertion is an ORDER assertion, so it is taken from INSIDE the kill:
            # the mock reads the real control file at the exact moment cut.ps1 asks for
            # the kill. A flag-after-kill implementation reaches this line with the flag
            # still 'streaming' and fails, which is the entire point -- a passing
            # "Set-PusherDesiredState was called" check would say nothing about order.
            $script:desiredStateAtKillTime = 'KILL-NEVER-HAPPENED'
            Mock Stop-PusherProcesses {
                $script:desiredStateAtKillTime = Get-PusherDesiredState -ControlFilePath $script:ControlFilePath
                return 1
            }
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'

            Invoke-Cut -ControlFilePath $script:ControlFilePath -ScriptRoot $script:CutTestRoot | Out-Null

            # Guards the sentinel: without this, an implementation that never kills at
            # all would leave the captured value untouched and could not be told apart
            # from a correct one by the assertion below.
            Should -Invoke Stop-PusherProcesses -Times 1 -Exactly
            $script:desiredStateAtKillTime | Should -Be 'stopped' -Because 'a kill with the flag still streaming lets the supervisor classify the cut as a crash and relaunch the stream the operator just cut'
        }

        It 'leaves desired=stopped behind after the cut, so the supervisor stays down' {
            Mock Stop-PusherProcesses { return 1 }
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'

            Invoke-Cut -ControlFilePath $script:ControlFilePath -ScriptRoot $script:CutTestRoot | Out-Null

            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
        }

        It 'still writes the flag when there is no pusher running to kill (cut must be safe to press twice)' {
            Mock Stop-PusherProcesses { return 0 }
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'

            Invoke-Cut -ControlFilePath $script:ControlFilePath -ScriptRoot $script:CutTestRoot | Out-Null

            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
            Should -Invoke Stop-PusherProcesses -Times 1 -Exactly
        }

        It 'never touches the recording file or the persisted offset (cut abandons the backlog, it does not destroy it -- a later start.ps1 resumes from the offset)' {
            Mock Stop-PusherProcesses { return 1 }
            $recordingPath = Join-Path $script:CutTestRoot 'recording-001.ts'
            $offsetPath = Join-Path $script:CutTestRoot 'offset.json'
            [System.IO.File]::WriteAllBytes($recordingPath, (New-Object byte[] 3760))
            [System.IO.File]::WriteAllText($offsetPath, '{"byteOffset":1880,"file":"recording-001.ts"}')
            $recordingBytesBefore = [System.IO.File]::ReadAllBytes($recordingPath)
            $offsetTextBefore = [System.IO.File]::ReadAllText($offsetPath)

            Invoke-Cut -ControlFilePath $script:ControlFilePath -ScriptRoot $script:CutTestRoot | Out-Null

            Test-Path -LiteralPath $recordingPath | Should -BeTrue
            [System.IO.File]::ReadAllBytes($recordingPath).Length | Should -Be $recordingBytesBefore.Length
            [System.IO.File]::ReadAllText($offsetPath) | Should -Be $offsetTextBefore
        }

        It 'returns 0 so the `exit (Invoke-Cut ...)` bottom guard reports a successful cut' {
            Mock Stop-PusherProcesses { return 1 }

            Invoke-Cut -ControlFilePath $script:ControlFilePath -ScriptRoot $script:CutTestRoot | Should -Be 0
        }
    }

    Context 'Stop-PusherProcesses (delegates matching to lib/PusherProcess.psm1, owns only the kill -- 05-03-PLAN.md Task 2)' {

        It 'obtains its process list by calling Get-RunningPusherProcesses exactly once with the passed ScriptRoot -- the filter is no longer forked inside cut.ps1' {
            Mock Get-RunningPusherProcesses { return , @() }

            Stop-PusherProcesses -ScriptRoot $script:CutTestRoot | Out-Null

            Should -Invoke Get-RunningPusherProcesses -Times 1 -Exactly -ParameterFilter {
                $ScriptRoot -eq $script:CutTestRoot
            }
        }

        It 'returns the number of processes it killed' {
            Mock Get-RunningPusherProcesses {
                return , @(
                    [pscustomobject]@{ ProcessId = 111 },
                    [pscustomobject]@{ ProcessId = 222 }
                )
            }
            Mock Stop-Process { }

            Stop-PusherProcesses -ScriptRoot $script:CutTestRoot | Should -Be 2
        }

        It 'does not throw when a process exits between enumeration and the kill' {
            # Real Stop-Process (not mocked) against a PID that cannot possibly exist --
            # this exercises the actual -ErrorAction SilentlyContinue on the real cmdlet,
            # not a mocked stand-in for it, which is the whole point of this test: the
            # pusher is being cut precisely because it may be exiting on its own at the
            # same moment.
            Mock Get-RunningPusherProcesses {
                return , @(
                    [pscustomobject]@{ ProcessId = 999999 }
                )
            }

            { $script:killedCount = Stop-PusherProcesses -ScriptRoot $script:CutTestRoot } | Should -Not -Throw
            $script:killedCount | Should -Be 1 -Because 'the loop still counts the attempt even when the process was already gone -- Stop-PusherProcesses reports what it TRIED to kill, matching its pre-refactor behavior'
        }
    }
}

Describe 'supervisor.ps1 after a cut' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:ControlFlagModulePath -Force

        . $script:SupervisorScriptPath

        $script:SupervisorTestRoot = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:SupervisorTestRoot -Force | Out-Null
        $script:ControlFilePath = Join-Path $script:SupervisorTestRoot 'control.json'

        # Captures only the supervisor's OWN log calls: Invoke-Supervisor is dot-sourced
        # into this scope, whereas ControlFlag's internal Write-Log calls run inside that
        # module's session state and are not intercepted here. That is exactly the split
        # wanted -- these tests are about what the supervisor tells the operator.
        $script:capturedLogMessages = [System.Collections.Generic.List[string]]::new()
        Mock Write-Log { $script:capturedLogMessages.Add($Message) }
        Mock Start-Sleep { }
    }

    AfterEach {
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    Context 'crash exit + flag already stopped => zero relaunch (the cut button must not restart what it cut)' {

        It 'never relaunches the pusher after a cut-induced non-zero exit' {
            # Models cut.ps1 exactly, in its real order: the flag goes to stopped, THEN
            # the kill lands, and the killed pusher reports a crash-class exit code.
            # Invoke-Supervisor must classify that as Relaunch and still not relaunch,
            # because the flag re-read at the top of the next tick overrules it.
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'
            Mock Start-PusherProcess {
                Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'stopped'
                return (New-FakePusherProcess -ExitCode 1)
            }

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 10

            Should -Invoke Start-PusherProcess -Times 1 -Exactly -Because 'the flag was already stopped before the kill, so the crash path must find it on the next tick and idle'
        }

        It 'leaves desired at stopped after a cut-induced crash exit (the crash path must never resurrect the flag)' {
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'
            Mock Start-PusherProcess {
                Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'stopped'
                return (New-FakePusherProcess -ExitCode 1)
            }

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 10

            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
        }

        It 'still relaunches on a genuine crash where no operator cut occurred (the cut guard must not disable crash restart itself)' {
            # The negative control for the two tests above: if "flag stopped => no
            # relaunch" were implemented by simply never relaunching, this fails.
            # Crash restart is the entire reason supervisor.ps1 exists.
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 1 }

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 3

            Should -Invoke Start-PusherProcess -Times 3 -Exactly
        }
    }

    Context 'the relaunch log must not promise a relaunch that never happens (D-14 bounded, and honest)' {

        It 'does not tell the operator it is relaunching when the cut flag means it will not' {
            # Today the supervisor logs "Relaunching the pusher in ${x}ms" BEFORE the
            # flag re-read turns that into a no-op, so after a cut the log states a
            # relaunch that never occurs. A church volunteer reading that line at 10:55
            # on a Sunday would believe the stream is coming back. It is not.
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'
            Mock Start-PusherProcess {
                Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'stopped'
                return (New-FakePusherProcess -ExitCode 1)
            }

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 10

            # Proves the capture works at all, so the emptiness below cannot be vacuous.
            $script:capturedLogMessages | Should -Not -BeNullOrEmpty
            @($script:capturedLogMessages -match 'Relaunching the pusher in') |
                Should -BeNullOrEmpty -Because 'the operator cut the stream; a log line claiming a relaunch that the very next tick cancels is a lie to the person trying to fix a live service'
        }

        It 'still tells the operator about a relaunch that genuinely does happen' {
            # The positive control that keeps the test above honest: deleting the log
            # line entirely would satisfy that test and fail this one. Both must hold.
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 1 }

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 3

            @($script:capturedLogMessages -match 'Relaunching the pusher in') |
                Should -Not -BeNullOrEmpty -Because 'a real crash restart must still be visible in the log'
        }

        It 'makes no relaunch claim ANYWHERE in the log after a cut -- not in the dedicated line, and not in the exit reason either' {
            # The same lie, surviving in a SECOND string. The dedicated "Relaunching the
            # pusher in ${x}ms" line was moved after the flag re-read (the two tests
            # above pin that), but Invoke-Supervisor's crash branch ALSO logs
            # $decision.Reason verbatim, and Get-SupervisorExitDecision's Relaunch Reason
            # still asserts "Relaunching after a backoff; ... the stream catches back up".
            # Observed live at 00:02:50 after a real cut on the real box:
            #   [Warning] Cut: killed pusher process 6872 -- ...
            #   [Error]   Pusher exited -1 -- ... Relaunching after a backoff ...  <-- lie
            #   [Info]    Desired state is now 'stopped'   <- no relaunch, correctly
            # The exit code is a FACT and must be logged. The relaunch is a DECISION the
            # flag re-read has not made yet, and must not be claimed here.
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'
            Mock Start-PusherProcess {
                Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'stopped'
                return (New-FakePusherProcess -ExitCode 1)
            }

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 10

            # Anti-vacuity, two ways. The capture works at all, AND the crash branch
            # provably ran and reported the exit -- so the emptiness below is the
            # absence of a CLAIM, not the absence of logging.
            $script:capturedLogMessages | Should -Not -BeNullOrEmpty
            @($script:capturedLogMessages -match 'Pusher exited 1') |
                Should -Not -BeNullOrEmpty -Because 'the exit itself is a fact and must still reach the operator'
            @($script:capturedLogMessages -match 'Relaunching|catches back up') |
                Should -BeNullOrEmpty -Because 'a volunteer who pressed Cut is told the stream is coming back; it is not'
        }

        It 'keeps the buffer reassurance ON the genuine relaunch line, where it is true' {
            # The counterweight to the test above, and the reason the fix cannot just be
            # "delete the reassuring words". When a REAL crash relaunches, "the recording
            # file on disk is the buffer, so the stream catches back up" is accurate and
            # is exactly what a volunteer needs at 10:55 on a Sunday. Pinning it to the
            # SAME message as "Relaunching the pusher in" is what makes it honest: that
            # line is only ever written once the flag re-read has confirmed the relaunch
            # will actually happen. Carried in the exit reason instead, it is emitted
            # before anything has decided, which is precisely the defect.
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'
            Mock Start-PusherProcess { New-FakePusherProcess -ExitCode 1 }

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 3

            @($script:capturedLogMessages | Where-Object {
                ($_ -match 'Relaunching the pusher in') -and
                ($_ -match 'the recording file on disk is the buffer') -and
                ($_ -match 'catches back up')
            }) | Should -Not -BeNullOrEmpty -Because 'the reassurance must travel with the relaunch it describes, not with the exit that has not decided one'
        }
    }
}

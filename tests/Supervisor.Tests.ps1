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

BeforeAll {
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
            Mock Start-PusherProcess { 0 }
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

    Context 'Invoke-Supervisor (exit 0 -- clean end-of-service stays down)' {

        BeforeEach {
            Mock Start-PusherProcess { 0 }
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
            Mock Start-PusherProcess { 2 }
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
            Mock Start-PusherProcess { 1 }

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 3

            Should -Invoke Start-PusherProcess -Times 3 -Exactly
        }

        It 'leaves desired at streaming across crashes (a crash is not an operator stop)' {
            Mock Start-PusherProcess { 1 }

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 3

            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'streaming'
        }

        It 'backs off between crash relaunches rather than hot-looping (Open-TailerFileStream throws when no recording file exists -- an un-delayed relaunch would spin at full CPU)' {
            Mock Start-PusherProcess { 1 }

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
                return 1
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
            Mock Start-PusherProcess { 0 }
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

    Context 'Session state persistence (260718-epo)' {

        BeforeEach {
            Mock Start-Sleep { }
            $script:SessionStateFilePath = Join-Path $script:SupervisorTestRoot 'session.json'
            $script:AutoPickupRecordingFolderPath = Join-Path $script:SupervisorTestRoot 'recordings'
            New-Item -ItemType Directory -Path $script:AutoPickupRecordingFolderPath -Force | Out-Null
        }

        It 'writes lastExitReason=clean-end-of-service and the finished recording file on exit 0' {
            Mock Start-PusherProcess { 0 }
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
            Mock Start-PusherProcess { 2 }
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'

            Invoke-Supervisor -ControlFilePath $script:ControlFilePath -ScriptRoot $script:SupervisorTestRoot -MaxTicks 1 `
                -RecordingFolderPath $script:AutoPickupRecordingFolderPath -RecordingFilenameGlob '*.ts' `
                -SessionStateFilePath $script:SessionStateFilePath

            $sessionState = Read-SessionState -SessionStateFilePath $script:SessionStateFilePath
            $sessionState.lastExitReason | Should -Be 'config-fail'
            $sessionState.finishedRecordingFilePath | Should -BeNullOrEmpty
        }

        It 'writes lastExitReason=crash with NO finished recording file on an unexpected exit code' {
            Mock Start-PusherProcess { 1 }
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
            Mock Start-PusherProcess { 0 }
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
            param([string] $InvocationState = 'Running')
            return [pscustomobject]@{
                Listener   = $null
                PowerShell = [pscustomobject]@{ InvocationStateInfo = [pscustomobject]@{ State = $InvocationState } }
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

        Mock Start-PusherProcess { 0 }
        Mock Start-Sleep { }
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

        Mock Start-PusherProcess { 0 }
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
        Mock Start-PusherProcess { 1 }
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
        Mock Start-PusherProcess { 1 }
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

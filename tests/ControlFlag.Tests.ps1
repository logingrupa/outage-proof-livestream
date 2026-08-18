# ControlFlag.Tests.ps1
# Unit tests for lib/ControlFlag.psm1 -- the {desired: stopped|streaming} control
# flag that is the seam between an explicit operator command (start.ps1/stop.ps1,
# and Phase 5's dashboard Start button) and supervisor.ps1's run loop.
#
# The safe default is ALWAYS 'stopped': streaming to a LIVE YouTube audience must
# never begin unattended, so every untrusted-input path (missing file, corrupt
# JSON, unknown value) resolves to stopped rather than to streaming. That bias is
# the exact inverse of OffsetStore's re-send bias, and is asserted here directly.

BeforeAll {
    $script:ControlFlagModulePath = Join-Path $PSScriptRoot '../lib/ControlFlag.psm1'
    $script:LoggingModulePath = Join-Path $PSScriptRoot '../lib/Logging.psm1'
}

Describe 'ControlFlag' -Tag 'Quick' {

    BeforeEach {
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:ControlFlagModulePath -Force

        # Per-It work directory -- $TestDrive is shared across every It in this
        # file's run, so a fixed control.json path would leak state across tests
        # (same convention as Install.Tests.ps1's Initialize-PusherEnvFile context).
        $script:ControlTestRoot = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:ControlTestRoot -Force | Out-Null
        $script:ControlFilePath = Join-Path $script:ControlTestRoot 'control.json'
    }

    AfterEach {
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
    }

    Context 'Get-PusherDesiredState (untrusted persisted input always resolves to a safe default)' {

        It 'returns stopped when no control file exists at all (boot = idle)' {
            Test-Path -LiteralPath $script:ControlFilePath | Should -BeFalse

            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
        }

        It 'returns stopped and never throws when the control file is corrupt JSON' {
            [System.IO.File]::WriteAllText($script:ControlFilePath, '{ this is not json')

            { Get-PusherDesiredState -ControlFilePath $script:ControlFilePath } | Should -Not -Throw
            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
        }

        It 'returns stopped when the persisted desired value is an unrecognised string' {
            [System.IO.File]::WriteAllText($script:ControlFilePath, '{"desired":"banana"}')

            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
        }

        It 'returns stopped when the control file is valid JSON with no desired property' {
            [System.IO.File]::WriteAllText($script:ControlFilePath, '{"somethingElse":"streaming"}')

            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
        }

        It 'returns stopped when the control file is empty' {
            [System.IO.File]::WriteAllText($script:ControlFilePath, '')

            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
        }
    }

    Context 'Test-PusherExplicitStopRequested (the OTHER question -- opposite safe default, on purpose)' {
        # Get-PusherDesiredState answers "may the supervisor START streaming?", where an
        # unreadable file must mean NO. This answers "did the operator ask a RUNNING
        # pusher to stop?", where an unreadable file must mean NO SIGNAL -- keep
        # streaming. Ending a live church service because a file was momentarily
        # unreadable is unrecoverable content loss; a stop that does not take is
        # recoverable (press Stop again, or Cut). The default follows the QUESTION, not
        # the file, so these two functions must disagree on every malformed input below.
        # A single reader shared between both questions is exactly the bug this pins.

        It 'is $true only when the operator explicitly wrote desired=stopped' {
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'stopped'

            Test-PusherExplicitStopRequested -ControlFilePath $script:ControlFilePath | Should -BeTrue
        }

        It 'is $false while desired=streaming' {
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'

            Test-PusherExplicitStopRequested -ControlFilePath $script:ControlFilePath | Should -BeFalse
        }

        It 'is $false when NO control file exists -- silence is not a stop' {
            # Every existing integration test, and any hand-run pusher.ps1, has no
            # control file. Reading that as an operator stop would make each of them
            # drain and exit 0 the instant it started -- turning the whole suite green
            # for entirely the wrong reason.
            Test-Path -LiteralPath $script:ControlFilePath | Should -BeFalse

            Test-PusherExplicitStopRequested -ControlFilePath $script:ControlFilePath | Should -BeFalse
            # Pinned against the other reader in the same It: same file, same instant,
            # opposite answers. This is the design, not an accident of implementation.
            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
        }

        It 'is $false when the control file is CORRUPT -- distinct from missing, and never ends a live service on a parse error' {
            [System.IO.File]::WriteAllText($script:ControlFilePath, '{ this is not json')

            { Test-PusherExplicitStopRequested -ControlFilePath $script:ControlFilePath } | Should -Not -Throw
            Test-PusherExplicitStopRequested -ControlFilePath $script:ControlFilePath | Should -BeFalse
            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
        }

        It 'is $false when the control file is empty' {
            [System.IO.File]::WriteAllText($script:ControlFilePath, '')

            Test-PusherExplicitStopRequested -ControlFilePath $script:ControlFilePath | Should -BeFalse
        }

        It 'is $false when the desired value is an unrecognised string' {
            [System.IO.File]::WriteAllText($script:ControlFilePath, '{"desired":"banana"}')

            Test-PusherExplicitStopRequested -ControlFilePath $script:ControlFilePath | Should -BeFalse
        }

        It 'is $false when there is no desired property at all' {
            [System.IO.File]::WriteAllText($script:ControlFilePath, '{"somethingElse":"stopped"}')

            Test-PusherExplicitStopRequested -ControlFilePath $script:ControlFilePath | Should -BeFalse
        }

        It 'is $false when desired is a list rather than a string, even one containing "stopped"' {
            # Without the `-is [string]` guard, a bare `-eq` against an array returns a
            # truthy FILTERED COLLECTION (@('stopped')) rather than $false -- so this
            # malformed file would end a live church service. Two elements, not one, is
            # deliberate: PowerShell unrolls a single-element array on return, so
            # {"desired":["stopped"]} arrives at the guard as the bare string 'stopped'
            # and is (correctly, and unavoidably) read as a stop. This pins the case the
            # guard can actually see.
            [System.IO.File]::WriteAllText($script:ControlFilePath, '{"desired":["stopped","banana"]}')

            Test-PusherExplicitStopRequested -ControlFilePath $script:ControlFilePath | Should -BeFalse
        }

        It 'is $false when desired is an object rather than a string' {
            [System.IO.File]::WriteAllText($script:ControlFilePath, '{"desired":{"value":"stopped"}}')

            Test-PusherExplicitStopRequested -ControlFilePath $script:ControlFilePath | Should -BeFalse
        }
    }

    Context 'Set-PusherDesiredState (round-trip through the real file)' {

        It 'round-trips streaming' {
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'

            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'streaming'
        }

        It 'round-trips stopped' {
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'stopped'

            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
        }

        It 'overwrites a previous value rather than appending a second one' {
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'stopped'

            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'stopped'
        }

        It 'creates the state directory when it does not exist yet (first-ever start on a fresh install)' {
            $freshControlPath = Join-Path $script:ControlTestRoot 'never/created/control.json'

            Set-PusherDesiredState -ControlFilePath $freshControlPath -DesiredState 'streaming'

            Get-PusherDesiredState -ControlFilePath $freshControlPath | Should -Be 'streaming'
        }

        It 'rejects an unrecognised desired state instead of persisting it' {
            # Asserts the ValidateSet rejection specifically, and that NO file was
            # written -- a bare `Should -Throw` here is satisfied by any exception
            # at all (including CommandNotFoundException before this module even
            # exists), which is precisely the kind of vacuous green that let the
            # Task Scheduler restart promise ship untested in the first place.
            { Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'banana' } |
                Should -Throw -ErrorId 'ParameterArgumentValidationError,Set-PusherDesiredState'

            Test-Path -LiteralPath $script:ControlFilePath | Should -BeFalse
        }

        It 'leaves the previous good file intact when a bad write is rejected' {
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'

            { Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'banana' } | Should -Throw

            Get-PusherDesiredState -ControlFilePath $script:ControlFilePath | Should -Be 'streaming'
        }

        It 'never leaves a stray temp file behind in the state directory' {
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'streaming'
            Set-PusherDesiredState -ControlFilePath $script:ControlFilePath -DesiredState 'stopped'

            @(Get-ChildItem -LiteralPath $script:ControlTestRoot -Filter '*.tmp').Count | Should -Be 0
        }
    }
}

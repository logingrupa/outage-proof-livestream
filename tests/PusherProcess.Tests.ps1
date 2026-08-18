# PusherProcess.Tests.ps1
# Unit tests for lib/PusherProcess.psm1 -- the shared read-only "what is a pusher
# process" filter extracted out of cut.ps1's Stop-PusherProcesses (05-03-PLAN.md).
#
# WHAT THESE TESTS PIN. The filter itself: match on full CommandLine (never process
# name -- a name match would also catch the supervisor and every other pwsh.exe on the
# box), ordinal case-insensitive Contains (never -like -- a ScriptRoot legitimately
# containing [, ], or ? must still match), a $null CommandLine skipped rather than
# thrown on, and a zero-/one-element result staying a real array under StrictMode (the
# unary-comma trap already recorded in STATE.md and guarded in Config.psm1's
# Test-PusherConfig). Test-PusherProcessAlive's degrade-to-$false-never-throw contract
# on an uninspectable process table is pinned separately (T-05-15).
#
# Get-CimInstance is mocked inside the module's own scope (-ModuleName PusherProcess)
# so no real process table is ever queried.

BeforeAll {
    $script:PusherProcessModulePath = Join-Path $PSScriptRoot '../lib/PusherProcess.psm1'
}

Describe 'PusherProcess' -Tag 'Quick' {

    BeforeEach {
        Remove-Module PusherProcess -ErrorAction SilentlyContinue
        Import-Module $script:PusherProcessModulePath -Force
    }

    AfterEach {
        Remove-Module PusherProcess -ErrorAction SilentlyContinue
    }

    Context 'Get-RunningPusherProcesses' {

        It 'returns exactly the one process whose CommandLine contains ScriptRoot\pusher.ps1' {
            Mock Get-CimInstance -ModuleName PusherProcess {
                @(
                    [pscustomobject]@{ ProcessId = 111; CommandLine = 'pwsh.exe -File C:\app\pusher.ps1' }
                )
            }

            # No @() wrapper on any of these calls, anywhere in this file, on purpose:
            # Get-RunningPusherProcesses already guards its own return with the unary
            # comma (`return , $array`), which exists specifically so a bare
            # `$result = Get-RunningPusherProcesses ...` StrictMode assignment gets a
            # real array. Wrapping that already-guarded return in an OUTER @() at the
            # call site double-wraps it (the single pipeline object -- the array
            # itself -- becomes the lone element of a second, synthetic array), which
            # silently breaks `.Count` and element access. The precedent this mirrors
            # is Config.psm1's own callers of `Test-PusherConfig`, which also assign
            # the guarded return directly, never through `@()`.
            $result = Get-RunningPusherProcesses -ScriptRoot 'C:\app'

            $result.Count | Should -Be 1
            $result[0].ProcessId | Should -Be 111
        }

        It 'does NOT return the supervisor process -- matching by name instead of command line would kill the one process that must survive a cut' {
            Mock Get-CimInstance -ModuleName PusherProcess {
                @(
                    [pscustomobject]@{ ProcessId = 222; CommandLine = 'pwsh.exe -File C:\app\supervisor.ps1' }
                )
            }

            $result = Get-RunningPusherProcesses -ScriptRoot 'C:\app'

            $result.Count | Should -Be 0
        }

        It 'matches case-insensitively (ordinal, not culture) -- a CommandLine with a differently-cased path still matches' {
            Mock Get-CimInstance -ModuleName PusherProcess {
                @(
                    [pscustomobject]@{ ProcessId = 333; CommandLine = 'pwsh.exe -File c:\app\PUSHER.PS1' }
                )
            }

            $result = Get-RunningPusherProcesses -ScriptRoot 'C:\app'

            $result.Count | Should -Be 1
            $result[0].ProcessId | Should -Be 333
        }

        It 'matches a ScriptRoot containing -like wildcard characters via ordinal Contains, not -like' {
            Mock Get-CimInstance -ModuleName PusherProcess {
                @(
                    [pscustomobject]@{ ProcessId = 444; CommandLine = 'pwsh.exe -File C:\app[1]\pusher.ps1' }
                )
            }

            $result = Get-RunningPusherProcesses -ScriptRoot 'C:\app[1]'

            $result.Count | Should -Be 1 -Because '-like would treat [1] as a character class and silently fail to match its own pusher.ps1'
            $result[0].ProcessId | Should -Be 444
        }

        It 'skips a process with a $null CommandLine (protected/system process) without throwing' {
            Mock Get-CimInstance -ModuleName PusherProcess {
                @(
                    [pscustomobject]@{ ProcessId = 555; CommandLine = $null },
                    [pscustomobject]@{ ProcessId = 666; CommandLine = 'pwsh.exe -File C:\app\pusher.ps1' }
                )
            }

            { $script:result = Get-RunningPusherProcesses -ScriptRoot 'C:\app' } | Should -Not -Throw
            $script:result.Count | Should -Be 1
            $script:result[0].ProcessId | Should -Be 666
        }

        It 'returns a real, zero-element array (never $null, never a bare scalar) when nothing matches' {
            Mock Get-CimInstance -ModuleName PusherProcess {
                @(
                    [pscustomobject]@{ ProcessId = 777; CommandLine = 'pwsh.exe -File C:\app\supervisor.ps1' }
                )
            }

            $result = Get-RunningPusherProcesses -ScriptRoot 'C:\app'

            $result.Count | Should -Be 0
        }
    }

    Context 'Test-PusherProcessAlive' {

        It 'returns $false when Get-RunningPusherProcesses finds no matching processes' {
            Mock Get-CimInstance -ModuleName PusherProcess { @() }

            Test-PusherProcessAlive -ScriptRoot 'C:\app' | Should -Be $false
        }

        It 'returns $true when Get-RunningPusherProcesses finds one or more matching processes' {
            Mock Get-CimInstance -ModuleName PusherProcess {
                @(
                    [pscustomobject]@{ ProcessId = 888; CommandLine = 'pwsh.exe -File C:\app\pusher.ps1' }
                )
            }

            Test-PusherProcessAlive -ScriptRoot 'C:\app' | Should -Be $true
        }

        It 'returns $false (never throws) when Get-CimInstance itself throws -- an uninspectable process table degrades to "assume not alive"' {
            Mock Get-CimInstance -ModuleName PusherProcess { throw 'simulated CIM failure' }

            { $script:result = Test-PusherProcessAlive -ScriptRoot 'C:\app' } | Should -Not -Throw
            $script:result | Should -Be $false
        }
    }
}

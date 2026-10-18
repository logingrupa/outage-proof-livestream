# SupervisorSingleInstance.Tests.ps1
# Tests for lib/SupervisorSingleInstance.psm1 -- the per-install Global\ mutex that
# keeps a second supervisor from ever running next to the first.
#
# WHY THIS FILE EXISTS: on 2026-10-04, after an unclean reboot, two different
# scheduled tasks each launched supervisor.ps1 once (MultipleInstances=IgnoreNew is
# per task and cannot see the other task). Two tick loops ran, each starting its own
# pusher; on 2026-09-13 two pushers pushed conflicting byte ranges. With OBS recording,
# two pushers would push the same file at the same time and break the byte-order
# guarantee.
#
# Every mutex name in this file is unique per test ('Global\GaplessSupervisorTest-'
# plus a GUID) -- never the production name, so a test can never block or be blocked
# by a real supervisor. A named mutex can be re-entered by the thread that already
# owns it, so real contention is exercised with a DIFFERENT process (the Integration
# Describe); every child process is started and killed by the test itself.

BeforeAll {
    $script:SingleInstanceModulePath = Join-Path $PSScriptRoot '../lib/SupervisorSingleInstance.psm1'
    $script:SingleInstanceModuleName = 'SupervisorSingleInstance'

    function New-UniqueTestMutexName {
        return 'Global\GaplessSupervisorTest-' + [Guid]::NewGuid().ToString('N')
    }
}

Describe 'SupervisorSingleInstance mutex naming' -Tag 'Quick' {

    BeforeEach {
        Remove-Module $script:SingleInstanceModuleName -ErrorAction SilentlyContinue
        Import-Module $script:SingleInstanceModulePath -Force
    }

    AfterEach {
        Remove-Module $script:SingleInstanceModuleName -ErrorAction SilentlyContinue
    }

    It 'returns a Global\ name with the supervisor prefix and no further backslash' {
        $name = Get-SupervisorSingleInstanceMutexName -ScriptRoot 'C:\Example\App'

        $name | Should -BeLike 'Global\GaplessSrtPusher-Supervisor-*'
        $name.Substring('Global\'.Length) | Should -Not -Match '\\'
    }

    It 'maps the same install to the same name regardless of case and trailing separator' {
        $first = Get-SupervisorSingleInstanceMutexName -ScriptRoot 'C:\Example\App'
        $second = Get-SupervisorSingleInstanceMutexName -ScriptRoot 'c:\example\app\'

        $second | Should -Be $first
    }

    It 'maps different installs to different names, so a portable kit never blocks production' {
        $app = Get-SupervisorSingleInstanceMutexName -ScriptRoot 'C:\Example\App'
        $other = Get-SupervisorSingleInstanceMutexName -ScriptRoot 'C:\Example\Other'

        $other | Should -Not -Be $app
    }

    It 'is deterministic across calls' {
        $first = Get-SupervisorSingleInstanceMutexName -ScriptRoot 'D:\gapless-srt-pusher'
        $second = Get-SupervisorSingleInstanceMutexName -ScriptRoot 'D:\gapless-srt-pusher'

        $second | Should -Be $first
    }

    It 'the Supervisor role, and the default with no -Role, equal the legacy supervisor name exactly (no silent rename across a rolling deploy)' {
        $installPath = 'C:\Example\App'
        $normalizedPath = [System.IO.Path]::GetFullPath($installPath).TrimEnd('\', '/').ToLowerInvariant()
        $hashBytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($normalizedPath))
        $expectedName = 'Global\GaplessSrtPusher-Supervisor-' + [Convert]::ToHexString($hashBytes).ToLowerInvariant().Substring(0, 16)

        Get-SupervisorSingleInstanceMutexName -ScriptRoot $installPath | Should -BeExactly $expectedName
        Get-SupervisorSingleInstanceMutexName -ScriptRoot $installPath -Role 'Supervisor' | Should -BeExactly $expectedName
    }

    It 'the Pusher role has its own prefix and never collides with the supervisor name of the same install' {
        $pusherName = Get-SupervisorSingleInstanceMutexName -ScriptRoot 'C:\Example\App' -Role 'Pusher'
        $supervisorName = Get-SupervisorSingleInstanceMutexName -ScriptRoot 'C:\Example\App' -Role 'Supervisor'

        $pusherName | Should -BeLike 'Global\GaplessSrtPusher-Pusher-*'
        $pusherName.Substring('Global\'.Length) | Should -Not -Match '\\'
        $pusherName | Should -Not -Be $supervisorName
    }
}

Describe 'Test-SingleInstanceMutexHeld (261018)' -Tag 'Quick' {
    # The orphan-pusher guard: the supervisor asks "does a pusher of this install still
    # hold the Pusher mutex?" before every launch. The probe must never throw, never
    # keep the kernel object alive, and treat a probe error as "not held" (the pusher's
    # own guard is the backstop).

    BeforeEach {
        Remove-Module $script:SingleInstanceModuleName -ErrorAction SilentlyContinue
        Import-Module $script:SingleInstanceModulePath -Force
    }

    AfterEach {
        Remove-Module $script:SingleInstanceModuleName -ErrorAction SilentlyContinue
    }

    It 'returns $false for a name that does not exist, and does not create it' {
        $mutexName = New-UniqueTestMutexName

        Test-SingleInstanceMutexHeld -MutexName $mutexName | Should -BeFalse

        $probeHandle = $null
        [System.Threading.Mutex]::TryOpenExisting($mutexName, [ref]$probeHandle) | Should -BeFalse
    }

    It 'returns $false for an existing mutex nobody owns' {
        $mutexName = New-UniqueTestMutexName
        $unownedMutex = [System.Threading.Mutex]::new($false, $mutexName)

        try {
            Test-SingleInstanceMutexHeld -MutexName $mutexName | Should -BeFalse
        } finally {
            $unownedMutex.Dispose()
        }
    }

    It 'returns $true when another principal holds the mutex (UnauthorizedAccessException on open)' {
        Mock Open-ExistingSingleInstanceMutexHandle -ModuleName $script:SingleInstanceModuleName {
            throw [System.UnauthorizedAccessException]::new('simulated cross-principal denial')
        }

        Test-SingleInstanceMutexHeld -MutexName (New-UniqueTestMutexName) | Should -BeTrue
    }

    It 'returns $false and does not throw on any other probe failure (a probe error must not block streaming)' {
        Mock Open-ExistingSingleInstanceMutexHandle -ModuleName $script:SingleInstanceModuleName {
            throw [System.IO.IOException]::new('simulated probe failure')
        }

        $probeResult = $null
        { $script:probeResult = Test-SingleInstanceMutexHeld -MutexName (New-UniqueTestMutexName) } | Should -Not -Throw
        $script:probeResult | Should -BeFalse
    }
}

Describe 'SupervisorSingleInstance enter and exit (same process)' -Tag 'Quick' {

    BeforeEach {
        Remove-Module $script:SingleInstanceModuleName -ErrorAction SilentlyContinue
        Import-Module $script:SingleInstanceModulePath -Force
    }

    AfterEach {
        Remove-Module $script:SingleInstanceModuleName -ErrorAction SilentlyContinue
        Remove-Variable -Name SingleInstanceTestDenialCount -Scope Global -ErrorAction SilentlyContinue
    }

    It 'the first Enter returns a held Mutex and Exit releases and disposes it without throwing' {
        $mutex = Enter-SupervisorSingleInstance -MutexName (New-UniqueTestMutexName) -WaitSeconds 1

        $mutex | Should -BeOfType ([System.Threading.Mutex])
        { Exit-SupervisorSingleInstance -Mutex $mutex } | Should -Not -Throw
    }

    It 'Exit with a $null mutex does nothing' {
        { Exit-SupervisorSingleInstance -Mutex $null } | Should -Not -Throw
    }

    It 'a cross-principal denial (UnauthorizedAccessException) is retried until the deadline, then Enter returns $null without throwing' {
        Mock New-SupervisorSingleInstanceMutexHandle -ModuleName $script:SingleInstanceModuleName {
            throw [System.UnauthorizedAccessException]::new('simulated cross-principal denial')
        }

        $result = $null
        { $script:result = Enter-SupervisorSingleInstance -MutexName (New-UniqueTestMutexName) -WaitSeconds 1 } | Should -Not -Throw

        $script:result | Should -BeNullOrEmpty
        Should -Invoke New-SupervisorSingleInstanceMutexHandle -ModuleName $script:SingleInstanceModuleName -Times 2
    }

    It 'a denial that clears within the wait still ends with a held Mutex' {
        $global:SingleInstanceTestDenialCount = 0
        Mock New-SupervisorSingleInstanceMutexHandle -ModuleName $script:SingleInstanceModuleName {
            if ($global:SingleInstanceTestDenialCount -lt 1) {
                $global:SingleInstanceTestDenialCount++
                throw [System.UnauthorizedAccessException]::new('simulated cross-principal denial')
            }
            return [System.Threading.Mutex]::new($false, $MutexName)
        }

        $mutex = Enter-SupervisorSingleInstance -MutexName (New-UniqueTestMutexName) -WaitSeconds 5

        try {
            $mutex | Should -BeOfType ([System.Threading.Mutex])
        } finally {
            Exit-SupervisorSingleInstance -Mutex $mutex
        }
    }
}

Describe 'SupervisorSingleInstance cross-process behavior (real second process)' -Tag 'Integration' {

    BeforeAll {
        $script:ChildProcessIds = [System.Collections.Generic.List[int]]::new()

        function Start-MutexChildProcess {
            <#
            .SYNOPSIS
            Starts a hidden child pwsh that takes the named mutex, writes a ready file,
            then runs HoldBehavior. Returns the child Process. The test that calls this
            owns the child and must clean it up (the Describe's AfterAll also kills any
            PID this helper recorded).
            #>
            param(
                [Parameter(Mandatory)] [string] $MutexName,
                [Parameter(Mandatory)] [string] $ReadyFilePath,
                [Parameter(Mandatory)] [ValidateSet('HoldSixtySeconds', 'ExitWithoutRelease', 'HoldOneSecondThenRelease')] [string] $HoldBehavior
            )

            $holdStatement = switch ($HoldBehavior) {
                'HoldSixtySeconds'         { 'Start-Sleep -Seconds 60' }
                'ExitWithoutRelease'       { 'exit 0' }
                'HoldOneSecondThenRelease' { 'Start-Sleep -Seconds 1; $mutex.ReleaseMutex()' }
            }
            $childScript = @"
`$mutex = [System.Threading.Mutex]::new(`$false, '$MutexName')
if (-not `$mutex.WaitOne(5000)) { exit 3 }
Set-Content -LiteralPath '$ReadyFilePath' -Value 'ready'
$holdStatement
"@
            $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($childScript))
            $childProcess = Start-Process -FilePath (Get-Process -Id $PID).Path `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedCommand) `
                -WindowStyle Hidden -PassThru
            $script:ChildProcessIds.Add($childProcess.Id)
            return $childProcess
        }

        function Wait-ForReadyFile {
            param([Parameter(Mandatory)] [string] $ReadyFilePath, [int] $TimeoutSeconds = 30)

            $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            while (-not (Test-Path -LiteralPath $ReadyFilePath)) {
                if ([DateTime]::UtcNow -ge $deadline) { throw "Child process never wrote '$ReadyFilePath'" }
                Start-Sleep -Milliseconds 100
            }
        }
    }

    BeforeEach {
        Remove-Module $script:SingleInstanceModuleName -ErrorAction SilentlyContinue
        Import-Module $script:SingleInstanceModulePath -Force
    }

    AfterEach {
        Remove-Module $script:SingleInstanceModuleName -ErrorAction SilentlyContinue
    }

    AfterAll {
        # Kills only PIDs this file itself spawned.
        foreach ($childProcessId in $script:ChildProcessIds) {
            Stop-Process -Id $childProcessId -Force -ErrorAction SilentlyContinue
        }
    }

    It 'contention: while another process holds the mutex, Enter waits out its deadline and returns $null' {
        $mutexName = New-UniqueTestMutexName
        $readyFilePath = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N') + '.ready')
        $child = Start-MutexChildProcess -MutexName $mutexName -ReadyFilePath $readyFilePath -HoldBehavior HoldSixtySeconds

        try {
            Wait-ForReadyFile -ReadyFilePath $readyFilePath

            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $mutex = Enter-SupervisorSingleInstance -MutexName $mutexName -WaitSeconds 1
            $stopwatch.Stop()

            $mutex | Should -BeNullOrEmpty
            $stopwatch.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 0.8
            $stopwatch.Elapsed.TotalSeconds | Should -BeLessOrEqual 10
        } finally {
            Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'abandoned: a mutex left behind by a process that exited without releasing it counts as acquired' {
        $mutexName = New-UniqueTestMutexName
        $readyFilePath = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N') + '.ready')
        # An observer handle that never owns the mutex keeps the kernel object alive
        # after the child exits, so the abandoned state survives for Enter to find.
        $observer = [System.Threading.Mutex]::new($false, $mutexName)

        try {
            $child = Start-MutexChildProcess -MutexName $mutexName -ReadyFilePath $readyFilePath -HoldBehavior ExitWithoutRelease
            Wait-ForReadyFile -ReadyFilePath $readyFilePath
            Wait-Process -Id $child.Id -Timeout 30

            $mutex = Enter-SupervisorSingleInstance -MutexName $mutexName -WaitSeconds 5

            try {
                $mutex | Should -BeOfType ([System.Threading.Mutex])
            } finally {
                Exit-SupervisorSingleInstance -Mutex $mutex
            }
        } finally {
            $observer.Dispose()
        }
    }

    It 'released within the wait: a previous instance that is shutting down does not leave zero supervisors' {
        $mutexName = New-UniqueTestMutexName
        $readyFilePath = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N') + '.ready')
        $child = Start-MutexChildProcess -MutexName $mutexName -ReadyFilePath $readyFilePath -HoldBehavior HoldOneSecondThenRelease

        try {
            Wait-ForReadyFile -ReadyFilePath $readyFilePath

            $mutex = Enter-SupervisorSingleInstance -MutexName $mutexName -WaitSeconds 10

            try {
                $mutex | Should -BeOfType ([System.Threading.Mutex])
            } finally {
                Exit-SupervisorSingleInstance -Mutex $mutex
            }
        } finally {
            Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'probe (261018): Test-SingleInstanceMutexHeld is $true while another process holds the mutex, $false once that holder is killed, and a second probe is still $false' {
        $mutexName = New-UniqueTestMutexName
        $readyFilePath = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N') + '.ready')
        # The observer keeps the kernel object alive after the holder dies, so the
        # abandoned state is what the probe actually meets.
        $observer = [System.Threading.Mutex]::new($false, $mutexName)

        try {
            $child = Start-MutexChildProcess -MutexName $mutexName -ReadyFilePath $readyFilePath -HoldBehavior HoldSixtySeconds
            try {
                Wait-ForReadyFile -ReadyFilePath $readyFilePath

                Test-SingleInstanceMutexHeld -MutexName $mutexName | Should -BeTrue
            } finally {
                Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
            }
            Wait-Process -Id $child.Id -Timeout 30

            Test-SingleInstanceMutexHeld -MutexName $mutexName | Should -BeFalse
            Test-SingleInstanceMutexHeld -MutexName $mutexName | Should -BeFalse
        } finally {
            $observer.Dispose()
        }
    }

    It 'probe (261018): a mutex abandoned by a process that exited without releasing it is not held, and the probe leaves no handle behind' {
        $mutexName = New-UniqueTestMutexName
        $readyFilePath = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N') + '.ready')
        $observer = [System.Threading.Mutex]::new($false, $mutexName)

        try {
            $child = Start-MutexChildProcess -MutexName $mutexName -ReadyFilePath $readyFilePath -HoldBehavior ExitWithoutRelease
            Wait-ForReadyFile -ReadyFilePath $readyFilePath
            Wait-Process -Id $child.Id -Timeout 30

            Test-SingleInstanceMutexHeld -MutexName $mutexName | Should -BeFalse
        } finally {
            $observer.Dispose()
        }

        # With the observer gone and the probe holding nothing, the name no longer exists.
        $reopenedHandle = $null
        [System.Threading.Mutex]::TryOpenExisting($mutexName, [ref]$reopenedHandle) | Should -BeFalse
    }
}

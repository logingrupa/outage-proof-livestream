# Integration.Dashboard.Tests.ps1
# The phase 05 (local-dashboard-stats) integration gate: proves the whole dashboard
# end-to-end against a REAL HttpListener, real HTTP requests, and real files -- every
# plan before this one tested its own layer with the next one mocked (correct, and it
# leaves exactly one thing unproven: that the layers actually fit together).
#
# THIS SUITE EXECUTES THE ATTACKS IT PROVES ARE BLOCKED, RATHER THAN READING THE CODE
# THAT BLOCKS THEM (05-RESEARCH.md Pitfall 4's "Warning signs" paragraph names this
# precisely: a unit test with a mocked context proves the function returns $false; only
# a real request against a real listener proves the wiring actually calls it):
#   - T-05-01 (CSRF, Tests 7-9): a forged-Origin POST to /api/control is asserted to
#     leave state/control.json's desired value UNCHANGED, not merely to return 403 --
#     the status code is the claim, the flag is the proof.
#   - T-05-02 (traversal, Test 10): real GET requests attempt to walk out of dashboard/
#     to read the real .env/pusher.ps1 siblings one level up.
#
# HOW THE REAL LISTENER IS HOSTED: mirrors supervisor.ps1's own Start-DashboardHost
# shape (05-09) -- Start-DashboardListener binds and starts the HttpListener
# synchronously on the Pester thread, then a fresh [powershell]::Create() runspace runs
# Invoke-DashboardListenerLoop (-MaxRequests 0, unbounded) via BeginInvoke(). The
# runspace does not inherit this process's imported modules, so its own script block
# re-imports every module Invoke-DashboardListenerLoop's call chain needs (Logging,
# ControlFlag, PusherProcess, StatsStore, Clock, Config, Dashboard) and dot-sources
# cut.ps1 at ITS OWN top level (05-07-SUMMARY.md's confirmed finding: a command called
# from inside an imported module only resolves against the caller's truly global
# functions, never a nested scriptblock's local ones -- Stop-PusherProcesses would
# otherwise throw CommandNotFoundException from inside the 'cut' action).
#
# EPHEMERAL PORTS ONLY (Wave 0 Gaps): every port is discovered at runtime via a
# TcpListener bound to port 0, never a hardcoded literal -- a suite that grabbed the
# production dashboard's default port would fail the moment a developer has the real
# dashboard open.
#
# PER-IT ISOLATION IS NOT OPTIONAL: each It gets its own GUID-suffixed work directory,
# its own ephemeral-port listener + runspace, and (where a "pusher is alive" input is
# needed) its own real decoy process -- a forcefully-killed process orphans children
# whose self-termination can lag under load and bleed into the next scenario's
# identically-named files (the same class of pollution
# tests/Integration.ExplicitStop.Tests.ps1 and tests/Integration.KillAndResume.Tests.ps1
# already guard against).
#
# "PUSHER IS ALIVE" IS PROVEN WITH A REAL DECOY PROCESS, NOT A MOCK: this suite runs the
# real, unmocked lib/PusherProcess.psm1's Test-PusherProcessAlive inside the listener's
# own runspace, so there is nothing to Mock from the Pester thread even if we wanted to
# (a Mock only shadows a function in the scope that defines it, and the runspace never
# shares scope with this file). Tests that need PusherProcessAlive=$true instead launch
# a real `pwsh -File <ScriptRoot>\pusher.ps1` decoy process (a fixture script that just
# sleeps) -- its CommandLine genuinely contains "<ScriptRoot>\pusher.ps1", which is
# exactly what lib/PusherProcess.psm1's Get-RunningPusherProcesses matches on.
#
# TAGGED 'Integration', NEVER 'Quick': this file binds real sockets and spawns real
# processes -- it belongs in the full suite, matching how the existing real-ffmpeg/SRT
# integration tests are already segregated out of the per-commit loop.
#
# Tag rationale: DASH-01, DASH-02, DASH-03, DASH-04 (backend edge data only -- see Test
# 5/6; the browser Notification firing itself is out of scope for a backend HTTP suite,
# per D-21/05-VALIDATION.md's Manual-Only Verifications), CFG-02.
#
# 05.1-07 ADDITIONS (SESS-03/SESS-04, T-05.1-19/20/21): the same executed-attack
# discipline extended to the two Plan 04 routes -- reset-resume and
# /api/recordings/delete. Every unsafe request (forged/missing Origin, an
# out-of-folder or absolute-path filename, the newest/live filename) is proven to
# leave the filesystem untouched by asserting real file-existence state AFTER the
# request, never the response body alone (Test 16-19); the happy path (list, delete a
# non-live file, refuse the live file, reset while stopped) is proven to actually work
# end-to-end (Test 20). RecordingFolderPath/RecordingFilenameGlob/StateFilePath are
# now threaded through the fixture and the runspace's 3-hop wiring exactly as
# supervisor.ps1's Start-DashboardHost does (05.1-05), with lib/Rotation.psm1 imported
# in the runspace so Get-NewestMatchingRecordingFile resolves for the delete guard.

BeforeAll {
    $script:RepoRootPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:RealDashboardRootPath = Join-Path $script:RepoRootPath 'dashboard'

    $script:LoggingModulePath = Join-Path $script:RepoRootPath 'lib/Logging.psm1'
    $script:ControlFlagModulePath = Join-Path $script:RepoRootPath 'lib/ControlFlag.psm1'
    $script:PusherProcessModulePath = Join-Path $script:RepoRootPath 'lib/PusherProcess.psm1'
    $script:StatsStoreModulePath = Join-Path $script:RepoRootPath 'lib/StatsStore.psm1'
    $script:ClockModulePath = Join-Path $script:RepoRootPath 'lib/Clock.psm1'
    $script:ConfigModulePath = Join-Path $script:RepoRootPath 'lib/Config.psm1'
    $script:DashboardModulePath = Join-Path $script:RepoRootPath 'lib/Dashboard.psm1'

    # The runspace's own script block (mirrors supervisor.ps1's Start-DashboardHost
    # $listenerLoopScriptBlock almost verbatim, minus the SYSTEM/Scheduled-Task-specific
    # comments that do not apply to a Pester process). Every path is passed as an
    # explicit argument -- never resolved from this runspace's own script-root or
    # current directory (WR-03 parity).
    $script:ListenerLoopScriptBlock = {
        param(
            $RepoRootPath, $ScriptRoot, $ControlFilePath, $StatsFilePath,
            $DashboardRootPath, $EnvFilePath, $DashboardPort, $Listener, $LogDirectoryPath,
            $RecordingFolderPath, $RecordingFilenameGlob, $StateFilePath
        )

        Import-Module (Join-Path $RepoRootPath 'lib/Logging.psm1')
        Set-LogDirectory -Path $LogDirectoryPath
        Import-Module (Join-Path $RepoRootPath 'lib/ControlFlag.psm1')
        Import-Module (Join-Path $RepoRootPath 'lib/PusherProcess.psm1')
        Import-Module (Join-Path $RepoRootPath 'lib/StatsStore.psm1')
        Import-Module (Join-Path $RepoRootPath 'lib/Clock.psm1')
        Import-Module (Join-Path $RepoRootPath 'lib/Config.psm1')
        # 05.1-05 Pitfall 5: Get-NewestMatchingRecordingFile (reset/delete's "what is
        # live" authority) resolves only if Rotation.psm1 is imported inside THIS
        # runspace -- mirrors supervisor.ps1's Start-DashboardHost wiring exactly.
        Import-Module (Join-Path $RepoRootPath 'lib/Rotation.psm1')
        Import-Module (Join-Path $RepoRootPath 'lib/Dashboard.psm1')

        # Stop-PusherProcesses only resolves against THIS runspace's own truly global
        # functions when called from inside Dashboard.psm1's Invoke-
        # DashboardRequestHandler (05-07-SUMMARY.md's confirmed finding) -- dot-source
        # at this script block's own top level, mirroring supervisor.ps1's
        # Start-DashboardHost exactly.
        . (Join-Path $RepoRootPath 'cut.ps1')

        Invoke-DashboardListenerLoop -Listener $Listener -ScriptRoot $ScriptRoot `
            -ControlFilePath $ControlFilePath -StatsFilePath $StatsFilePath `
            -DashboardRootPath $DashboardRootPath -EnvFilePath $EnvFilePath `
            -DashboardPort $DashboardPort -RecordingFolderPath $RecordingFolderPath `
            -RecordingFilenameGlob $RecordingFilenameGlob -StateFilePath $StateFilePath `
            -MaxRequests 0
    }

    function Get-DashboardIntegrationEphemeralPort {
        <#
        .SYNOPSIS
        Discovers a free TCP port at runtime by binding a TcpListener to port 0
        (OS-assigned), reading the assigned port, then releasing it -- mirrors
        tests/Dashboard.Tests.ps1's and tests/Supervisor.Tests.ps1's identical helper.
        Never a literal port: a leaked test listener must never collide with the real
        dashboard's configured port or a developer's own open dashboard tab.
        #>
        $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        try {
            $tcpListener.Start()
            return ([System.Net.IPEndPoint] $tcpListener.LocalEndpoint).Port
        } finally {
            $tcpListener.Stop()
        }
    }

    function New-DashboardIntegrationFixture {
        <#
        .SYNOPSIS
        Builds a full, per-It GUID-suffixed fixture tree under $TestDrive: a scriptRoot
        directory (the "install root" Test-PusherProcessAlive/cut.ps1 match against),
        an .env fixture carrying a comment line, a blank line, RELAY_PORT=8890,
        SRT_PASSPHRASE=canary-do-not-leak, and a hand-added MY_OWN_NOTE=keepme (D-15
        round-trip fidelity), and a log directory. DashboardRootPath points at the
        REAL repo dashboard/ folder (never written to by any handler route) so Tests
        1/2/10 exercise the actual shipped page/assets/traversal boundary.

        05.1-07: RecordingFolderPath is a fresh, empty sibling directory
        (case-xxx/recordings) under the SAME case dir as an outside-canary target
        (case-xxx/outside-canary.txt lives ONE level above it, i.e. exactly what a
        single '..\' traversal segment reaches) -- RecordingFilenameGlob is '*.ts',
        matching pusher.ps1's real default. StateFilePath is
        case-xxx/scriptroot/state/offset.json (the parent directory is NOT
        pre-created; each It creates it only when it needs to seed a real offset file,
        so the genuine "reset when nothing to reset" idempotent path stays available).

        .OUTPUTS
        PSCustomObject: WorkDir, ScriptRoot, ControlFilePath, StatsFilePath,
        EnvFilePath, LogDirectoryPath, DashboardRootPath, RecordingFolderPath,
        RecordingFilenameGlob, StateFilePath.
        #>
        $caseId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $workDir = Join-Path $TestDrive ("case-{0}" -f $caseId)
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        $scriptRoot = Join-Path $workDir 'scriptroot'
        New-Item -ItemType Directory -Path $scriptRoot -Force | Out-Null

        $envFilePath = Join-Path $workDir '.env'
        $envFixtureContent = "# integration test fixture .env`n`nRELAY_PORT=8890`nSRT_PASSPHRASE=canary-do-not-leak`nMY_OWN_NOTE=keepme`n"
        [System.IO.File]::WriteAllText($envFilePath, $envFixtureContent)

        $recordingFolderPath = Join-Path $workDir 'recordings'
        New-Item -ItemType Directory -Path $recordingFolderPath -Force | Out-Null

        return [pscustomobject]@{
            WorkDir               = $workDir
            ScriptRoot            = $scriptRoot
            ControlFilePath       = Join-Path $scriptRoot 'control.json'
            StatsFilePath         = Join-Path $scriptRoot 'stats.json'
            EnvFilePath           = $envFilePath
            LogDirectoryPath      = Join-Path $workDir 'logs'
            DashboardRootPath     = $script:RealDashboardRootPath
            RecordingFolderPath   = $recordingFolderPath
            RecordingFilenameGlob = '*.ts'
            StateFilePath         = Join-Path $scriptRoot 'state/offset.json'
        }
    }

    function Start-DashboardIntegrationHost {
        <#
        .SYNOPSIS
        Starts a real HttpListener on an ephemeral port and hosts
        Invoke-DashboardListenerLoop (-MaxRequests 0) in a background runspace for the
        calling It's lifetime -- mirrors supervisor.ps1's Start-DashboardHost (05-09)
        almost exactly, minus the D-03 never-throw guard (a genuine startup failure
        here is a real test-infrastructure fault this suite SHOULD surface loudly, not
        silently degrade past).

        .OUTPUTS
        PSCustomObject: Listener, PowerShell, AsyncResult, Port.
        #>
        param(
            [Parameter(Mandatory)] $Fixture
        )

        $port = Get-DashboardIntegrationEphemeralPort
        $listener = Start-DashboardListener -DashboardPort $port

        try {
            $powershell = [powershell]::Create()
            [void] $powershell.AddScript($script:ListenerLoopScriptBlock).
                AddArgument($script:RepoRootPath).AddArgument($Fixture.ScriptRoot).
                AddArgument($Fixture.ControlFilePath).AddArgument($Fixture.StatsFilePath).
                AddArgument($Fixture.DashboardRootPath).AddArgument($Fixture.EnvFilePath).
                AddArgument($port).AddArgument($listener).AddArgument($Fixture.LogDirectoryPath).
                AddArgument($Fixture.RecordingFolderPath).AddArgument($Fixture.RecordingFilenameGlob).
                AddArgument($Fixture.StateFilePath)

            $asyncResult = $powershell.BeginInvoke()
        } catch {
            Stop-DashboardListener -Listener $listener
            throw
        }

        # Start-DashboardListener's own .Start() call already puts the socket into
        # IsListening=true synchronously (before any GetContext() call), so an
        # incoming connection queues at the OS level even before the runspace thread
        # actually reaches its first GetContext() -- this is a startup settle margin
        # for the BACKGROUND THREAD itself to spin up, not for the socket to bind.
        Start-Sleep -Milliseconds 250

        return [pscustomobject]@{
            Listener    = $listener
            PowerShell  = $powershell
            AsyncResult = $asyncResult
            Port        = $port
        }
    }

    function Stop-DashboardIntegrationHost {
        <#
        .SYNOPSIS
        Tears down a handle returned by Start-DashboardIntegrationHost: stopping the
        listener makes the runspace's blocking GetContext() throw (the ordinary
        shutdown path per 05-01's fault-probe finding, Invoke-DashboardListenerLoop's
        own try/catch), which lets the loop return cleanly and the runspace reach a
        terminal invocation state. Every step is individually guarded -- a leaked
        listener holds its ephemeral port and is exactly the class of pollution this
        plan's acceptance criteria (no ephemeral port remains bound after the suite)
        exists to catch.
        #>
        param(
            [Parameter(Mandatory)] $DashboardHost
        )

        try { Stop-DashboardListener -Listener $DashboardHost.Listener } catch { }
        try { $DashboardHost.PowerShell.Stop() } catch { }
        try { $null = $DashboardHost.PowerShell.EndInvoke($DashboardHost.AsyncResult) } catch { }
        try { $DashboardHost.PowerShell.Dispose() } catch { }
    }

    function Start-DashboardIntegrationFakePusherProcess {
        <#
        .SYNOPSIS
        Launches a REAL pwsh.exe process whose CommandLine genuinely contains
        "<ScriptRoot>\pusher.ps1" -- lib/PusherProcess.psm1's Get-RunningPusherProcesses
        full-command-line match, exercised for real rather than mocked (the listener's
        own runspace never shares Pester's Mock scope, so there is nothing to Mock even
        if this suite wanted to). The fixture script just sleeps; it is never actually
        pusher.ps1's real logic. A short settle sleep lets the CIM Win32_Process table
        observe the new process's CommandLine before the caller relies on it.
        #>
        param(
            [Parameter(Mandatory)] [string] $ScriptRoot
        )

        if (-not (Test-Path -LiteralPath $ScriptRoot)) {
            New-Item -ItemType Directory -Path $ScriptRoot -Force | Out-Null
        }
        $fakePusherScriptPath = Join-Path $ScriptRoot 'pusher.ps1'
        Set-Content -LiteralPath $fakePusherScriptPath -Value 'Start-Sleep -Seconds 60' -Encoding utf8

        $process = Start-Process -FilePath 'pwsh' `
            -ArgumentList @('-NoProfile', '-File', $fakePusherScriptPath) `
            -PassThru -WindowStyle Hidden
        Start-Sleep -Milliseconds 500
        return $process
    }

    function Stop-DashboardIntegrationFakePusherProcess {
        param(
            [AllowNull()] $Process
        )

        if ($null -eq $Process) { return }
        try {
            $Process.Refresh()
            if (-not $Process.HasExited) {
                Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
                $Process.WaitForExit(5000) | Out-Null
            }
        } catch {
            # Process already gone between the check and the kill -- not an error.
        }
    }
}

Describe 'Dashboard end-to-end: real listener, real HTTP, real attacks (phase 05 gate)' -Tag 'Integration' {

    BeforeEach {
        Remove-Module Dashboard -ErrorAction SilentlyContinue
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module PusherProcess -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue

        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'pester-thread-logs')
        Import-Module $script:ControlFlagModulePath -Force
        Import-Module $script:PusherProcessModulePath -Force
        Import-Module $script:StatsStoreModulePath -Force
        Import-Module $script:ClockModulePath -Force
        Import-Module $script:ConfigModulePath -Force
        Import-Module $script:DashboardModulePath -Force
    }

    AfterEach {
        Remove-Module Dashboard -ErrorAction SilentlyContinue
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module PusherProcess -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
    }

    It 'Test 1 (DASH-01): GET / serves the real dashboard page over real HTTP' {
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/" -UseBasicParsing -SkipHttpErrorCheck

            $response.StatusCode | Should -Be 200
            ($response.Headers['Content-Type'] -join '') | Should -Match 'text/html; charset=utf-8'
            $response.Content | Should -Match 'id="delay-value"'
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 2 (DASH-01): GET /app.js and GET /app.css return 200 with correct content types' {
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            $jsResponse = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/app.js" -UseBasicParsing -SkipHttpErrorCheck
            $jsResponse.StatusCode | Should -Be 200
            ($jsResponse.Headers['Content-Type'] -join '') | Should -Match 'text/javascript; charset=utf-8'

            $cssResponse = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/app.css" -UseBasicParsing -SkipHttpErrorCheck
            $cssResponse.StatusCode | Should -Be 200
            ($cssResponse.Headers['Content-Type'] -join '') | Should -Match 'text/css; charset=utf-8'
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 3 (DASH-03): GET /api/stats returns every Get-DashboardViewModel property with a valid ConnectionState' {
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/stats" -UseBasicParsing -SkipHttpErrorCheck
            $response.StatusCode | Should -Be 200
            ($response.Headers['Content-Type'] -join '') | Should -Match 'application/json'

            $viewModel = $response.Content | ConvertFrom-Json
            $expectedProperties = @(
                'ConnectionState', 'StartEnabled', 'StopEnabled', 'CutEnabled', 'IsStale',
                'SecondsSinceUpdate', 'DelaySecondsBehindLive', 'DrainEtaSeconds', 'SentBytes',
                'PendingBytes', 'TotalBytes', 'SendBytesPerSecond', 'RecordBytesPerSecond',
                'BackoffAttemptNumber', 'CumulativeReconnectCount', 'OutageActive',
                'LastClassificationCause', 'CatchUpCapUtilization', 'Reason'
            )
            $actualPropertyNames = @($viewModel.PSObject.Properties.Name)
            foreach ($propertyName in $expectedProperties) {
                $actualPropertyNames | Should -Contain $propertyName -Because "the /api/stats response must carry the full Get-DashboardViewModel shape (D-26)"
            }

            $viewModel.ConnectionState | Should -BeIn @('Idle', 'Reconnecting', 'Draining', 'Streaming', 'Unknown')
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 4 (DASH-03, idle): no stats.json on disk yields Idle with StartEnabled true and no fabricated delay' {
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            Test-Path -LiteralPath $fixture.StatsFilePath | Should -BeFalse -Because 'this test asserts the genuine no-stats-file case'

            $response = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/stats" -UseBasicParsing -SkipHttpErrorCheck
            $viewModel = $response.Content | ConvertFrom-Json

            $viewModel.ConnectionState | Should -Be 'Idle'
            $viewModel.StartEnabled | Should -BeTrue
            $viewModel.DelaySecondsBehindLive | Should -BeNullOrEmpty -Because 'D-13: an unknown delay must render as null, never a fabricated 0'
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 5 (DASH-02, the full chain): a real stats.json fixture flows through StatsStore -> Dashboard -> JSON carrying its real values' {
        $fixture = New-DashboardIntegrationFixture
        $fakePusherProcess = $null
        $dashboardHost = $null
        try {
            $fakePusherProcess = Start-DashboardIntegrationFakePusherProcess -ScriptRoot $fixture.ScriptRoot
            $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture

            Save-PusherStats -StatsFilePath $fixture.StatsFilePath -PusherState 'Streaming' `
                -RecordingFilePath 'recording-001.ts' -OffsetBytes 500000 -FileLengthBytes 750000 `
                -SendBytesPerSecond 100000.0 -RecordBytesPerSecond 90000.0 -SecondsBehindLive 4.5 `
                -BackoffAttemptNumber 0 -CumulativeReconnectCount 2 -CatchUpCapUtilization 0.5 `
                -OutageActive $false -StaleWithinSeconds 30.0

            $response = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/stats" -UseBasicParsing -SkipHttpErrorCheck
            $viewModel = $response.Content | ConvertFrom-Json

            $viewModel.ConnectionState | Should -Be 'Streaming'
            $viewModel.DelaySecondsBehindLive | Should -Be 4.5
            $viewModel.SendBytesPerSecond | Should -Be 100000.0
            $viewModel.SentBytes | Should -Be 500000
            $viewModel.PendingBytes | Should -Be 250000
            $viewModel.DrainEtaSeconds | Should -Be 2.5 -Because 'PendingBytes / SendBytesPerSecond = 250000 / 100000'
        } finally {
            if ($dashboardHost) { Stop-DashboardIntegrationHost -DashboardHost $dashboardHost }
            Stop-DashboardIntegrationFakePusherProcess -Process $fakePusherProcess
        }
    }

    It 'Test 6 (D-06): a stats.json past its own staleAfterEpochSeconds deadline reports Unknown, never a frozen number' {
        $fixture = New-DashboardIntegrationFixture
        $fakePusherProcess = $null
        $dashboardHost = $null
        try {
            $fakePusherProcess = Start-DashboardIntegrationFakePusherProcess -ScriptRoot $fixture.ScriptRoot
            $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture

            # A negative StaleWithinSeconds puts staleAfterEpochSeconds firmly in the
            # past at write time -- the writer's own declared deadline, already expired.
            Save-PusherStats -StatsFilePath $fixture.StatsFilePath -PusherState 'Streaming' `
                -RecordingFilePath 'recording-001.ts' -OffsetBytes 500000 -FileLengthBytes 750000 `
                -SendBytesPerSecond 100000.0 -RecordBytesPerSecond 90000.0 -SecondsBehindLive 4.5 `
                -BackoffAttemptNumber 0 -CumulativeReconnectCount 0 -CatchUpCapUtilization 0.5 `
                -OutageActive $false -StaleWithinSeconds -100.0

            $response = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/stats" -UseBasicParsing -SkipHttpErrorCheck
            $viewModel = $response.Content | ConvertFrom-Json

            $viewModel.IsStale | Should -BeTrue
            $viewModel.ConnectionState | Should -Be 'Unknown'
            $viewModel.DelaySecondsBehindLive | Should -BeNullOrEmpty
        } finally {
            if ($dashboardHost) { Stop-DashboardIntegrationHost -DashboardHost $dashboardHost }
            Stop-DashboardIntegrationFakePusherProcess -Process $fakePusherProcess
        }
    }

    It 'Test 7 (T-05-01, the CSRF proof): a forged Origin cannot cut the stream -- the control flag is proven unchanged, not just the status code' {
        $fixture = New-DashboardIntegrationFixture
        $fakePusherProcess = $null
        $dashboardHost = $null
        try {
            $fakePusherProcess = Start-DashboardIntegrationFakePusherProcess -ScriptRoot $fixture.ScriptRoot
            $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture

            Set-PusherDesiredState -ControlFilePath $fixture.ControlFilePath -DesiredState 'streaming'

            $response = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/control" -Method Post `
                -Body '{"action":"cut"}' -ContentType 'application/json' `
                -Headers @{ Origin = 'http://evil.example.com' } -UseBasicParsing -SkipHttpErrorCheck

            $response.StatusCode | Should -Be 403

            (Get-PusherDesiredState -ControlFilePath $fixture.ControlFilePath) | Should -Be 'streaming' `
                -Because 'a forged Origin must never flip the control flag -- a 403 with the cut already performed is the exact failure this test exists to catch'

            $fakePusherProcess.Refresh()
            $fakePusherProcess.HasExited | Should -BeFalse -Because 'a rejected control request must never reach Stop-PusherProcesses'
        } finally {
            if ($dashboardHost) { Stop-DashboardIntegrationHost -DashboardHost $dashboardHost }
            Stop-DashboardIntegrationFakePusherProcess -Process $fakePusherProcess
        }
    }

    It 'Test 8 (CSRF, headerless): a POST with neither Origin nor Sec-Fetch-Site fails closed' {
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            Set-PusherDesiredState -ControlFilePath $fixture.ControlFilePath -DesiredState 'streaming'

            $response = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/control" -Method Post `
                -Body '{"action":"cut"}' -ContentType 'application/json' -UseBasicParsing -SkipHttpErrorCheck

            $response.StatusCode | Should -Be 403
            (Get-PusherDesiredState -ControlFilePath $fixture.ControlFilePath) | Should -Be 'streaming' `
                -Because 'the fail-closed decision (both headers absent) must still refuse the request'
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 9 (CSRF, legitimate): a same-origin POST is not blocked and genuinely performs the cut' {
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            Set-PusherDesiredState -ControlFilePath $fixture.ControlFilePath -DesiredState 'streaming'

            $response = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/control" -Method Post `
                -Body '{"action":"cut"}' -ContentType 'application/json' `
                -Headers @{ Origin = "http://localhost:$($dashboardHost.Port)" } -UseBasicParsing -SkipHttpErrorCheck

            $response.StatusCode | Should -Be 200
            (Get-PusherDesiredState -ControlFilePath $fixture.ControlFilePath) | Should -Be 'stopped' `
                -Because 'a check that rejects everything is not a working control -- the real dashboard page must not be blocked'
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 10 (T-05-02, the traversal proof): traversal requests never serve .env or pusher.ps1 content' {
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            $traversalPaths = @('/../.env', '/..%2f..%2fpusher.ps1', '/%2e%2e%2f.env')
            foreach ($traversalPath in $traversalPaths) {
                $response = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)$traversalPath" -UseBasicParsing -SkipHttpErrorCheck

                # Two independent layers reject these requests, confirmed empirically
                # while writing this suite: the plain '/../.env' form reaches
                # lib/Dashboard.psm1's own Resolve-DashboardStaticPath boundary guard
                # and 404s; the percent-encoded '..%2f'/'%2e%2e%2f' forms are rejected
                # by HTTP.sys itself at the kernel level (403 "Forbidden URL") BEFORE
                # HttpListener.GetContext() ever returns them to this process -- an
                # even stronger guarantee than the application-level guard, not a
                # weaker one. Both are a genuine "never served", so the assertion that
                # matters is never-200 plus never-leaked-content, not one hardcoded
                # status code (see 05-11-SUMMARY.md Deviations for the full finding).
                $response.StatusCode | Should -Not -Be 200 -Because "traversal path '$traversalPath' must never be served"
                $response.Content | Should -Not -Match 'RELAY_HOST'
                $response.Content | Should -Not -Match 'Start-Pusher'
            }
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 11 (CFG-02): a valid config write round-trips through Write-DotEnvFile over real HTTP, preserving comments and unknown keys' {
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/config" -Method Post `
                -Body '{"RELAY_PORT":"9100"}' -ContentType 'application/json' `
                -Headers @{ Origin = "http://localhost:$($dashboardHost.Port)" } -UseBasicParsing -SkipHttpErrorCheck

            $response.StatusCode | Should -Be 200
            $writeResult = $response.Content | ConvertFrom-Json
            $writeResult.Success | Should -BeTrue

            $envContentAfter = [System.IO.File]::ReadAllText($fixture.EnvFilePath)
            $envContentAfter | Should -Match '(?m)^# integration test fixture \.env$' -Because 'the comment line must survive byte-for-byte (D-15)'
            $envContentAfter | Should -Match '(?m)^RELAY_PORT=9100$' -Because 'the changed key must reflect the new value'
            $envContentAfter | Should -Match '(?m)^SRT_PASSPHRASE=canary-do-not-leak$' -Because 'an untouched key must survive unchanged'
            $envContentAfter | Should -Match '(?m)^MY_OWN_NOTE=keepme$' -Because 'an operator-added unknown key must survive the write'
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 12 (CFG-02, rejection): an invalid RELAY_PORT is rejected with a Problems array and the .env fixture is byte-for-byte unchanged' {
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            $envContentBefore = [System.IO.File]::ReadAllText($fixture.EnvFilePath)

            $response = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/config" -Method Post `
                -Body '{"RELAY_PORT":"70000"}' -ContentType 'application/json' `
                -Headers @{ Origin = "http://localhost:$($dashboardHost.Port)" } -UseBasicParsing -SkipHttpErrorCheck

            $response.StatusCode | Should -Be 400
            $writeResult = $response.Content | ConvertFrom-Json
            $writeResult.Success | Should -BeFalse
            @($writeResult.Problems).Count | Should -BeGreaterThan 0

            $envContentAfter = [System.IO.File]::ReadAllText($fixture.EnvFilePath)
            $envContentAfter | Should -Be $envContentBefore -Because 'a rejected config write must never touch disk, not even partially (D-16)'
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 13 (D-18): GET /api/config never serves the raw SrtPassphrase canary' {
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/config" -UseBasicParsing -SkipHttpErrorCheck

            $response.StatusCode | Should -Be 200
            $response.Content | Should -Not -Match 'canary-do-not-leak' -Because 'the raw SRT passphrase must never reach the HTTP surface'
            $response.Content | Should -Match '\*\*\*REDACTED\*\*\*' -Because 'Get-RedactedConfig must be what actually serves this route'
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 14 (T-05-25): a 1MB /api/control body is rejected with 413 and never changes the flag' {
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            Set-PusherDesiredState -ControlFilePath $fixture.ControlFilePath -DesiredState 'stopped'
            $oversizedBody = '{"action":"start","padding":"' + ('a' * 1048576) + '"}'

            $response = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/control" -Method Post `
                -Body $oversizedBody -ContentType 'application/json' `
                -Headers @{ Origin = "http://localhost:$($dashboardHost.Port)" } -UseBasicParsing -SkipHttpErrorCheck

            $response.StatusCode | Should -Be 413
            (Get-PusherDesiredState -ControlFilePath $fixture.ControlFilePath) | Should -Be 'stopped'
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 15 (D-03): a real handler fault returns 500 and the listener survives to serve the next request' {
        $fixture = New-DashboardIntegrationFixture
        # A directory in place of the config file is the mechanism that actually
        # reaches the outer handler try/catch as a genuine, uncaught .NET exception:
        # Write-DotEnvFile's Step 3 raw-text-line read ([System.IO.File]::ReadAllText)
        # has no try/catch of its own. -StatsFilePath as a directory (the plan's
        # original proposal) does NOT reach this handler's outer catch -- confirmed
        # empirically while writing this suite: lib/StatsStore.psm1's Read-PusherStats
        # already wraps its own ReadAllText call in a catch-all that returns $null (by
        # design, D-04's "corrupt/missing stats.json is 'not streaming', never a
        # fault"), so ApiStats cannot be faulted this way -- that swallow is itself a
        # correctness property, not a gap. -EnvFilePath is what genuinely proves D-03's
        # fault containment against a real, unmocked module boundary (see
        # 05-11-SUMMARY.md Deviations for the full empirical trail).
        $faultyEnvDirectoryPath = Join-Path $fixture.WorkDir 'env-is-a-directory'
        New-Item -ItemType Directory -Path $faultyEnvDirectoryPath -Force | Out-Null
        $fixture.EnvFilePath = $faultyEnvDirectoryPath

        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            $faultResponse = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/config" -Method Post `
                -Body '{"RELAY_PORT":"9100"}' -ContentType 'application/json' `
                -Headers @{ Origin = "http://localhost:$($dashboardHost.Port)" } -UseBasicParsing -SkipHttpErrorCheck

            $faultResponse.StatusCode | Should -Be 500 -Because 'the fault must be contained as a 500, never escape as a thrown exception (D-03)'

            $subsequentResponse = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/stats" -UseBasicParsing -SkipHttpErrorCheck
            $subsequentResponse.StatusCode | Should -Be 200 -Because 'a faulted handler must never take down the listener loop -- the next request must still be served'
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 16 (T-05.1-19, the reset-resume CSRF proof): a forged/missing-Origin reset is rejected 403 and the offset file survives' {
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            New-Item -ItemType Directory -Path (Split-Path $fixture.StateFilePath -Parent) -Force | Out-Null
            Set-Content -LiteralPath $fixture.StateFilePath -Value '{"offsetBytes":123456}' -Encoding utf8 -NoNewline

            $forgedResponse = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/control" -Method Post `
                -Body '{"action":"reset-resume"}' -ContentType 'application/json' `
                -Headers @{ Origin = 'http://evil.example.com' } -UseBasicParsing -SkipHttpErrorCheck

            $forgedResponse.StatusCode | Should -Be 403
            Test-Path -LiteralPath $fixture.StateFilePath | Should -BeTrue `
                -Because 'a forged-Origin reset-resume must never clear the resume anchor -- the 403 is the claim, the surviving file is the proof'

            $headerlessResponse = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/control" -Method Post `
                -Body '{"action":"reset-resume"}' -ContentType 'application/json' -UseBasicParsing -SkipHttpErrorCheck

            $headerlessResponse.StatusCode | Should -Be 403
            Test-Path -LiteralPath $fixture.StateFilePath | Should -BeTrue `
                -Because 'a headerless reset-resume (both Origin and Sec-Fetch-Site absent) must still fail closed and never clear the resume anchor'
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 17 (T-05.1-19, the delete CSRF proof): a forged/missing-Origin delete is rejected 403 and the target file survives' {
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            $targetFilePath = Join-Path $fixture.RecordingFolderPath 'recording-001.ts'
            Set-Content -LiteralPath $targetFilePath -Value 'seeded content' -Encoding utf8 -NoNewline

            $forgedResponse = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/recordings/delete" -Method Post `
                -Body '{"filename":"recording-001.ts"}' -ContentType 'application/json' `
                -Headers @{ Origin = 'http://evil.example.com' } -UseBasicParsing -SkipHttpErrorCheck

            $forgedResponse.StatusCode | Should -Be 403
            Test-Path -LiteralPath $targetFilePath | Should -BeTrue `
                -Because 'a forged-Origin delete must never remove the target file -- the 403 is the claim, the surviving file is the proof'

            $headerlessResponse = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/recordings/delete" -Method Post `
                -Body '{"filename":"recording-001.ts"}' -ContentType 'application/json' -UseBasicParsing -SkipHttpErrorCheck

            $headerlessResponse.StatusCode | Should -Be 403
            Test-Path -LiteralPath $targetFilePath | Should -BeTrue `
                -Because 'a headerless delete (both Origin and Sec-Fetch-Site absent) must still fail closed and never remove the target file'
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 18 (T-05.1-20, the traversal proof): a traversal filename in a delete request never removes a file outside RecordingFolderPath' {
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            # The canary lives ONE level above RecordingFolderPath -- exactly what a
            # single '..\' traversal segment reaches from inside it.
            $outsideCanaryFilePath = Join-Path $fixture.WorkDir 'outside-canary.txt'
            Set-Content -LiteralPath $outsideCanaryFilePath -Value 'do-not-delete-me' -Encoding utf8 -NoNewline

            $validOriginHeader = @{ Origin = "http://localhost:$($dashboardHost.Port)" }
            # (1) a relative '..\'-style escape that resolves to the exact canary path,
            # (2) a percent-encoded variant (never decoded by this JSON-body route --
            # it is treated as a literal, harmless filename component, proving the
            # route has no decode-then-check ordering bug to exploit), and (3) the
            # canary's own absolute path (an illegal embedded drive-letter once
            # concatenated onto RecordingFolderPath, surfacing as a contained fault
            # rather than a traversal -- still never a 2xx, still never deleted).
            $traversalPayloads = @(
                '..\outside-canary.txt',
                '..%2foutside-canary.txt',
                $outsideCanaryFilePath
            )
            foreach ($traversalFilename in $traversalPayloads) {
                $bodyJson = (@{ filename = $traversalFilename } | ConvertTo-Json -Compress)
                $response = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/recordings/delete" -Method Post `
                    -Body $bodyJson -ContentType 'application/json' -Headers $validOriginHeader -UseBasicParsing -SkipHttpErrorCheck

                $response.StatusCode | Should -Not -BeIn @(200, 201, 204) `
                    -Because "traversal payload '$traversalFilename' must never succeed"
                Test-Path -LiteralPath $outsideCanaryFilePath | Should -BeTrue `
                    -Because "traversal payload '$traversalFilename' must never delete the outside canary -- never-2xx plus never-deleted is the proof, not one hardcoded status code"
            }
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 19 (T-05.1-21, the live-file proof): a valid-Origin delete of the newest/live recording is refused 409 and the file survives' {
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            $olderFilePath = Join-Path $fixture.RecordingFolderPath 'recording-001.ts'
            $newestFilePath = Join-Path $fixture.RecordingFolderPath 'recording-002.ts'
            Set-Content -LiteralPath $olderFilePath -Value 'older' -Encoding utf8 -NoNewline
            Set-Content -LiteralPath $newestFilePath -Value 'newest-live' -Encoding utf8 -NoNewline
            (Get-Item -LiteralPath $newestFilePath).LastWriteTime = (Get-Date).AddSeconds(10)

            $validOriginHeader = @{ Origin = "http://localhost:$($dashboardHost.Port)" }
            $response = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/recordings/delete" -Method Post `
                -Body '{"filename":"recording-002.ts"}' -ContentType 'application/json' -Headers $validOriginHeader -UseBasicParsing -SkipHttpErrorCheck

            $response.StatusCode | Should -Be 409
            Test-Path -LiteralPath $newestFilePath | Should -BeTrue `
                -Because 'the newest/live recording must never be deleted, regardless of a valid Origin -- server-side identity, never a client claim'
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 20 (happy path): list returns files, delete removes a non-live file, delete refuses the live file, reset (stopped) removes the offset file' {
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        try {
            $olderFilePath = Join-Path $fixture.RecordingFolderPath 'recording-001.ts'
            $newestFilePath = Join-Path $fixture.RecordingFolderPath 'recording-002.ts'
            Set-Content -LiteralPath $olderFilePath -Value 'older' -Encoding utf8 -NoNewline
            Set-Content -LiteralPath $newestFilePath -Value 'newest-live' -Encoding utf8 -NoNewline
            (Get-Item -LiteralPath $newestFilePath).LastWriteTime = (Get-Date).AddSeconds(10)

            New-Item -ItemType Directory -Path (Split-Path $fixture.StateFilePath -Parent) -Force | Out-Null
            Set-Content -LiteralPath $fixture.StateFilePath -Value '{"offsetBytes":123456}' -Encoding utf8 -NoNewline

            $validOriginHeader = @{ Origin = "http://localhost:$($dashboardHost.Port)" }

            $listResponse = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/recordings" -UseBasicParsing -SkipHttpErrorCheck
            $listResponse.StatusCode | Should -Be 200
            $recordings = @($listResponse.Content | ConvertFrom-Json)
            $recordings.Count | Should -Be 2
            ($recordings | Where-Object { $_.name -eq 'recording-002.ts' }).isLive | Should -BeTrue -Because 'the newest file must be flagged live'
            ($recordings | Where-Object { $_.name -eq 'recording-001.ts' }).isLive | Should -BeFalse -Because 'the older file must not be flagged live'

            $refuseResponse = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/recordings/delete" -Method Post `
                -Body '{"filename":"recording-002.ts"}' -ContentType 'application/json' -Headers $validOriginHeader -UseBasicParsing -SkipHttpErrorCheck
            $refuseResponse.StatusCode | Should -Be 409
            Test-Path -LiteralPath $newestFilePath | Should -BeTrue

            $deleteResponse = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/recordings/delete" -Method Post `
                -Body '{"filename":"recording-001.ts"}' -ContentType 'application/json' -Headers $validOriginHeader -UseBasicParsing -SkipHttpErrorCheck
            $deleteResponse.StatusCode | Should -Be 200
            Test-Path -LiteralPath $olderFilePath | Should -BeFalse -Because 'a valid-Origin delete of a non-live file must actually remove it'

            # No fake pusher process was started for this fixture's ScriptRoot --
            # Test-PusherProcessAlive is genuinely $false here, so this exercises the
            # real stopped-only reset path, not a mocked one.
            $resetResponse = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/control" -Method Post `
                -Body '{"action":"reset-resume"}' -ContentType 'application/json' -Headers $validOriginHeader -UseBasicParsing -SkipHttpErrorCheck
            $resetResponse.StatusCode | Should -Be 200
            Test-Path -LiteralPath $fixture.StateFilePath | Should -BeFalse -Because 'a valid-Origin reset while stopped must clear the offset file'
        } finally {
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }

    It 'Test 21 (CR-01, the locked-file proof): a genuinely locked target file survives a valid-Origin delete with a 409, proven against the real runspace (no mocked Remove-Item)' {
        # This is the scenario CR-01 identified as untested: the listener loop runs
        # in its own [powershell]::Create() runspace exactly like supervisor.ps1's
        # production wiring, and that runspace never sets $ErrorActionPreference =
        # 'Stop'. tests/Dashboard.Tests.ps1's locked-file case mocks Remove-Item with
        # a `throw`, which is ALWAYS terminating regardless of -ErrorAction and so
        # cannot prove the real cmdlet's non-terminating failure is actually caught.
        # Only a real exclusive file handle, opened before the real Remove-Item call
        # runs inside the real runspace, proves that.
        $fixture = New-DashboardIntegrationFixture
        $dashboardHost = Start-DashboardIntegrationHost -Fixture $fixture
        $lockedFileStream = $null
        try {
            # A second, newer file is required so the locked file is NOT itself the
            # newest/live one -- otherwise Test-RecordingFileDeletable's D-07 guard
            # would refuse it with 409 "cannot delete the live recording" before
            # Remove-Item is ever reached, masking the CR-01 scenario this test exists
            # to prove.
            $lockedFilePath = Join-Path $fixture.RecordingFolderPath 'recording-001.ts'
            $newestFilePath = Join-Path $fixture.RecordingFolderPath 'recording-002.ts'
            Set-Content -LiteralPath $lockedFilePath -Value 'locked-content' -Encoding utf8 -NoNewline
            Set-Content -LiteralPath $newestFilePath -Value 'newest-live' -Encoding utf8 -NoNewline
            (Get-Item -LiteralPath $newestFilePath).LastWriteTime = (Get-Date).AddSeconds(10)

            $lockedFileStream = [System.IO.File]::Open(
                $lockedFilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)

            $validOriginHeader = @{ Origin = "http://localhost:$($dashboardHost.Port)" }
            $response = Invoke-WebRequest -Uri "http://localhost:$($dashboardHost.Port)/api/recordings/delete" -Method Post `
                -Body '{"filename":"recording-001.ts"}' -ContentType 'application/json' -Headers $validOriginHeader -UseBasicParsing -SkipHttpErrorCheck

            $response.StatusCode | Should -Be 409 `
                -Because 'a locked file must surface as an operator-readable in-use error, never a false 200 success'
            $body = $response.Content | ConvertFrom-Json
            $body.error | Should -Match 'in use'
            Test-Path -LiteralPath $lockedFilePath | Should -BeTrue `
                -Because 'CR-01: the file must genuinely still exist on disk -- a false {"success":true} while the file survives is exactly the bug this test catches'
        } finally {
            if ($lockedFileStream) { $lockedFileStream.Dispose() }
            Stop-DashboardIntegrationHost -DashboardHost $dashboardHost
        }
    }
}

# Integration.ProbeSystem.Tests.ps1
# The phase 06 (monitoring-plugin-framework-vps-probe) close-out gate: proves the whole
# store -> host -> fold chain fits together for real, against real files on disk and the
# real (unmocked) Invoke-DashboardRequestHandler -- every prior 06-0N plan tested its own
# layer with the next one mocked. This is the one suite that proves the layers actually
# connect end-to-end (06-09-PLAN.md's objective).
#
# NO REAL HTTPLISTENER IS NEEDED HERE (unlike tests/Integration.Dashboard.Tests.ps1): the
# ApiStats route reads only files (state/stats.json, state/probes/*.json) and process
# liveness -- there is no socket-level behavior (CSRF headers, traversal, HTTP.sys) left
# to prove for this route beyond what Integration.Dashboard.Tests.ps1 already covers. The
# duck-typed fake context (mirrors tests/Dashboard.Tests.ps1's New-FakeDashboardContext,
# copied here per this repo's established per-suite-copy convention rather than touching
# a shared/live-proven helper for tidiness -- StatsStore/ProbeStore header precedent)
# drives the REAL, UNMOCKED Invoke-DashboardRequestHandler -- nothing about the handler's
# internal calls (Read-PusherStats, Get-DashboardViewModel, Get-ProbeResultsForDashboard)
# is mocked in this file, which is what makes this an integration proof rather than a
# repeat of tests/Dashboard.Tests.ps1's unit coverage.
#
# NO FFMPEG DEPENDENCY: the store/host/fold legs under test here (ProbeStore.psm1,
# ProbeHost.psm1, Dashboard.psm1's ApiStats fold) never shell out to ffmpeg or open a
# real SRT/UDP socket -- that is probes/vps.psm1's own concern, already covered by
# tests/Integration.ProbeVps.Tests.ps1. There is nothing to skip here.
#
# FOUR SCENARIOS, MATCHING 06-09-PLAN.md'S must_haves EXACTLY:
#   Test 1 (MON-01/03/04, full chain): Invoke-ProbeHostLoop writes a real probe result to
#     state/probes/*.json; the SAME directory folds into /api/stats's probes[] via the
#     real, unmocked handler.
#   Test 2 (MON-04, zero-plugin): with no enabled probes, probes[] is [] and every
#     non-probe field is byte-for-byte identical between "no state/probes directory at
#     all" and "an empty state/probes directory" -- zero probes must never perturb local
#     stats, the exact MON-04 baseline this phase promises.
#   Test 3 (MON-05, real timing): a HangingProbe fixture (60s sleep) alongside a fast
#     fixture, raced against a short real HardTimeoutMilliseconds, proves one
#     Invoke-ProbeHostLoop cycle completes in a small fraction of the 60s sleep, the
#     sibling fast probe persists, and a subsequent ApiStats call stays responsive.
#   Test 4 (T-06-05, broken-file resilience): a corrupt state/probes/*.json alongside a
#     valid one still yields 200 with the valid probe intact and local stats untouched --
#     ProbeStore's Read-ProbeResult silent-safe-default contract proven through the whole
#     fold, not just at the unit level.
#
# EPHEMERAL, PER-IT FIXTURES: each It gets its own GUID-suffixed ScriptRoot under
# $TestDrive with its own probes/ and state/probes/ subdirectories laid out EXACTLY like
# supervisor.ps1's Start-ProbeHost (probesDirectoryPath = ScriptRoot/probes,
# stateProbesDirectoryPath = ScriptRoot/state/probes) -- so this suite proves the real
# production directory layout, not a simplified stand-in.
#
# TAGGED 'Integration', NEVER 'Quick': this suite writes real files and imports real
# fixture .psm1 modules into throwaway child [powershell] instances (ProbeHost.psm1's own
# MON-05 mechanism) -- it belongs in the full suite alongside the other Integration.*.

BeforeAll {
    $script:RepoRootPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:RealDashboardRootPath = Join-Path $script:RepoRootPath 'dashboard'

    $script:LoggingModulePath = Join-Path $script:RepoRootPath 'lib/Logging.psm1'
    $script:ControlFlagModulePath = Join-Path $script:RepoRootPath 'lib/ControlFlag.psm1'
    $script:PusherProcessModulePath = Join-Path $script:RepoRootPath 'lib/PusherProcess.psm1'
    $script:StatsStoreModulePath = Join-Path $script:RepoRootPath 'lib/StatsStore.psm1'
    $script:ClockModulePath = Join-Path $script:RepoRootPath 'lib/Clock.psm1'
    $script:ProbeStoreModulePath = Join-Path $script:RepoRootPath 'lib/ProbeStore.psm1'
    $script:ProbeHostModulePath = Join-Path $script:RepoRootPath 'lib/ProbeHost.psm1'
    $script:DashboardModulePath = Join-Path $script:RepoRootPath 'lib/Dashboard.psm1'

    $script:HangingProbeFixtureModulePath = Join-Path $script:RepoRootPath 'tests/fixtures/HangingProbe.psm1'

    function New-ProbeSystemFixture {
        <#
        .SYNOPSIS
        Builds a per-It GUID-suffixed fixture tree under $TestDrive, laid out exactly
        like production (supervisor.ps1's Start-ProbeHost): ScriptRoot/probes (discovery
        scan dir) and ScriptRoot/state/probes (persisted results, read back by the
        ApiStats fold). Neither directory is pre-created -- each It creates only what its
        own scenario needs, so the genuine "directory does not exist yet" case (a fresh
        install that has never enabled a probe) stays exercisable.

        .OUTPUTS
        PSCustomObject: WorkDir, ScriptRoot, ProbesDirectory, StateProbesDirectory,
        ControlFilePath, StatsFilePath, EnvFilePath, DashboardRootPath, DashboardPort.
        #>
        $caseId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $workDir = Join-Path $TestDrive ("case-{0}" -f $caseId)
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        $scriptRoot = Join-Path $workDir 'scriptroot'
        New-Item -ItemType Directory -Path $scriptRoot -Force | Out-Null

        return [pscustomobject]@{
            WorkDir              = $workDir
            ScriptRoot           = $scriptRoot
            ProbesDirectory      = Join-Path $scriptRoot 'probes'
            StateProbesDirectory = Join-Path $scriptRoot 'state/probes'
            ControlFilePath      = Join-Path $scriptRoot 'control.json'
            StatsFilePath        = Join-Path $scriptRoot 'stats.json'
            EnvFilePath          = Join-Path $scriptRoot '.env'
            DashboardRootPath    = $script:RealDashboardRootPath
            DashboardPort        = 8787
        }
    }

    function New-FastFixtureProbeModule {
        <#
        .SYNOPSIS
        Writes a throwaway, near-instant probe module (stem 'fast' -> Config property
        ProbeFastEnabled, per Get-ProbeConfigPropertyName's fixed naming formula) into
        ProbesDirectory. Returns a normalized D-02 result immediately -- the sibling this
        suite's hung-probe test proves survives alongside an abandoned HangingProbe.
        #>
        param([Parameter(Mandatory)] [string] $ProbesDirectory)

        New-Item -ItemType Directory -Path $ProbesDirectory -Force | Out-Null
        $modulePath = Join-Path $ProbesDirectory 'fast.psm1'
        $moduleContent = @'
Set-StrictMode -Version Latest
function Invoke-Probe {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Config
    )
    return [pscustomobject]@{
        name    = 'fast-probe'
        title   = 'Fast Probe (test fixture)'
        status  = 'ok'
        metrics = @(@{ label = 'Latency'; value = 5; unit = 'ms' })
        detail  = $null
    }
}
Export-ModuleMember -Function Invoke-Probe
'@
        Set-Content -LiteralPath $modulePath -Value $moduleContent -Encoding utf8
        return $modulePath
    }

    function Copy-HangingProbeFixtureModule {
        <#
        .SYNOPSIS
        Copies tests/fixtures/HangingProbe.psm1 (stem 'HangingProbe' -> Config property
        ProbeHangingprobeEnabled) into ProbesDirectory -- the fixture lives under
        tests/fixtures/ deliberately (never probes/), so copying it into a throwaway
        $TestDrive ProbesDirectory for this one test is how it gets discovered without
        ever risking production's real probes/ scan path (06-RESEARCH.md Open Question 3).
        #>
        param([Parameter(Mandatory)] [string] $ProbesDirectory)

        New-Item -ItemType Directory -Path $ProbesDirectory -Force | Out-Null
        $destinationPath = Join-Path $ProbesDirectory 'HangingProbe.psm1'
        Copy-Item -LiteralPath $script:HangingProbeFixtureModulePath -Destination $destinationPath -Force
        return $destinationPath
    }

    function New-ProbeSystemFakeContext {
        <#
        .SYNOPSIS
        Duck-typed stand-in for [System.Net.HttpListenerContext] (no public constructor),
        backed by a real System.IO.MemoryStream for the response body -- mirrors
        tests/Dashboard.Tests.ps1's New-FakeDashboardContext, copied here rather than
        shared (this repo's established per-suite-copy convention for small test-only
        helpers, matching the StatsStore/ProbeStore/OffsetStore atomic-write precedent).
        #>
        param(
            [string] $HttpMethod = 'GET',
            [string] $Path = '/api/stats'
        )

        $request = [pscustomobject]@{
            HttpMethod  = $HttpMethod
            Url         = [System.Uri]::new("http://localhost:8787$Path")
            Headers     = [System.Collections.Specialized.NameValueCollection]::new()
            InputStream = [System.IO.MemoryStream]::new([byte[]] @())
        }

        $response = [pscustomobject]@{
            StatusCode   = 200
            ContentType  = $null
            OutputStream = [System.IO.MemoryStream]::new()
            Headers      = [System.Collections.Specialized.NameValueCollection]::new()
        }
        $response | Add-Member -MemberType ScriptMethod -Name Close -Value { } -Force

        return [pscustomobject]@{ Request = $request; Response = $response }
    }

    function Invoke-ProbeSystemApiStats {
        <#
        .SYNOPSIS
        Drives the REAL, UNMOCKED Invoke-DashboardRequestHandler's ApiStats route against
        Fixture (a New-ProbeSystemFixture object) and returns the parsed response.

        .OUTPUTS
        PSCustomObject: StatusCode, ContentType, Body (raw JSON string), ViewModel
        (parsed).
        #>
        param([Parameter(Mandatory)] $Fixture)

        $context = New-ProbeSystemFakeContext -HttpMethod 'GET' -Path '/api/stats'
        Invoke-DashboardRequestHandler -Context $context -ScriptRoot $Fixture.ScriptRoot `
            -ControlFilePath $Fixture.ControlFilePath -StatsFilePath $Fixture.StatsFilePath `
            -DashboardRootPath $Fixture.DashboardRootPath -EnvFilePath $Fixture.EnvFilePath `
            -DashboardPort $Fixture.DashboardPort

        $context.Response.OutputStream.Position = 0
        $reader = [System.IO.StreamReader]::new($context.Response.OutputStream, [System.Text.Encoding]::UTF8, $false, 1024, $true)
        $body = $null
        try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }

        return [pscustomobject]@{
            StatusCode  = $context.Response.StatusCode
            ContentType = $context.Response.ContentType
            Body        = $body
            ViewModel   = ($body | ConvertFrom-Json)
        }
    }
}

Describe 'Probe system end-to-end: store -> host -> fold -> /api/stats (phase 06 gate)' -Tag 'Integration' {

    BeforeEach {
        Remove-Module Dashboard -ErrorAction SilentlyContinue
        Remove-Module ProbeHost -ErrorAction SilentlyContinue
        Remove-Module ProbeStore -ErrorAction SilentlyContinue
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module PusherProcess -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue

        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'pester-thread-logs')
        Import-Module $script:ControlFlagModulePath -Force
        Import-Module $script:PusherProcessModulePath -Force
        Import-Module $script:StatsStoreModulePath -Force
        Import-Module $script:ClockModulePath -Force
        Import-Module $script:ProbeStoreModulePath -Force
        Import-Module $script:ProbeHostModulePath -Force
        Import-Module $script:DashboardModulePath -Force
    }

    AfterEach {
        Remove-Module Dashboard -ErrorAction SilentlyContinue
        Remove-Module ProbeHost -ErrorAction SilentlyContinue
        Remove-Module ProbeStore -ErrorAction SilentlyContinue
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module PusherProcess -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
    }

    It 'Test 1 (MON-01/MON-03/MON-04, the full chain): a probe-host-written result flows into /api/stats probes[]' {
        $fixture = New-ProbeSystemFixture
        New-FastFixtureProbeModule -ProbesDirectory $fixture.ProbesDirectory | Out-Null
        $probeConfig = [pscustomobject]@{ ProbeFastEnabled = $true }

        Invoke-ProbeHostLoop -ProbesDirectory $fixture.ProbesDirectory -Config $probeConfig `
            -HardTimeoutMilliseconds 5000 -PollIntervalSeconds 0 `
            -StateProbesDirectory $fixture.StateProbesDirectory -MaxCycles 1

        Test-Path -LiteralPath (Join-Path $fixture.StateProbesDirectory 'fast-probe.json') | Should -BeTrue `
            -Because 'the probe host must persist the enabled fixture''s result to state/probes/<name>.json'

        $result = Invoke-ProbeSystemApiStats -Fixture $fixture

        $result.StatusCode | Should -Be 200
        ($result.ContentType) | Should -Match 'application/json'
        $probes = @($result.ViewModel.probes)
        $probes.Count | Should -Be 1 -Because 'exactly one enabled probe was polled this cycle'
        $probes[0].name | Should -Be 'fast-probe'
        $probes[0].title | Should -Be 'Fast Probe (test fixture)'
        $probes[0].status | Should -Be 'ok'
        @($probes[0].metrics).Count | Should -Be 1
        $probes[0].metrics[0].label | Should -Be 'Latency'
    }

    It 'Test 2 (MON-04, zero-plugin): probes: [] and every non-probe field is byte-for-byte identical whether state/probes is absent or merely empty' {
        $fixture = New-ProbeSystemFixture

        # Scenario A: state/probes has never been created (a fresh install, or a build
        # that never enabled a probe at all).
        Test-Path -LiteralPath $fixture.StateProbesDirectory | Should -BeFalse -Because 'this scenario asserts the genuine no-directory-at-all case'
        $noDirectoryResult = Invoke-ProbeSystemApiStats -Fixture $fixture
        $noDirectoryResult.StatusCode | Should -Be 200
        @($noDirectoryResult.ViewModel.probes).Count | Should -Be 0

        # Scenario B: state/probes exists but has zero enabled/polled probes inside it
        # (an operator who enabled, then disabled, every probe -- MON-04's other real
        # zero-plugin path).
        New-Item -ItemType Directory -Path $fixture.StateProbesDirectory -Force | Out-Null
        $emptyDirectoryResult = Invoke-ProbeSystemApiStats -Fixture $fixture
        $emptyDirectoryResult.StatusCode | Should -Be 200
        @($emptyDirectoryResult.ViewModel.probes).Count | Should -Be 0

        $baselineWithoutProbes = $noDirectoryResult.ViewModel | Select-Object -ExcludeProperty probes | ConvertTo-Json -Compress
        $comparisonWithoutProbes = $emptyDirectoryResult.ViewModel | Select-Object -ExcludeProperty probes | ConvertTo-Json -Compress
        $comparisonWithoutProbes | Should -Be $baselineWithoutProbes `
            -Because 'MON-04: zero enabled probes (however state/probes is laid out) must never perturb any local stats field'
    }

    It 'Test 3 (MON-05, real timing): a hanging enabled probe never stalls the host cycle, and ApiStats stays responsive afterward' {
        $fixture = New-ProbeSystemFixture
        New-FastFixtureProbeModule -ProbesDirectory $fixture.ProbesDirectory | Out-Null
        Copy-HangingProbeFixtureModule -ProbesDirectory $fixture.ProbesDirectory | Out-Null
        $probeConfig = [pscustomobject]@{ ProbeFastEnabled = $true; ProbeHangingprobeEnabled = $true }
        $hardTimeoutMilliseconds = 1000

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-ProbeHostLoop -ProbesDirectory $fixture.ProbesDirectory -Config $probeConfig `
            -HardTimeoutMilliseconds $hardTimeoutMilliseconds -PollIntervalSeconds 0 `
            -StateProbesDirectory $fixture.StateProbesDirectory -MaxCycles 1
        $stopwatch.Stop()

        # Generous margin over 2x the hard timeout (both probes run sequentially in one
        # cycle) covers child-runspace/module-import overhead on a slow CI box, while
        # staying an order of magnitude below the fixture's real 60s sleep -- the
        # assertion that actually matters is "nowhere near 60s", not a tight bound.
        $stopwatch.Elapsed.TotalMilliseconds | Should -BeLessThan 20000 `
            -Because 'one cycle must complete within timeout+margin, never anywhere close to the HangingProbe fixture''s 60s sleep (MON-05)'

        Test-Path -LiteralPath (Join-Path $fixture.StateProbesDirectory 'fast-probe.json') | Should -BeTrue `
            -Because 'the sibling fast probe must persist even though the hanging probe was abandoned mid-cycle'

        $result = Invoke-ProbeSystemApiStats -Fixture $fixture
        $result.StatusCode | Should -Be 200 -Because 'ApiStats must stay responsive after a cycle that included a hung probe'
        $probes = @($result.ViewModel.probes)
        ($probes | Where-Object { $_.name -eq 'fast-probe' }).status | Should -Be 'ok'
    }

    It 'Test 4 (T-06-05, broken-file resilience): a corrupt probe JSON survives alongside a valid one, local stats untouched' {
        $fixture = New-ProbeSystemFixture
        New-Item -ItemType Directory -Path $fixture.StateProbesDirectory -Force | Out-Null

        Set-Content -LiteralPath (Join-Path $fixture.StateProbesDirectory 'broken.json') -Value '{not valid json' -Encoding utf8 -NoNewline

        Save-ProbeResult -ProbeResultFilePath (Join-Path $fixture.StateProbesDirectory 'valid-probe.json') `
            -Name 'valid-probe' -Title 'Valid Probe' -Status 'ok' -Metrics @() -Detail $null

        $result = Invoke-ProbeSystemApiStats -Fixture $fixture

        $result.StatusCode | Should -Be 200 -Because 'a corrupt probe file must never fault /api/stats (T-06-05)'
        $probes = @($result.ViewModel.probes)
        $probes.Count | Should -Be 1 -Because 'the corrupt file is skipped by Read-ProbeResult''s silent-safe-default contract, never surfaced as a phantom panel'
        $probes[0].name | Should -Be 'valid-probe'
        $probes[0].status | Should -Be 'ok'

        $result.ViewModel.ConnectionState | Should -Be 'Idle' `
            -Because 'local stats (no stats.json, no live pusher) must stay intact even with a corrupt probe file present'
        $result.ViewModel.StartEnabled | Should -BeTrue
    }
}

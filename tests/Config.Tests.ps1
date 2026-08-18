BeforeAll {
    $script:LoggingModulePath = Join-Path $PSScriptRoot '../lib/Logging.psm1'
    $script:ConfigModulePath = Join-Path $PSScriptRoot '../lib/Config.psm1'
}

Describe 'Read-DotEnvFile' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:ConfigModulePath -Force
    }

    AfterEach {
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'returns an empty hashtable and never throws when the .env path is missing' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'

        { $script:parsedValues = Read-DotEnvFile -Path $missingPath } | Should -Not -Throw

        $script:parsedValues.Count | Should -Be 0
    }

    It 'splits only on the first = so a value containing = is preserved intact' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, 'RELAY_HOST=srt://host:9000?streamid=abc=def')

        $parsedValues = Read-DotEnvFile -Path $envPath

        $parsedValues['RELAY_HOST'] | Should -Be 'srt://host:9000?streamid=abc=def'
    }

    It 'trims surrounding whitespace and strips one layer of matching quotes' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, '  STREAM_ID  =  "church-01"  ')

        $parsedValues = Read-DotEnvFile -Path $envPath

        $parsedValues['STREAM_ID'] | Should -Be 'church-01'
    }

    It 'skips blank lines and comment lines' {
        $envPath = Join-Path $TestDrive '.env'
        $content = "`n# a full-line comment`nRELAY_HOST=10.0.0.5`n   `n"
        [System.IO.File]::WriteAllText($envPath, $content)

        $parsedValues = Read-DotEnvFile -Path $envPath

        $parsedValues.Count | Should -Be 1
        $parsedValues['RELAY_HOST'] | Should -Be '10.0.0.5'
    }

    It 'ignores a malformed line with no = rather than throwing' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "NOEQUALSIGNHERE`nRELAY_HOST=10.0.0.5`n")

        { $script:parsedValues = Read-DotEnvFile -Path $envPath } | Should -Not -Throw

        $script:parsedValues.Count | Should -Be 1
        $script:parsedValues.ContainsKey('NOEQUALSIGNHERE') | Should -BeFalse
    }
}

Describe 'Read-PusherConfig' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:ConfigModulePath -Force
    }

    AfterEach {
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'returns code defaults for every key when no .env file exists, with CatchUpMultiplier = 1.5 (Pitfall 4)' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'

        $config = Read-PusherConfig -Path $missingPath

        $config.RecordingFolderPath | Should -Be 'state/'
        $config.RecordingFilenameGlob | Should -Be '*.ts'
        $config.RelayHost | Should -Be '127.0.0.1'
        $config.RelayPort | Should -Be 8890
        $config.StreamId | Should -Be 'church-01'
        $config.LatencyMicroseconds | Should -Be 500000
        $config.CatchUpMultiplier | Should -Be 1.5
        $config.ObsProcessName | Should -Be 'obs64'
        $config.SessionResumeStaleAfterSeconds | Should -Be 1800
        $config.SessionResumeStaleAfterSeconds | Should -BeOfType [double]
    }

    It 'coerces SESSION_RESUME_STALE_AFTER_SECONDS to [double] from a .env string value (SESS-01)' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "SESSION_RESUME_STALE_AFTER_SECONDS=600`n")

        $config = Read-PusherConfig -Path $envPath

        $config.SessionResumeStaleAfterSeconds | Should -Be 600
        $config.SessionResumeStaleAfterSeconds | Should -BeOfType [double]
    }

    It 'defaults RecordingStartStaleAfterSeconds to 300.0 [double] when RECORDING_START_STALE_AFTER_SECONDS is absent from .env (260809-ow9, START-STALE-01)' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'

        $config = Read-PusherConfig -Path $missingPath

        $config.RecordingStartStaleAfterSeconds | Should -Be 300
        $config.RecordingStartStaleAfterSeconds | Should -BeOfType [double]
    }

    It 'coerces RECORDING_START_STALE_AFTER_SECONDS=45 from .env to the [double] 45.0 (START-STALE-01)' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "RECORDING_START_STALE_AFTER_SECONDS=45`n")

        $config = Read-PusherConfig -Path $envPath

        $config.RecordingStartStaleAfterSeconds | Should -Be 45
        $config.RecordingStartStaleAfterSeconds | Should -BeOfType [double]
    }

    It 'coerces RELAY_PORT to [int] from a .env string value' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "RELAY_PORT=9000`n")

        $config = Read-PusherConfig -Path $envPath

        $config.RelayPort | Should -Be 9000
        $config.RelayPort | Should -BeOfType [int]
    }

    It 'defaults RelayProtocol to tcp and SendCeilingBytesPerSecond to 0 when absent from .env (public-release default, 260818-fs1)' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'

        $config = Read-PusherConfig -Path $missingPath

        $config.RelayProtocol | Should -BeExactly 'tcp'
        $config.SendCeilingBytesPerSecond | Should -Be 0
        $config.SendCeilingBytesPerSecond | Should -BeOfType [long]
    }

    It 'reads RELAY_PROTOCOL=tcp and coerces SEND_CEILING_BYTES_PER_SECOND to [long] from .env' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "RELAY_PROTOCOL=tcp`nSEND_CEILING_BYTES_PER_SECOND=2000000`n")

        $config = Read-PusherConfig -Path $envPath

        $config.RelayProtocol | Should -BeExactly 'tcp'
        $config.SendCeilingBytesPerSecond | Should -Be 2000000
        $config.SendCeilingBytesPerSecond | Should -BeOfType [long]
    }

    It 'reads an explicit RELAY_PROTOCOL=srt override from .env even though the default is now tcp (260818-fs1)' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "RELAY_PROTOCOL=srt`n")

        $config = Read-PusherConfig -Path $envPath

        $config.RelayProtocol | Should -BeExactly 'srt'
    }

    It 'defaults GrowthRateSmoothingSeconds to 30.0 [double] when GROWTH_RATE_SMOOTHING_SECONDS is absent from .env (260718-h23, DASH-BRIEF-1/2)' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'

        $config = Read-PusherConfig -Path $missingPath

        $config.GrowthRateSmoothingSeconds | Should -Be 30.0
        $config.GrowthRateSmoothingSeconds | Should -BeOfType [double]
    }

    It 'coerces GROWTH_RATE_SMOOTHING_SECONDS=45 from .env to the [double] 45.0' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "GROWTH_RATE_SMOOTHING_SECONDS=45`n")

        $config = Read-PusherConfig -Path $envPath

        $config.GrowthRateSmoothingSeconds | Should -Be 45.0
        $config.GrowthRateSmoothingSeconds | Should -BeOfType [double]
    }

    It 'defaults SrtStallToleranceSeconds to 30.0 [double] when SRT_STALL_TOLERANCE_SECONDS is absent from .env (Front A, 260718-j58)' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'

        $config = Read-PusherConfig -Path $missingPath

        $config.SrtStallToleranceSeconds | Should -Be 30.0
        $config.SrtStallToleranceSeconds | Should -BeOfType [double]
    }

    It 'coerces SRT_STALL_TOLERANCE_SECONDS=8 from .env to the [double] 8.0' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "SRT_STALL_TOLERANCE_SECONDS=8`n")

        $config = Read-PusherConfig -Path $envPath

        $config.SrtStallToleranceSeconds | Should -Be 8.0
        $config.SrtStallToleranceSeconds | Should -BeOfType [double]
    }

    It 'defaults EndOfServiceReconnectMaxDurationSeconds to 900.0 [double] and EndOfServiceReconnectMaxAttempts to 100 [int] (Front C, 260718-j58)' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'

        $config = Read-PusherConfig -Path $missingPath

        $config.EndOfServiceReconnectMaxDurationSeconds | Should -Be 900.0
        $config.EndOfServiceReconnectMaxDurationSeconds | Should -BeOfType [double]
        $config.EndOfServiceReconnectMaxAttempts | Should -Be 100
        $config.EndOfServiceReconnectMaxAttempts | Should -BeOfType [int]
    }

    It 'coerces END_OF_SERVICE_RECONNECT_MAX_DURATION_SECONDS=5 and END_OF_SERVICE_RECONNECT_MAX_ATTEMPTS=3 from .env' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "END_OF_SERVICE_RECONNECT_MAX_DURATION_SECONDS=5`nEND_OF_SERVICE_RECONNECT_MAX_ATTEMPTS=3`n")

        $config = Read-PusherConfig -Path $envPath

        $config.EndOfServiceReconnectMaxDurationSeconds | Should -Be 5.0
        $config.EndOfServiceReconnectMaxDurationSeconds | Should -BeOfType [double]
        $config.EndOfServiceReconnectMaxAttempts | Should -Be 3
        $config.EndOfServiceReconnectMaxAttempts | Should -BeOfType [int]
    }

    It 'defaults SrtNicName to the empty string when SRT_NIC_NAME is absent from .env (260722-xbr/NIC-TELEMETRY-01)' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'

        $config = Read-PusherConfig -Path $missingPath

        $config.SrtNicName | Should -Be ''
    }

    It 'coerces SRT_NIC_NAME=Ethernet from .env (260722-xbr/NIC-TELEMETRY-01)' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "SRT_NIC_NAME=Ethernet`n")

        $config = Read-PusherConfig -Path $envPath

        $config.SrtNicName | Should -Be 'Ethernet'
    }

    It 'defaults VpsRoutePrefix and VpsRouteNextHop to the empty string when both are absent from .env' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'

        $config = Read-PusherConfig -Path $missingPath

        $config.VpsRoutePrefix | Should -Be ''
        $config.VpsRouteNextHop | Should -Be ''
    }

    It 'coerces explicit VPS_ROUTE_PREFIX/VPS_ROUTE_NEXT_HOP values from .env verbatim' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "VPS_ROUTE_PREFIX=203.0.113.10/32`nVPS_ROUTE_NEXT_HOP=192.0.2.1`n")

        $config = Read-PusherConfig -Path $envPath

        $config.VpsRoutePrefix | Should -Be '203.0.113.10/32'
        $config.VpsRouteNextHop | Should -Be '192.0.2.1'
    }

    It 'defaults the Tier 1 sender SRT knobs to omit values when absent from .env (debug/srt-throughput-degraded-today.md)' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'

        $config = Read-PusherConfig -Path $missingPath

        $config.SrtSendBufferBytes | Should -Be 0
        $config.SrtSendBufferBytes | Should -BeOfType [int]
        $config.SrtFlightFlagSizeBytes | Should -Be 0
        $config.SrtFlightFlagSizeBytes | Should -BeOfType [int]
        $config.SrtLossMaxTtl | Should -Be 0
        $config.SrtLossMaxTtl | Should -BeOfType [int]
        $config.SrtNakReport | Should -Be ''
    }

    It 'coerces the Tier 1 sender SRT knobs from .env (sndbuf/ffs/lossmaxttl int, nakreport string)' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "SRT_SEND_BUFFER_BYTES=67108864`nSRT_FLIGHT_FLAG_SIZE_BYTES=65536`nSRT_LOSS_MAX_TTL=4096`nSRT_NAK_REPORT=true`n")

        $config = Read-PusherConfig -Path $envPath

        $config.SrtSendBufferBytes | Should -Be 67108864
        $config.SrtSendBufferBytes | Should -BeOfType [int]
        $config.SrtFlightFlagSizeBytes | Should -Be 65536
        $config.SrtLossMaxTtl | Should -Be 4096
        $config.SrtNakReport | Should -Be 'true'
    }

    It 'coerces LATENCY_MICROSECONDS and the log-rotation keys to their numeric types' {
        $envPath = Join-Path $TestDrive '.env'
        $envContent = "LATENCY_MICROSECONDS=750000`nLOG_MAX_SIZE_BYTES=20971520`nLOG_RETENTION_COUNT=3`n"
        [System.IO.File]::WriteAllText($envPath, $envContent)

        $config = Read-PusherConfig -Path $envPath

        $config.LatencyMicroseconds | Should -Be 750000
        $config.LogMaxSizeBytes | Should -Be 20971520
        $config.LogRetentionCount | Should -Be 3
    }

    It 'coerces a boolean-shaped value to [bool] via the private coercion helper' {
        InModuleScope Config {
            $coerced = ConvertTo-CoercedConfigValue -Value 'true' -Type 'bool' -EnvKey 'TEST_BOOL' -DefaultValue $false

            $coerced | Should -BeOfType [bool]
            $coerced | Should -BeTrue
        }
    }

    It 'coerces PROBE_VPS_ENABLED=true to a real [bool] via Read-PusherConfig -- first real bool schema row (D-14, RESEARCH Pitfall 4)' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "PROBE_VPS_ENABLED=true`n")

        $config = Read-PusherConfig -Path $envPath

        $config.ProbeVpsEnabled | Should -BeOfType [bool]
        $config.ProbeVpsEnabled | Should -BeTrue
    }

    It 'coerces PROBE_VPS_ENABLED=false to $false via Read-PusherConfig' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "PROBE_VPS_ENABLED=false`n")

        $config = Read-PusherConfig -Path $envPath

        $config.ProbeVpsEnabled | Should -BeOfType [bool]
        $config.ProbeVpsEnabled | Should -BeFalse
    }

    It 'defaults ProbeVpsEnabled to $false when PROBE_VPS_ENABLED is entirely absent' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'

        $config = Read-PusherConfig -Path $missingPath

        $config.ProbeVpsEnabled | Should -BeOfType [bool]
        $config.ProbeVpsEnabled | Should -BeFalse
    }

    It 'falls back to the default $false for a malformed PROBE_VPS_ENABLED value without throwing (D-14)' {
        foreach ($malformedValue in @('yes', '1', 'maybe')) {
            $envPath = Join-Path $TestDrive '.env'
            [System.IO.File]::WriteAllText($envPath, "PROBE_VPS_ENABLED=$malformedValue`n")

            { $script:config = Read-PusherConfig -Path $envPath } | Should -Not -Throw
            $script:config.ProbeVpsEnabled | Should -BeOfType [bool]
            $script:config.ProbeVpsEnabled | Should -BeFalse
        }
    }

    It 'reads PROBE_VPS_SSH_HOST/USER/KEYPATH as strings, defaulting to empty when absent' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'

        $config = Read-PusherConfig -Path $missingPath

        $config.ProbeVpsSshHost | Should -Be ''
        $config.ProbeVpsSshUser | Should -Be ''
        $config.ProbeVpsSshKeyPath | Should -Be ''
    }

    It 'overrides PROBE_VPS_SSH_HOST/USER/KEYPATH from .env string values' {
        $envPath = Join-Path $TestDrive '.env'
        $envContent = "PROBE_VPS_SSH_HOST=vps.example.com`nPROBE_VPS_SSH_USER=deploy`nPROBE_VPS_SSH_KEYPATH=C:\keys\vps_id_rsa`n"
        [System.IO.File]::WriteAllText($envPath, $envContent)

        $config = Read-PusherConfig -Path $envPath

        $config.ProbeVpsSshHost | Should -Be 'vps.example.com'
        $config.ProbeVpsSshUser | Should -Be 'deploy'
        $config.ProbeVpsSshKeyPath | Should -Be 'C:\keys\vps_id_rsa'
    }

    It 'defaults ProbeVpsSshPort to the standard SSH port 22 [int] when PROBE_VPS_SSH_PORT is absent from .env (CHUR-02/D-07)' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'

        $config = Read-PusherConfig -Path $missingPath

        $config.ProbeVpsSshPort | Should -Be 22
        $config.ProbeVpsSshPort | Should -BeOfType [int]
    }

    It 'an explicit non-standard PROBE_VPS_SSH_PORT=2222 in .env wins over the default' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "PROBE_VPS_SSH_PORT=2222`n")

        $config = Read-PusherConfig -Path $envPath

        $config.ProbeVpsSshPort | Should -Be 2222
        $config.ProbeVpsSshPort | Should -BeOfType [int]
    }

    It 'defaults ColdStartCatchUpCeilingBytesPerSecond to 3500000 [long] when absent from .env (D-04, 28 Mbit/s)' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'

        $config = Read-PusherConfig -Path $missingPath

        $config.ColdStartCatchUpCeilingBytesPerSecond | Should -Be 3500000
        $config.ColdStartCatchUpCeilingBytesPerSecond | Should -BeOfType [long]
    }

    It 'coerces COLD_START_CATCH_UP_CEILING_BYTES_PER_SECOND from .env (D-04, row now lives in the operator-facing block)' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "COLD_START_CATCH_UP_CEILING_BYTES_PER_SECOND=4000000`n")

        $config = Read-PusherConfig -Path $envPath

        $config.ColdStartCatchUpCeilingBytesPerSecond | Should -Be 4000000
        $config.ColdStartCatchUpCeilingBytesPerSecond | Should -BeOfType [long]
    }

    It 'defaults AutoPickupEnabled to $false when AUTO_PICKUP is absent from .env (260718-epo, T-epo-01)' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'

        $config = Read-PusherConfig -Path $missingPath

        $config.AutoPickupEnabled | Should -BeOfType [bool]
        $config.AutoPickupEnabled | Should -BeFalse
    }

    It 'reads AUTO_PICKUP=true from .env as $true' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "AUTO_PICKUP=true`n")

        $config = Read-PusherConfig -Path $envPath

        $config.AutoPickupEnabled | Should -BeOfType [bool]
        $config.AutoPickupEnabled | Should -BeTrue
    }

    It 'reads AUTO_PICKUP=false from .env as $false' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "AUTO_PICKUP=false`n")

        $config = Read-PusherConfig -Path $envPath

        $config.AutoPickupEnabled | Should -BeOfType [bool]
        $config.AutoPickupEnabled | Should -BeFalse
    }

    It 'never surfaces an unrecognised credential-shaped .env key on the returned config object (D-07)' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "YOUTUBE_API_KEY=AIzaFakeSecretValue123`nRELAY_HOST=10.0.0.5`n")

        $config = Read-PusherConfig -Path $envPath

        $config.PSObject.Properties.Name | Should -Not -Contain 'YoutubeApiKey'
        $config.PSObject.Properties.Name | Should -Not -Contain 'YOUTUBE_API_KEY'
        $config.RelayHost | Should -Be '10.0.0.5'
    }

    It 'never reads an internal safety constant (D-06) from .env, even if a matching line is present' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "CHUNK_SIZE_BYTES=999999`n")

        $config = Read-PusherConfig -Path $envPath

        $config.ChunkSizeBytes | Should -Be 65424
    }

    It 'exports Read-DotEnvFile and Read-PusherConfig' {
        Get-Command -Module Config -Name Read-DotEnvFile | Should -Not -BeNullOrEmpty
        Get-Command -Module Config -Name Read-PusherConfig | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-PusherConfig' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:ConfigModulePath -Force
    }

    AfterEach {
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'returns an empty problems array for a fully valid config' {
        $validConfig = [pscustomobject]@{
            RelayHost           = '127.0.0.1'
            RelayPort           = 8890
            RecordingFolderPath = $TestDrive
        }

        $problems = Test-PusherConfig -Config $validConfig

        $problems.Count | Should -Be 0
    }

    It 'returns a problem naming RELAY_HOST when blank or whitespace' {
        $config = [pscustomobject]@{
            RelayHost           = '   '
            RelayPort           = 8890
            RecordingFolderPath = $TestDrive
        }

        $problems = Test-PusherConfig -Config $config

        ($problems -join "`n") | Should -Match 'RELAY_HOST'
    }

    It 'returns a problem naming RELAY_PORT for an out-of-range or non-numeric value' {
        foreach ($badPort in @(0, -1, 70000, 'not-a-number')) {
            $config = [pscustomobject]@{
                RelayHost           = '127.0.0.1'
                RelayPort           = $badPort
                RecordingFolderPath = $TestDrive
            }

            $problems = Test-PusherConfig -Config $config

            ($problems -join "`n") | Should -Match 'RELAY_PORT'
        }
    }

    It 'returns a problem naming RELAY_PROTOCOL for an unsupported protocol value, and accepts srt/tcp' {
        foreach ($protocol in @('srt', 'tcp')) {
            $config = [pscustomobject]@{
                RelayHost           = '127.0.0.1'
                RelayPort           = 8890
                RelayProtocol       = $protocol
                RecordingFolderPath = $TestDrive
            }

            (Test-PusherConfig -Config $config).Count | Should -Be 0
        }

        $badConfig = [pscustomobject]@{
            RelayHost           = '127.0.0.1'
            RelayPort           = 8890
            RelayProtocol       = 'udp'
            RecordingFolderPath = $TestDrive
        }

        ((Test-PusherConfig -Config $badConfig) -join "`n") | Should -Match 'RELAY_PROTOCOL'
    }

    It 'returns a problem naming RECORDING_FOLDER_PATH when the folder does not exist' {
        $config = [pscustomobject]@{
            RelayHost           = '127.0.0.1'
            RelayPort           = 8890
            RecordingFolderPath = (Join-Path $TestDrive 'this-folder-does-not-exist')
        }

        $problems = Test-PusherConfig -Config $config

        ($problems -join "`n") | Should -Match 'RECORDING_FOLDER_PATH'
    }

    It 'returns a problem naming COLD_START_CATCH_UP_CEILING_BYTES_PER_SECOND for 0 or a negative value (CR-01/WR-03)' {
        foreach ($badColdStartCeiling in @(0, -1, -3500000)) {
            $config = [pscustomobject]@{
                RelayHost                              = '127.0.0.1'
                RelayPort                               = 8890
                RecordingFolderPath                     = $TestDrive
                ColdStartCatchUpCeilingBytesPerSecond   = $badColdStartCeiling
            }

            $problems = Test-PusherConfig -Config $config

            ($problems -join "`n") | Should -Match 'COLD_START_CATCH_UP_CEILING_BYTES_PER_SECOND'
        }
    }

    It 'accepts a positive COLD_START_CATCH_UP_CEILING_BYTES_PER_SECOND value, and treats an absent property as no problem' {
        $configWithPositiveCeiling = [pscustomobject]@{
            RelayHost                              = '127.0.0.1'
            RelayPort                               = 8890
            RecordingFolderPath                     = $TestDrive
            ColdStartCatchUpCeilingBytesPerSecond   = 3500000
        }
        (Test-PusherConfig -Config $configWithPositiveCeiling).Count | Should -Be 0

        $configWithoutColdStartCeiling = [pscustomobject]@{
            RelayHost           = '127.0.0.1'
            RelayPort           = 8890
            RecordingFolderPath = $TestDrive
        }
        (Test-PusherConfig -Config $configWithoutColdStartCeiling).Count | Should -Be 0
    }

    It 'returns a problem naming RECORDING_START_STALE_AFTER_SECONDS for 0 or a negative value (260809-ow9, START-STALE-01)' {
        foreach ($badStaleAfterSeconds in @(0, -1, -300)) {
            $config = [pscustomobject]@{
                RelayHost                         = '127.0.0.1'
                RelayPort                          = 8890
                RecordingFolderPath                = $TestDrive
                RecordingStartStaleAfterSeconds    = $badStaleAfterSeconds
            }

            $problems = Test-PusherConfig -Config $config

            ($problems -join "`n") | Should -Match 'RECORDING_START_STALE_AFTER_SECONDS'
        }
    }

    It 'accepts a positive RECORDING_START_STALE_AFTER_SECONDS value, and treats an absent property as no problem (START-STALE-01)' {
        foreach ($goodStaleAfterSeconds in @(0.5, 300)) {
            $configWithGoodValue = [pscustomobject]@{
                RelayHost                         = '127.0.0.1'
                RelayPort                          = 8890
                RecordingFolderPath                = $TestDrive
                RecordingStartStaleAfterSeconds    = $goodStaleAfterSeconds
            }
            (Test-PusherConfig -Config $configWithGoodValue).Count | Should -Be 0
        }

        $configWithoutStaleAfterSeconds = [pscustomobject]@{
            RelayHost           = '127.0.0.1'
            RelayPort           = 8890
            RecordingFolderPath = $TestDrive
        }
        (Test-PusherConfig -Config $configWithoutStaleAfterSeconds).Count | Should -Be 0
    }

    It 'returns an empty problems array when PROBE_VPS_* keys are present -- new probe keys are accepted, not validated (D-14)' {
        $config = [pscustomobject]@{
            RelayHost           = '127.0.0.1'
            RelayPort           = 8890
            RecordingFolderPath = $TestDrive
            ProbeVpsEnabled     = $true
            ProbeVpsSshHost     = 'vps.example.com'
            ProbeVpsSshUser     = 'deploy'
            ProbeVpsSshKeyPath  = 'C:\keys\vps_id_rsa'
        }

        $problems = Test-PusherConfig -Config $config

        $problems.Count | Should -Be 0
    }

    It 'never exits and never throws, even on thoroughly invalid input' {
        $config = [pscustomobject]@{
            RelayHost           = $null
            RelayPort           = 'bad'
            RecordingFolderPath = 'C:\definitely-not-a-real-folder-path'
        }

        { Test-PusherConfig -Config $config } | Should -Not -Throw
    }
}

Describe 'Resolve-PusherConfigPaths' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:ConfigModulePath -Force
    }

    AfterEach {
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'anchors a relative RecordingFolderPath and StateFilePath under the supplied ScriptRoot' {
        $config = [pscustomobject]@{
            RecordingFolderPath = 'state/'
            StateFilePath       = 'state/offset.json'
        }

        $resolved = Resolve-PusherConfigPaths -Config $config -ScriptRoot $TestDrive

        $resolved.RecordingFolderPath | Should -Be (Join-Path $TestDrive 'state/')
        $resolved.StateFilePath | Should -Be (Join-Path $TestDrive 'state/offset.json')
    }

    It 'leaves an already-absolute path unchanged' {
        $absoluteRecordingPath = Join-Path $TestDrive 'already-absolute-recordings'
        $absoluteStatePath = Join-Path $TestDrive 'already-absolute-state/offset.json'
        $config = [pscustomobject]@{
            RecordingFolderPath = $absoluteRecordingPath
            StateFilePath       = $absoluteStatePath
        }

        $resolved = Resolve-PusherConfigPaths -Config $config -ScriptRoot 'C:\some\unrelated\root'

        $resolved.RecordingFolderPath | Should -Be $absoluteRecordingPath
        $resolved.StateFilePath | Should -Be $absoluteStatePath
    }
}

Describe 'Write-DotEnvFile' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:ConfigModulePath -Force

        # Read-PusherConfig's default RecordingFolderPath ('state/') must resolve to a
        # real directory relative to $TestDrive so Test-PusherConfig's validation gate
        # (step 2, D-16) never rejects an otherwise-valid write with an unrelated
        # RECORDING_FOLDER_PATH problem in the tests below.
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'state') -Force | Out-Null
    }

    AfterEach {
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'patches only the requested key, leaving every other line byte-for-byte identical and in order' {
        $envPath = Join-Path $TestDrive '.env'
        $originalLines = @(
            '# church-01 pusher config'
            ''
            'RELAY_PORT=8890'
            'MY_OWN_NOTE=keepme'
        )
        [System.IO.File]::WriteAllText($envPath, ($originalLines -join "`n") + "`n")

        $result = Write-DotEnvFile -Path $envPath -Changes @{ RELAY_PORT = 9000 }

        $result.Success | Should -BeTrue
        $writtenLines = @(Get-Content -LiteralPath $envPath -Encoding utf8)
        $writtenLines[0] | Should -Be $originalLines[0]
        $writtenLines[1] | Should -Be $originalLines[1]
        $writtenLines[2] | Should -Be 'RELAY_PORT=9000'
        $writtenLines[3] | Should -Be $originalLines[3]
        $writtenLines.Count | Should -Be $originalLines.Count
    }

    It 'appends a schema key absent from the file as a new line, leaving existing lines untouched' {
        $envPath = Join-Path $TestDrive '.env'
        $originalLines = @('RELAY_PORT=8890')
        [System.IO.File]::WriteAllText($envPath, ($originalLines -join "`n") + "`n")

        $result = Write-DotEnvFile -Path $envPath -Changes @{ STREAM_ID = 'church-02' }

        $result.Success | Should -BeTrue
        $writtenLines = @(Get-Content -LiteralPath $envPath -Encoding utf8)
        $writtenLines[0] | Should -Be 'RELAY_PORT=8890'
        $writtenLines[1] | Should -Be 'STREAM_ID=church-02'
        $writtenLines.Count | Should -Be 2
    }

    It 'rejects a key not present in the schema, leaving the file unchanged' {
        $envPath = Join-Path $TestDrive '.env'
        $originalContent = "RELAY_PORT=8890`n"
        [System.IO.File]::WriteAllText($envPath, $originalContent)

        $result = Write-DotEnvFile -Path $envPath -Changes @{ TOTALLY_MADE_UP = 'x' }

        $result.Success | Should -BeFalse
        ($result.Problems -join "`n") | Should -Match 'TOTALLY_MADE_UP'
        [System.IO.File]::ReadAllText($envPath) | Should -Be $originalContent
    }

    It 'rejects an internal safety constant (EnvKey = $null), leaving the file unchanged' {
        $envPath = Join-Path $TestDrive '.env'
        $originalContent = "RELAY_PORT=8890`n"
        [System.IO.File]::WriteAllText($envPath, $originalContent)

        $result = Write-DotEnvFile -Path $envPath -Changes @{ CHUNK_SIZE_BYTES = 1 }

        $result.Success | Should -BeFalse
        ($result.Problems -join "`n") | Should -Match 'CHUNK_SIZE_BYTES'
        [System.IO.File]::ReadAllText($envPath) | Should -Be $originalContent
    }

    It 'rejects a proposed config that Test-PusherConfig rejects, leaving the file unchanged' {
        $envPath = Join-Path $TestDrive '.env'
        $originalContent = "RELAY_PORT=8890`n"
        [System.IO.File]::WriteAllText($envPath, $originalContent)

        $result = Write-DotEnvFile -Path $envPath -Changes @{ RELAY_PORT = 70000 }

        $result.Success | Should -BeFalse
        ($result.Problems -join "`n") | Should -Match 'RELAY_PORT'
        [System.IO.File]::ReadAllText($envPath) | Should -Be $originalContent
    }

    It 'rejects a string-typed value containing an embedded newline (CR-03), leaving the file unchanged -- refuses a .env line-injection attempt' {
        $envPath = Join-Path $TestDrive '.env'
        $originalContent = "RELAY_PORT=8890`n"
        [System.IO.File]::WriteAllText($envPath, $originalContent)

        $injectedValue = "church-01`nRELAY_HOST=attacker.example"
        $result = Write-DotEnvFile -Path $envPath -Changes @{ STREAM_ID = $injectedValue }

        $result.Success | Should -BeFalse
        ($result.Problems -join "`n") | Should -Match 'STREAM_ID'
        ($result.Problems -join "`n") | Should -Match 'newline'
        [System.IO.File]::ReadAllText($envPath) | Should -Be $originalContent
    }

    It 'rejects a string-typed value containing an embedded CRLF (CR-03), leaving the file unchanged' {
        $envPath = Join-Path $TestDrive '.env'
        $originalContent = "RELAY_PORT=8890`n"
        [System.IO.File]::WriteAllText($envPath, $originalContent)

        $injectedValue = "church-01`r`nRELAY_HOST=attacker.example"
        $result = Write-DotEnvFile -Path $envPath -Changes @{ STREAM_ID = $injectedValue }

        $result.Success | Should -BeFalse
        [System.IO.File]::ReadAllText($envPath) | Should -Be $originalContent
    }

    It 'round-trips a written value exactly through Read-DotEnvFile' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "RELAY_PORT=8890`n")

        Write-DotEnvFile -Path $envPath -Changes @{ STREAM_ID = 'church-99' } | Out-Null
        $parsedValues = Read-DotEnvFile -Path $envPath

        $parsedValues['STREAM_ID'] | Should -Be 'church-99'
    }

    It 'preserves a value containing = intact, without re-splitting its own output' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "RELAY_PORT=8890`n")
        $urlValue = 'srt://host:9000?streamid=abc=def'

        Write-DotEnvFile -Path $envPath -Changes @{ RELAY_HOST = $urlValue } | Out-Null
        $parsedValues = Read-DotEnvFile -Path $envPath

        $parsedValues['RELAY_HOST'] | Should -Be $urlValue
    }

    It 'creates the file with only the requested keys when the .env does not yet exist, and does not throw' {
        $envPath = Join-Path $TestDrive 'fresh.env'
        Test-Path -LiteralPath $envPath | Should -BeFalse

        { $script:result = Write-DotEnvFile -Path $envPath -Changes @{ STREAM_ID = 'church-03' } } | Should -Not -Throw

        $script:result.Success | Should -BeTrue
        $parsedValues = Read-DotEnvFile -Path $envPath
        $parsedValues.Count | Should -Be 1
        $parsedValues['STREAM_ID'] | Should -Be 'church-03'
    }

    It 'leaves no *.tmp file in the directory after a successful write' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "RELAY_PORT=8890`n")

        Write-DotEnvFile -Path $envPath -Changes @{ RELAY_PORT = 9000 } | Out-Null

        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.tmp') | Should -BeNullOrEmpty
    }

    It 'preserves quoting on an untouched line when a different key is patched' {
        $envPath = Join-Path $TestDrive '.env'
        $originalLines = @("STREAM_ID='church-01'", 'RELAY_PORT=8890')
        [System.IO.File]::WriteAllText($envPath, ($originalLines -join "`n") + "`n")

        $result = Write-DotEnvFile -Path $envPath -Changes @{ RELAY_PORT = 9000 }

        $result.Success | Should -BeTrue
        $writtenLines = @(Get-Content -LiteralPath $envPath -Encoding utf8)
        $writtenLines[0] | Should -Be "STREAM_ID='church-01'"
    }

    It 'exports Write-DotEnvFile' {
        Get-Command -Module Config -Name Write-DotEnvFile | Should -Not -BeNullOrEmpty
    }

    It 'accepts PROBE_VPS_SSH_PORT (now in the schema allow-list) and still refuses an unknown key' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "RELAY_PORT=8890`n")

        $acceptedResult = Write-DotEnvFile -Path $envPath -Changes @{ PROBE_VPS_SSH_PORT = 2222 }
        $acceptedResult.Success | Should -BeTrue
        (Read-DotEnvFile -Path $envPath)['PROBE_VPS_SSH_PORT'] | Should -Be '2222'

        $refusedResult = Write-DotEnvFile -Path $envPath -Changes @{ TOTALLY_UNKNOWN_KEY = 1 }
        $refusedResult.Success | Should -BeFalse
    }

    It 'round-trips a change to PROBE_VPS_ENABLED without corrupting comments/order/unknown keys (D-14)' {
        $envPath = Join-Path $TestDrive '.env'
        $originalLines = @(
            '# church-01 pusher config'
            ''
            'RELAY_PORT=8890'
            'MY_OWN_NOTE=keepme'
        )
        [System.IO.File]::WriteAllText($envPath, ($originalLines -join "`n") + "`n")

        $result = Write-DotEnvFile -Path $envPath -Changes @{ PROBE_VPS_ENABLED = $true }

        $result.Success | Should -BeTrue
        $writtenLines = @(Get-Content -LiteralPath $envPath -Encoding utf8)
        $writtenLines[0] | Should -Be $originalLines[0]
        $writtenLines[1] | Should -Be $originalLines[1]
        $writtenLines[2] | Should -Be $originalLines[2]
        $writtenLines[3] | Should -Be $originalLines[3]
        $writtenLines[4] | Should -Be 'PROBE_VPS_ENABLED=True'

        $parsedValues = Read-DotEnvFile -Path $envPath
        $parsedValues['PROBE_VPS_ENABLED'] | Should -Be 'True'
    }
}

Describe 'Get-RedactedConfig' -Tag 'Quick' {

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:ConfigModulePath -Force
    }

    AfterEach {
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'masks SrtPassphrase so the raw value never appears in the redacted view' {
        $realPassphrase = 'super-secret-church-passphrase-value'
        $config = [pscustomobject]@{
            RelayHost     = '127.0.0.1'
            SrtPassphrase = $realPassphrase
        }

        $redacted = Get-RedactedConfig -Config $config

        ($redacted | Out-String) | Should -Not -Match ([regex]::Escape($realPassphrase))
        $redacted.SrtPassphrase | Should -Not -Be $realPassphrase
    }

    It 'leaves a blank SrtPassphrase blank (nothing to redact)' {
        $config = [pscustomobject]@{
            RelayHost     = '127.0.0.1'
            SrtPassphrase = ''
        }

        $redacted = Get-RedactedConfig -Config $config

        $redacted.SrtPassphrase | Should -Be ''
    }

    It 'does not mutate the original config object' {
        $realPassphrase = 'another-secret-value'
        $config = [pscustomobject]@{
            RelayHost     = '127.0.0.1'
            SrtPassphrase = $realPassphrase
        }

        Get-RedactedConfig -Config $config | Out-Null

        $config.SrtPassphrase | Should -Be $realPassphrase
    }
}

Describe 'Read-LiveTunableOverrides' -Tag 'Quick' {
    # DIAL-02 (14.5-07): the narrow live-reload reader for exactly the two dial keys
    # (CATCH_UP_MULTIPLIER, SEND_CEILING_BYTES_PER_SECOND). Scope-fenced (T-14.5-07-03):
    # must reuse Read-DotEnvFile + ConvertTo-CoercedConfigValue, never Read-PusherConfig's
    # full schema, so no other .env key ever becomes hot-reloadable through this path.
    # Each returned property is $null ONLY as "no override" signal (key absent, blank
    # file, unparseable value, or a value failing bounds) -- the caller then keeps its
    # own current in-memory value, mirroring ControlFlag.psm1's safe-default discipline.

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:ConfigModulePath -Force
    }

    AfterEach {
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'exports Read-LiveTunableOverrides' {
        Get-Command -Module Config -Name Read-LiveTunableOverrides | Should -Not -BeNullOrEmpty
    }

    It 'returns null for both dial keys when the .env file is missing (safe default, caller keeps current value)' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'

        $overrides = Read-LiveTunableOverrides -Path $missingPath

        $overrides.CatchUpMultiplier | Should -BeNullOrEmpty
        $overrides.SendCeilingBytesPerSecond | Should -BeNullOrEmpty
    }

    It 'returns null for both dial keys when the .env file is empty' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, '')

        $overrides = Read-LiveTunableOverrides -Path $envPath

        $overrides.CatchUpMultiplier | Should -BeNullOrEmpty
        $overrides.SendCeilingBytesPerSecond | Should -BeNullOrEmpty
    }

    It 'reads ONLY the two dial keys from a fixture .env carrying many other keys -- RELAY_HOST/RELAY_PORT/etc are ignored (scope fence, T-14.5-07-03)' {
        $envPath = Join-Path $TestDrive '.env'
        $envContent = @(
            'RELAY_HOST=10.0.0.5'
            'RELAY_PORT=9000'
            'RELAY_PROTOCOL=tcp'
            'SRT_PASSPHRASE=super-secret'
            'CATCH_UP_MULTIPLIER=2.0'
            'SEND_CEILING_BYTES_PER_SECOND=3000000'
        ) -join "`n"
        [System.IO.File]::WriteAllText($envPath, $envContent + "`n")

        $overrides = Read-LiveTunableOverrides -Path $envPath

        $overrides.CatchUpMultiplier | Should -Be 2.0
        $overrides.SendCeilingBytesPerSecond | Should -Be 3000000
        $overrides.PSObject.Properties.Name | Should -Not -Contain 'RelayHost'
        $overrides.PSObject.Properties.Name | Should -Not -Contain 'RelayPort'
        $overrides.PSObject.Properties.Name | Should -Not -Contain 'RelayProtocol'
        $overrides.PSObject.Properties.Name | Should -Not -Contain 'SrtPassphrase'
    }

    It 'accepts CatchUpMultiplier exactly at the boundaries (1.0 and 3.0)' {
        foreach ($boundaryValue in @('1.0', '3.0')) {
            $envPath = Join-Path $TestDrive '.env'
            [System.IO.File]::WriteAllText($envPath, "CATCH_UP_MULTIPLIER=$boundaryValue`n")

            $overrides = Read-LiveTunableOverrides -Path $envPath

            $overrides.CatchUpMultiplier | Should -Be ([double] $boundaryValue)
        }
    }

    It 'rejects CatchUpMultiplier just outside the boundaries (0.9 and 3.1), returning null (safe, caller keeps current value)' {
        foreach ($outOfRangeValue in @('0.9', '3.1')) {
            $envPath = Join-Path $TestDrive '.env'
            [System.IO.File]::WriteAllText($envPath, "CATCH_UP_MULTIPLIER=$outOfRangeValue`n")

            $overrides = Read-LiveTunableOverrides -Path $envPath

            $overrides.CatchUpMultiplier | Should -BeNullOrEmpty
        }
    }

    It 'accepts SendCeilingBytesPerSecond exactly 0 (=off, multiplier governs) as a real value, not a missing-key null' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "SEND_CEILING_BYTES_PER_SECOND=0`n")

        $overrides = Read-LiveTunableOverrides -Path $envPath

        $overrides.SendCeilingBytesPerSecond | Should -Be 0
        $overrides.SendCeilingBytesPerSecond | Should -BeOfType [long]
    }

    It 'accepts SendCeilingBytesPerSecond at the band floor (1, adjacency against 0=off) and a mid-band value' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "SEND_CEILING_BYTES_PER_SECOND=1`n")
        (Read-LiveTunableOverrides -Path $envPath).SendCeilingBytesPerSecond | Should -Be 1

        [System.IO.File]::WriteAllText($envPath, "SEND_CEILING_BYTES_PER_SECOND=2000000`n")
        (Read-LiveTunableOverrides -Path $envPath).SendCeilingBytesPerSecond | Should -Be 2000000
    }

    It 'rejects a negative SendCeilingBytesPerSecond, returning null' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "SEND_CEILING_BYTES_PER_SECOND=-100`n")

        $overrides = Read-LiveTunableOverrides -Path $envPath

        $overrides.SendCeilingBytesPerSecond | Should -BeNullOrEmpty
    }

    It 'rejects a SendCeilingBytesPerSecond value grotesquely above the sane absolute band, returning null' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "SEND_CEILING_BYTES_PER_SECOND=99999999999`n")

        $overrides = Read-LiveTunableOverrides -Path $envPath

        $overrides.SendCeilingBytesPerSecond | Should -BeNullOrEmpty
    }

    It 'returns null (not throw) for an unparseable CatchUpMultiplier value' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "CATCH_UP_MULTIPLIER=not-a-number`n")

        { $script:overrides = Read-LiveTunableOverrides -Path $envPath } | Should -Not -Throw
        $script:overrides.CatchUpMultiplier | Should -BeNullOrEmpty
    }

    It 'returns null (not throw) for an unparseable SendCeilingBytesPerSecond value' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "SEND_CEILING_BYTES_PER_SECOND=not-a-number`n")

        { $script:overrides = Read-LiveTunableOverrides -Path $envPath } | Should -Not -Throw
        $script:overrides.SendCeilingBytesPerSecond | Should -BeNullOrEmpty
    }

    It 'never throws and returns null for both keys on a torn/locked .env read (simulated exclusive-lock race against Write-DotEnvFile)' {
        $envPath = Join-Path $TestDrive '.env'
        [System.IO.File]::WriteAllText($envPath, "CATCH_UP_MULTIPLIER=2.0`nSEND_CEILING_BYTES_PER_SECOND=3000000`n")

        $lockedStream = [System.IO.File]::Open($envPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            { $script:overrides = Read-LiveTunableOverrides -Path $envPath } | Should -Not -Throw
            $script:overrides.CatchUpMultiplier | Should -BeNullOrEmpty
            $script:overrides.SendCeilingBytesPerSecond | Should -BeNullOrEmpty
        } finally {
            $lockedStream.Close()
        }
    }
}

Describe 'Mbit per second to bytes per second conversion contract (DIAL-02)' -Tag 'Quick' {
    # 1 Mbit/s = 125000 bytes/s (decimal Mbit, not Mebibit); display rounds bytes/s
    # to Mbit/s at 1 decimal, half-up; the .env-stored value stays the raw long
    # bytes/s (no precision loss in the stored value).

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Import-Module $script:LoggingModulePath -Force
        Import-Module $script:ConfigModulePath -Force
    }

    AfterEach {
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
        Pop-Location
    }

    It 'exports ConvertTo-BytesPerSecondFromMegabitsPerSecond and ConvertTo-MegabitsPerSecondFromBytesPerSecond' {
        Get-Command -Module Config -Name ConvertTo-BytesPerSecondFromMegabitsPerSecond | Should -Not -BeNullOrEmpty
        Get-Command -Module Config -Name ConvertTo-MegabitsPerSecondFromBytesPerSecond | Should -Not -BeNullOrEmpty
    }

    It 'converts 1 Mbit/s to exactly 125000 bytes/s' {
        ConvertTo-BytesPerSecondFromMegabitsPerSecond -MegabitsPerSecond 1 | Should -Be 125000
        (ConvertTo-BytesPerSecondFromMegabitsPerSecond -MegabitsPerSecond 1) | Should -BeOfType [long]
    }

    It 'converts 16 Mbit/s to exactly 2000000 bytes/s (the documented SEND_CEILING example)' {
        ConvertTo-BytesPerSecondFromMegabitsPerSecond -MegabitsPerSecond 16 | Should -Be 2000000
    }

    It 'converts 125000 bytes/s back to exactly 1.0 Mbit/s for display' {
        ConvertTo-MegabitsPerSecondFromBytesPerSecond -BytesPerSecond 125000 | Should -Be 1.0
    }

    It 'rounds bytes/s to Mbit/s display at 1 decimal, half-up' {
        # 187500 B/s = 1.5 Mbit/s exactly
        ConvertTo-MegabitsPerSecondFromBytesPerSecond -BytesPerSecond 187500 | Should -Be 1.5
        # 143750 B/s = 1.15 Mbit/s -> half-up rounds to 1.2, not banker's-rounds to 1.1
        ConvertTo-MegabitsPerSecondFromBytesPerSecond -BytesPerSecond 143750 | Should -Be 1.2
    }

    It 'keeps the raw stored bytes/s value lossless (no precision loss) regardless of display rounding' {
        $storedBytesPerSecond = [long] 2000000
        $displayMegabits = ConvertTo-MegabitsPerSecondFromBytesPerSecond -BytesPerSecond $storedBytesPerSecond

        $displayMegabits | Should -Be 16.0
        $storedBytesPerSecond | Should -Be 2000000
        $storedBytesPerSecond | Should -BeOfType [long]
    }
}

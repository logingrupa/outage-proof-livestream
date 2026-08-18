# Dashboard.Tests.ps1
# Unit tests for lib/Dashboard.psm1's Get-DashboardViewModel -- the pure function that
# answers "what should the operator see right now?" (D-10). Zero mocks are needed for
# the decision-branching tests: the function takes plain inputs and does no I/O, so
# every test below constructs its inputs directly and asserts the returned view model.
#
# Test numbering below matches 05-05-PLAN.md's <behavior> list verbatim so a reader can
# cross-reference the plan's rationale for each case (especially Test 7, "the one that
# matters" -- a deep-backoff pusher must never be misreported as lost contact).

BeforeAll {
    $script:DashboardModulePath = Join-Path $PSScriptRoot '../lib/Dashboard.psm1'

    function New-DashboardTestStats {
        <#
        .SYNOPSIS
        Builds a fresh, healthy stats payload (matching StatsStore.psm1's schema
        exactly, camelCase field names) at a given monotonic "now", with per-field
        overrides for the case under test.
        #>
        param(
            [Parameter(Mandatory)] [double] $NowMonotonicSeconds,
            [hashtable] $Overrides = @{}
        )

        $defaults = [ordered]@{
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
            updatedEpochSeconds      = $NowMonotonicSeconds
            staleAfterEpochSeconds   = $NowMonotonicSeconds + 3.0
        }
        foreach ($key in $Overrides.Keys) {
            $defaults[$key] = $Overrides[$key]
        }
        return [pscustomobject]$defaults
    }
}

Describe 'Dashboard' -Tag 'Quick' {

    BeforeEach {
        Remove-Module Dashboard -ErrorAction SilentlyContinue
        Import-Module $script:DashboardModulePath -Force
    }

    AfterEach {
        Remove-Module Dashboard -ErrorAction SilentlyContinue
    }

    Context 'Get-DashboardViewModel -- ConnectionState resolution' {

        It 'Test 1 (Idle): not alive, flag stopped, no stats -> Idle, Start enabled, Stop/Cut disabled, every stats-derived value null' {
            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $null -NowMonotonicSeconds 1.0

            $result.ConnectionState | Should -Be 'Idle'
            $result.StartEnabled | Should -BeTrue
            $result.StopEnabled | Should -BeFalse
            $result.CutEnabled | Should -BeFalse
            $result.DelaySecondsBehindLive | Should -BeNullOrEmpty
            $result.DrainEtaSeconds | Should -BeNullOrEmpty
            $result.SecondsSinceUpdate | Should -BeNullOrEmpty
            $result.SentBytes | Should -BeNullOrEmpty
            $result.PendingBytes | Should -BeNullOrEmpty
            $result.TotalBytes | Should -BeNullOrEmpty
            $result.SendBytesPerSecond | Should -BeNullOrEmpty
            $result.RecordBytesPerSecond | Should -BeNullOrEmpty
            $result.BackoffAttemptNumber | Should -BeNullOrEmpty
            $result.CumulativeReconnectCount | Should -BeNullOrEmpty
            $result.LastClassificationCause | Should -BeNullOrEmpty
            $result.CatchUpCapUtilization | Should -BeNullOrEmpty
            $result.OutageActive | Should -BeFalse
        }

        It 'Test 2 (Streaming): alive, flag streaming, fresh stats Streaming/not-outage -> Streaming, Start disabled, Stop/Cut enabled, delay passes through' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{ secondsBehindLive = 7.5 }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.ConnectionState | Should -Be 'Streaming'
            $result.StartEnabled | Should -BeFalse
            $result.StopEnabled | Should -BeTrue
            $result.CutEnabled | Should -BeTrue
            $result.DelaySecondsBehindLive | Should -Be 7.5
        }

        It 'Test 3 (Reconnecting): outageActive wins over pusherState=Streaming' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{ pusherState = 'Streaming'; outageActive = $true }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.ConnectionState | Should -Be 'Reconnecting'
            $result.StopEnabled | Should -BeTrue
            $result.CutEnabled | Should -BeTrue
            $result.StartEnabled | Should -BeFalse
        }

        It 'Test 4 (Draining): the operator already committed to stopping -- all three controls disabled' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{ pusherState = 'Draining' }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.ConnectionState | Should -Be 'Draining'
            $result.StartEnabled | Should -BeFalse
            $result.StopEnabled | Should -BeFalse
            $result.CutEnabled | Should -BeFalse
        }

        It 'Test 5 (Rotating renders as Streaming): a healthy mid-service event, never an error state' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{ pusherState = 'Rotating'; outageActive = $false }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.ConnectionState | Should -Be 'Streaming'
        }

        It 'Test 6 (Unknown by deadline): staleAfterEpochSeconds before now -> Unknown, delay and ETA both null' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{ staleAfterEpochSeconds = ($now - 1.0) }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.IsStale | Should -BeTrue
            $result.ConnectionState | Should -Be 'Unknown'
            $result.DelaySecondsBehindLive | Should -BeNullOrEmpty
            $result.DrainEtaSeconds | Should -BeNullOrEmpty
        }

        It 'Test 7 (the deep-backoff case that matters): stale-by-a-flat-rule but fresh-by-the-published-deadline stays Reconnecting' {
            $now = 1000.0
            # A pusher that declared a 33s quiet window before its backoff sleep:
            # updatedEpochSeconds 20s in the past, staleAfterEpochSeconds 13s in the future.
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{
                updatedEpochSeconds    = ($now - 20.0)
                staleAfterEpochSeconds = ($now + 13.0)
                outageActive           = $true
            }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.IsStale | Should -BeFalse -Because 'a flat 3s threshold would wrongly call this Unknown mid-backoff'
            $result.ConnectionState | Should -Be 'Reconnecting'
        }

        It 'Test 8 (stale but process dead): a dead pusher''s leftover stats file is normal Idle, not Unknown' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{ staleAfterEpochSeconds = ($now - 50.0) }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $stats -NowMonotonicSeconds $now

            $result.ConnectionState | Should -Be 'Idle'
        }

        It 'Test 9 (Finished, 260718-epo): not alive, clean-end-of-service SessionState, flag stopped -> Finished, SessionFinished=$true, calm Reason' {
            $now = 100.0
            $sessionState = [pscustomobject]@{ lastExitReason = 'clean-end-of-service' }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $null -NowMonotonicSeconds $now -SessionState $sessionState

            $result.ConnectionState | Should -Be 'Finished'
            $result.SessionFinished | Should -BeTrue
            $result.Reason | Should -Not -BeNullOrEmpty
            $result.Reason | Should -Not -Match 'Idle'
            $result.Reason | Should -Not -Match 'Unknown'
            $result.StartEnabled | Should -BeTrue
        }

        It 'Test 10 (Finished requires the flag to be stopped too): not alive, clean-end-of-service SessionState, but flag streaming -> stays Idle, not Finished' {
            $now = 100.0
            $sessionState = [pscustomobject]@{ lastExitReason = 'clean-end-of-service' }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $false -Stats $null -NowMonotonicSeconds $now -SessionState $sessionState

            $result.ConnectionState | Should -Be 'Idle'
            $result.SessionFinished | Should -BeFalse
        }

        It 'Test 11 (Idle unchanged for a $null SessionState): not alive, no session record at all -> Idle, not Finished' {
            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $null -NowMonotonicSeconds 1.0 -SessionState $null

            $result.ConnectionState | Should -Be 'Idle'
            $result.SessionFinished | Should -BeFalse
        }

        It 'Test 12 (Idle unchanged for a crash SessionState): not alive, lastExitReason=crash -> Idle, not Finished' {
            $now = 100.0
            $sessionState = [pscustomobject]@{ lastExitReason = 'crash' }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $null -NowMonotonicSeconds $now -SessionState $sessionState

            $result.ConnectionState | Should -Be 'Idle'
            $result.SessionFinished | Should -BeFalse
        }

        It 'a partial/older SessionState missing lastExitReason never throws and degrades to Idle' {
            $sessionState = [pscustomobject]@{ someOtherField = 'x' }

            { $script:result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $null -NowMonotonicSeconds 1.0 -SessionState $sessionState } | Should -Not -Throw
            $script:result.ConnectionState | Should -Be 'Idle'
        }

        It 'Test 13 (Front C/260718-j58): Finished with PendingBytes==0 -> calm Reason, never claims undelivered bytes' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{ offsetBytes = 8000; fileLengthBytes = 8000 }
            $sessionState = [pscustomobject]@{ lastExitReason = 'clean-end-of-service' }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $stats -NowMonotonicSeconds $now -SessionState $sessionState

            $result.ConnectionState | Should -Be 'Finished'
            $result.PendingBytes | Should -Be 0
            $result.Reason | Should -Match 'everything recorded was sent'
            $result.Reason | Should -Not -Match 'undelivered'
        }

        It 'Test 14 (Front C/260718-j58): Finished with PendingBytes>0 -> honest Reason naming the undelivered amount, never claims everything was sent' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{ offsetBytes = 1000000; fileLengthBytes = 6000000 }
            $sessionState = [pscustomobject]@{ lastExitReason = 'finished-with-undelivered-backlog' }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $stats -NowMonotonicSeconds $now -SessionState $sessionState

            $result.ConnectionState | Should -Be 'Finished'
            $result.SessionFinished | Should -BeTrue
            $result.PendingBytes | Should -Be 5000000
            $result.Reason | Should -Not -BeNullOrEmpty
            $result.Reason | Should -Not -Match 'everything recorded was sent'
            $result.Reason | Should -Match 'undelivered'
            $result.Reason | Should -Match '4.77MB'
        }

        It 'Test 15 (Front C/260718-j58): lastExitReason=finished-with-undelivered-backlog alone (no Stats at all) still resolves to Finished' {
            $now = 100.0
            $sessionState = [pscustomobject]@{ lastExitReason = 'finished-with-undelivered-backlog' }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $null -NowMonotonicSeconds $now -SessionState $sessionState

            $result.ConnectionState | Should -Be 'Finished'
            $result.SessionFinished | Should -BeTrue
            $result.Reason | Should -Not -BeNullOrEmpty
        }

        It 'Test 16 (WaitingForRecording, 260809-ow9/START-STALE-01): alive, fresh stats, pusherState WaitingForRecording -> distinct state, Stop/Cut stay enabled, honest Reason' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{ pusherState = 'WaitingForRecording' }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.ConnectionState | Should -Be 'WaitingForRecording'
            $result.StartEnabled | Should -BeFalse
            $result.StopEnabled | Should -BeTrue
            $result.CutEnabled | Should -BeTrue
            $result.Reason | Should -Match 'waiting'
            $result.Reason | Should -Match 'not currently growing|not currently sending|not sending'
        }

        It 'Test 17 (WaitingForRecording, 260809-ow9/START-STALE-01): outageActive still wins over pusherState=WaitingForRecording (precedence unchanged)' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{ pusherState = 'WaitingForRecording'; outageActive = $true }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.ConnectionState | Should -Be 'Reconnecting'
        }
    }

    Context 'Get-DashboardViewModel -- LiveUptimeSeconds / SessionDurationSeconds (260718-epo/FEAT-B)' {

        It 'LiveUptimeSeconds is positive while alive and fresh with a sessionStartEpochSeconds' {
            $now = 500.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{ sessionStartEpochSeconds = ($now - 42.0) }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.LiveUptimeSeconds | Should -Be 42.0
        }

        It 'LiveUptimeSeconds is $null when not alive' {
            $now = 500.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{ sessionStartEpochSeconds = ($now - 42.0) }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $stats -NowMonotonicSeconds $now

            $result.LiveUptimeSeconds | Should -BeNullOrEmpty
        }

        It 'LiveUptimeSeconds is $null when stale, even if alive' {
            $now = 500.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{
                sessionStartEpochSeconds = ($now - 42.0)
                staleAfterEpochSeconds   = ($now - 1.0)
            }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.LiveUptimeSeconds | Should -BeNullOrEmpty
        }

        It 'LiveUptimeSeconds is $null when sessionStartEpochSeconds is absent from the payload (older/partial build)' {
            $now = 500.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.LiveUptimeSeconds | Should -BeNullOrEmpty
        }

        It 'SessionDurationSeconds is computed from updatedEpochSeconds minus sessionStartEpochSeconds and SURVIVES staleness (the finished screen needs it after the pusher stops)' {
            $now = 1000.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{
                sessionStartEpochSeconds = ($now - 300.0)
                updatedEpochSeconds      = ($now - 5.0)
                staleAfterEpochSeconds   = ($now - 999.0)
            }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $stats -NowMonotonicSeconds $now

            $result.IsStale | Should -BeTrue
            $result.SessionDurationSeconds | Should -Be 295.0
        }

        It 'SessionDurationSeconds is $null when either half of the calculation is missing' {
            $now = 1000.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.SessionDurationSeconds | Should -BeNullOrEmpty
        }
    }

    Context 'Get-DashboardViewModel -- NewRecordingDetected (260718-epo/FEAT-C)' {

        It 'NewRecordingDetected is $true with NewRecordingFilePath set when SessionState carries a non-empty newRecordingDetectedFilePath' {
            $sessionState = [pscustomobject]@{ lastExitReason = 'clean-end-of-service'; newRecordingDetectedFilePath = 'D:\obs_streaming\new.ts' }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $null -NowMonotonicSeconds 1.0 -SessionState $sessionState

            $result.NewRecordingDetected | Should -BeTrue
            $result.NewRecordingFilePath | Should -Be 'D:\obs_streaming\new.ts'
        }

        It 'NewRecordingDetected is $false and NewRecordingFilePath is $null when the field is absent' {
            $sessionState = [pscustomobject]@{ lastExitReason = 'clean-end-of-service' }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $null -NowMonotonicSeconds 1.0 -SessionState $sessionState

            $result.NewRecordingDetected | Should -BeFalse
            $result.NewRecordingFilePath | Should -BeNullOrEmpty
        }

        It 'NewRecordingDetected is $false when SessionState itself is $null' {
            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $null -NowMonotonicSeconds 1.0 -SessionState $null

            $result.NewRecordingDetected | Should -BeFalse
        }
    }

    Context 'Get-DashboardViewModel -- drain ETA honesty (D-13: never fabricated)' {

        It 'Test 9 (DrainEta honest): pending / send rate, computed exactly' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{
                sendBytesPerSecond = 1000.0
                fileLengthBytes    = 11000
                offsetBytes        = 1000
            }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.DrainEtaSeconds | Should -Be 10.0
        }

        It 'Test 10a (DrainEta degrades to null when send rate is zero)' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{ sendBytesPerSecond = 0.0 }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.DrainEtaSeconds | Should -BeNullOrEmpty
        }

        It 'Test 10b (DrainEta degrades to null when stale)' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{ staleAfterEpochSeconds = ($now - 1.0) }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.DrainEtaSeconds | Should -BeNullOrEmpty
        }

        It 'Test 10c (DrainEta degrades to null when the pusher is not alive, per D-13)' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $stats -NowMonotonicSeconds $now

            $result.DrainEtaSeconds | Should -BeNullOrEmpty
        }

        It 'Test 11 (DrainEta never negative): a resume-margin rewind (offset > length) floors to zero, not negative' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{
                offsetBytes        = 5000
                fileLengthBytes    = 4000
                sendBytesPerSecond = 1000.0
            }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.PendingBytes | Should -Be 0
            $result.DrainEtaSeconds | Should -Be 0.0
        }
    }

    Context 'Get-DashboardViewModel -- byte accounting' {

        It 'Test 12 (SentBytes/PendingBytes/TotalBytes): derived directly from offset/length' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{
                offsetBytes     = 3000
                fileLengthBytes = 8000
            }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.SentBytes | Should -Be 3000
            $result.PendingBytes | Should -Be 5000
            $result.TotalBytes | Should -Be 8000
        }
    }

    Context 'Get-DashboardViewModel -- purity and StrictMode safety' {

        It 'Test 13 (no I/O): still returns a view model with every I/O cmdlet mocked to throw' {
            Mock -CommandName Get-CimInstance -MockWith { throw 'I/O attempted -- purity violated' }
            Mock -CommandName Test-Path -MockWith { throw 'I/O attempted -- purity violated' }
            Mock -CommandName Get-Content -MockWith { throw 'I/O attempted -- purity violated' }
            Mock -CommandName Get-Date -MockWith { throw 'I/O attempted -- purity violated' }

            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now

            { $script:result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now } | Should -Not -Throw
            $script:result.ConnectionState | Should -Be 'Streaming'
        }

        It 'purity is structural: the PURE decision/routing functions reference none of the forbidden I/O cmdlets outside comments' {
            # 05-07 widened this module to also own the HTTP surface (Invoke-
            # DashboardRequestHandler, the listener lifecycle) -- those functions are
            # DELIBERATELY not pure (module header, 05-07-PLAN.md Task 2). This check is
            # scoped via the AST to exactly the functions the module header still
            # promises are I/O-free, rather than the whole file, so it keeps testing the
            # thing it was written to test instead of going stale the moment the module
            # legitimately grew a second responsibility.
            $tokens = $null
            $parseErrors = $null
            $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:DashboardModulePath, [ref] $tokens, [ref] $parseErrors)
            $parseErrors.Count | Should -Be 0 -Because 'the module must parse cleanly before purity can even be checked'

            $pureFunctionNames = @(
                'Get-DashboardViewModel',
                'Test-DashboardStatsHasProperty',
                'Test-DashboardRequestOrigin',
                'Test-RecordingFileDeletable',
                'Resolve-DashboardStaticPath',
                'Get-DashboardContentType',
                'Get-DashboardRouteMatch',
                'Get-ProbePanelViewModel'
            )
            $functionAsts = $moduleAst.FindAll(
                { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $pureFunctionNames -contains $node.Name },
                $true)

            $functionAsts.Count | Should -Be $pureFunctionNames.Count -Because 'every pure function must still exist under its exact name'

            foreach ($functionAst in $functionAsts) {
                $bodyLines = ($functionAst.Extent.Text -split "`n") | Where-Object { $_ -notmatch '^\s*#' }
                $forbiddenMatches = $bodyLines | Select-String -Pattern 'Get-Date|Get-CimInstance|Test-Path|Get-Content|Write-Log|Import-Module|ReadAllBytes|ReadAllText|HttpListener'
                $forbiddenMatches.Count | Should -Be 0 -Because "function '$($functionAst.Name)' must stay pure (no I/O)"
            }
        }

        It 'Test 14 (StrictMode-safe against a partial payload): a schemaVersion-0 payload missing fields never throws and degrades to Unknown' {
            $now = 100.0
            $partialStats = [pscustomobject]@{
                pusherState  = 'Streaming'
                outageActive = $false
                # No updatedEpochSeconds / staleAfterEpochSeconds / offsetBytes / etc --
                # simulates an older build's payload shape.
            }

            { $script:result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $partialStats -NowMonotonicSeconds $now } | Should -Not -Throw
            $script:result.ConnectionState | Should -Be 'Unknown'
        }

        It 'the returned object serializes to valid JSON (it is the /api/stats response body, D-26)' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now
            $json = $result | ConvertTo-Json -Compress

            { $json | ConvertFrom-Json } | Should -Not -Throw
        }
    }

    # 06-06-PLAN.md Task 1: Get-ProbePanelViewModel is the pure staleness/status
    # normaliser that mirrors Get-DashboardViewModel's own purity contract -- no I/O, no
    # clock read (now is passed in), no logging -- so the ApiStats probes[] fold (Task
    # 2) can trust it exactly the way it already trusts Get-DashboardViewModel.
    # Get-ProbeResultsForDashboard is the edge-I/O sibling (06-06's other new function);
    # its zero-plugin/never-$null contract is unit-tested here directly, and its
    # end-to-end fold + corrupt-file resilience is proven through the real HTTP handler
    # in the 'ApiStats probes fold' context below.
    Context 'Get-ProbePanelViewModel (06-06: pure probe-panel normaliser, D-07)' {

        It 'a fresh probe (now <= staleAfterEpochSeconds) passes through with its true status; metrics preserved' {
            $now = 100.0
            $probeResult = [pscustomobject]@{
                schemaVersion          = 1
                name                   = 'vps-relay'
                title                  = 'VPS Relay'
                status                 = 'ok'
                metrics                = @(@{ label = 'Latency'; value = 42; unit = 'ms' })
                detail                 = $null
                updatedEpochSeconds    = $now
                staleAfterEpochSeconds = $now + 30.0
            }

            $result = Get-ProbePanelViewModel -ProbeResult $probeResult -NowMonotonicSeconds $now

            $result.name | Should -Be 'vps-relay'
            $result.title | Should -Be 'VPS Relay'
            $result.status | Should -Be 'ok'
            $result.metrics.Count | Should -Be 1
            $result.metrics[0].label | Should -Be 'Latency'
            $result.detail | Should -BeNullOrEmpty
        }

        It 'a stale probe (now > staleAfterEpochSeconds) is normalised to status=unknown regardless of its last-known status, with a last-update-age marker' {
            $now = 1000.0
            $probeResult = [pscustomobject]@{
                schemaVersion          = 1
                name                   = 'vps-relay'
                title                  = 'VPS Relay'
                status                 = 'ok'
                metrics                = @(@{ label = 'Latency'; value = 42; unit = 'ms' })
                detail                 = $null
                updatedEpochSeconds    = ($now - 90.0)
                staleAfterEpochSeconds = ($now - 30.0)
            }

            $result = Get-ProbePanelViewModel -ProbeResult $probeResult -NowMonotonicSeconds $now

            $result.status | Should -Be 'unknown' -Because 'a stale probe must never render as its last-known live status (D-07)'
            $result.lastUpdateAgeSeconds | Should -Be 90.0 -Because 'the client renders "stale -- last update Ns ago" from now - updatedEpochSeconds'
        }

        It 'a degraded-but-fresh probe passes its true status through unchanged (only staleness forces unknown)' {
            $now = 100.0
            $probeResult = [pscustomobject]@{
                schemaVersion          = 1
                name                   = 'vps-relay'
                title                  = 'VPS Relay'
                status                 = 'degraded'
                metrics                = @()
                detail                 = 'high latency'
                updatedEpochSeconds    = $now
                staleAfterEpochSeconds = $now + 30.0
            }

            $result = Get-ProbePanelViewModel -ProbeResult $probeResult -NowMonotonicSeconds $now

            $result.status | Should -Be 'degraded'
            $result.detail | Should -Be 'high latency'
            $result.lastUpdateAgeSeconds | Should -BeNullOrEmpty -Because 'never fabricate an age marker while the probe is genuinely fresh'
        }

        It 'performs NO I/O, NO clock read, NO logging (now is passed in) -- mirrors Get-DashboardViewModel''s purity contract' {
            Mock -CommandName Get-CimInstance -MockWith { throw 'I/O attempted -- purity violated' }
            Mock -CommandName Test-Path -MockWith { throw 'I/O attempted -- purity violated' }
            Mock -CommandName Get-Content -MockWith { throw 'I/O attempted -- purity violated' }
            Mock -CommandName Get-Date -MockWith { throw 'I/O attempted -- purity violated' }

            $now = 100.0
            $probeResult = [pscustomobject]@{
                schemaVersion          = 1
                name                   = 'vps-relay'
                title                  = 'VPS Relay'
                status                 = 'ok'
                metrics                = @()
                detail                 = $null
                updatedEpochSeconds    = $now
                staleAfterEpochSeconds = $now + 30.0
            }

            { $script:result = Get-ProbePanelViewModel -ProbeResult $probeResult -NowMonotonicSeconds $now } | Should -Not -Throw
            $script:result.status | Should -Be 'ok'
        }
    }

    # 06-06-PLAN.md Task 1: Get-ProbeResultsForDashboard is the edge I/O reader --
    # zero/absent probes directory must return an empty array, NEVER $null (PowerShell
    # array-return safety convention, D-14 elsewhere in this repo), so the ApiStats fold
    # can always safely serialize `probes` as `[]`.
    Context 'Get-ProbeResultsForDashboard (06-06: edge I/O reader, MON-04 zero-plugin)' {

        It 'an absent state/probes directory returns an empty array, never $null' {
            $absentProbesDirectory = Join-Path $TestDrive ([Guid]::NewGuid())

            $result = Get-ProbeResultsForDashboard -ProbesDirectory $absentProbesDirectory -NowMonotonicSeconds 100.0

            ($null -eq $result) | Should -BeFalse -Because 'MON-04 requires probes==[] on the wire, never a null that would serialize to JSON null'
            @($result).Count | Should -Be 0
        }

        It 'an existing but empty state/probes directory also returns an empty array, never $null' {
            $emptyProbesDirectory = Join-Path $TestDrive ([Guid]::NewGuid())
            New-Item -ItemType Directory -Path $emptyProbesDirectory -Force | Out-Null

            $result = Get-ProbeResultsForDashboard -ProbesDirectory $emptyProbesDirectory -NowMonotonicSeconds 100.0

            ($null -eq $result) | Should -BeFalse
            @($result).Count | Should -Be 0
        }
    }

    # 05.1-03-PLAN.md Task 1: SESS-02's view-model fields -- which file is being
    # followed, and whether it is actually growing right now (vs. a static/old file),
    # both never fabricated per D-13.
    Context 'Get-DashboardViewModel -- RecordingFilePath / RecordingFileGrowing (SESS-02, D-13)' {

        It 'Test 15 (growing): alive, fresh, recordBytesPerSecond>0 -> path exposed, growing true' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{
                recordingFilePath    = 'D:\recording.ts'
                recordBytesPerSecond = 500.0
            }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.RecordingFilePath | Should -Be 'D:\recording.ts'
            $result.RecordingFileGrowing | Should -BeTrue
        }

        It 'Test 16 (static): alive, fresh, recordBytesPerSecond == 0 -> path still exposed, growing false' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{
                recordingFilePath    = 'D:\recording.ts'
                recordBytesPerSecond = 0.0
            }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.RecordingFilePath | Should -Be 'D:\recording.ts'
            $result.RecordingFileGrowing | Should -BeFalse
        }

        It 'Test 17a (never fabricated): Stats = $null -> RecordingFilePath null, RecordingFileGrowing false' {
            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $null -NowMonotonicSeconds 1.0

            $result.RecordingFilePath | Should -BeNullOrEmpty
            $result.RecordingFileGrowing | Should -BeFalse
        }

        It 'Test 17b (never fabricated): stale stats -> RecordingFilePath null, RecordingFileGrowing false, even though the payload has a path' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{
                recordingFilePath      = 'D:\recording.ts'
                staleAfterEpochSeconds = ($now - 1.0)
            }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.RecordingFilePath | Should -BeNullOrEmpty
            $result.RecordingFileGrowing | Should -BeFalse
        }
    }

    Context 'Get-DashboardViewModel -- LastSuccessfulSendAgeSeconds (DASH-08, D-13: never fabricated)' {

        It 'alive, fresh, field present and numeric -> age equals Now minus the published epoch' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{
                lastSuccessfulSendEpochSeconds = ($now - 4.0)
            }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.LastSuccessfulSendAgeSeconds | Should -Be 4.0
        }

        It 'field absent (never sent yet, or an older/partial build) -> null, never a fabricated 0' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.LastSuccessfulSendAgeSeconds | Should -BeNullOrEmpty
        }

        It 'stats stale -> null even though the payload carries a value' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{
                lastSuccessfulSendEpochSeconds = ($now - 4.0)
                staleAfterEpochSeconds         = ($now - 1.0)
            }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.LastSuccessfulSendAgeSeconds | Should -BeNullOrEmpty
        }

        It 'pusher not alive -> null even though the payload carries a value' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{
                lastSuccessfulSendEpochSeconds = ($now - 4.0)
            }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'stopped' -PusherProcessAlive $false -Stats $stats -NowMonotonicSeconds $now

            $result.LastSuccessfulSendAgeSeconds | Should -BeNullOrEmpty
        }

        It 'field present but $null (never sent yet) -> stays null, never coerced to a numeric age' {
            $now = 100.0
            $stats = New-DashboardTestStats -NowMonotonicSeconds $now -Overrides @{
                lastSuccessfulSendEpochSeconds = $null
            }

            $result = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $stats -NowMonotonicSeconds $now

            $result.LastSuccessfulSendAgeSeconds | Should -BeNullOrEmpty
        }
    }

    # 05.1-03-PLAN.md Task 1: SESS-04's delete-eligibility guard -- the live/newest
    # recording file must never be deletable, unconditionally (D-07). Pure: no
    # filesystem access, the caller resolves NewestMatchingFile via
    # Rotation.psm1's Get-NewestMatchingRecordingFile and passes it in.
    Context 'Test-RecordingFileDeletable (SESS-04, D-07)' {

        It 'Test 18a: candidate equal to the newest file (case-insensitive) is NOT deletable' {
            $newest = [pscustomobject]@{ FullName = 'D:\recordings\2026-07-16.ts' }
            Test-RecordingFileDeletable -CandidateFileFullName 'd:\recordings\2026-07-16.ts' -NewestMatchingFile $newest | Should -BeFalse
        }

        It 'Test 18b: candidate different from the newest file is deletable' {
            $newest = [pscustomobject]@{ FullName = 'D:\recordings\2026-07-16.ts' }
            Test-RecordingFileDeletable -CandidateFileFullName 'D:\recordings\2026-07-15.ts' -NewestMatchingFile $newest | Should -BeTrue
        }

        It 'Test 18c: an empty folder (NewestMatchingFile is $null) makes any candidate deletable' {
            Test-RecordingFileDeletable -CandidateFileFullName 'D:\recordings\2026-07-16.ts' -NewestMatchingFile $null | Should -BeTrue
        }
    }

    # 05-07-PLAN.md Task 1: pure routing helpers (route match, content type, path
    # resolution, origin check) -- zero HttpListener in scope, matching this module's
    # established purity convention for everything except Task 2's HTTP handler.
    Context 'Test-DashboardRequestOrigin (T-05-01 CSRF gate)' {

        It 'Test 1: returns $true when Origin is exactly http://localhost:8787 and DashboardPort is 8787' {
            Test-DashboardRequestOrigin -OriginHeader 'http://localhost:8787' -SecFetchSiteHeader $null -DashboardPort 8787 | Should -BeTrue
        }

        It 'Test 2a: returns $false for an unrelated Origin' {
            Test-DashboardRequestOrigin -OriginHeader 'http://evil.example.com' -SecFetchSiteHeader $null -DashboardPort 8787 | Should -BeFalse
        }

        It 'Test 2b: returns $false for the right host but wrong port' {
            Test-DashboardRequestOrigin -OriginHeader 'http://localhost:9999' -SecFetchSiteHeader $null -DashboardPort 8787 | Should -BeFalse
        }

        It 'Test 2c: returns $false for the right host/port but wrong scheme' {
            Test-DashboardRequestOrigin -OriginHeader 'https://localhost:8787' -SecFetchSiteHeader $null -DashboardPort 8787 | Should -BeFalse
        }

        It 'Test 2d: an exact-equality compare rejects a suffix-extended Origin (never StartsWith)' {
            Test-DashboardRequestOrigin -OriginHeader 'http://localhost:8787.evil.com' -SecFetchSiteHeader $null -DashboardPort 8787 | Should -BeFalse
        }

        It 'Test 3: returns $true when Origin is absent AND Sec-Fetch-Site is same-origin' {
            Test-DashboardRequestOrigin -OriginHeader $null -SecFetchSiteHeader 'same-origin' -DashboardPort 8787 | Should -BeTrue
        }

        It 'Test 4: returns $false when Origin is absent and Sec-Fetch-Site is cross-site' {
            Test-DashboardRequestOrigin -OriginHeader $null -SecFetchSiteHeader 'cross-site' -DashboardPort 8787 | Should -BeFalse
        }

        It 'Test 5 (fail closed -- deliberate): returns $false when BOTH Origin and Sec-Fetch-Site are absent' {
            Test-DashboardRequestOrigin -OriginHeader $null -SecFetchSiteHeader $null -DashboardPort 8787 | Should -BeFalse
        }

        It 'Test 5b: also fails closed on empty-string headers, not just $null' {
            Test-DashboardRequestOrigin -OriginHeader '' -SecFetchSiteHeader '' -DashboardPort 8787 | Should -BeFalse
        }
    }

    Context 'Resolve-DashboardStaticPath (T-05-02 traversal guard)' {

        BeforeEach {
            $script:DashboardRootTestPath = Join-Path $TestDrive ([Guid]::NewGuid())
            New-Item -ItemType Directory -Path $script:DashboardRootTestPath -Force | Out-Null
        }

        It 'Test 6a: ../.env is refused ($null)' {
            Resolve-DashboardStaticPath -RequestPath '/../.env' -DashboardRootPath $script:DashboardRootTestPath | Should -BeNullOrEmpty
        }

        It 'Test 6b: URL-encoded traversal (%2e%2e%2f) is refused -- decode happens BEFORE the boundary check' {
            Resolve-DashboardStaticPath -RequestPath '/%2e%2e%2f%2e%2e%2fpusher.ps1' -DashboardRootPath $script:DashboardRootTestPath | Should -BeNullOrEmpty
        }

        It 'Test 6c: ../../pusher.ps1 is refused' {
            Resolve-DashboardStaticPath -RequestPath '/../../pusher.ps1' -DashboardRootPath $script:DashboardRootTestPath | Should -BeNullOrEmpty
        }

        It 'Test 6d: an absolute drive path smuggled into the request path is refused' {
            Resolve-DashboardStaticPath -RequestPath '/C:/Windows/win.ini' -DashboardRootPath $script:DashboardRootTestPath | Should -BeNullOrEmpty
        }

        It 'Test 7: / resolves to index.html under the dashboard root' {
            $resolved = Resolve-DashboardStaticPath -RequestPath '/' -DashboardRootPath $script:DashboardRootTestPath
            $resolved | Should -Be (Join-Path $script:DashboardRootTestPath 'index.html')
        }

        It 'Test 8a: /app.js resolves inside the dashboard root' {
            $resolved = Resolve-DashboardStaticPath -RequestPath '/app.js' -DashboardRootPath $script:DashboardRootTestPath
            $resolved | Should -Be (Join-Path $script:DashboardRootTestPath 'app.js')
        }

        It 'Test 8b: a sibling directory whose name merely starts with the root name is refused (trailing-separator subtlety)' {
            $siblingLikeName = "$script:DashboardRootTestPath-secrets"
            $requestPath = '/../' + (Split-Path -Leaf $siblingLikeName) + '/x'
            Resolve-DashboardStaticPath -RequestPath $requestPath -DashboardRootPath $script:DashboardRootTestPath | Should -BeNullOrEmpty
        }

        It 'rejects a null byte in the request path' {
            Resolve-DashboardStaticPath -RequestPath "/app.js`0.txt" -DashboardRootPath $script:DashboardRootTestPath | Should -BeNullOrEmpty
        }

        It 'never throws on a malformed request path' {
            { Resolve-DashboardStaticPath -RequestPath '/%zz%zz' -DashboardRootPath $script:DashboardRootTestPath } | Should -Not -Throw
        }
    }

    Context 'Get-DashboardContentType' {

        It 'Test 9a: .html maps to text/html; charset=utf-8' {
            Get-DashboardContentType -Path 'C:\x\index.html' | Should -Be 'text/html; charset=utf-8'
        }

        It 'Test 9b: .js maps to text/javascript; charset=utf-8' {
            Get-DashboardContentType -Path 'C:\x\app.js' | Should -Be 'text/javascript; charset=utf-8'
        }

        It 'Test 9c: .css maps to text/css; charset=utf-8' {
            Get-DashboardContentType -Path 'C:\x\app.css' | Should -Be 'text/css; charset=utf-8'
        }

        It 'Test 9d: an unknown extension maps to application/octet-stream' {
            Get-DashboardContentType -Path 'C:\x\favicon.ico' | Should -Be 'application/octet-stream'
        }
    }

    Context 'Get-DashboardRouteMatch' {

        It 'Test 10a: (GET, /) -> StaticFile' {
            Get-DashboardRouteMatch -HttpMethod 'GET' -UrlPath '/' | Should -Be 'StaticFile'
        }

        It 'Test 10b: (GET, /api/stats) -> ApiStats' {
            Get-DashboardRouteMatch -HttpMethod 'GET' -UrlPath '/api/stats' | Should -Be 'ApiStats'
        }

        It 'Test 10c: (POST, /api/control) -> ApiControl' {
            Get-DashboardRouteMatch -HttpMethod 'POST' -UrlPath '/api/control' | Should -Be 'ApiControl'
        }

        It 'Test 10d: (POST, /api/config) -> ApiConfig' {
            Get-DashboardRouteMatch -HttpMethod 'POST' -UrlPath '/api/config' | Should -Be 'ApiConfig'
        }

        It 'Test 10e: (GET, /api/config) -> ApiConfigRead' {
            Get-DashboardRouteMatch -HttpMethod 'GET' -UrlPath '/api/config' | Should -Be 'ApiConfigRead'
        }

        It 'Test 10f: (GET, /nope.js) -> StaticFile (unknown paths fall through, the handler 404s)' {
            Get-DashboardRouteMatch -HttpMethod 'GET' -UrlPath '/nope.js' | Should -Be 'StaticFile'
        }

        It 'Test 10g: (DELETE, /api/stats) -> MethodNotAllowed (never silently falls through to StaticFile)' {
            Get-DashboardRouteMatch -HttpMethod 'DELETE' -UrlPath '/api/stats' | Should -Be 'MethodNotAllowed'
        }

        It 'Test 10h: (GET, /api/control) -> MethodNotAllowed, not a 404 -- the route exists' {
            Get-DashboardRouteMatch -HttpMethod 'GET' -UrlPath '/api/control' | Should -Be 'MethodNotAllowed'
        }

        It 'Test 10i (05.1-03): (GET, /api/recordings) -> ApiRecordings' {
            Get-DashboardRouteMatch -HttpMethod 'GET' -UrlPath '/api/recordings' | Should -Be 'ApiRecordings'
        }

        It 'Test 10j (05.1-03): (POST, /api/recordings) -> MethodNotAllowed, not a 404 -- the route exists' {
            Get-DashboardRouteMatch -HttpMethod 'POST' -UrlPath '/api/recordings' | Should -Be 'MethodNotAllowed'
        }

        It 'Test 10k (05.1-04): (POST, /api/recordings/delete) -> ApiRecordingsDelete' {
            Get-DashboardRouteMatch -HttpMethod 'POST' -UrlPath '/api/recordings/delete' | Should -Be 'ApiRecordingsDelete'
        }

        It 'Test 10l (05.1-04): (GET, /api/recordings/delete) -> MethodNotAllowed, not a 404 -- the route exists' {
            Get-DashboardRouteMatch -HttpMethod 'GET' -UrlPath '/api/recordings/delete' | Should -Be 'MethodNotAllowed'
        }
    }
}

# 05-07-PLAN.md Task 2: the request handler -- /api/stats, /api/control, /api/config,
# static files. Invoke-DashboardRequestHandler wires the pure Task 1 functions to the
# existing modules (ControlFlag, PusherProcess, StatsStore, Clock, Config) and I/O; it
# takes an untyped -Context (duck-typed against a fake HttpListenerContext below) rather
# than a literal [HttpListenerContext] parameter type, since that .NET type has no
# public constructor and could not otherwise be unit-tested without a real listener --
# a real HttpListenerContext satisfies the same shape in production (05-09), so this is
# a testability seam, not a behavior change.
Describe 'Invoke-DashboardRequestHandler' -Tag 'Quick' {

    BeforeAll {
        $script:LoggingModulePath = Join-Path $PSScriptRoot '../lib/Logging.psm1'
        $script:ControlFlagModulePath = Join-Path $PSScriptRoot '../lib/ControlFlag.psm1'
        $script:PusherProcessModulePath = Join-Path $PSScriptRoot '../lib/PusherProcess.psm1'
        $script:StatsStoreModulePath = Join-Path $PSScriptRoot '../lib/StatsStore.psm1'
        $script:ClockModulePath = Join-Path $PSScriptRoot '../lib/Clock.psm1'
        $script:ConfigModulePath = Join-Path $PSScriptRoot '../lib/Config.psm1'
        $script:ProbeStoreModulePath = Join-Path $PSScriptRoot '../lib/ProbeStore.psm1'
        $script:SessionStateModulePath = Join-Path $PSScriptRoot '../lib/SessionState.psm1'
        $script:CutScriptPath = Join-Path $PSScriptRoot '../cut.ps1'

        function New-FakeDashboardContext {
            <#
            .SYNOPSIS
            Builds a duck-typed stand-in for [System.Net.HttpListenerContext] (which has no
            public constructor, so it cannot be instantiated directly for a unit test): a
            plain object exposing exactly the .Request/.Response members the handler reads
            or writes, backed by real System.IO.MemoryStream instances so body read/write
            actually works, not merely a recorded call.
            #>
            param(
                [string] $HttpMethod = 'GET',
                [string] $Path = '/',
                [hashtable] $Headers = @{},
                [byte[]] $BodyBytes = @()
            )

            $requestHeaders = [System.Collections.Specialized.NameValueCollection]::new()
            foreach ($key in $Headers.Keys) {
                $requestHeaders.Add($key, [string] $Headers[$key])
            }

            $request = [pscustomobject]@{
                HttpMethod  = $HttpMethod
                Url         = [System.Uri]::new("http://localhost:8787$Path")
                Headers     = $requestHeaders
                InputStream = [System.IO.MemoryStream]::new([byte[]] $BodyBytes)
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

        function Get-FakeContextResponseBody {
            param($Context)
            $Context.Response.OutputStream.Position = 0
            $reader = [System.IO.StreamReader]::new($Context.Response.OutputStream, [System.Text.Encoding]::UTF8, $false, 1024, $true)
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
    }

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Dashboard -ErrorAction SilentlyContinue
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module PusherProcess -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module ProbeStore -ErrorAction SilentlyContinue
        Remove-Module SessionState -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue

        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:ControlFlagModulePath -Force
        Import-Module $script:PusherProcessModulePath -Force
        Import-Module $script:StatsStoreModulePath -Force
        Import-Module $script:ClockModulePath -Force
        Import-Module $script:ConfigModulePath -Force
        Import-Module $script:ProbeStoreModulePath -Force
        Import-Module $script:SessionStateModulePath -Force
        Import-Module $script:DashboardModulePath -Force

        # Stop-PusherProcesses is top-level in cut.ps1 (never a module, D-08's own
        # convention -- see cut.ps1's header), so it is brought into scope here the same
        # way 05-09 brings it into supervisor.ps1's session: dot-source, never a copy
        # (DRY). The bottom `if ($MyInvocation.InvocationName -ne '.')` guard keeps the
        # real kill from ever running under dot-sourcing. Copied explicitly into GLOBAL
        # scope (not just this BeforeEach block's local scope) because that is where it
        # actually lands in production: supervisor.ps1 dot-sources cut.ps1 at its own
        # top level, which for a script run directly by pwsh IS the runspace's global
        # scope -- and a command called from inside an imported module (Dashboard.psm1)
        # only resolves against a caller's GLOBAL functions, never a nested scriptblock's
        # local ones. Test 4/6's Mock -ModuleName Dashboard replaces this global function
        # from inside the module's own session state, exactly as it will for the real one.
        . $script:CutScriptPath
        Set-Item -Path 'function:global:Stop-PusherProcesses' -Value (Get-Item 'function:Stop-PusherProcesses').ScriptBlock

        $script:HandlerTestRoot = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:HandlerTestRoot -Force | Out-Null
        $script:DashboardRootPath = Join-Path $script:HandlerTestRoot 'dashboard'
        New-Item -ItemType Directory -Path $script:DashboardRootPath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:DashboardRootPath 'index.html') -Value '<html>dashboard</html>' -Encoding utf8 -NoNewline

        $script:ControlFilePath = Join-Path $script:HandlerTestRoot 'control.json'
        $script:StatsFilePath = Join-Path $script:HandlerTestRoot 'stats.json'
        $script:EnvFilePath = Join-Path $script:HandlerTestRoot '.env'
        $script:DashboardPort = 8787

        $script:HandlerParams = @{
            ScriptRoot        = $script:HandlerTestRoot
            ControlFilePath   = $script:ControlFilePath
            StatsFilePath     = $script:StatsFilePath
            DashboardRootPath = $script:DashboardRootPath
            EnvFilePath       = $script:EnvFilePath
            DashboardPort     = $script:DashboardPort
        }
    }

    AfterEach {
        Pop-Location
        Remove-Module Dashboard -ErrorAction SilentlyContinue
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module PusherProcess -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module ProbeStore -ErrorAction SilentlyContinue
        Remove-Module SessionState -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
    }

    Context 'ApiStats (GET /api/stats)' {

        It 'Test 1: returns 200, application/json, and a body built from the mocked reads via Get-DashboardViewModel' {
            Mock Read-PusherStats -ModuleName Dashboard { return [pscustomobject]@{ pusherState = 'Streaming' } }
            Mock Get-PusherDesiredState -ModuleName Dashboard { return 'streaming' }
            Mock Test-PusherProcessAlive -ModuleName Dashboard { return $true }
            Mock Get-MonotonicSeconds -ModuleName Dashboard { return 42.0 }
            Mock Get-DashboardViewModel -ModuleName Dashboard {
                return [pscustomobject]@{ ConnectionState = 'Streaming'; StartEnabled = $false }
            }

            $context = New-FakeDashboardContext -HttpMethod 'GET' -Path '/api/stats'
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 200
            $context.Response.ContentType | Should -Be 'application/json'
            $body = Get-FakeContextResponseBody -Context $context
            ($body | ConvertFrom-Json).ConnectionState | Should -Be 'Streaming'

            Should -Invoke Get-DashboardViewModel -ModuleName Dashboard -Times 1 -Exactly -ParameterFilter {
                $ControlFlagDesiredState -eq 'streaming' -and $PusherProcessAlive -eq $true -and $NowMonotonicSeconds -eq 42.0
            }
        }

        It 'Test 13 (260718-epo): reads state/session.json via Read-SessionState and feeds it into Get-DashboardViewModel' {
            Mock Read-PusherStats -ModuleName Dashboard { return $null }
            Mock Get-PusherDesiredState -ModuleName Dashboard { return 'stopped' }
            Mock Test-PusherProcessAlive -ModuleName Dashboard { return $false }
            Mock Get-MonotonicSeconds -ModuleName Dashboard { return 42.0 }

            $sessionStateFilePath = Join-Path $script:HandlerTestRoot 'state/session.json'
            Save-SessionState -SessionStateFilePath $sessionStateFilePath -LastExitReason 'clean-end-of-service' -LastExitEpochSeconds 40.0

            $context = New-FakeDashboardContext -HttpMethod 'GET' -Path '/api/stats'
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 200
            $body = Get-FakeContextResponseBody -Context $context
            # Real (unmocked) Get-DashboardViewModel is exercised end-to-end here: a
            # 'Finished' ConnectionState is only reachable when the handler actually
            # read state/session.json and threaded lastExitReason='clean-end-of-service'
            # through -SessionState -- proving the wiring, not just the pure function
            # (already covered directly against Get-DashboardViewModel in
            # Dashboard.Tests.ps1's own 'ConnectionState resolution' Context).
            ($body | ConvertFrom-Json).ConnectionState | Should -Be 'Finished'
        }

        It 'Test 14 (260718-epo): a missing/corrupt session.json degrades honestly -- ApiStats still returns 200 with today''s Idle behavior' {
            Mock Read-PusherStats -ModuleName Dashboard { return $null }
            Mock Get-PusherDesiredState -ModuleName Dashboard { return 'stopped' }
            Mock Test-PusherProcessAlive -ModuleName Dashboard { return $false }
            Mock Get-MonotonicSeconds -ModuleName Dashboard { return 42.0 }

            $context = New-FakeDashboardContext -HttpMethod 'GET' -Path '/api/stats'
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 200
            $body = Get-FakeContextResponseBody -Context $context
            ($body | ConvertFrom-Json).ConnectionState | Should -Be 'Idle'
        }
    }

    # 06-06-PLAN.md: fold enabled probe results into the existing /api/stats response
    # (D-12 -- one poll path, not a second /api/probes route). Get-DashboardViewModel
    # itself is untouched (the mocked-return Test 1 above proves that trivially); these
    # tests drive the REAL Get-DashboardViewModel end-to-end so the zero-plugin
    # byte-for-byte comparison against a directly-computed baseline is meaningful.
    Context 'ApiStats probes fold (06-06: MON-04 zero-plugin, D-07 staleness, Pitfall 5 corrupt-file resilience)' {

        It 'MON-04 zero-plugin: no state/probes directory -> probes==[] and every non-probes field is byte-for-byte unchanged vs. the pre-fold baseline' {
            Mock Read-PusherStats -ModuleName Dashboard { return [pscustomobject]@{ pusherState = 'Streaming' } }
            Mock Get-PusherDesiredState -ModuleName Dashboard { return 'streaming' }
            Mock Test-PusherProcessAlive -ModuleName Dashboard { return $true }
            Mock Get-MonotonicSeconds -ModuleName Dashboard { return 42.0 }

            $context = New-FakeDashboardContext -HttpMethod 'GET' -Path '/api/stats'
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 200
            $body = Get-FakeContextResponseBody -Context $context
            $parsed = $body | ConvertFrom-Json

            @($parsed.probes).Count | Should -Be 0 -Because 'MON-04: zero probes on disk must fold to an empty array, not omit the field or fabricate an entry'

            # Baseline: the exact same inputs, computed directly against the untouched
            # Get-DashboardViewModel (the plan's objective: that function is never
            # modified, so this baseline and the handler's real output must agree on
            # every field except the newly-added 'probes').
            $baselineStats = [pscustomobject]@{ pusherState = 'Streaming' }
            $baselineViewModel = Get-DashboardViewModel -ControlFlagDesiredState 'streaming' -PusherProcessAlive $true -Stats $baselineStats -NowMonotonicSeconds 42.0
            $baselineParsed = ($baselineViewModel | ConvertTo-Json -Compress -Depth 4) | ConvertFrom-Json

            foreach ($propertyName in $baselineParsed.PSObject.Properties.Name) {
                ($parsed.$propertyName | ConvertTo-Json -Compress) | Should -Be ($baselineParsed.$propertyName | ConvertTo-Json -Compress) `
                    -Because "field '$propertyName' must be byte-for-byte unchanged when zero probes are present (MON-04)"
            }
        }

        It 'fold: two valid probe result files present -> probes is a 2-element array carrying name/title/status/metrics/detail per entry' {
            Mock Read-PusherStats -ModuleName Dashboard { return [pscustomobject]@{ pusherState = 'Streaming' } }
            Mock Get-PusherDesiredState -ModuleName Dashboard { return 'streaming' }
            Mock Test-PusherProcessAlive -ModuleName Dashboard { return $true }
            Mock Get-MonotonicSeconds -ModuleName Dashboard { return 100.0 }

            $probesDirectory = Join-Path $script:HandlerTestRoot 'state/probes'
            Save-ProbeResult -ProbeResultFilePath (Join-Path $probesDirectory 'vps-relay.json') `
                -Name 'vps-relay' -Title 'VPS Relay' -Status 'ok' `
                -Metrics @(@{ label = 'Latency'; value = 42; unit = 'ms' }) -Detail $null -StaleWithinSeconds 999999.0
            Save-ProbeResult -ProbeResultFilePath (Join-Path $probesDirectory 'omr.json') `
                -Name 'omr' -Title 'OMR Router' -Status 'degraded' `
                -Metrics @() -Detail 'partial bond' -StaleWithinSeconds 999999.0

            $context = New-FakeDashboardContext -HttpMethod 'GET' -Path '/api/stats'
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 200
            $body = Get-FakeContextResponseBody -Context $context
            $probes = @(($body | ConvertFrom-Json).probes)

            $probes.Count | Should -Be 2
            ($probes | Where-Object { $_.name -eq 'vps-relay' }).title | Should -Be 'VPS Relay'
            ($probes | Where-Object { $_.name -eq 'vps-relay' }).status | Should -Be 'ok'
            ($probes | Where-Object { $_.name -eq 'vps-relay' }).metrics[0].label | Should -Be 'Latency'
            ($probes | Where-Object { $_.name -eq 'omr' }).status | Should -Be 'degraded'
            ($probes | Where-Object { $_.name -eq 'omr' }).detail | Should -Be 'partial bond'
        }

        It 'Pitfall 5: a corrupt probe result file alongside a valid one never crashes the handler -- the valid probe and local stats still render' {
            Mock Read-PusherStats -ModuleName Dashboard { return [pscustomobject]@{ pusherState = 'Streaming' } }
            Mock Get-PusherDesiredState -ModuleName Dashboard { return 'streaming' }
            Mock Test-PusherProcessAlive -ModuleName Dashboard { return $true }
            Mock Get-MonotonicSeconds -ModuleName Dashboard { return 100.0 }

            $probesDirectory = Join-Path $script:HandlerTestRoot 'state/probes'
            New-Item -ItemType Directory -Path $probesDirectory -Force | Out-Null
            Save-ProbeResult -ProbeResultFilePath (Join-Path $probesDirectory 'vps-relay.json') `
                -Name 'vps-relay' -Title 'VPS Relay' -Status 'ok' -Metrics @() -Detail $null -StaleWithinSeconds 999999.0
            Set-Content -LiteralPath (Join-Path $probesDirectory 'bad.json') -Value '{not-valid-json' -Encoding utf8

            $context = New-FakeDashboardContext -HttpMethod 'GET' -Path '/api/stats'

            { Invoke-DashboardRequestHandler @script:HandlerParams -Context $context } | Should -Not -Throw

            $context.Response.StatusCode | Should -Be 200 -Because 'a broken third-party probe file must never take down the local stats panel'
            $body = Get-FakeContextResponseBody -Context $context
            $parsed = $body | ConvertFrom-Json
            $probes = @($parsed.probes)

            $probes.Count | Should -Be 1 -Because 'the corrupt file is skipped, the valid probe still renders'
            $probes[0].name | Should -Be 'vps-relay'
            $probes[0].status | Should -Be 'ok'
            $parsed.ConnectionState | Should -Not -BeNullOrEmpty -Because 'local stats must still be present and computed, not swallowed by the corrupt probe file'
        }
    }

    Context 'ApiControl (POST /api/control)' {

        It 'Test 2: {action:start} with a valid Origin calls Set-PusherDesiredState streaming exactly once and returns 200' {
            Mock Set-PusherDesiredState -ModuleName Dashboard { }
            Mock Stop-PusherProcesses -ModuleName Dashboard { }

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/control' `
                -Headers @{ Origin = 'http://localhost:8787' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"action":"start"}'))
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 200
            Should -Invoke Set-PusherDesiredState -ModuleName Dashboard -Times 1 -Exactly -ParameterFilter { $DesiredState -eq 'streaming' }
            Should -Invoke Stop-PusherProcesses -ModuleName Dashboard -Times 0
        }

        It 'Test 3: {action:stop} calls Set-PusherDesiredState stopped exactly once and never calls Stop-PusherProcesses' {
            Mock Set-PusherDesiredState -ModuleName Dashboard { }
            Mock Stop-PusherProcesses -ModuleName Dashboard { }

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/control' `
                -Headers @{ Origin = 'http://localhost:8787' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"action":"stop"}'))
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            Should -Invoke Set-PusherDesiredState -ModuleName Dashboard -Times 1 -Exactly -ParameterFilter { $DesiredState -eq 'stopped' }
            Should -Invoke Stop-PusherProcesses -ModuleName Dashboard -Times 0
        }

        It 'Test 4 (order is the contract): {action:cut} calls Set-PusherDesiredState stopped BEFORE Stop-PusherProcesses' {
            $script:cutCallOrder = [System.Collections.Generic.List[string]]::new()
            Mock Set-PusherDesiredState -ModuleName Dashboard { $script:cutCallOrder.Add("Set:$DesiredState") }
            Mock Stop-PusherProcesses -ModuleName Dashboard { $script:cutCallOrder.Add('Stop') }

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/control' `
                -Headers @{ Origin = 'http://localhost:8787' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"action":"cut"}'))
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $script:cutCallOrder.Count | Should -Be 2 -Because 'both the flag write and the kill must have run'
            $script:cutCallOrder[0] | Should -Be 'Set:stopped' -Because 'cut.ps1''s flag-before-kill order is load-bearing (a kill-first ordering lets the supervisor relaunch the stream the operator just cut)'
            $script:cutCallOrder[1] | Should -Be 'Stop'
        }

        It 'Test 5: an unrecognised action returns 400 and calls neither control function' {
            Mock Set-PusherDesiredState -ModuleName Dashboard { }
            Mock Stop-PusherProcesses -ModuleName Dashboard { }

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/control' `
                -Headers @{ Origin = 'http://localhost:8787' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"action":"DROP TABLE"}'))
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 400
            Should -Invoke Set-PusherDesiredState -ModuleName Dashboard -Times 0
            Should -Invoke Stop-PusherProcesses -ModuleName Dashboard -Times 0
        }

        It 'Test 6 (the CSRF gate): a foreign Origin returns 403 and the side effect never happens' {
            Mock Set-PusherDesiredState -ModuleName Dashboard { }
            Mock Stop-PusherProcesses -ModuleName Dashboard { }

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/control' `
                -Headers @{ Origin = 'http://evil.example.com' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"action":"cut"}'))
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 403
            Should -Invoke Set-PusherDesiredState -ModuleName Dashboard -Times 0
            Should -Invoke Stop-PusherProcesses -ModuleName Dashboard -Times 0
        }

        It 'Test 15: malformed JSON body returns 400, not 500, and does not throw' {
            Mock Set-PusherDesiredState -ModuleName Dashboard { }
            Mock Stop-PusherProcesses -ModuleName Dashboard { }

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/control' `
                -Headers @{ Origin = 'http://localhost:8787' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{not-json'))

            { Invoke-DashboardRequestHandler @script:HandlerParams -Context $context } | Should -Not -Throw
            $context.Response.StatusCode | Should -Be 400
            Should -Invoke Set-PusherDesiredState -ModuleName Dashboard -Times 0
            Should -Invoke Stop-PusherProcesses -ModuleName Dashboard -Times 0
        }

        It 'Test 16: a body larger than the configured cap returns 413 and is never parsed' {
            Mock Set-PusherDesiredState -ModuleName Dashboard { }
            Mock Stop-PusherProcesses -ModuleName Dashboard { }

            $oversizedPadding = 'x' * 70000
            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/control' `
                -Headers @{ Origin = 'http://localhost:8787' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"action":"start","padding":"' + $oversizedPadding + '"}'))

            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 413
            Should -Invoke Set-PusherDesiredState -ModuleName Dashboard -Times 0
            Should -Invoke Stop-PusherProcesses -ModuleName Dashboard -Times 0
        }
    }

    # 05.1-04-PLAN.md Task 1: SESS-03's reset-resume action -- CSRF-gated (inherits
    # ApiControl's existing gate, never a second Test-DashboardRequestOrigin call),
    # refuses while the pusher is alive (D-05), and clears the resume anchor by
    # Remove-Item (never a sentinel write -- Restore-PusherOffset already treats a
    # missing file as the safe-default fresh start, OffsetStore.psm1:90-93).
    Context 'ApiControl reset-resume (SESS-03, D-05)' {

        BeforeEach {
            $script:ResetStateFilePath = Join-Path $script:HandlerTestRoot 'state.json'
        }

        It 'Test 17: forged/missing Origin+Sec-Fetch-Site -> 403, offset file NOT removed' {
            Set-Content -LiteralPath $script:ResetStateFilePath -Value '{"file":"D:\\rec.ts","byteOffset":1000}' -Encoding utf8

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/control' `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"action":"reset-resume"}'))
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context -StateFilePath $script:ResetStateFilePath

            $context.Response.StatusCode | Should -Be 403
            Test-Path -LiteralPath $script:ResetStateFilePath | Should -BeTrue
        }

        It 'Test 18: valid Origin, pusher ALIVE -> 409, offset file NOT removed (D-05)' {
            Mock Test-PusherProcessAlive -ModuleName Dashboard { return $true }
            Set-Content -LiteralPath $script:ResetStateFilePath -Value '{"file":"D:\\rec.ts","byteOffset":1000}' -Encoding utf8

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/control' `
                -Headers @{ Origin = 'http://localhost:8787' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"action":"reset-resume"}'))
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context -StateFilePath $script:ResetStateFilePath

            $context.Response.StatusCode | Should -Be 409
            Test-Path -LiteralPath $script:ResetStateFilePath | Should -BeTrue
        }

        It 'Test 19: valid Origin, pusher STOPPED, offset file present -> 200 success, offset file removed' {
            Mock Test-PusherProcessAlive -ModuleName Dashboard { return $false }
            Set-Content -LiteralPath $script:ResetStateFilePath -Value '{"file":"D:\\rec.ts","byteOffset":1000}' -Encoding utf8

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/control' `
                -Headers @{ Origin = 'http://localhost:8787' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"action":"reset-resume"}'))
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context -StateFilePath $script:ResetStateFilePath

            $context.Response.StatusCode | Should -Be 200
            $body = Get-FakeContextResponseBody -Context $context
            ($body | ConvertFrom-Json).success | Should -BeTrue
            Test-Path -LiteralPath $script:ResetStateFilePath | Should -BeFalse
        }

        It 'Test 20: valid Origin, pusher STOPPED, offset file ALREADY absent -> 200 success (idempotent)' {
            Mock Test-PusherProcessAlive -ModuleName Dashboard { return $false }

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/control' `
                -Headers @{ Origin = 'http://localhost:8787' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"action":"reset-resume"}'))

            { Invoke-DashboardRequestHandler @script:HandlerParams -Context $context -StateFilePath $script:ResetStateFilePath } | Should -Not -Throw

            $context.Response.StatusCode | Should -Be 200
            Test-Path -LiteralPath $script:ResetStateFilePath | Should -BeFalse
        }

        It 'Source assertion: the reset-resume arm gates on Test-PusherProcessAlive before Remove-Item, uses Remove-Item (not a WriteAllText/Move sentinel write), and does not duplicate the CSRF check' {
            $tokens = $null
            $parseErrors = $null
            $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:DashboardModulePath, [ref] $tokens, [ref] $parseErrors)
            $parseErrors.Count | Should -Be 0

            $apiControlFunctionAst = $moduleAst.Find(
                { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DashboardRequestHandler' },
                $true)
            $handlerText = $apiControlFunctionAst.Extent.Text

            $resetArmMatch = [regex]::Match($handlerText, "'reset-resume'\s*\{(?<body>(?:[^{}]|(?<open>\{)|(?<-open>\}))*)\}(?(open)(?!))", 'Singleline')
            $resetArmMatch.Success | Should -BeTrue -Because 'a reset-resume arm must exist in the switch($action) block'
            $resetArmBody = $resetArmMatch.Groups['body'].Value
            # Comment lines legitimately reference these names in rationale prose (the
            # PLAN's own <action> text does the same) -- code-shape assertions must only
            # look at non-comment lines, mirroring the purity test's own convention above.
            $resetArmCodeOnly = (($resetArmBody -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

            $resetArmCodeOnly | Should -Match 'Test-PusherProcessAlive'
            $resetArmCodeOnly | Should -Match 'Remove-Item'
            $resetArmCodeOnly | Should -Not -Match 'WriteAllText|\bMove-Item\b'
            $resetArmCodeOnly | Should -Not -Match 'Test-DashboardRequestOrigin'

            $aliveIndex = $resetArmCodeOnly.IndexOf('Test-PusherProcessAlive')
            $removeIndex = $resetArmCodeOnly.IndexOf('Remove-Item')
            $aliveIndex | Should -BeLessThan $removeIndex -Because 'the liveness gate must be checked before Remove-Item runs'
        }
    }

    Context 'ApiConfig (POST /api/config) and ApiConfigRead (GET /api/config)' {

        It 'Test 7: a valid Origin and body calls Write-DotEnvFile once with the parsed changes and returns 200 Success=true' {
            Mock Write-DotEnvFile -ModuleName Dashboard { return [pscustomobject]@{ Success = $true; Problems = @() } }

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/config' `
                -Headers @{ Origin = 'http://localhost:8787' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"RELAY_HOST":"10.0.0.5"}'))
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 200
            $body = Get-FakeContextResponseBody -Context $context
            ($body | ConvertFrom-Json).Success | Should -BeTrue
            Should -Invoke Write-DotEnvFile -ModuleName Dashboard -Times 1 -Exactly -ParameterFilter {
                $Changes.ContainsKey('RELAY_HOST') -and $Changes['RELAY_HOST'] -eq '10.0.0.5'
            }
        }

        It 'Test 8: a rejected change set returns 400 with the Problems array (the specific validation reason)' {
            Mock Write-DotEnvFile -ModuleName Dashboard { return [pscustomobject]@{ Success = $false; Problems = @('RELAY_PORT is not a valid port number') } }

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/config' `
                -Headers @{ Origin = 'http://localhost:8787' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"RELAY_PORT":"999999"}'))
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 400
            $body = Get-FakeContextResponseBody -Context $context
            $parsed = $body | ConvertFrom-Json
            $parsed.Success | Should -BeFalse
            $parsed.Problems | Should -Contain 'RELAY_PORT is not a valid port number'
        }

        It 'Test 9: a bad Origin returns 403 and never calls Write-DotEnvFile' {
            Mock Write-DotEnvFile -ModuleName Dashboard { }

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/config' `
                -Headers @{ Origin = 'http://evil.example.com' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"RELAY_HOST":"10.0.0.5"}'))
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 403
            Should -Invoke Write-DotEnvFile -ModuleName Dashboard -Times 0
        }

        It 'Test 10: GET /api/config returns the redacted config -- the raw SrtPassphrase canary never appears in the body' {
            Mock Read-PusherConfig -ModuleName Dashboard { return [pscustomobject]@{ SrtPassphrase = 'CANARY-SECRET-VALUE'; RelayHost = '127.0.0.1' } }

            $context = New-FakeDashboardContext -HttpMethod 'GET' -Path '/api/config'
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 200
            $body = Get-FakeContextResponseBody -Context $context
            $body | Should -Not -Match 'CANARY-SECRET-VALUE'
            ($body | ConvertFrom-Json).SrtPassphrase | Should -Be '***REDACTED***'
        }
    }

    Context 'StaticFile serving and traversal (T-05-02)' {

        It 'Test 11: GET / serves dashboard/index.html with text/html; charset=utf-8 and 200' {
            $context = New-FakeDashboardContext -HttpMethod 'GET' -Path '/'
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 200
            $context.Response.ContentType | Should -Be 'text/html; charset=utf-8'
            (Get-FakeContextResponseBody -Context $context) | Should -Be '<html>dashboard</html>'
        }

        It 'Test 12: GET /../.env returns 404 and never reads a static file off disk' {
            Mock Get-DashboardStaticFileBytes -ModuleName Dashboard { throw 'must never be called for a refused path' }

            $context = New-FakeDashboardContext -HttpMethod 'GET' -Path '/../.env'
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 404
            Should -Invoke Get-DashboardStaticFileBytes -ModuleName Dashboard -Times 0
        }

        It 'Test 13: GET /missing.js (resolves inside the root, but the file does not exist) returns 404' {
            $context = New-FakeDashboardContext -HttpMethod 'GET' -Path '/missing.js'
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 404
        }
    }

    # 05.1-03-PLAN.md Task 2: the recordings list -- live-flagged via the same
    # Test-RecordingFileDeletable/Get-NewestMatchingRecordingFile authority Task 1
    # introduced, and honestly degrading (never throwing) when the caller has not
    # threaded RecordingFolderPath through yet (the design note's Wave 1/Wave 3 gap).
    Context 'ApiRecordings (GET /api/recordings, 05.1-03)' {

        BeforeEach {
            $script:RecordingsTestFolder = Join-Path $script:HandlerTestRoot 'recordings'
            New-Item -ItemType Directory -Path $script:RecordingsTestFolder -Force | Out-Null
        }

        It 'Test 19a: a folder of 3 matching .ts files returns a 3-element JSON array with exactly one isLive=true (the newest)' {
            $olderPath = Join-Path $script:RecordingsTestFolder 'session-1.ts'
            $middlePath = Join-Path $script:RecordingsTestFolder 'session-2.ts'
            $newestPath = Join-Path $script:RecordingsTestFolder 'session-3.ts'
            Set-Content -LiteralPath $olderPath -Value 'a' -NoNewline
            Set-Content -LiteralPath $middlePath -Value 'bb' -NoNewline
            Set-Content -LiteralPath $newestPath -Value 'ccc' -NoNewline
            (Get-Item -LiteralPath $olderPath).LastWriteTime = (Get-Date).AddMinutes(-20)
            (Get-Item -LiteralPath $middlePath).LastWriteTime = (Get-Date).AddMinutes(-10)
            (Get-Item -LiteralPath $newestPath).LastWriteTime = (Get-Date)

            $context = New-FakeDashboardContext -HttpMethod 'GET' -Path '/api/recordings'
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context `
                -RecordingFolderPath $script:RecordingsTestFolder -RecordingFilenameGlob '*.ts'

            $context.Response.StatusCode | Should -Be 200
            $context.Response.ContentType | Should -Be 'application/json'
            $body = Get-FakeContextResponseBody -Context $context
            $recordings = @($body | ConvertFrom-Json)

            $recordings.Count | Should -Be 3
            @($recordings | Where-Object { $_.isLive }).Count | Should -Be 1
            ($recordings | Where-Object { $_.isLive }).name | Should -Be 'session-3.ts'
        }

        It 'Test 19b: $RecordingFolderPath = $null responds 500 with the not-configured error, never throws' {
            $context = New-FakeDashboardContext -HttpMethod 'GET' -Path '/api/recordings'

            { Invoke-DashboardRequestHandler @script:HandlerParams -Context $context } | Should -Not -Throw

            $context.Response.StatusCode | Should -Be 500
            $body = Get-FakeContextResponseBody -Context $context
            ($body | ConvertFrom-Json).error | Should -Be 'recordings folder not configured'
        }
    }

    # 05.1-04-PLAN.md Task 2: SESS-04's delete route -- CSRF-gated, traversal-guarded
    # (the exact T-03-04/T-05-02 GetFullPath+trailing-separator idiom), never the
    # newest/live file (Test-RecordingFileDeletable, D-07), and lock-tolerant
    # (Pitfall 4). Every unsafe case must stop BEFORE Remove-Item runs at all.
    Context 'ApiRecordingsDelete (POST /api/recordings/delete, SESS-04)' {

        BeforeEach {
            $script:DeleteRecordingsFolder = Join-Path $script:HandlerTestRoot 'delete-recordings'
            New-Item -ItemType Directory -Path $script:DeleteRecordingsFolder -Force | Out-Null

            $script:DeleteOlderPath = Join-Path $script:DeleteRecordingsFolder 'session-old.ts'
            $script:DeleteNewestPath = Join-Path $script:DeleteRecordingsFolder 'session-newest.ts'
            Set-Content -LiteralPath $script:DeleteOlderPath -Value 'a' -NoNewline
            Set-Content -LiteralPath $script:DeleteNewestPath -Value 'bb' -NoNewline
            (Get-Item -LiteralPath $script:DeleteOlderPath).LastWriteTime = (Get-Date).AddMinutes(-20)
            (Get-Item -LiteralPath $script:DeleteNewestPath).LastWriteTime = (Get-Date)

            $script:DeleteHandlerParams = $script:HandlerParams.Clone()
            $script:DeleteHandlerParams['RecordingFolderPath'] = $script:DeleteRecordingsFolder
            $script:DeleteHandlerParams['RecordingFilenameGlob'] = '*.ts'
        }

        It 'Test 21: forged/missing Origin+Sec-Fetch-Site -> 403, Remove-Item NEVER called' {
            Mock Remove-Item -ModuleName Dashboard { }

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/recordings/delete' `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"filename":"session-old.ts"}'))
            Invoke-DashboardRequestHandler @script:DeleteHandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 403
            Should -Invoke Remove-Item -ModuleName Dashboard -Times 0
        }

        It 'Test 22: valid Origin, filename resolving OUTSIDE RecordingFolderPath -> 400/403, Remove-Item NEVER called' {
            Mock Remove-Item -ModuleName Dashboard { }

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/recordings/delete' `
                -Headers @{ Origin = 'http://localhost:8787' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"filename":"..\\..\\Windows\\System32\\drivers\\etc\\hosts"}'))
            Invoke-DashboardRequestHandler @script:DeleteHandlerParams -Context $context

            $context.Response.StatusCode | Should -BeIn @(400, 403)
            Should -Invoke Remove-Item -ModuleName Dashboard -Times 0
        }

        It 'Test 23: valid Origin, filename == newest/live file -> 409, Remove-Item NEVER called (D-07)' {
            Mock Remove-Item -ModuleName Dashboard { }

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/recordings/delete' `
                -Headers @{ Origin = 'http://localhost:8787' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"filename":"session-newest.ts"}'))
            Invoke-DashboardRequestHandler @script:DeleteHandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 409
            $body = Get-FakeContextResponseBody -Context $context
            ($body | ConvertFrom-Json).error | Should -Be 'cannot delete the live recording'
            Should -Invoke Remove-Item -ModuleName Dashboard -Times 0
        }

        It 'Test 24: valid Origin, in-folder non-live file -> 200 success, Remove-Item called once on the resolved absolute path' {
            Mock Remove-Item -ModuleName Dashboard { }

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/recordings/delete' `
                -Headers @{ Origin = 'http://localhost:8787' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"filename":"session-old.ts"}'))
            Invoke-DashboardRequestHandler @script:DeleteHandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 200
            $body = Get-FakeContextResponseBody -Context $context
            ($body | ConvertFrom-Json).success | Should -BeTrue
            Should -Invoke Remove-Item -ModuleName Dashboard -Times 1 -Exactly -ParameterFilter {
                $LiteralPath -eq $script:DeleteOlderPath
            }
        }

        It 'Test 25: valid Origin, in-folder non-live file, Remove-Item throws IOException (locked) -> operator-readable error, never a raw 500 stack' {
            Mock Remove-Item -ModuleName Dashboard { throw [System.IO.IOException]::new('The process cannot access the file because it is being used by another process.') }

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/recordings/delete' `
                -Headers @{ Origin = 'http://localhost:8787' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"filename":"session-old.ts"}'))

            { Invoke-DashboardRequestHandler @script:DeleteHandlerParams -Context $context } | Should -Not -Throw

            $context.Response.StatusCode | Should -BeIn @(409, 500)
            $body = Get-FakeContextResponseBody -Context $context
            ($body | ConvertFrom-Json).error | Should -Match 'in use'
        }

        It 'CR-01 source assertion: the delete route''s Remove-Item call passes -ErrorAction Stop, converting the cmdlet''s otherwise non-terminating failures into the terminating IOException/UnauthorizedAccessException the catch blocks require -- a mocked "throw" (Test 25, and this test''s own scenario below) always terminates regardless of -ErrorAction, so it cannot prove this by itself; the production runspace (supervisor.ps1''s $listenerLoopScriptBlock) never sets $ErrorActionPreference = ''Stop''' {
            $tokens = $null
            $parseErrors = $null
            $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:DashboardModulePath, [ref] $tokens, [ref] $parseErrors)
            $parseErrors.Count | Should -Be 0

            $deleteFunctionAst = $moduleAst.Find(
                { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DashboardRequestHandler' },
                $true)
            $handlerText = $deleteFunctionAst.Extent.Text

            $deleteArmMatch = [regex]::Match($handlerText, "'ApiRecordingsDelete'\s*\{(?<body>(?:[^{}]|(?<open>\{)|(?<-open>\}))*)\}(?(open)(?!))", 'Singleline')
            $deleteArmMatch.Success | Should -BeTrue -Because 'an ApiRecordingsDelete case must exist in the route switch'
            $deleteArmBody = $deleteArmMatch.Groups['body'].Value

            $deleteArmBody | Should -Match 'Remove-Item\s+-LiteralPath\s+\$candidateFileFullName\s+-Force\s+-ErrorAction\s+Stop' `
                -Because 'CR-01: without -ErrorAction Stop, Remove-Item failures are non-terminating in the real (non-Stop-default) dashboard runspace and the catch blocks never fire'
        }

        It 'Test 26 (CR-02): valid Origin, filename resolves INSIDE RecordingFolderPath but does NOT match RecordingFilenameGlob -> 400, Remove-Item NEVER called' {
            Mock Remove-Item -ModuleName Dashboard { }

            $offsetFilePath = Join-Path $script:DeleteRecordingsFolder 'offset.json'
            Set-Content -LiteralPath $offsetFilePath -Value '{"offset":123}' -NoNewline

            $context = New-FakeDashboardContext -HttpMethod 'POST' -Path '/api/recordings/delete' `
                -Headers @{ Origin = 'http://localhost:8787' } `
                -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('{"filename":"offset.json"}'))
            Invoke-DashboardRequestHandler @script:DeleteHandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 400
            $body = Get-FakeContextResponseBody -Context $context
            ($body | ConvertFrom-Json).error | Should -Be 'not a recognised recording'
            Should -Invoke Remove-Item -ModuleName Dashboard -Times 0
            Test-Path -LiteralPath $offsetFilePath | Should -BeTrue
        }

        It 'Source assertion: the delete handler checks CSRF and the traversal guard BEFORE Get-NewestMatchingRecordingFile / Remove-Item, and never gates on Test-PusherProcessAlive' {
            $tokens = $null
            $parseErrors = $null
            $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:DashboardModulePath, [ref] $tokens, [ref] $parseErrors)
            $parseErrors.Count | Should -Be 0

            $deleteFunctionAst = $moduleAst.Find(
                { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DashboardRequestHandler' },
                $true)
            $handlerText = $deleteFunctionAst.Extent.Text

            $deleteArmMatch = [regex]::Match($handlerText, "'ApiRecordingsDelete'\s*\{(?<body>(?:[^{}]|(?<open>\{)|(?<-open>\}))*)\}(?(open)(?!))", 'Singleline')
            $deleteArmMatch.Success | Should -BeTrue -Because 'an ApiRecordingsDelete case must exist in the route switch'
            $deleteArmBody = $deleteArmMatch.Groups['body'].Value
            $deleteArmCodeOnly = (($deleteArmBody -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

            $deleteArmCodeOnly | Should -Not -Match 'Test-PusherProcessAlive' -Because 'delete gates per-file (Test-RecordingFileDeletable), never on pusher liveness (RESEARCH Anti-Patterns / A3)'

            $csrfIndex = $deleteArmCodeOnly.IndexOf('Test-DashboardRequestOrigin')
            $traversalIndex = $deleteArmCodeOnly.IndexOf('StartsWith')
            $newestIndex = $deleteArmCodeOnly.IndexOf('Get-NewestMatchingRecordingFile')
            $removeIndex = $deleteArmCodeOnly.IndexOf('Remove-Item')

            $csrfIndex | Should -BeGreaterThan -1
            $traversalIndex | Should -BeGreaterThan -1
            $newestIndex | Should -BeGreaterThan -1
            $removeIndex | Should -BeGreaterThan -1
            $csrfIndex | Should -BeLessThan $traversalIndex
            $traversalIndex | Should -BeLessThan $newestIndex
            $newestIndex | Should -BeLessThan $removeIndex
        }
    }

    Context 'Handler signature extension (05.1-03 runspace-boundary contract)' {

        It 'Invoke-DashboardRequestHandler declares the three new optional params' {
            $command = Get-Command Invoke-DashboardRequestHandler -Module Dashboard
            $command.Parameters.Keys | Should -Contain 'RecordingFolderPath'
            $command.Parameters.Keys | Should -Contain 'RecordingFilenameGlob'
            $command.Parameters.Keys | Should -Contain 'StateFilePath'
        }

        It 'Invoke-DashboardListenerLoop declares the three new optional params and passes all three through to the handler' {
            $command = Get-Command Invoke-DashboardListenerLoop -Module Dashboard
            $command.Parameters.Keys | Should -Contain 'RecordingFolderPath'
            $command.Parameters.Keys | Should -Contain 'RecordingFilenameGlob'
            $command.Parameters.Keys | Should -Contain 'StateFilePath'

            $tokens = $null
            $parseErrors = $null
            $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:DashboardModulePath, [ref] $tokens, [ref] $parseErrors)
            $loopFunctionAst = $moduleAst.Find(
                { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DashboardListenerLoop' },
                $true)
            $loopFunctionText = $loopFunctionAst.Extent.Text

            $loopFunctionText | Should -Match '-RecordingFolderPath\s+\$RecordingFolderPath'
            $loopFunctionText | Should -Match '-RecordingFilenameGlob\s+\$RecordingFilenameGlob'
            $loopFunctionText | Should -Match '-StateFilePath\s+\$StateFilePath'
        }
    }

    Context 'MethodNotAllowed' {

        It 'DELETE /api/stats returns 405' {
            $context = New-FakeDashboardContext -HttpMethod 'DELETE' -Path '/api/stats'
            Invoke-DashboardRequestHandler @script:HandlerParams -Context $context

            $context.Response.StatusCode | Should -Be 405
        }
    }

    Context 'D-03 fault containment' {

        It 'Test 14: an exception inside the handler (Get-DashboardViewModel mocked to throw) returns 500 and never escapes' {
            Mock Read-PusherStats -ModuleName Dashboard { return $null }
            Mock Get-PusherDesiredState -ModuleName Dashboard { return 'stopped' }
            Mock Test-PusherProcessAlive -ModuleName Dashboard { return $false }
            Mock Get-MonotonicSeconds -ModuleName Dashboard { return 1.0 }
            Mock Get-DashboardViewModel -ModuleName Dashboard { throw 'simulated internal fault' }

            $context = New-FakeDashboardContext -HttpMethod 'GET' -Path '/api/stats'

            { Invoke-DashboardRequestHandler @script:HandlerParams -Context $context } | Should -Not -Throw
            $context.Response.StatusCode | Should -Be 500
        }
    }
}

# 05-07-PLAN.md Task 3: the listener loop 05-09 will host. Runspace-hosted per 05-01's
# HOST DECISION (05-SPIKE-FINDINGS.md) -- these tests bind REAL HttpListeners on
# runtime-discovered ephemeral ports (Wave 0 Gaps: never hardcode 8787 for a test that
# opens a real socket) and drive them with real HTTP requests from a background job, so
# these tests are heavier than the pure/mocked contexts above but exercise the actual
# accept loop, not a stand-in for it.
Describe 'Dashboard listener lifecycle' -Tag 'Quick' {

    BeforeAll {
        $script:LoggingModulePath = Join-Path $PSScriptRoot '../lib/Logging.psm1'
        $script:ControlFlagModulePath = Join-Path $PSScriptRoot '../lib/ControlFlag.psm1'
        $script:PusherProcessModulePath = Join-Path $PSScriptRoot '../lib/PusherProcess.psm1'
        $script:StatsStoreModulePath = Join-Path $PSScriptRoot '../lib/StatsStore.psm1'
        $script:ClockModulePath = Join-Path $PSScriptRoot '../lib/Clock.psm1'
        $script:ConfigModulePath = Join-Path $PSScriptRoot '../lib/Config.psm1'
        $script:ProbeStoreModulePath = Join-Path $PSScriptRoot '../lib/ProbeStore.psm1'
        $script:SessionStateModulePath = Join-Path $PSScriptRoot '../lib/SessionState.psm1'
        $script:CutScriptPath = Join-Path $PSScriptRoot '../cut.ps1'

        function Get-DashboardTestEphemeralPort {
            <#
            .SYNOPSIS
            Discovers a free TCP port at runtime by binding a TcpListener to port 0
            (OS-assigned), reading the assigned port, then releasing it -- mirrors
            spike/Confirm-DashboardHost.ps1's Get-EphemeralFreePort. A leaked test
            listener must never collide with a real dashboard's configured port or
            another parallel test run.
            #>
            $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            try {
                $tcpListener.Start()
                return ([System.Net.IPEndPoint] $tcpListener.LocalEndpoint).Port
            } finally {
                $tcpListener.Stop()
            }
        }

        function Invoke-DashboardTestBackgroundRequests {
            <#
            .SYNOPSIS
            Fires Count real HTTP GETs at Port from a SEPARATE background job -- a
            genuinely concurrent client is required because Invoke-
            DashboardListenerLoop blocks synchronously inside GetContext() on the
            thread that calls it. A background job is its own process, so it needs no
            access to this file's Pester mocks (which only need to exist on the thread
            actually running the loop under test), matching
            spike/Confirm-DashboardHost.ps1's third-process probe pattern.
            #>
            param(
                [Parameter(Mandatory)] [int] $Port,
                [int] $Count = 1,
                [string] $Path = '/'
            )
            return Start-Job -ScriptBlock {
                param($Port, $Count, $Path)
                for ($i = 0; $i -lt $Count; $i++) {
                    try { Invoke-WebRequest -Uri "http://localhost:$Port$Path" -UseBasicParsing -TimeoutSec 5 | Out-Null } catch { }
                }
            } -ArgumentList $Port, $Count, $Path
        }
    }

    BeforeEach {
        Push-Location $TestDrive
        Remove-Module Dashboard -ErrorAction SilentlyContinue
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module PusherProcess -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module ProbeStore -ErrorAction SilentlyContinue
        Remove-Module SessionState -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue

        Import-Module $script:LoggingModulePath -Force
        Set-LogDirectory (Join-Path $TestDrive 'state/logs')
        Import-Module $script:ControlFlagModulePath -Force
        Import-Module $script:PusherProcessModulePath -Force
        Import-Module $script:StatsStoreModulePath -Force
        Import-Module $script:ClockModulePath -Force
        Import-Module $script:ConfigModulePath -Force
        Import-Module $script:ProbeStoreModulePath -Force
        Import-Module $script:SessionStateModulePath -Force
        Import-Module $script:DashboardModulePath -Force

        . $script:CutScriptPath
        Set-Item -Path 'function:global:Stop-PusherProcesses' -Value (Get-Item 'function:Stop-PusherProcesses').ScriptBlock

        $script:ListenerTestRoot = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:ListenerTestRoot -Force | Out-Null
        $script:ListenerDashboardRootPath = Join-Path $script:ListenerTestRoot 'dashboard'
        New-Item -ItemType Directory -Path $script:ListenerDashboardRootPath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:ListenerDashboardRootPath 'index.html') -Value '<html>listener-loop</html>' -Encoding utf8 -NoNewline

        $script:ListenerLoopParams = @{
            ScriptRoot        = $script:ListenerTestRoot
            ControlFilePath   = Join-Path $script:ListenerTestRoot 'control.json'
            StatsFilePath     = Join-Path $script:ListenerTestRoot 'stats.json'
            DashboardRootPath = $script:ListenerDashboardRootPath
            EnvFilePath       = Join-Path $script:ListenerTestRoot '.env'
        }

        $script:StartedListeners = [System.Collections.Generic.List[System.Net.HttpListener]]::new()
    }

    AfterEach {
        foreach ($listener in $script:StartedListeners) {
            try { Stop-DashboardListener -Listener $listener } catch { }
        }
        Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue

        Pop-Location
        Remove-Module Dashboard -ErrorAction SilentlyContinue
        Remove-Module ControlFlag -ErrorAction SilentlyContinue
        Remove-Module PusherProcess -ErrorAction SilentlyContinue
        Remove-Module StatsStore -ErrorAction SilentlyContinue
        Remove-Module Clock -ErrorAction SilentlyContinue
        Remove-Module Config -ErrorAction SilentlyContinue
        Remove-Module ProbeStore -ErrorAction SilentlyContinue
        Remove-Module SessionState -ErrorAction SilentlyContinue
        Remove-Module Logging -ErrorAction SilentlyContinue
    }

    It 'Test 1: Start-DashboardListener returns a started listener; Stop-DashboardListener stops and disposes it' {
        $port = Get-DashboardTestEphemeralPort
        $listener = Start-DashboardListener -DashboardPort $port
        $script:StartedListeners.Add($listener)

        $listener.IsListening | Should -BeTrue

        Stop-DashboardListener -Listener $listener
        $listener.IsListening | Should -BeFalse
    }

    It 'Test 2: binding an already-bound port throws a clear, port-naming error' {
        $port = Get-DashboardTestEphemeralPort
        $firstListener = Start-DashboardListener -DashboardPort $port
        $script:StartedListeners.Add($firstListener)

        { Start-DashboardListener -DashboardPort $port } | Should -Throw -ExpectedMessage "*$port*"
    }

    It 'Test 3: Invoke-DashboardListenerLoop -MaxRequests 1 serves exactly one real request and returns' {
        $port = Get-DashboardTestEphemeralPort
        $listener = Start-DashboardListener -DashboardPort $port
        $script:StartedListeners.Add($listener)

        $job = Invoke-DashboardTestBackgroundRequests -Port $port -Count 1 -Path '/'
        try {
            Invoke-DashboardListenerLoop -Listener $listener @script:ListenerLoopParams -DashboardPort $port -MaxRequests 1
        } finally {
            Wait-Job $job -Timeout 10 | Out-Null
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }

        # Reaching this line at all is the primary assertion: MaxRequests 1 means the
        # call above blocks in GetContext() until the background job's single request
        # lands, serves it, then returns -- a loop that never bounded would hang the
        # test until Bash's own timeout killed it instead.
        $listener.IsListening | Should -BeTrue -Because 'MaxRequests exhaustion returns without stopping the listener itself'
    }

    It 'Test 4: continues looping after a request whose handler threw' {
        $port = Get-DashboardTestEphemeralPort
        $listener = Start-DashboardListener -DashboardPort $port
        $script:StartedListeners.Add($listener)

        $script:handlerCallCount = 0
        Mock Invoke-DashboardRequestHandler -ModuleName Dashboard {
            $script:handlerCallCount++
            try {
                if ($script:handlerCallCount -eq 1) { throw 'simulated handler fault' }
                $Context.Response.StatusCode = 200
            } finally {
                try { $Context.Response.Close() } catch { }
            }
        }

        $job = Invoke-DashboardTestBackgroundRequests -Port $port -Count 2 -Path '/'
        try {
            Invoke-DashboardListenerLoop -Listener $listener @script:ListenerLoopParams -DashboardPort $port -MaxRequests 2
        } finally {
            Wait-Job $job -Timeout 10 | Out-Null
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }

        $script:handlerCallCount | Should -Be 2 -Because 'a throwing handler on the first request must not stop the loop from serving the second'
    }

    It 'Test 5: the registered prefix is exactly http://localhost:{port}/ -- no wildcard/0.0.0.0 binding' {
        $port = Get-DashboardTestEphemeralPort
        $listener = Start-DashboardListener -DashboardPort $port
        $script:StartedListeners.Add($listener)

        $listener.Prefixes.Count | Should -Be 1
        $listener.Prefixes | Should -Contain "http://localhost:$port/"
    }
}

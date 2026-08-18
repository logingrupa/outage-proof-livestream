<#
.SYNOPSIS
Operator command: start streaming this service.

Flips the control flag to 'streaming'. That is the whole job -- it starts no process
itself. The already-running supervisor (launched idle at boot by the Scheduled Task)
polls the flag once per second and brings the pusher up on its next tick. Phase 5's
dashboard Start button writes this same flag through this same module, so there is
exactly one way the system is ever told to stream.

Safe to run twice: the flag is a state, not an event, and the write is atomic.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/Logging.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/ControlFlag.psm1') -Force

Set-LogDirectory -Path (Join-Path $PSScriptRoot 'state/logs')

Set-PusherDesiredState -ControlFilePath (Get-PusherControlFilePath -ScriptRoot $PSScriptRoot) -DesiredState 'streaming'
Write-Log -Level Info -Message 'Operator started streaming -- the supervisor will launch the pusher on its next poll (within a second).'

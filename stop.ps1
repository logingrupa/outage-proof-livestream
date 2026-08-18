<#
.SYNOPSIS
Operator command: stop streaming.

Flips the control flag to 'stopped'. The supervisor sees it on its next poll and
stops relaunching the pusher -- including mid-crash-loop, which is exactly when an
operator most needs a stop to be obeyed. Phase 5's dashboard Stop button writes this
same flag through this same module.

This does NOT kill a pusher that is currently running: it withdraws the permission to
(re)launch, so the current run finishes on its own terms rather than being cut off
mid-write to a live audience. Safe to run twice.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/Logging.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/ControlFlag.psm1') -Force

Set-LogDirectory -Path (Join-Path $PSScriptRoot 'state/logs')

Set-PusherDesiredState -ControlFilePath (Get-PusherControlFilePath -ScriptRoot $PSScriptRoot) -DesiredState 'stopped'
Write-Log -Level Info -Message 'Operator stopped streaming -- the supervisor will not relaunch the pusher. A pusher that is mid-run is left to finish on its own terms.'

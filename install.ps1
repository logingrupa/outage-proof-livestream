<#
.SYNOPSIS
Idempotent, elevation-aware installer for the Gapless SRT Pusher (SVC-01, SVC-02).

Verifies prerequisites (elevation, PowerShell 7, ffmpeg with libsrt support), copies
`.env.example` -> `.env` on first run only (never overwrites an operator-edited
`.env`), and registers a single `-AtStartup` Windows Scheduled Task
('GaplessSrtPusher') that launches supervisor.ps1 -- which comes up IDLE and streams
nothing until an operator explicitly starts it, and which owns crash restart (the
task settings do NOT restart the action on a non-zero exit; see
Register-PusherScheduledTask). All Session-0
hardening (PITFALLS.md Pitfall 10) is baked in: an absolute `pwsh.exe` path,
explicit `-ExecutionPolicy Bypass -NoProfile`, and an explicit WorkingDirectory =
script root -- a Scheduled Task launches with CWD = %windir%\system32 and cannot
be assumed to inherit the developer's own execution policy or PATH.

Functions are defined at top level (not wrapped in a module) so
tests/Install.Tests.ps1 can dot-source this file and Mock Get-Command /
Get-ScheduledTask / Register-ScheduledTask / Test-IsElevatedProcess /
Get-FfmpegProtocolsOutput without ever registering a real Scheduled Task --
real registration needs elevation and a real Windows box, and the real
reboot/Session-0 verification is deferred manual UAT (see 04-04-PLAN.md
user_setup / verification). Invoke-Install (the main flow) only runs when
this script is executed directly, never when dot-sourced -- see the guard at
the bottom of this file.

Exit codes (this installer's own contract, independent of pusher.ps1's D-12
runtime exit-code contract): 0 = install succeeded, 1 = one or more
prerequisites failed (nothing was registered -- never a half-applied install,
T-04-10).
#>

param(
    # Opt-in tunnel autostart registration (AO-01/D-09, 14.5-06) -- registers
    # the ssh -L tunnel Scheduled Task + persists the NIC2 VPS route. Never
    # fires as a side effect of a bare `install.ps1` invocation; see
    # Invoke-TunnelRegistration below for why this is a separate opt-in flow.
    [switch] $RegisterTunnel
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ScheduledTasks -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'lib/Logging.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Config.psm1') -Force

# Fixed TaskName (idempotency key, SVC-02): Register-ScheduledTask -Force always
# targets this exact name, so re-running install.ps1 updates the same task in
# place rather than creating a duplicate.
$script:TaskName = 'GaplessSrtPusher'
$script:ExitCodeSuccess = 0
$script:ExitCodePrerequisiteFailure = 1

# Tunnel autostart (AO-01/D-09, 14.5-06): its own fixed TaskName, distinct from
# $script:TaskName above, so registering/updating the tunnel task can never
# collide with or overwrite the pusher's own GaplessSrtPusher task.
$script:TunnelTaskName = 'GaplessTcpRelayTunnel'

function Test-IsElevatedProcess {
    <#
    .SYNOPSIS
    Returns whether the current process is running with Administrator rights.
    Extracted into its own function (rather than inlined in
    Test-InstallPrerequisites) purely so Pester can Mock this .NET-backed check
    without needing a real elevated/non-elevated process to test both branches
    (T-04-10).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FfmpegProtocolsOutput {
    <#
    .SYNOPSIS
    Runs `<FfmpegPath> -protocols` and returns its combined stdout+stderr as a
    single string. Extracted into its own function so Pester can Mock this
    external-process call rather than depending on a real ffmpeg binary being
    present wherever the test suite runs (CLAUDE.md's mandated
    `ffmpeg -protocols | findstr srt` check, D-11).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $FfmpegPath
    )

    return (& $FfmpegPath -protocols 2>&1 | Out-String)
}

function Test-InstallPrerequisites {
    <#
    .SYNOPSIS
    Checks elevation, PowerShell 7 (pwsh) presence, and ffmpeg-with-SRT support.
    Mirrors Test-PusherConfig's contract (lib/Config.psm1): returns a problems
    list -- empty means valid -- and NEVER throws or exits itself; the caller
    (Invoke-Install, Task 2) decides how loud to fail. Collects every problem
    rather than short-circuiting on the first one, so a single re-run of
    install.ps1 can report all blockers at once instead of trickling them out
    one fix at a time.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $problems = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-IsElevatedProcess)) {
        $problems.Add('Not running as Administrator -- re-run install.ps1 from an elevated (Administrator) PowerShell session before it can register the Scheduled Task (T-04-10)')
    }

    $pwshCommand = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    if (-not $pwshCommand) {
        $problems.Add('pwsh.exe (PowerShell 7) was not found on PATH -- install PowerShell 7 before running install.ps1 (the Scheduled Task action requires pwsh.exe, never powershell.exe)')
    }

    $ffmpegCommand = Get-Command -Name 'ffmpeg' -ErrorAction SilentlyContinue
    if (-not $ffmpegCommand) {
        $problems.Add('ffmpeg was not found on PATH -- install an ffmpeg build with libsrt support (e.g. gyan.dev "full" build) before running install.ps1')
    } else {
        $protocolsOutput = Get-FfmpegProtocolsOutput -FfmpegPath $ffmpegCommand.Source
        if ($protocolsOutput -notmatch 'srt') {
            $problems.Add("ffmpeg at '$($ffmpegCommand.Source)' does not report SRT protocol support (ffmpeg -protocols | findstr srt found nothing) -- install a libsrt-enabled ffmpeg build (CLAUDE.md-mandated check)")
        }
    }

    # Unary comma (,) prevents PowerShell's return/pipeline enumeration from
    # unwrapping the array -- WITHOUT it, a zero-problem (i.e. fully healthy)
    # machine returns an empty array that collapses to $null on assignment, and a
    # one-problem machine collapses to a bare scalar string. The caller's
    # `$problems.Count` then throws under Set-StrictMode -Version Latest, so the
    # installer crashed on exactly the machines where every prerequisite PASSED
    # and never registered the Scheduled Task (SVC-01/SVC-02). Identical to
    # Test-PusherConfig's return in lib/Config.psm1 -- both honour an
    # [OutputType([string[]])] promise that bare `return` silently breaks.
    return , $problems.ToArray()
}

function Initialize-PusherEnvFile {
    <#
    .SYNOPSIS
    First-run convenience copy: `.env.example` -> `.env`, ONLY when `.env` is
    absent. An existing `.env` (an operator's already-configured deployment) is
    never touched -- this must remain safe to call on every install.ps1 rerun
    (D-11 idempotency covers this too, not just the Scheduled Task).
    #>
    [CmdletBinding()]
    param(
        [string] $ScriptRoot = $PSScriptRoot
    )

    $envPath = Join-Path $ScriptRoot '.env'
    $envExamplePath = Join-Path $ScriptRoot '.env.example'

    if (Test-Path -LiteralPath $envPath) {
        Write-Log -Level Debug -Message ".env already exists at '$envPath' -- leaving the operator's existing config untouched (never overwrite)"
        return
    }
    if (-not (Test-Path -LiteralPath $envExamplePath)) {
        Write-Log -Level Warning -Message ".env.example not found at '$envExamplePath' -- skipping first-run .env copy"
        return
    }

    Copy-Item -LiteralPath $envExamplePath -Destination $envPath
    Write-Log -Level Info -Message "First-run: copied .env.example to '$envPath' -- edit .env for this church's deployment before the service starts (CFG-01)"
}

function Register-PusherScheduledTask {
    <#
    .SYNOPSIS
    Builds and registers the -AtStartup Scheduled Task per RESEARCH.md Pattern 3
    (cited Microsoft Learn): absolute pwsh.exe path + explicit WorkingDirectory
    (Pitfall 10), -AtStartup trigger, bounded RestartCount/RestartInterval +
    MultipleInstances IgnoreNew (D-10), and SYSTEM/ServiceAccount/Highest
    principal (T-04-09 -- SYSTEM needs no stored password and runs
    non-interactively; the recording folder must be a LOCAL/UNC path, not a
    mapped drive, since SYSTEM cannot see per-session drive mappings, Pitfall 1).
    Register-ScheduledTask -Force is the whole idempotency mechanism (SVC-02) --
    a rerun with an existing same-name task updates it in place, never
    duplicates and never throws (T-04-11).
    #>
    [CmdletBinding()]
    param(
        [string] $ScriptRoot = $PSScriptRoot
    )

    $pwshCommand = Get-Command -Name 'pwsh.exe' -ErrorAction Stop
    $pwshPath = $pwshCommand.Source
    # The task launches supervisor.ps1, NOT pusher.ps1 directly. The supervisor comes
    # up IDLE and streams nothing until an operator explicitly starts it (start.ps1 or
    # Phase 5's dashboard Start button) -- a church machine must never begin pushing to
    # a LIVE YouTube audience unattended just because it rebooted. The supervisor is
    # also what actually restarts a crashed pusher; see the settings note below.
    $scriptPath = Join-Path $ScriptRoot 'supervisor.ps1'

    $action = New-ScheduledTaskAction -Execute $pwshPath `
        -Argument "-ExecutionPolicy Bypass -NoProfile -File `"$scriptPath`"" `
        -WorkingDirectory $ScriptRoot

    $trigger = New-ScheduledTaskTrigger -AtStartup

    # RestartCount/RestartInterval do NOT restart the action on a non-zero exit code.
    # This was believed for the whole of Phase 4 and is false: Task Scheduler's
    # RestartOnFailure fires only on ABNORMAL TASK termination (a task-engine
    # failure), never when the action process merely exits non-zero. Proven by an
    # isolated probe on the real box -- a task with these exact settings whose action
    # was `pwsh -Command "exit 1"` left lastRun FROZEN and rerun False across 160s,
    # zero relaunches. These settings are kept for the abnormal-termination case they
    # genuinely do cover; PROCESS DEATH IS COVERED BY supervisor.ps1, which is what
    # this task now launches. Phase 2's in-session reconnect loop (RES D-02) still
    # owns network outages -- three distinct mechanisms, three distinct failures, no
    # overlap. MultipleInstances IgnoreNew prevents a boot + a manual run from ever
    # double-launching two supervisors against the same recording file.
    $settings = New-ScheduledTaskSettingsSet `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew -StartWhenAvailable

    $principal = New-ScheduledTaskPrincipal `
        -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    $existingTask = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Log -Level Info -Message "Existing Scheduled Task '$script:TaskName' found -- updating in place (idempotent -Force overwrite, SVC-02)"
    } else {
        Write-Log -Level Info -Message "No existing Scheduled Task '$script:TaskName' found -- installing fresh"
    }

    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null

    Write-Log -Level Info -Message "Scheduled Task '$script:TaskName' registered -- runs supervisor.ps1 at boot as SYSTEM/ServiceAccount, MultipleInstances IgnoreNew (SVC-01/T-04-09/T-04-11)"
}

function Register-TunnelScheduledTask {
    <#
    .SYNOPSIS
    Registers tools/bin/tcp-relay-tunnel.ps1 (the ssh -L tunnel loop) as its own
    -AtStartup Scheduled Task, mirroring Register-PusherScheduledTask's exact
    shape (absolute pwsh.exe path, explicit WorkingDirectory, bounded
    RestartCount/RestartInterval, MultipleInstances IgnoreNew, SYSTEM/
    ServiceAccount/Highest principal) so the tunnel survives a church-PC
    reboot/logout the same way the pusher supervisor already does (AO-01,
    D-09). SYSTEM needs no stored password and runs before any interactive
    logon, which is the whole point of "always-on" -- and SYSTEM already has
    read access to the askpass credential path under the operator's own
    profile via the default C:\Users ACL, same as the pusher's own SYSTEM
    task already relies on for the recording folder.

    Register-ScheduledTask -Force is the idempotency mechanism (AO-01
    adjacency edge, mirrors SVC-02): a re-run with an existing same-name task
    updates it in place, never a duplicate, never an error.
    #>
    [CmdletBinding()]
    param(
        [string] $ScriptRoot = $PSScriptRoot
    )

    $pwshCommand = Get-Command -Name 'pwsh.exe' -ErrorAction Stop
    $pwshPath = $pwshCommand.Source
    $scriptPath = Join-Path $ScriptRoot 'tools/bin/tcp-relay-tunnel.ps1'

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-Log -Level Warning -Message "Register-TunnelScheduledTask: tunnel helper script not found at '$scriptPath' -- no Scheduled Task was registered. This deployment does not ship the ssh-forwarding tunnel helper, which is only needed when the relay is not directly reachable from the OBS machine; a directly-reachable relay needs no tunnel, so this skip is expected and harmless."
        return
    }

    $action = New-ScheduledTaskAction -Execute $pwshPath `
        -Argument "-ExecutionPolicy Bypass -NoProfile -File `"$scriptPath`"" `
        -WorkingDirectory $ScriptRoot

    $trigger = New-ScheduledTaskTrigger -AtStartup

    $settings = New-ScheduledTaskSettingsSet `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew -StartWhenAvailable

    $principal = New-ScheduledTaskPrincipal `
        -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    $existingTask = Get-ScheduledTask -TaskName $script:TunnelTaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Log -Level Info -Message "Existing Scheduled Task '$script:TunnelTaskName' found -- updating in place (idempotent -Force overwrite)"
    } else {
        Write-Log -Level Info -Message "No existing Scheduled Task '$script:TunnelTaskName' found -- installing fresh"
    }

    Register-ScheduledTask -TaskName $script:TunnelTaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null

    Write-Log -Level Info -Message "Scheduled Task '$script:TunnelTaskName' registered -- runs tools/bin/tcp-relay-tunnel.ps1 at boot as SYSTEM/ServiceAccount"
}

function Get-VpsRouteConfiguration {
    <#
    .SYNOPSIS
    Reads VPS_ROUTE_PREFIX/VPS_ROUTE_NEXT_HOP from .env (lib/Config.psm1 schema) and
    returns them as DestinationPrefix/NextHop -- the mockable seam Set-VpsRoutePersistent
    calls first, so the Pester suite never has to touch the operator's real .env (the
    exact fixture-leak class 15-01 had to fix). ANY failure here (missing file,
    unreadable file, coercion failure) resolves to blank/blank rather than propagating,
    matching lib/NicTelemetry.psm1's and Read-LiveTunableOverrides' own never-throw
    edge-seam convention -- a route-config read failure must never crash the installer,
    it must simply be treated as "not configured" (Set-VpsRoutePersistent's own skip
    branch then logs the loud warning).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $EnvFilePath = (Join-Path $PSScriptRoot '.env')
    )

    try {
        $envConfig = Read-PusherConfig -Path $EnvFilePath
        return [pscustomobject]@{
            DestinationPrefix = [string] $envConfig.VpsRoutePrefix
            NextHop            = [string] $envConfig.VpsRouteNextHop
        }
    } catch {
        Write-Log -Level Warning -Message "Get-VpsRouteConfiguration: '$EnvFilePath' could not be read -- treating the persistent VPS route as unconfigured: $($_.Exception.Message)"
        return [pscustomobject]@{ DestinationPrefix = ''; NextHop = '' }
    }
}

function Find-RouteNextHopInterfaceIndex {
    <#
    .SYNOPSIS
    Finds the local network interface currently on-link with the configured route's
    next hop -- the ONLY interface the persistent-route step is ever allowed to touch.
    Scoped to the next hop's own /24 (derived from its first three octets) rather than
    any hardcoded subnet, so this works for whatever gateway an operator configures,
    while still refusing to guess: every other interface is never touched. Returns
    $null when the next hop does not parse into four dotted octets, and $null when no
    local interface holds an address on that /24 -- the caller must treat both cases
    identically and refuse to fall back to any other interface.
    #>
    [CmdletBinding()]
    [OutputType([Nullable[int]])]
    param(
        [Parameter(Mandatory)] [string] $NextHop
    )

    $nextHopOctets = $NextHop -split '\.'
    if ($nextHopOctets.Count -ne 4) {
        return $null
    }
    $onLinkMatchPattern = '{0}.{1}.{2}.*' -f $nextHopOctets[0], $nextHopOctets[1], $nextHopOctets[2]

    $onLinkAddress = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like $onLinkMatchPattern } |
        Select-Object -First 1

    if (-not $onLinkAddress) {
        return $null
    }
    return $onLinkAddress.InterfaceIndex
}

function ConvertTo-DottedSubnetMask {
    <#
    .SYNOPSIS
    Converts a CIDR prefix length (e.g. 32) to its dotted-decimal subnet mask
    (e.g. 255.255.255.255) -- needed because `route.exe add` (Add-PersistentNetRoute
    below) takes a mask, not a CIDR prefix length, unlike New-NetRoute's
    -DestinationPrefix.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [int] $PrefixLength
    )

    $maskBits = ('1' * $PrefixLength).PadRight(32, '0')
    $octets = for ($bitOffset = 0; $bitOffset -lt 32; $bitOffset += 8) {
        [Convert]::ToInt32($maskBits.Substring($bitOffset, 8), 2)
    }
    return ($octets -join '.')
}

function Add-PersistentNetRoute {
    <#
    .SYNOPSIS
    Thin wrapper around the classic `route.exe -p add` command, extracted into
    its own function purely so Pester can Mock this external-process call --
    mirrors this file's own established Get-FfmpegProtocolsOutput pattern.

    `New-NetRoute -PolicyStore PersistentStore` is deliberately NOT used here:
    live-run against the actual target church PC (14.5-06 Task 2) proved it
    fails outright with a native CIM error ("Invalid parameter PolicyStore
    PersistentStore", Windows System Error 87) on this machine's networking
    stack build, even under -WhatIf -- a genuine environment bug, not a
    parameter-value typo (Rule 1 fix). `route.exe -p add ... if <index>` was
    verified live to write into the SAME persistent-routes store Get-NetRoute
    -PolicyStore PersistentStore reads back from (round-tripped with a
    documentation-only TEST-NET-3 destination before touching the real VPS
    route), and its `if <index>` argument gives the same NIC-scoping guarantee
    -InterfaceIndex would have -- so this is a faithful, portable substitute,
    not a scope change.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $DestinationIp,
        [Parameter(Mandatory)] [string] $SubnetMask,
        [Parameter(Mandatory)] [string] $NextHop,
        [Parameter(Mandatory)] [int] $InterfaceIndex
    )

    route.exe -p add $DestinationIp mask $SubnetMask $NextHop if $InterfaceIndex | Out-Null
    return $LASTEXITCODE
}

function Test-VpsRoutePersistent {
    <#
    .SYNOPSIS
    Returns whether a persistent host route to the given destination prefix already
    exists in the PersistentStore (survives reboot) -- the check half of the
    check-then-add idempotency contract (a re-run when already persistent must be a
    no-op, not an error).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $DestinationPrefix
    )

    $persistentRoute = Get-NetRoute -DestinationPrefix $DestinationPrefix `
        -PolicyStore PersistentStore -ErrorAction SilentlyContinue
    return [bool]$persistentRoute
}

function Set-VpsRoutePersistent {
    <#
    .SYNOPSIS
    Idempotent (check-then-add): persists the operator-configured VPS_ROUTE_PREFIX ->
    VPS_ROUTE_NEXT_HOP host route (read via Get-VpsRouteConfiguration) so it survives
    reboot. Both keys default to blank (lib/Config.psm1) -- THE SAFETY BRANCH: when
    either is blank, this function logs a Warning naming BOTH env keys and the
    consequence in plain words, then returns WITHOUT throwing and WITHOUT writing any
    route. It must never claim a route was persisted when none was. Once both keys
    are set, the route write is scoped to ONLY the interface
    Find-RouteNextHopInterfaceIndex resolves (the interface currently on-link with the
    configured next hop); every other interface is never touched, and this function
    refuses (throws) rather than guessing an interface when that interface cannot be
    identified. Writes via Add-PersistentNetRoute (route.exe -p add), not
    New-NetRoute -- see that function's own doc comment for why (live-proven Rule 1
    environment-bug fix, 14.5-06 Task 2).
    #>
    [CmdletBinding()]
    param()

    $routeConfiguration = Get-VpsRouteConfiguration

    if ([string]::IsNullOrWhiteSpace($routeConfiguration.DestinationPrefix) -or [string]::IsNullOrWhiteSpace($routeConfiguration.NextHop)) {
        Write-Log -Level Warning -Message 'VPS_ROUTE_PREFIX and/or VPS_ROUTE_NEXT_HOP is blank in .env -- skipping the persistent host route step. No persistent route to the relay was added, so it will NOT survive a reboot until both keys are set and install.ps1 -RegisterTunnel is re-run.'
        return
    }

    $destinationPrefix = $routeConfiguration.DestinationPrefix
    $nextHop = $routeConfiguration.NextHop

    if (Test-VpsRoutePersistent -DestinationPrefix $destinationPrefix) {
        Write-Log -Level Info -Message "Persistent route $destinationPrefix -> $nextHop already present -- no-op (idempotent)"
        return
    }

    $interfaceIndex = Find-RouteNextHopInterfaceIndex -NextHop $nextHop
    if (-not $interfaceIndex) {
        throw "Cannot find an interface on-link with next hop '$nextHop' to scope the persistent VPS route to -- refusing to guess an interface. Connect the network carrying that gateway before re-running install.ps1 -RegisterTunnel."
    }

    $destinationPrefixParts = $destinationPrefix -split '/'
    $destinationIp = $destinationPrefixParts[0]
    $subnetMask = ConvertTo-DottedSubnetMask -PrefixLength ([int] $destinationPrefixParts[1])

    $routeExitCode = Add-PersistentNetRoute -DestinationIp $destinationIp -SubnetMask $subnetMask `
        -NextHop $nextHop -InterfaceIndex $interfaceIndex

    if ($routeExitCode -ne 0) {
        throw "route.exe -p add failed with exit code $routeExitCode while persisting $destinationPrefix -> $nextHop on interface index $interfaceIndex"
    }

    Write-Log -Level Info -Message "Persisted route $destinationPrefix -> $nextHop on interface index $interfaceIndex -- survives reboot"
}

function Invoke-TunnelRegistration {
    <#
    .SYNOPSIS
    Applies the tunnel Scheduled Task registration + persistent NIC2 VPS
    route (AO-01/D-09, 14.5-06 Task 2) -- the live-apply surface for
    install.ps1 -RegisterTunnel. Deliberately NOT part of Invoke-Install's
    default flow: this touches the network path currently carrying the live
    escape tunnel, so it must only run after the plan's operator checkpoint
    approves applying in a confirmed no-stream window. Registration/
    route-persistence itself does not restart the currently-running tunnel
    process or interrupt a live stream -- it only writes Task Scheduler and
    routing-table state that takes effect on the NEXT boot.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    Write-Log -Level Info -Message 'Gapless TCP relay tunnel registration starting (AO-01/D-09)'

    if (-not (Test-IsElevatedProcess)) {
        Write-Log -Level Error -Message 'Not running as Administrator -- re-run install.ps1 -RegisterTunnel from an elevated (Administrator) PowerShell session. Nothing was registered or persisted.'
        return $script:ExitCodePrerequisiteFailure
    }

    $pwshCommand = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    if (-not $pwshCommand) {
        Write-Log -Level Error -Message 'pwsh.exe (PowerShell 7) was not found on PATH -- install PowerShell 7 before running install.ps1 -RegisterTunnel. Nothing was registered or persisted.'
        return $script:ExitCodePrerequisiteFailure
    }

    Register-TunnelScheduledTask -ScriptRoot $PSScriptRoot
    Set-VpsRoutePersistent

    Write-Log -Level Info -Message "Tunnel registration complete -- see the preceding log lines for whether the Scheduled Task '$script:TunnelTaskName' was registered or skipped, and whether a persistent VPS route was added or skipped (AO-01/D-09)."
    return $script:ExitCodeSuccess
}

function Invoke-Install {
    <#
    .SYNOPSIS
    Main install flow: validate prerequisites (bail loud+non-zero before touching
    anything if invalid, T-04-10), then first-run .env copy, then register the
    Scheduled Task. Never a half-applied install -- registration only runs once
    every prerequisite problem is resolved.

    RETURNS this installer's exit code rather than calling `exit` itself: `exit`
    is a flow-control exception that tears down the whole host, so an
    exit-inside-the-flow made the main path impossible to drive from Pester --
    which is precisely why the crash this function used to have on the
    all-prerequisites-PASS path shipped unnoticed. The single `exit` now lives at
    the script's bottom guard, the one place that is genuinely a process edge
    (CLAUDE.md: side effects isolated at edges). Every logging path stays on the
    error/warning/host streams (lib/Logging.psm1), so nothing pollutes the
    returned exit code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    Write-Log -Level Info -Message "Gapless SRT Pusher installer starting (script root '$PSScriptRoot')"

    # Plain assignment, deliberately NOT `@(Test-InstallPrerequisites)`: the
    # callee returns its array via unary comma, which emits the array as ONE
    # un-enumerated pipeline item. `@(...)` collects pipeline ITEMS, so wrapping
    # this call would build a 1-element array CONTAINING the empty array --
    # .Count = 1 on a healthy machine, inverting the check and reporting a blank
    # "Prerequisite check failed: " problem. The unary-comma return is the whole
    # fix; an @() wrapper here re-breaks it. (`@($problems)` on the resulting
    # VARIABLE is safe -- that enumerates the array -- which is exactly why the
    # `@($problems).Count | Should -Be 0` unit assertion stayed green while the
    # real installer crashed. Mirrors pusher.ps1:64 / Test-PusherConfig.)
    $problems = Test-InstallPrerequisites
    if ($problems.Count -gt 0) {
        foreach ($problem in $problems) {
            Write-Log -Level Error -Message "Prerequisite check failed: $problem"
        }
        Write-Log -Level Error -Message 'Install aborted -- fix the problem(s) above and re-run install.ps1. No Scheduled Task was registered.'
        return $script:ExitCodePrerequisiteFailure
    }

    Initialize-PusherEnvFile -ScriptRoot $PSScriptRoot
    Register-PusherScheduledTask -ScriptRoot $PSScriptRoot

    Write-Log -Level Info -Message "Install complete. Scheduled Task '$script:TaskName' will start supervisor.ps1 at boot (SVC-01)."
    Write-Log -Level Info -Message 'The supervisor comes up IDLE at boot -- it streams NOTHING until you start it. Run start.ps1 to begin a service and stop.ps1 to end it (Phase 5''s dashboard buttons write the same control flag, state/control.json).'
    Write-Log -Level Info -Message 'pusher.ps1 exit-code contract (D-12), enforced by supervisor.ps1: 0 = clean end-of-service (stays down, and the control flag is set back to stopped), 2 = config validation failure (stays down -- fix .env, then run start.ps1 again), any other non-zero = crash (the supervisor relaunches the pusher automatically with backoff; the recording file on disk is the buffer, so the stream catches back up).'
    return $script:ExitCodeSuccess
}

# Only run the real install/registration flow when this script is invoked
# directly -- when dot-sourced (tests/Install.Tests.ps1's
# `. $script:InstallScriptPath`), every function above is defined and
# mockable, but nothing executes or exits. This guard is the installer's
# single process edge -- the one place `exit` belongs (Invoke-Install and
# Invoke-TunnelRegistration both return their exit code so each flow stays
# testable). -RegisterTunnel routes to the separate opt-in tunnel-autostart
# flow (AO-01/D-09) instead of the default pusher install flow -- see the
# param block and Invoke-TunnelRegistration's own doc comment for why these
# are never combined into one invocation.
if ($MyInvocation.InvocationName -ne '.') {
    if ($RegisterTunnel) {
        exit (Invoke-TunnelRegistration)
    }
    exit (Invoke-Install)
}

# ControlFlag.psm1
# Sole owner of the {desired: stopped|streaming} control flag -- the seam between an
# explicit operator command (start.ps1 / stop.ps1, and Phase 5's dashboard Start
# button) and supervisor.ps1's run loop. Persisted atomically via
# write-temp-then-rename, exactly as OffsetStore.psm1 persists the byte offset (D-08).
#
# TWO QUESTIONS, OPPOSITE SAFE ANSWERS. This module answers two different questions
# about the same file, and an unreadable file must answer them differently. The default
# follows the QUESTION, not the file:
#
#   Get-PusherDesiredState        -- "may the supervisor START streaming?"
#                                    unreadable => NO. Streaming to a live audience
#                                    unattended, with nobody in the room, is the
#                                    unrecoverable mistake.
#   Test-PusherExplicitStopRequested -- "did the operator ask a RUNNING pusher to stop?"
#                                    unreadable => NO SIGNAL, keep streaming. Ending a
#                                    live church service because a file was momentarily
#                                    unreadable is unrecoverable content loss; a stop
#                                    that does not take is recoverable (press Stop
#                                    again, or Cut). Never end a live service on the
#                                    strength of a parse error.
#
# Both are therefore biased AWAY from the irreversible outcome, which is why they point
# in opposite directions -- and why they must never be collapsed into one function.
# Get-PusherDesiredState's 'stopped' default is itself the deliberate inverse of
# OffsetStore's re-send bias: an offset that cannot be trusted is resolved toward
# sending bytes again, because the cost of being wrong there is only duplicate bytes.
# Neither reader ever throws on untrusted persisted input (ASVS V5).
#
# WHY BOTH READERS ARE SILENT (no Write-Log on any fallback path, unlike the loud
# Restore-PusherOffset they otherwise mirror): the supervisor polls
# Get-PusherDesiredState once per second for the entire time the machine is idle --
# i.e. all week between services -- and the pusher polls
# Test-PusherExplicitStopRequested on every tick of its hot loop for the whole
# service. A single Write-Log on the missing-or-corrupt path would emit ~86,000 lines
# per idle day, blowing the bounded log budget (D-14/SVC-03) and rotating the pusher's
# real diagnostic history off disk. Loudness for this value is owned by the callers
# instead, and only for TRANSITIONS: supervisor.ps1 logs desired-state changes (once
# per change, not once per poll), pusher.ps1 logs the one Streaming -> Draining
# transition an explicit stop causes, and Set-PusherDesiredState below logs every write.
# A corrupt control file is also self-healing -- the operator's next Start writes a
# valid file over it atomically.
#
# Exports: Get-PusherDesiredState, Test-PusherExplicitStopRequested,
#          Set-PusherDesiredState, Get-PusherControlFilePath

Set-StrictMode -Version Latest

# Import the logger explicitly (WR-02, OffsetStore parity): Set-PusherDesiredState
# calls Write-Log, so relying on the caller to have imported Logging would turn a
# CommandNotFoundException loose on the operator's Start command. Deliberately NOT
# -Force: a re-import would reset Logging's already-configured LogDirectory back to
# its module default, redirecting an in-flight service's logs mid-run.
Import-Module (Join-Path $PSScriptRoot 'Logging.psm1')

$script:DesiredStateStopped = 'stopped'
$script:DesiredStateStreaming = 'streaming'

function Get-PusherControlFilePath {
    <#
    .SYNOPSIS
    The one place the control flag's on-disk location is decided:
    <ScriptRoot>/state/control.json, alongside the existing state/offset.json and
    state/logs. supervisor.ps1, start.ps1 and stop.ps1 all resolve the path through
    here rather than each repeating the literal -- three copies of a path literal is
    three chances for the operator's Start button to write a file the supervisor
    never reads.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ScriptRoot
    )

    return (Join-Path $ScriptRoot 'state/control.json')
}

function Read-PusherControlFileDesiredValue {
    <#
    .SYNOPSIS
    Private (never exported): returns the `desired` value exactly as it is written on
    disk, or $null when there is nothing trustworthy to read -- no file (a fresh boot),
    empty file, corrupt JSON, no `desired` property, or any read error.

    $null means NO SIGNAL, and deliberately nothing more than that. The two public
    readers map $null to OPPOSITE answers (see the module header), so this function
    must not resolve it on their behalf: the single parse lives here so the two
    readers can never drift apart on what the file says, while each keeps ownership
    of what to do when the file says nothing.

    Never throws, never logs (see module header for both).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ControlFilePath
    )

    if (-not (Test-Path -LiteralPath $ControlFilePath)) {
        return $null
    }

    # The whole body is wrapped so this function genuinely never throws on untrusted
    # persisted state (OffsetStore's Restore-PusherOffset / Resolve-ResumeOffset
    # never-throw contract). The expected malformed cases below are each handled by
    # an explicit guard rather than by falling into this catch -- a catch that is
    # load-bearing for ordinary inputs hides the unexpected ones it exists to catch.
    try {
        # .NET static file APIs resolve relative paths against the process CWD, not
        # the PowerShell location (WR-03) -- and a Scheduled Task's CWD is
        # %windir%\system32.
        $absoluteControlFilePath = [System.IO.Path]::GetFullPath($ControlFilePath)
        $rawControlJson = [System.IO.File]::ReadAllText($absoluteControlFilePath)
        if ([string]::IsNullOrWhiteSpace($rawControlJson)) {
            return $null
        }

        $control = $rawControlJson | ConvertFrom-Json
        $desiredProperty = $control.PSObject.Properties['desired']
        if (-not $desiredProperty) {
            return $null
        }
        return $desiredProperty.Value
    } catch {
        return $null
    }
}

function Get-PusherDesiredState {
    <#
    .SYNOPSIS
    Answers "may the supervisor START streaming?". Returns 'streaming' ONLY when the
    file exists, parses as JSON, and carries a `desired` property whose value is
    exactly 'streaming'. Every other outcome -- no file (a fresh boot), empty file,
    corrupt JSON, no `desired` property, an unrecognised value -- returns 'stopped',
    because starting an unattended stream to a live audience is the unrecoverable
    mistake (module header). Never throws, never logs.

    .OUTPUTS
    String: 'stopped' or 'streaming'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ControlFilePath
    )

    $desiredValue = Read-PusherControlFileDesiredValue -ControlFilePath $ControlFilePath
    if ($desiredValue -eq $script:DesiredStateStreaming) {
        return $script:DesiredStateStreaming
    }
    return $script:DesiredStateStopped
}

function Test-PusherExplicitStopRequested {
    <#
    .SYNOPSIS
    Answers the OTHER question: "did the operator ask a RUNNING pusher to stop?".
    Returns $true ONLY when the control file exists, parses, and explicitly says
    desired='stopped'. Missing file, empty file, corrupt JSON, absent property,
    unrecognised value, or any read error all return $false -- NO SIGNAL, keep
    streaming. Never throws, never logs.

    This is NOT `(Get-PusherDesiredState -eq 'stopped')`, and the difference is the
    whole reason the function exists. That expression would read a missing or corrupt
    file as an operator stop, which would (a) end a live church service on the
    strength of a parse error, and (b) make every existing integration test -- and any
    hand-run pusher.ps1, none of which have a control file -- drain and exit 0 the
    instant they started, turning the suite green for entirely the wrong reason.
    Silence is not a stop.

    .OUTPUTS
    Bool.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $ControlFilePath
    )

    $desiredValue = Read-PusherControlFileDesiredValue -ControlFilePath $ControlFilePath
    # -is [string] before the comparison: a `desired` deserialised as an array or an
    # object would make a bare -eq return a truthy filtered collection rather than a
    # bool, i.e. would end a live service on a malformed value. The bias here is always
    # "anything I do not positively recognise is not a stop".
    return ($desiredValue -is [string] -and $desiredValue -eq $script:DesiredStateStopped)
}

function Set-PusherDesiredState {
    <#
    .SYNOPSIS
    Atomically persists {desired} to ControlFilePath: writes a temp file in the same
    directory, then renames it over the final path with the single-syscall atomic
    replace [System.IO.File]::Move(src, dst, overwrite:$true) (MoveFileEx +
    MOVEFILE_REPLACE_EXISTING) -- unlike Move-Item -Force, which is delete-then-move
    with a crash window in which no control file exists. Reuses Save-PusherOffset's
    exact discipline (OffsetStore.psm1) because the failure mode is the same: the
    supervisor may read this file at any instant, and must never see a half-written
    one (D-08, CR-04).

    ValidateSet rejects an unrecognised state at parameter-binding time, BEFORE the
    body runs -- so a bad value never creates a directory, never writes a temp file,
    and never touches the previous good control file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ControlFilePath,
        [Parameter(Mandatory)] [ValidateSet('stopped', 'streaming')] [string] $DesiredState
    )

    $absoluteControlFilePath = [System.IO.Path]::GetFullPath($ControlFilePath)
    $controlDirectory = Split-Path -Parent $absoluteControlFilePath
    if ($controlDirectory -and -not (Test-Path -LiteralPath $controlDirectory)) {
        New-Item -ItemType Directory -Path $controlDirectory -Force | Out-Null
    }

    $temporaryPath = Join-Path $controlDirectory ("control.{0}.tmp" -f [Guid]::NewGuid())
    $payload = @{ desired = $DesiredState } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($temporaryPath, $payload)

    # The atomic replace can transiently fail with "Access to the path is denied" when
    # a scanner (Windows Defender real-time, Search indexer, a backup agent) holds a
    # momentary handle on the destination -- observed against Save-PusherOffset's live
    # per-250ms commit cadence, and the same discipline applies here. The failure is
    # transient (clears in a few ms), so retry with a short backoff. The write stays
    # atomic: the temp file is already fully written, and on total exhaustion the
    # PREVIOUS good control file is still intact (we never deleted it), so the worst
    # case is a rejected operator command that reports itself loudly, never a
    # corrupt/missing control file. A persistent denial (a real ACL problem) still
    # throws after the final attempt.
    $maximumMoveAttempts = 5
    $moveBackoffMilliseconds = 20
    for ($attempt = 1; ; $attempt++) {
        try {
            [System.IO.File]::Move($temporaryPath, $absoluteControlFilePath, $true)
            break
        } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if ($attempt -ge $maximumMoveAttempts) {
                if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
                throw
            }
            Start-Sleep -Milliseconds $moveBackoffMilliseconds
        }
    }

    Write-Log -Level Info -Message "Desired state set to '$DesiredState' in '$absoluteControlFilePath'"
}

Export-ModuleMember -Function Get-PusherDesiredState, Test-PusherExplicitStopRequested, Set-PusherDesiredState, Get-PusherControlFilePath

# ProbeHost.psm1
# The isolation engine that makes MON-05 structural rather than hopeful (06-04-PLAN.md):
# probe discovery (folder scan + per-probe enable-flag gating, D-03), a per-probe HARD
# timeout that actually abandons a hung probe ([powershell]::Create() + AddScript() +
# BeginInvoke() + AsyncWaitHandle.WaitOne(timeoutMs) + .Stop() -- the ONLY mechanism in
# .NET/PowerShell that can interrupt a hung synchronous call from outside a runspace,
# D-04/D-05), and a scheduler loop that persists each result via ProbeStore.psm1's
# Save-ProbeResult. Running each probe in its own throwaway child instance also solves
# the multi-module Invoke-Probe name-collision problem for free -- each child imports
# exactly one probe module.
#
# DISCOVERY VS. ENABLEMENT (D-03/D-14 reconciliation): discovering WHAT probe files
# exist stays a pure Get-ChildItem probes/*.psm1 scan -- no manifest registry, no
# marketplace (D-03/YAGNI). A probe is only ACTIVE when its .env enable flag is true.
# The bridge between a discovered filename stem and its Config enable property is a
# fixed, deterministic naming formula (Get-ProbeConfigPropertyName below): 'vps' ->
# 'ProbeVpsEnabled', matching lib/Config.psm1's real PROBE_VPS_ENABLED schema row
# verbatim. This is still "no manifest file" -- there is no per-probe registration step
# anywhere -- but it additionally means Phase 7's probes/omr.psm1 (MON-02) needs no
# edit to THIS module at all, only its own Config schema row (ProbeOmrEnabled), which
# 06-PATTERNS.md's "Contract generality for Phase 7" section already requires of the
# rest of the D-02 schema. An unrecognized stem, or a Config object with no matching
# property, safely defaults to DISABLED -- never silently activated.
#
# TIMESTAMP OWNERSHIP (mirrors StatsStore/ProbeStore's own precedent): a probe module's
# Invoke-Probe never returns updatedEpochSeconds/staleAfterEpochSeconds -- only the
# HOST, at the moment it actually persists a result via Save-ProbeResult, can honestly
# declare "as of when" and "stale after when" (see ProbeStore.psm1's own header).
#
# SAFE-DEFAULT NORMALIZATION (T-06-08, Tampering): a probe module is explicitly
# extensible/potentially church-authored (MON-01) and therefore less trusted than this
# repo's own first-party writers. Get-NormalizedProbeResult coerces a missing/invalid
# name, title, status, or metrics shape to a safe default BEFORE it ever reaches
# Save-ProbeResult's ValidateSet'd -Status parameter -- a malformed probe result must
# degrade to an 'unknown'-ish persisted result, never crash the host or the cycle.
#
# Exports: Invoke-ProbeWithTimeout, Invoke-ProbeHostLoop, Get-EnabledProbeModulePaths

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ProbeStore.psm1')
Import-Module (Join-Path $PSScriptRoot 'Clock.psm1')

# RESEARCH.md Open Question 2: probe poll cadence stays a code-only internal constant
# for v1 (YAGNI, mirroring Config.psm1's "empirically-tuned internal safety constants
# stay code-only" convention) -- not .env-configurable this phase. Callers (tests, and
# 06-07's supervisor wiring) may still override it via the parameter below.
$script:DefaultPollIntervalSeconds = 20

# The D-02 schema's four possible status values -- the same ValidateSet
# Save-ProbeResult (ProbeStore.psm1) enforces. Kept as a script-scoped constant here so
# Get-NormalizedProbeResult's coercion and Save-ProbeResult's own validation can never
# silently drift apart.
$script:ValidProbeStatuses = @('ok', 'degraded', 'down', 'unknown')

function Get-ProbeConfigPropertyName {
    <#
    .SYNOPSIS
    Private (never exported). Deterministic filename-stem -> Config property name
    derivation for the D-03/D-14 discovery-vs-enablement bridge: 'vps' ->
    'ProbeVpsEnabled', matching lib/Config.psm1's real PROBE_VPS_ENABLED schema row.
    A fixed formula, not a manifest file or a per-probe switch arm -- adding a new
    probe type needs only a new Config schema row, never an edit here.

    .OUTPUTS
    String: the Config property name this probe's enable flag would carry.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ModuleStem
    )

    $lowerCaseStem = $ModuleStem.ToLowerInvariant()
    $pascalCaseStem = (Get-Culture).TextInfo.ToTitleCase($lowerCaseStem) -replace '[^A-Za-z0-9]', ''
    return "Probe${pascalCaseStem}Enabled"
}

function Test-ProbeModuleEnabled {
    <#
    .SYNOPSIS
    Private (never exported). Whether a discovered probe module stem is ACTIVE per
    D-03: true only when Config carries a matching enable property AND it is truthy.
    An unrecognized stem, or a Config object with no matching property at all
    (StrictMode-safe -- property existence is checked before access), safely defaults
    to disabled. Never throws.

    .OUTPUTS
    Bool.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $ModuleStem,
        [AllowNull()] $Config
    )

    if ($null -eq $Config) { return $false }

    $configPropertyName = Get-ProbeConfigPropertyName -ModuleStem $ModuleStem
    if ($Config.PSObject.Properties.Name -notcontains $configPropertyName) {
        return $false
    }

    return [bool] $Config.$configPropertyName
}

function Get-EnabledProbeModulePaths {
    <#
    .SYNOPSIS
    D-03 discovery: a plain folder scan of ProbesDirectory for *.psm1 files, gated by
    each discovered module's mapped Config enable property (Test-ProbeModuleEnabled).
    No manifest registry, no marketplace, no auto-download -- dropping a new .psm1
    file in IS the entire "install" step for a new probe type; whether it is ACTIVE is
    controlled entirely by Config (D-14).

    A missing or empty ProbesDirectory returns an empty array -- the MON-04
    zero-probe baseline -- never $null and never throws, matching this repo's own
    documented PowerShell array-return-safety convention (STATE.md: wrap a return as
    ", $array" so a StrictMode caller always gets a real array on zero/one-element
    results).

    .OUTPUTS
    String[]: full paths to every ENABLED probe module, or an empty array.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $ProbesDirectory,
        [Parameter(Mandatory)] $Config
    )

    if (-not (Test-Path -LiteralPath $ProbesDirectory)) {
        return , @()
    }

    $discoveredModuleFiles = @(Get-ChildItem -LiteralPath $ProbesDirectory -Filter '*.psm1' -File -ErrorAction SilentlyContinue | Sort-Object -Property Name)

    $enabledModulePaths = [System.Collections.Generic.List[string]]::new()
    foreach ($moduleFile in $discoveredModuleFiles) {
        if (Test-ProbeModuleEnabled -ModuleStem $moduleFile.BaseName -Config $Config) {
            $enabledModulePaths.Add($moduleFile.FullName)
        }
    }

    return , $enabledModulePaths.ToArray()
}

function Invoke-ProbeWithTimeout {
    <#
    .SYNOPSIS
    Runs ProbeModulePath's Invoke-Probe inside its own throwaway child [powershell]
    instance and races it against a hard timeout (D-04/D-05, MON-05's core mechanism).
    A synchronous call inside a thread cannot be interrupted from outside -- only an
    async BeginInvoke() raced against AsyncWaitHandle.WaitOne(timeoutMs), followed by
    an explicit .Stop(), can abandon a hung operation. This is the one place this
    repo's codebase introduces that pattern fresh (06-PATTERNS.md: no local twin
    existed before this phase); Stop-FfmpegProcess's TOCTOU-safe try/catch-every-call
    idiom (lib/FfmpegProcess.psm1) is mirrored for the abandonment path below, since
    the child can also finish or fault in the brief window between WaitOne returning
    false and this call.

    Running each probe in its OWN child instance also solves the multi-module
    Invoke-Probe name-collision problem for free: each child imports exactly one probe
    module, so two probe modules that both export Invoke-Probe never collide (D-04).

    .OUTPUTS
    PSCustomObject: the probe's own raw result on the completed-in-time branch, or a
    status='unknown' timeout result (name/title omitted -- the HOST fills those in via
    Get-NormalizedProbeResult, mirroring StatsStore's timestamp-ownership precedent).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $ProbeModulePath,
        [Parameter(Mandatory)] $ProbeConfig,
        [Parameter(Mandatory)] [int] $HardTimeoutMilliseconds
    )

    $childPowerShell = [powershell]::Create()
    try {
        [void] $childPowerShell.AddScript({
            param($ModulePath, $Config)
            Import-Module $ModulePath -Force
            Invoke-Probe -Config $Config
        }).AddArgument($ProbeModulePath).AddArgument($ProbeConfig)

        $asyncResult = $childPowerShell.BeginInvoke()
        $completedInTime = $asyncResult.AsyncWaitHandle.WaitOne($HardTimeoutMilliseconds)

        if ($completedInTime) {
            $results = $childPowerShell.EndInvoke($asyncResult)
            return $results[0]
        }

        # Abandon: .Stop() sends a stop-processing signal to the child pipeline --
        # reliably interrupts most hung managed-code operations (a Start-Sleep, a
        # blocked Receive() on a socket honoring cancellation), but is NOT guaranteed
        # against a call blocked deep in unmanaged/native code with no cancellation
        # path. Wrapped in its own try/catch (Stop-FfmpegProcess's TOCTOU-safe
        # convention): the child can also finish or fault on its own in the window
        # between WaitOne returning false and this call.
        try { $childPowerShell.Stop() } catch { }

        return [pscustomobject]@{
            name    = $null
            title   = $null
            status  = 'unknown'
            metrics = @()
            detail  = "probe timed out after ${HardTimeoutMilliseconds}ms"
        }
    } finally {
        try { $childPowerShell.Dispose() } catch { }
    }
}

function Test-ProbeResultHasNonEmptyStringProperty {
    <#
    .SYNOPSIS
    Private (never exported). StrictMode-safe check: does ProbeResult carry
    PropertyName, and is its value a non-empty/non-whitespace string? Used by
    Get-NormalizedProbeResult's name/title fallback logic -- a probe module is
    less-trusted input (MON-01), so no field is read without first confirming it
    exists (mirrors lib/Dashboard.psm1's Test-DashboardStatsHasProperty pattern).

    .OUTPUTS
    Bool.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()] $ProbeResult,
        [Parameter(Mandatory)] [string] $PropertyName
    )

    if ($null -eq $ProbeResult) { return $false }
    if ($ProbeResult.PSObject.Properties.Name -notcontains $PropertyName) { return $false }

    return -not [string]::IsNullOrWhiteSpace($ProbeResult.$PropertyName)
}

function Get-NormalizedProbeResult {
    <#
    .SYNOPSIS
    T-06-08 safe-default normalization: coerces a probe's raw result (which may be
    $null, partial, or carry an invalid shape -- a probe module is explicitly
    less-trusted, potentially church-authored input, MON-01) into the five fields
    Save-ProbeResult requires, never trusting the raw shape directly.
      name    -- falls back to the probe module's own filename stem
      title   -- falls back to the resolved name
      status  -- coerced to 'unknown' unless it is exactly one of
                 ok|degraded|down|unknown (Save-ProbeResult's own ValidateSet)
      metrics -- coerced to an empty array unless it is already an array
      detail  -- passed through as-is if present, otherwise $null
    A malformed probe result therefore degrades to a safe, persistable shape -- it
    never crashes the host or the cycle (MON-04's "zero plugins/a broken plugin must
    not break local stats either" implication).

    .OUTPUTS
    PSCustomObject: { name, title, status, metrics, detail }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] $ProbeResult,
        [Parameter(Mandatory)] [string] $ProbeModulePath
    )

    $fallbackName = [System.IO.Path]::GetFileNameWithoutExtension($ProbeModulePath)

    $normalizedName = if (Test-ProbeResultHasNonEmptyStringProperty -ProbeResult $ProbeResult -PropertyName 'name') {
        $ProbeResult.name
    } else {
        $fallbackName
    }

    $normalizedTitle = if (Test-ProbeResultHasNonEmptyStringProperty -ProbeResult $ProbeResult -PropertyName 'title') {
        $ProbeResult.title
    } else {
        $normalizedName
    }

    $rawStatus = if (($null -ne $ProbeResult) -and ($ProbeResult.PSObject.Properties.Name -contains 'status')) {
        $ProbeResult.status
    } else {
        $null
    }
    $normalizedStatus = if ($script:ValidProbeStatuses -contains $rawStatus) { $rawStatus } else { 'unknown' }

    # STATEMENT assignment (not an if/else EXPRESSION capture, Dashboard.psm1's
    # Get-ProbePanelViewModel convention): a genuine single-element metrics array
    # (e.g. one latency reading) is exactly the case an expression-form `$x = if
    # (...) { $ProbeResult.metrics } ...` silently destroys -- the if-branch's output
    # is routed through the pipeline, which unwraps a 1-element array down to its
    # bare element before the assignment ever sees it (confirmed empirically while
    # writing 06-09's full-chain integration test: a real single-metric probe result
    # arrived here as a bare Hashtable, not an array, and fell through to the
    # zero-metrics branch below). A plain if/else statement is a direct reference
    # copy, never routed through the output stream, so it cannot collapse.
    if (($null -ne $ProbeResult) -and ($ProbeResult.PSObject.Properties.Name -contains 'metrics')) {
        $rawMetrics = $ProbeResult.metrics
    } else {
        $rawMetrics = $null
    }
    # Unary comma at the exact branch-output point (NOT merely on the intermediate
    # variable): PowerShell's if/else-as-expression capture unrolls a bare empty-array
    # branch output to $null, the identical array-return-safety pitfall STATE.md
    # documents for `return` statements -- confirmed empirically here, since even
    # `$x = if (...) { , @() }` still collapsed when the comma was applied one level
    # too early. A zero-metrics probe result must stay a real empty array, never
    # $null, so PSObject.Properties.Name -contains 'metrics' checks downstream (and
    # Save-ProbeResult's own -Metrics array binding) never see a StrictMode surprise.
    $normalizedMetrics = if ($rawMetrics -is [array]) { , $rawMetrics } else { , @() }

    $normalizedDetail = if (($null -ne $ProbeResult) -and ($ProbeResult.PSObject.Properties.Name -contains 'detail')) {
        $ProbeResult.detail
    } else {
        $null
    }

    return [pscustomobject]@{
        name    = $normalizedName
        title   = $normalizedTitle
        status  = $normalizedStatus
        metrics = $normalizedMetrics
        detail  = $normalizedDetail
    }
}

function Invoke-ProbeHostLoop {
    <#
    .SYNOPSIS
    The scheduler (D-04/D-06): each cycle, discovers the currently-enabled probes
    (Get-EnabledProbeModulePaths), runs each one through Invoke-ProbeWithTimeout, and
    persists the normalized result via ProbeStore.psm1's Save-ProbeResult to
    <StateProbesDirectory>/<name>.json. The HOST supplies name/title fallbacks and
    owns the persist call -- timestamps come from Save-ProbeResult itself (D-07),
    mirroring StatsStore's precedent.

    Every probe's poll-and-persist step is individually guarded by its own try/catch:
    one probe's failure, timeout-turned-exception, or a Save-ProbeResult write error
    never aborts the cycle for its siblings (MON-05 isolation -- one church's flaky
    router probe must not freeze the VPS panel next to it, and vice versa).

    -MaxCycles bounds the loop for tests (0 = unbounded, the production default --
    this is a boot-to-shutdown background worker, mirroring Invoke-Supervisor's own
    -MaxTicks test seam). -PollIntervalSeconds defaults to a code-only constant
    (RESEARCH.md Open Question 2, YAGNI) but tests may pass 0 to skip the real sleep.

    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ProbesDirectory,
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [int] $HardTimeoutMilliseconds,
        [int] $PollIntervalSeconds = $script:DefaultPollIntervalSeconds,
        [Parameter(Mandatory)] [string] $StateProbesDirectory,
        [int] $MaxCycles = 0
    )

    for ($cycleNumber = 1; ($MaxCycles -le 0) -or ($cycleNumber -le $MaxCycles); $cycleNumber++) {
        $enabledProbeModulePaths = Get-EnabledProbeModulePaths -ProbesDirectory $ProbesDirectory -Config $Config

        foreach ($probeModulePath in $enabledProbeModulePaths) {
            try {
                $rawProbeResult = Invoke-ProbeWithTimeout -ProbeModulePath $probeModulePath -ProbeConfig $Config -HardTimeoutMilliseconds $HardTimeoutMilliseconds
                $normalizedProbeResult = Get-NormalizedProbeResult -ProbeResult $rawProbeResult -ProbeModulePath $probeModulePath

                $probeResultFilePath = Join-Path $StateProbesDirectory ("{0}.json" -f $normalizedProbeResult.name)
                Save-ProbeResult -ProbeResultFilePath $probeResultFilePath -Name $normalizedProbeResult.name `
                    -Title $normalizedProbeResult.title -Status $normalizedProbeResult.status `
                    -Metrics $normalizedProbeResult.metrics -Detail $normalizedProbeResult.detail
            } catch {
                # MON-05 isolation: one probe's failure (a thrown exception from its
                # own Invoke-Probe, or a Save-ProbeResult write error) must never abort
                # this cycle for its siblings -- the next cycle simply tries again.
            }
        }

        if ($MaxCycles -gt 0 -and $cycleNumber -ge $MaxCycles) { break }
        if ($PollIntervalSeconds -gt 0) { Start-Sleep -Seconds $PollIntervalSeconds }
    }
}

Export-ModuleMember -Function Invoke-ProbeWithTimeout, Invoke-ProbeHostLoop, Get-EnabledProbeModulePaths

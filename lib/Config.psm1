# Config.psm1
# Sole parser + validator of the secret-free .env file (CFG-01, CFG-03).
# Read-PusherConfig replaces pusher.ps1's ~30 top-of-script literals with a single
# typed settings object: every key has a code-level default (D-03), an optional
# .env override for the operator-facing subset (D-05), and the empirically-tuned
# internal safety constants (D-06) stay code-default-only -- never sourced from
# .env, even though they are still exposed as properties so pusher.ps1's hot loop
# can read $config.* uniformly instead of loose top-of-script literals.
#
# Read-DotEnvFile never throws (a missing .env is normal, D-03) and only maps
# schema-listed keys onto the returned object -- an unrecognised/credential-shaped
# .env key (e.g. a YouTube API key) is structurally dropped, never forwarded
# (D-07, T-04-01). Test-PusherConfig is the one deliberately fatal-by-convention
# exception to this module's "never throw" contract: it never exits or throws
# itself, but returns a problems list the CALLER (pusher.ps1) uses to exit loud
# on deployment-critical misconfiguration (D-08) -- the opposite of the hot
# loop's loud-but-non-terminating contract (02-07), so this path must never be
# reused for runtime logging.
#
# Write-DotEnvFile is the ONLY writer of .env (CFG-02/D-14): it patches raw text lines
# in place rather than regenerating the file from Read-PusherConfig's typed object --
# that object has already dropped every comment, blank line and unrecognised key on
# read (D-07), so serializing it back out would silently destroy an operator's own
# hand-written annotations. Its contract is "the operator's file survives" (D-15), and
# it refuses three ways -- deliberately, loudly, and BEFORE ever touching disk: a key
# with no matching schema EnvKey (config injection), a key naming an internal safety
# constant (EnvKey = $null, D-06 -- never .env-sourced even on write), and a proposed
# config Test-PusherConfig itself rejects (D-16, never a partial apply). A refusal the
# operator can read is always better than a service that will not start.
#
# Read-LiveTunableOverrides (DIAL-02, 14.5-07) is a NARROW sibling reader living
# alongside Read-PusherConfig -- it reads ONLY CATCH_UP_MULTIPLIER and
# SEND_CEILING_BYTES_PER_SECOND from .env, reusing Read-DotEnvFile +
# ConvertTo-CoercedConfigValue, and is the read half of the cross-process
# live-apply channel pusher.ps1 will poll every ~1s (14.5-08); Write-DotEnvFile
# above is the atomic write half. It deliberately does NOT call Read-PusherConfig
# or walk $script:ConfigSchema -- a full-schema reload would make every other
# .env key (RELAY_HOST, protocol, tunnel knobs) hot-reloadable too, which is
# exactly the scope creep the scope fence (T-14.5-07-03) exists to prevent. Each
# returned property is $null ONLY as a "no override" signal (key absent, blank
# file, unparseable value, or a value failing bounds) so the caller keeps its own
# current in-memory value -- mirrors ControlFlag.psm1's safe-default discipline.
# Never throws, even on a torn/locked read racing Write-DotEnvFile's atomic move.
#
# Exports: Read-DotEnvFile, Read-PusherConfig, Test-PusherConfig,
#          Resolve-PusherConfigPaths, Get-RedactedConfig, Write-DotEnvFile,
#          Read-LiveTunableOverrides, ConvertTo-BytesPerSecondFromMegabitsPerSecond,
#          ConvertTo-MegabitsPerSecondFromBytesPerSecond

Set-StrictMode -Version Latest

# Import the logger explicitly (WR-02 convention, mirrored from OffsetStore.psm1):
# Read-DotEnvFile's missing-.env path logs a Debug line, so relying on the caller
# to have imported Logging would turn a CommandNotFoundException loose exactly
# while handling the normal "no .env yet" case.
Import-Module (Join-Path $PSScriptRoot 'Logging.psm1')

# ---------------------------------------------------------------------------
# Config schema: one entry per config property. EnvKey is the SCREAMING_SNAKE_CASE
# .env name an operator can set; EnvKey = $null means the key is an empirically-
# tuned internal safety constant (D-06) that is NEVER read from .env -- only its
# code default is ever used, even if a church operator's .env happens to contain
# a matching line. Every default below is copied verbatim from pusher.ps1 lines
# ~29-79 EXCEPT CatchUpMultiplier, deliberately set to 1.5 instead of the current
# top-of-script 2.0 literal (Pitfall 4 / D-05's "lean 1.5x").
# ---------------------------------------------------------------------------
$script:ConfigSchema = @(
    # --- Operator-facing, .env-overridable (D-05) ---
    @{ EnvKey = 'RECORDING_FOLDER_PATH';                Property = 'RecordingFolderPath';                Type = 'string'; Default = 'state/' }
    @{ EnvKey = 'RECORDING_FILENAME_GLOB';               Property = 'RecordingFilenameGlob';               Type = 'string'; Default = '*.ts' }
    @{ EnvKey = 'RELAY_HOST';                            Property = 'RelayHost';                           Type = 'string'; Default = '127.0.0.1' }
    @{ EnvKey = 'RELAY_PORT';                            Property = 'RelayPort';                           Type = 'int';    Default = 8890 }
    # RELAY_PROTOCOL: 'tcp' (default) or 'srt' (advanced, needs a libsrt-enabled ffmpeg on
    # both ends). 'tcp' is the default because plain TCP's own congestion control paces the
    # send, which replaces SRT file-mode's retransmission-based recovery -- on an
    # uncontrolled network path that retransmission behaviour can feed back on itself into a
    # storm: loss triggers retransmits, retransmits add load, more load causes more loss.
    # That is exactly what happened in production on 2026-07-26, which is why 'tcp' became
    # the safer default rather than merely an alternative. With 'tcp' every SRT_* knob and
    # LATENCY_MICROSECONDS is ignored by Build-FfmpegArguments.
    @{ EnvKey = 'RELAY_PROTOCOL';                        Property = 'RelayProtocol';                       Type = 'string'; Default = 'tcp' }
    # --- Probe framework, off by default (D-14/MON-03). PROBE_VPS_ENABLED is the FIRST
    # schema row to use Type = 'bool' -- ConvertTo-CoercedConfigValue's [bool]::Parse case
    # already exists and is tested (RESEARCH Pitfall 4), this is just its first real
    # consumer. The SSH keys are OPTIONAL: the VPS probe reaches reachability+latency with
    # zero credentials (D-09) and reuses RELAY_HOST/RELAY_PORT above (D-10) -- no duplicate
    # relay address. PROBE_VPS_SSH_KEYPATH is a filesystem PATH, not key material, so it is
    # deliberately NOT added to Get-RedactedConfig below (D-09/RESEARCH). If a future
    # password-shaped credential is ever added to this schema, it MUST follow the exact
    # Get-RedactedConfig / SrtPassphrase precedent (blank stays blank, a set value becomes
    # the fixed '***REDACTED***' placeholder, never a substring/hash of the real value).
    @{ EnvKey = 'PROBE_VPS_ENABLED';                     Property = 'ProbeVpsEnabled';                     Type = 'bool';   Default = $false }
    @{ EnvKey = 'PROBE_VPS_SSH_HOST';                    Property = 'ProbeVpsSshHost';                     Type = 'string'; Default = '' }
    @{ EnvKey = 'PROBE_VPS_SSH_USER';                    Property = 'ProbeVpsSshUser';                     Type = 'string'; Default = '' }
    @{ EnvKey = 'PROBE_VPS_SSH_KEYPATH';                 Property = 'ProbeVpsSshKeyPath';                  Type = 'string'; Default = '' }
    # PROBE_VPS_SSH_PORT (CHUR-02/D-07): the SSH port used for the optional VPS health
    # probe above. Defaults to the standard SSH port, 22 -- set it only if the relay's
    # SSH daemon listens somewhere non-standard (e.g. behind a NAT port-forward). A port
    # is not key material (same reasoning as PROBE_VPS_SSH_KEYPATH above), so this row
    # is deliberately NOT added to Get-RedactedConfig below.
    @{ EnvKey = 'PROBE_VPS_SSH_PORT';                    Property = 'ProbeVpsSshPort';                     Type = 'int';    Default = 22 }
    @{ EnvKey = 'STREAM_ID';                             Property = 'StreamId';                            Type = 'string'; Default = 'church-01' }
    @{ EnvKey = 'LATENCY_MICROSECONDS';                  Property = 'LatencyMicroseconds';                 Type = 'int';    Default = 500000 }
    # SRT_MAXBW_BYTES_PER_SECOND (.planning/debug/srt-throughput-degraded-today.md): hard
    # ceiling on aggregate SRT send bandwidth (originals + retransmits), in BYTES/sec.
    # Default 0 = maxbw OMITTED (libsrt unlimited). The capped-maxbw direction was FALSIFIED
    # during the Tier-1 debug cycle -- it starved the retransmits a lossy path needs -- and a
    # positive maxbw also rate-caps the close-time flush, dropping the stream's tail bytes at
    # every clean finish (measured: 564-byte shortfall in the D-20 byte-match test). Opt in
    # explicitly via .env only with a measured reason. See FfmpegProcess.psm1.
    @{ EnvKey = 'SRT_MAXBW_BYTES_PER_SECOND';            Property = 'SrtMaxBandwidthBytesPerSecond';       Type = 'int';    Default = 0 }
    # TIER 1 sender-side SRT buffer/window tuning (.planning/debug/srt-throughput-degraded-today.md).
    # These ENLARGE sender buffering / reorder tolerance (the opposite of the falsified maxbw cap)
    # so a loss burst on a lossy or bandwidth-constrained upstream path is ridden out instead of
    # stalling the feed, and mirror the relay listener's receiver-side sizing (ffs=65536,
    # rcvbuf=64MB, lossmaxttl=4096). Each default OMITS the option (libsrt default = exact pre-Tier-1 behaviour)
    # so shipping them changes nothing until an operator opts in; the one-line revert per knob is
    # setting the .env value back to 0 (blank for SRT_NAK_REPORT). See FfmpegProcess.psm1.
    @{ EnvKey = 'SRT_SEND_BUFFER_BYTES';                 Property = 'SrtSendBufferBytes';                  Type = 'int';    Default = 0 }
    @{ EnvKey = 'SRT_FLIGHT_FLAG_SIZE_BYTES';            Property = 'SrtFlightFlagSizeBytes';              Type = 'int';    Default = 0 }
    @{ EnvKey = 'SRT_LOSS_MAX_TTL';                      Property = 'SrtLossMaxTtl';                       Type = 'int';    Default = 0 }
    @{ EnvKey = 'SRT_NAK_REPORT';                        Property = 'SrtNakReport';                        Type = 'string'; Default = '' }
    @{ EnvKey = 'CATCH_UP_MULTIPLIER';                   Property = 'CatchUpMultiplier';                   Type = 'double'; Default = 1.5 }
    # SEND_CEILING_BYTES_PER_SECOND (2026-07-26 incident): ABSOLUTE send-rate cap in bytes/sec.
    # When > 0 it REPLACES the CatchUpMultiplier x record-rate ceiling entirely -- the send rate
    # is then decoupled from the recording bitrate and bounded only by this value and the path
    # itself. 0 (default) keeps the legacy multiplier behaviour. Set it to just under the
    # measured path capacity (e.g. 2000000 = 16 Mbit) so catch-up fills the pipe regardless of
    # what OBS happens to be encoding at.
    @{ EnvKey = 'SEND_CEILING_BYTES_PER_SECOND';         Property = 'SendCeilingBytesPerSecond';           Type = 'long';   Default = [long]0 }
    # COLD_START_CATCH_UP_CEILING_BYTES_PER_SECOND (D-04, 2026-07-26 startup-lag incident):
    # the catch-up ceiling used ONLY during the startup blind window before any real record
    # rate has been observed. Default raised 750000 -> 3500000 (28 Mbit/s) because OBS
    # records at roughly 25-26 Mbit and the old 6 Mbit default made the pusher fall behind
    # at every start. This row always had a real EnvKey and was therefore always
    # .env-readable despite previously sitting among the internal-constants block below --
    # the move to this operator-facing block is the WR-02 correction; reading behaviour is
    # unchanged by the move itself, only the default value changes.
    @{ EnvKey = 'COLD_START_CATCH_UP_CEILING_BYTES_PER_SECOND'; Property = 'ColdStartCatchUpCeilingBytesPerSecond'; Type = 'long';   Default = [long] 3500000 }
    # GROWTH_RATE_SMOOTHING_SECONDS (260718-h23, DASH-BRIEF-1/2): the EWMA time-constant
    # tau for Pacer.psm1's Update-GrowthRateWindow SmoothedBytesPerSecond -- larger means
    # steadier dashboard numbers and pacing; <=0 disables smoothing (exact raw passthrough,
    # the resilience escape hatch). The decimal literal 30.0 is required (not 30) per the
    # locked 05.1 config decision -- a whole-number double MUST be written as a decimal
    # literal here, or the no-override path returns an uncoerced [int].
    @{ EnvKey = 'GROWTH_RATE_SMOOTHING_SECONDS';         Property = 'GrowthRateSmoothingSeconds';          Type = 'double'; Default = 30.0 }
    @{ EnvKey = 'OBS_PROCESS_NAME';                      Property = 'ObsProcessName';                      Type = 'string'; Default = 'obs64' }
    @{ EnvKey = 'GROWTH_STALL_SUSTAINED_WINDOW_SECONDS'; Property = 'GrowthStallSustainedWindowSeconds';   Type = 'int';    Default = 30 }
    @{ EnvKey = 'LOG_MAX_SIZE_BYTES';                    Property = 'LogMaxSizeBytes';                     Type = 'long';   Default = 10485760 }
    @{ EnvKey = 'LOG_RETENTION_COUNT';                   Property = 'LogRetentionCount';                   Type = 'int';    Default = 5 }
    @{ EnvKey = 'DASHBOARD_PORT';                        Property = 'DashboardPort';                       Type = 'int';    Default = 8787 }
    @{ EnvKey = 'SESSION_RESUME_STALE_AFTER_SECONDS';    Property = 'SessionResumeStaleAfterSeconds';      Type = 'double'; Default = 1800.0 }
    # RECORDING_START_STALE_AFTER_SECONDS (260809-ow9, START-STALE-01): guards ONLY the
    # initial file pick in Start-Pusher's null-resume branch -- never the mid-session
    # rotation path. A newest-matching recording whose mtime is older than this many
    # seconds (and is not observably growing in length) is treated as a finished prior
    # service, not this one: an OBS recording that has not been written to in five
    # minutes is a finished prior service, not this one. This is the start-pick sibling
    # of SESSION_RESUME_STALE_AFTER_SECONDS above, deliberately a SEPARATE knob -- the two
    # questions have different blast radii (resume trusts a persisted offset; the start
    # pick decides whether to open a file at all). The decimal literal 300.0 is required
    # (not 300), same whole-number-double rule as GROWTH_RATE_SMOOTHING_SECONDS /
    # SRT_STALL_TOLERANCE_SECONDS above -- or the no-override path returns an uncoerced [int].
    @{ EnvKey = 'RECORDING_START_STALE_AFTER_SECONDS';  Property = 'RecordingStartStaleAfterSeconds';     Type = 'double'; Default = 300.0 }
    @{ EnvKey = 'SRT_PASSPHRASE';                        Property = 'SrtPassphrase';                       Type = 'string'; Default = '' }
    # AUTO_PICKUP (260718-epo, T-epo-01): default OFF, matching the ControlFlag.psm1
    # "never stream unattended" bias verbatim -- a strictly-newer recording appearing
    # after a clean finish is ALWAYS detected/surfaced (Get-NewRecordingPickupDecision),
    # but streaming only auto-starts when the operator has explicitly opted in here.
    # Self-wiring (the 06-03 decision): no other Config code changes needed, this row
    # alone makes Read-PusherConfig/Write-DotEnvFile/Test-PusherConfig handle it.
    @{ EnvKey = 'AUTO_PICKUP';                           Property = 'AutoPickupEnabled';                   Type = 'bool';   Default = $false }
    # SRT_STALL_TOLERANCE_SECONDS (260718-j58/Front A/HARDEN-A): how long the pusher
    # holds ONE SRT session through transient bond backpressure (ffmpeg's stdin write
    # not completing while the process is still alive) before giving up and escalating
    # to the existing NetworkDeath reconnect machinery. A genuinely dead link still
    # reconnects within this bound -- a stall never holds forever (T-j58-01). The
    # decimal literal 30.0 is required (not 30), same whole-number-double rule as
    # GROWTH_RATE_SMOOTHING_SECONDS above.
    @{ EnvKey = 'SRT_STALL_TOLERANCE_SECONDS';           Property = 'SrtStallToleranceSeconds';            Type = 'double'; Default = 30.0 }
    # END_OF_SERVICE_RECONNECT_MAX_DURATION_SECONDS / END_OF_SERVICE_RECONNECT_MAX_ATTEMPTS
    # (260718-j58/Front C/EOS-DRAIN-01): the bounded give-up ceiling for the
    # end-of-service drain's reconnect-through-a-relay-drop behavior (Task 4) -- once
    # EITHER bound is exceeded, the drain gives up with an honest exit-3
    # 'finished-with-undelivered-backlog' rather than reconnecting forever against a
    # relay that is never coming back. The decimal literal 900.0 is required (not 900).
    @{ EnvKey = 'END_OF_SERVICE_RECONNECT_MAX_DURATION_SECONDS'; Property = 'EndOfServiceReconnectMaxDurationSeconds'; Type = 'double'; Default = 900.0 }
    @{ EnvKey = 'END_OF_SERVICE_RECONNECT_MAX_ATTEMPTS';         Property = 'EndOfServiceReconnectMaxAttempts';         Type = 'int';    Default = 100 }
    # SRT_NIC_NAME (260722-xbr/NIC-TELEMETRY-01): overrides Resolve-SrtNicName's
    # Find-NetRoute auto-detection of the SRT-path adapter (the NIC that routes to
    # RELAY_HOST). Blank (the default) means "auto-detect"; a non-blank operator
    # value always wins.
    @{ EnvKey = 'SRT_NIC_NAME';                          Property = 'SrtNicName';                          Type = 'string'; Default = '' }
    # VPS_ROUTE_PREFIX / VPS_ROUTE_NEXT_HOP: an optional persistent host route to the
    # relay, for installs where the relay is reached over a specific gateway (e.g. a
    # site-to-site tunnel or VPN uplink) rather than the machine's default route.
    # Both are blank by default and must be set TOGETHER -- install.ps1
    # -RegisterTunnel skips the persistent-route step (with a loud warning) whenever
    # either one is blank, so leaving both blank is always a safe, supported
    # configuration for a standard single-uplink install.
    @{ EnvKey = 'VPS_ROUTE_PREFIX';                      Property = 'VpsRoutePrefix';                      Type = 'string'; Default = '' }
    @{ EnvKey = 'VPS_ROUTE_NEXT_HOP';                    Property = 'VpsRouteNextHop';                     Type = 'string'; Default = '' }

    # --- Internal safety constants, code-default only, NEVER read from .env (D-06) ---
    @{ EnvKey = $null; Property = 'StateFilePath';                         Type = 'string'; Default = 'state/offset.json' }
    @{ EnvKey = $null; Property = 'PacketSizeBytes';                       Type = 'int';    Default = 1316 }
    @{ EnvKey = $null; Property = 'LingerSeconds';                         Type = 'int';    Default = 4 }
    @{ EnvKey = $null; Property = 'ChunkSizeBytes';                        Type = 'int';    Default = 65424 }
    @{ EnvKey = $null; Property = 'PollIntervalMilliseconds';              Type = 'int';    Default = 250 }
    @{ EnvKey = $null; Property = 'PersistIntervalMilliseconds';           Type = 'int';    Default = 250 }
    @{ EnvKey = $null; Property = 'PersistIntervalBytes';                  Type = 'int';    Default = 262144 }
    @{ EnvKey = $null; Property = 'WatchdogTimeoutMilliseconds';           Type = 'int';    Default = 5000 }
    @{ EnvKey = $null; Property = 'ColdStartResumeMarginBytes';            Type = 'int';    Default = 65424 }
    @{ EnvKey = $null; Property = 'TargetLowSeconds';                      Type = 'int';    Default = 5 }
    @{ EnvKey = $null; Property = 'TargetHighSeconds';                     Type = 'int';    Default = 10 }
    @{ EnvKey = $null; Property = 'BackoffBaseMilliseconds';               Type = 'int';    Default = 1000 }
    @{ EnvKey = $null; Property = 'BackoffCeilingMilliseconds';            Type = 'int';    Default = 30000 }
    @{ EnvKey = $null; Property = 'FfmpegCrashRestartDelayMilliseconds';   Type = 'int';    Default = 200 }
    @{ EnvKey = $null; Property = 'ResumeMarginFloorBytes';                Type = 'int';    Default = 65424 }
    @{ EnvKey = $null; Property = 'ResumeMarginCeilingBytes';              Type = 'int';    Default = 2097152 }
    @{ EnvKey = $null; Property = 'SustainedHealthyWindowSeconds';         Type = 'int';    Default = 45 }
    @{ EnvKey = $null; Property = 'SrtConnectionTimeoutMicroseconds';      Type = 'int';    Default = 3000000 }
    @{ EnvKey = $null; Property = 'NetworkDeathDetectionDelaySeconds';     Type = 'double'; Default = 10.0 }
    @{ EnvKey = $null; Property = 'FfmpegPath';                            Type = 'string'; Default = 'ffmpeg' }
    @{ EnvKey = $null; Property = 'GrowthStallDegradedWindowSeconds';      Type = 'int';    Default = 90 }
)

# --- DIAL-02 live-dial bounds + Mbit/s<->bytes/s conversion contract (14.5-07) ---
# CatchUpMultiplier: 1.0-3.0 inclusive is the sane operator-tunable band (below the
# stream's own record rate makes no sense; above 3x risks the ARQ-storm/restart-storm
# pattern already root-caused live, see the 'catchup-multiplier-relay-ceiling' memory
# note -- 1.2-1.5x is the proven-safe operating point, 3.0 is a hard outer guard, not
# a recommendation). SendCeiling: 0 is the explicit "off, multiplier governs" value
# (not a missing-key sentinel); the upper band guards against garbage/overflow-shaped
# input, not real-world tuning -- SEND_CEILING is meant to sit just under measured
# path capacity (currently ~26-29 Mbit, see 'measured-throughput-baseline'), so 1000
# Mbit/s of headroom is generous without being unbounded.
$script:LiveDialCatchUpMultiplierMinimum = 1.0
$script:LiveDialCatchUpMultiplierMaximum = 3.0
$script:LiveDialSendCeilingMaximumBytesPerSecond = [long] 125000000   # 1000 Mbit/s
# 1 Mbit/s = 1,000,000 bits/s = 125,000 bytes/s (decimal Mbit, not Mebibit) -- the
# single source of truth for every Mbit/s<->bytes/s conversion in this codebase.
$script:BytesPerSecondPerMegabit = 125000

function ConvertTo-CoercedConfigValue {
    <#
    .SYNOPSIS
    Private coercion helper. Casts a raw .env string value to the schema entry's
    declared Type. A value that fails to coerce (e.g. a non-numeric RELAY_PORT)
    never throws out of Read-PusherConfig -- it logs a Warning and falls back to
    the schema's own DefaultValue, keeping .env parsing in the same "tolerant,
    never-fatal" family as Read-DotEnvFile (only Test-PusherConfig is allowed to
    be a fatal-by-convention path, D-08).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value,
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] [string] $EnvKey,
        [Parameter(Mandatory)] [AllowNull()] $DefaultValue
    )

    try {
        switch ($Type) {
            'int'    { return [int] $Value }
            'long'   { return [long] $Value }
            'double' { return [double] $Value }
            'bool'   { return [bool]::Parse($Value) }
            default  { return $Value }
        }
    } catch {
        Write-Log -Level Warning -Message "Config key '$EnvKey' value '$Value' could not be coerced to $Type -- using default '$DefaultValue': $($_.Exception.Message)"
        return $DefaultValue
    }
}

function ConvertTo-ScreamingSnakeCaseName {
    <#
    .SYNOPSIS
    Private (never exported): derives the SCREAMING_SNAKE_CASE name a schema Property
    would have as an .env key, by inserting '_' before every internal capital letter
    and upper-casing the result (e.g. 'ChunkSizeBytes' -> 'CHUNK_SIZE_BYTES'). Every
    operator-facing schema entry's real EnvKey already equals this derivation by
    construction, so this helper is used ONLY to recognise when a caller's .env-style
    key names an internal safety constant (EnvKey = $null) that has no real EnvKey of
    its own -- Write-DotEnvFile's second refusal (D-06).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $PropertyName
    )

    return [regex]::Replace($PropertyName, '(?<!^)([A-Z])', '_$1').ToUpperInvariant()
}

function Write-DotEnvFile {
    <#
    .SYNOPSIS
    The ONLY writer of .env (D-14). Patches raw text lines in place -- never
    regenerates the file from Read-PusherConfig's typed object, which has already
    dropped every comment, blank line and unrecognised key on read (D-07). Refuses,
    before touching disk, in this order:
      1. Any key in $Changes with no matching schema EnvKey (config injection).
      2. Any key naming a schema Property whose EnvKey is $null -- an internal safety
         constant (D-06) that must never become .env-sourced, even by write.
      3. A syntactically-accepted change set that Test-PusherConfig rejects as a whole
         (D-16) -- never a partial apply. An invalid RELAY_PORT would hand the operator
         an exit-2 service that stays down until a human fixes it (Phase 4's proven
         failure mode).
    A refusal the operator can read is always better than a service that will not
    start. This is the THIRD copy of the temp-then-rename atomic-write idiom
    (OffsetStore.psm1's Save-PusherOffset, ControlFlag.psm1's Set-PusherDesiredState)
    -- duplicated deliberately (D-07) rather than extracting a shared helper that
    would touch the live-proven offset write path.

    .OUTPUTS
    [pscustomobject]@{ Success = [bool]; Problems = [string[]] }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [hashtable] $Changes
    )

    $problems = [System.Collections.Generic.List[string]]::new()

    # --- Step 1: allow-list the incoming keys BEFORE anything else touches the file
    # (Security Domain V5/Tampering, T-05-03). This is the writer's mirror of
    # Read-PusherConfig's structural drop of non-schema keys on read (D-07/T-04-01).
    $writableSchemaByEnvKey = @{}
    $internalConstantEnvKeyNames = @{}
    foreach ($entry in $script:ConfigSchema) {
        if ($entry.EnvKey) {
            $writableSchemaByEnvKey[$entry.EnvKey] = $entry
        } else {
            $derivedName = ConvertTo-ScreamingSnakeCaseName -PropertyName $entry.Property
            $internalConstantEnvKeyNames[$derivedName] = $entry.Property
        }
    }

    $acceptedEntries = @{}
    foreach ($changedKey in $Changes.Keys) {
        # CR-03: a string-typed value containing an embedded CR/LF would otherwise write
        # as TWO real .env lines in Step 3 (line 384/392 below) -- injecting an entirely
        # separate, unvalidated KEY=value line that bypasses both this step's key
        # allow-list and Step 2's Test-PusherConfig gate (T-05-03, D-16). Checked BEFORE
        # any other Step 1 acceptance so a newline-carrying value never reaches
        # $acceptedEntries regardless of whether its key is otherwise valid.
        if ([string]$Changes[$changedKey] -match '[\r\n]') {
            $problems.Add("'$changedKey' value contains a newline -- refusing to write it (would inject an unvalidated extra .env line)")
            continue
        }
        if ($writableSchemaByEnvKey.ContainsKey($changedKey)) {
            $acceptedEntries[$changedKey] = $writableSchemaByEnvKey[$changedKey]
            continue
        }
        if ($internalConstantEnvKeyNames.ContainsKey($changedKey)) {
            $problems.Add("'$changedKey' is an internal safety constant (Property '$($internalConstantEnvKeyNames[$changedKey])') and is never read from .env -- refusing to write it")
        } else {
            $problems.Add("'$changedKey' is not a recognised config key -- refusing to write it")
        }
    }

    if ($problems.Count -gt 0) {
        return [pscustomobject]@{ Success = $false; Problems = $problems.ToArray() }
    }

    # --- Step 2: build the proposed config and validate it BEFORE writing anything
    # (D-16). Read-PusherConfig's typed object is used ONLY to compute this validation
    # value -- the bytes actually written come from the raw line walk in Step 3.
    $currentConfig = Read-PusherConfig -Path $Path
    $proposedConfig = $currentConfig.PSObject.Copy()
    foreach ($changedKey in $acceptedEntries.Keys) {
        $entry = $acceptedEntries[$changedKey]
        $coercedValue = ConvertTo-CoercedConfigValue -Value ([string] $Changes[$changedKey]) -Type $entry.Type -EnvKey $entry.EnvKey -DefaultValue $entry.Default
        $proposedConfig.($entry.Property) = $coercedValue
    }

    $validationProblems = Test-PusherConfig -Config $proposedConfig
    if ($validationProblems.Count -gt 0) {
        return [pscustomobject]@{ Success = $false; Problems = $validationProblems }
    }

    # --- Step 3: patch the raw text lines -- mirrors Read-DotEnvFile's dialect exactly
    # (trim; skip blank/comment; split on the FIRST '=' only) so a round-trip is
    # lossless. An unchanged line is emitted from the original array UNMODIFIED, not
    # trimmed -- this is what keeps the operator's comments/blank lines/unknown keys
    # byte-for-byte intact (D-15).
    $absolutePath = [System.IO.Path]::GetFullPath($Path)
    $fileAlreadyExisted = Test-Path -LiteralPath $absolutePath
    $originalHadTrailingNewline = $false
    $existingLines = @()
    if ($fileAlreadyExisted) {
        $rawFileText = [System.IO.File]::ReadAllText($absolutePath)
        $originalHadTrailingNewline = $rawFileText.Length -gt 0 -and $rawFileText.EndsWith("`n")
        $existingLines = @(Get-Content -LiteralPath $absolutePath -Encoding utf8)
    }

    $remainingKeysToAppend = [System.Collections.Generic.List[string]]::new([string[]] $acceptedEntries.Keys)
    $outputLines = [System.Collections.Generic.List[string]]::new()
    foreach ($rawLine in $existingLines) {
        $trimmedLine = $rawLine.Trim()
        $matchedKey = $null
        if ($trimmedLine.Length -gt 0 -and -not $trimmedLine.StartsWith('#')) {
            $parts = $trimmedLine -split '=', 2
            if ($parts.Count -eq 2) {
                $candidateKey = $parts[0].Trim()
                if ($acceptedEntries.ContainsKey($candidateKey)) {
                    $matchedKey = $candidateKey
                }
            }
        }

        if ($matchedKey) {
            $outputLines.Add(("{0}={1}" -f $matchedKey, $Changes[$matchedKey]))
            $remainingKeysToAppend.Remove($matchedKey) | Out-Null
        } else {
            $outputLines.Add($rawLine)
        }
    }

    foreach ($newKey in $remainingKeysToAppend) {
        $outputLines.Add(("{0}={1}" -f $newKey, $Changes[$newKey]))
    }

    $joinedContent = [string]::Join("`n", $outputLines)
    $shouldEndWithNewline = if ($fileAlreadyExisted) { $originalHadTrailingNewline } else { $true }
    if ($shouldEndWithNewline -and $outputLines.Count -gt 0) {
        $joinedContent += "`n"
    }

    # --- Step 4: write atomically. Same discipline as Save-PusherOffset/
    # Set-PusherDesiredState: a scanner (Windows Defender, Search indexer) holding a
    # momentary handle on the destination is an observed real transient failure on
    # this box, so retry with a short backoff rather than crashing the caller.
    $targetDirectory = Split-Path -Parent $absolutePath
    if ($targetDirectory -and -not (Test-Path -LiteralPath $targetDirectory)) {
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    }

    $temporaryPath = Join-Path $targetDirectory (".env.{0}.tmp" -f [Guid]::NewGuid())
    [System.IO.File]::WriteAllText($temporaryPath, $joinedContent)

    $maximumMoveAttempts = 5
    $moveBackoffMilliseconds = 20
    for ($attempt = 1; ; $attempt++) {
        try {
            [System.IO.File]::Move($temporaryPath, $absolutePath, $true)
            break
        } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if ($attempt -ge $maximumMoveAttempts) {
                if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
                throw
            }
            Start-Sleep -Milliseconds $moveBackoffMilliseconds
        }
    }

    return [pscustomobject]@{ Success = $true; Problems = @() }
}

function Read-DotEnvFile {
    <#
    .SYNOPSIS
    Parses a flat KEY=value .env file into a string-keyed hashtable. A missing
    file is normal (D-03) and returns an empty hashtable without throwing --
    the caller (Read-PusherConfig) applies code defaults for everything. Splits
    each line on the FIRST '=' only so an SRT URL or passphrase value containing
    '=' is preserved intact; blank lines and lines starting with '#' are skipped;
    a line with no '=' at all is silently ignored (malformed, not fatal).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $values = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log -Level Debug -Message "No .env file found at '$Path' -- using code defaults (D-03, not fatal)"
        return $values
    }

    foreach ($rawLine in Get-Content -LiteralPath $Path -Encoding utf8) {
        $line = $rawLine.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }

        # Split on the FIRST '=' only -- SRT URLs / passphrases may contain '=' (D-02)
        $parts = $line -split '=', 2
        if ($parts.Count -ne 2) { continue }   # malformed line, ignore

        $key = $parts[0].Trim()
        $value = $parts[1].Trim()

        # Strip one layer of matching surrounding quotes
        if ($value.Length -ge 2 -and (
                ($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))
            )) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $values[$key] = $value
    }
    return $values
}

function Read-PusherConfig {
    <#
    .SYNOPSIS
    Loads the full typed settings object pusher.ps1 consumes: every schema key
    gets its code-level default (D-03), an operator-facing key (EnvKey non-null,
    D-05) is overridden when present in the parsed .env, and an internal safety
    constant (EnvKey = $null, D-06) is NEVER read from .env even if a matching
    line exists -- it always resolves to its code default. Any .env key not
    present in the schema (a credential-shaped key, e.g. a YouTube API key) is
    structurally dropped: no property is ever created for it on the returned
    object (D-07, T-04-01).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Path = '.env'
    )

    $envValues = Read-DotEnvFile -Path $Path
    $config = [ordered]@{}

    foreach ($entry in $script:ConfigSchema) {
        $resolvedValue = $entry.Default
        if ($entry.EnvKey -and $envValues.ContainsKey($entry.EnvKey)) {
            $resolvedValue = ConvertTo-CoercedConfigValue -Value $envValues[$entry.EnvKey] -Type $entry.Type -EnvKey $entry.EnvKey -DefaultValue $entry.Default
        }
        $config[$entry.Property] = $resolvedValue
    }

    return [pscustomobject] $config
}

function ConvertTo-BytesPerSecondFromMegabitsPerSecond {
    <#
    .SYNOPSIS
    Mbit/s -> bytes/s, the write-side half of the DIAL-02 conversion contract
    (1 Mbit/s = 125000 bytes/s exactly). Uses [decimal] arithmetic internally so
    the multiply-then-round never inherits binary floating-point representation
    error for the common decimal inputs an operator types (e.g. 1.5, 16). Returns
    [long] because SEND_CEILING_BYTES_PER_SECOND is stored as a raw long bytes/s
    value -- the lossless source of truth (never the Mbit/s display value).
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)] [double] $MegabitsPerSecond
    )

    $bytesPerSecond = [decimal] $MegabitsPerSecond * [decimal] $script:BytesPerSecondPerMegabit
    return [long] [Math]::Round($bytesPerSecond, 0, [MidpointRounding]::AwayFromZero)
}

function ConvertTo-MegabitsPerSecondFromBytesPerSecond {
    <#
    .SYNOPSIS
    bytes/s -> Mbit/s, the display-side half of the DIAL-02 conversion contract.
    Rounds to 1 decimal place, half-up (MidpointRounding.AwayFromZero) -- e.g.
    143750 B/s (1.15 Mbit/s exactly) displays as 1.2, not PowerShell/.NET's default
    banker's-rounds-to-even 1.1. [decimal] arithmetic is used for the same reason
    as the inverse conversion above: the halfway point must land exactly on .x5,
    not on a binary-double neighbour of it. This is a DISPLAY-ONLY value -- the
    caller's own stored bytes/s value is never mutated or replaced by this result.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [double] $BytesPerSecond
    )

    $megabitsPerSecond = [decimal] $BytesPerSecond / [decimal] $script:BytesPerSecondPerMegabit
    return [double] [Math]::Round($megabitsPerSecond, 1, [MidpointRounding]::AwayFromZero)
}

function Read-LiveTunableOverrides {
    <#
    .SYNOPSIS
    DIAL-02's narrow live-reload reader: returns ONLY CatchUpMultiplier and
    SendCeilingBytesPerSecond from the .env at Path, reusing Read-DotEnvFile +
    the private ConvertTo-CoercedConfigValue helper -- never Read-PusherConfig's
    full schema walk (T-14.5-07-03 scope fence). See the module header for the
    full rationale.

    Each returned property is $null ONLY as a "no override" signal: the key is
    absent, the file is missing/blank/unreadable, the value fails numeric
    coercion, or the coerced value fails bounds validation. $null means "the
    caller keeps whatever value it already has" -- it is never itself applied as
    a fallback constant. A present, in-bounds SendCeilingBytesPerSecond of
    EXACTLY 0 is a real, meaningful value (explicit "off, multiplier governs"),
    not a no-override null.

    Bounds (D-04): CatchUpMultiplier in [1.0, 3.0] inclusive.
    SendCeilingBytesPerSecond in [0, LiveDialSendCeilingMaximumBytesPerSecond].

    Never throws -- the whole body is wrapped so a torn/locked read racing
    Write-DotEnvFile's atomic temp+move (T-14.5-07-02), or any other unexpected
    I/O failure, resolves to the same safe "no override" result rather than
    propagating out to a caller polling this every ~1s in a hot loop (14.5-08).

    .OUTPUTS
    [pscustomobject]@{ CatchUpMultiplier = [double] or $null; SendCeilingBytesPerSecond = [long] or $null }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $overrides = [pscustomobject]@{
        CatchUpMultiplier         = $null
        SendCeilingBytesPerSecond = $null
    }

    try {
        $envValues = Read-DotEnvFile -Path $Path

        if ($envValues.ContainsKey('CATCH_UP_MULTIPLIER')) {
            $coercedMultiplier = ConvertTo-CoercedConfigValue -Value $envValues['CATCH_UP_MULTIPLIER'] -Type 'double' -EnvKey 'CATCH_UP_MULTIPLIER' -DefaultValue $null
            if ($coercedMultiplier -is [double] -and
                $coercedMultiplier -ge $script:LiveDialCatchUpMultiplierMinimum -and
                $coercedMultiplier -le $script:LiveDialCatchUpMultiplierMaximum) {
                $overrides.CatchUpMultiplier = $coercedMultiplier
            }
        }

        if ($envValues.ContainsKey('SEND_CEILING_BYTES_PER_SECOND')) {
            $coercedCeiling = ConvertTo-CoercedConfigValue -Value $envValues['SEND_CEILING_BYTES_PER_SECOND'] -Type 'long' -EnvKey 'SEND_CEILING_BYTES_PER_SECOND' -DefaultValue $null
            if ($coercedCeiling -is [long] -and
                $coercedCeiling -ge 0 -and
                $coercedCeiling -le $script:LiveDialSendCeilingMaximumBytesPerSecond) {
                $overrides.SendCeilingBytesPerSecond = $coercedCeiling
            }
        }
    } catch {
        Write-Log -Level Warning -Message "Read-LiveTunableOverrides: '$Path' could not be read -- keeping caller's current dial values: $($_.Exception.Message)"
        return [pscustomobject]@{ CatchUpMultiplier = $null; SendCeilingBytesPerSecond = $null }
    }

    return $overrides
}

function Test-PusherConfig {
    <#
    .SYNOPSIS
    Validates only the deployment-critical, no-safe-default keys (RelayHost,
    RelayPort range, RecordingFolderPath existence) and returns a problems
    list -- empty means valid. NEVER exits and NEVER throws itself (D-08): the
    CALLER (pusher.ps1) decides whether/how loud to fail on a non-empty list.
    This is the one deliberately fatal-by-CONVENTION path in the module (the
    caller is expected to exit on a non-empty result), but the function itself
    stays a pure list-returning check, matching RESEARCH.md Pattern 2 -- do not
    add exit/throw here even for "obviously fatal" input.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] $Config
    )

    $problems = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrWhiteSpace($Config.RelayHost)) {
        $problems.Add('RELAY_HOST is unset or blank')
    }

    $isValidPort = ($Config.RelayPort -is [int]) -and ($Config.RelayPort -gt 0) -and ($Config.RelayPort -le 65535)
    if (-not $isValidPort) {
        $problems.Add("RELAY_PORT '$($Config.RelayPort)' is not a valid port number (must be 1-65535)")
    }

    # Property-existence guard: Test-PusherConfig accepts partial config objects (its own
    # test precedent passes only the three original keys), so a missing RelayProtocol means
    # "schema default", never a validation problem.
    $relayProtocolProperty = $Config.PSObject.Properties['RelayProtocol']
    if ($null -ne $relayProtocolProperty -and $relayProtocolProperty.Value -notin @('srt', 'tcp')) {
        $problems.Add("RELAY_PROTOCOL '$($relayProtocolProperty.Value)' is not supported (must be 'srt' or 'tcp')")
    }

    # DIAL-02 bounds (CR-01): the same clamps Read-LiveTunableOverrides applies on the
    # ~1s hot-loop poll must also gate the persistent path (dashboard Save-Settings ->
    # Write-DotEnvFile -> Test-PusherConfig, and pusher startup) -- otherwise a value
    # outside the ARQ-storm-safe band survives into the next restart unclamped.
    $catchUpMultiplierProperty = $Config.PSObject.Properties['CatchUpMultiplier']
    if ($null -ne $catchUpMultiplierProperty -and $null -ne $catchUpMultiplierProperty.Value -and
        ($catchUpMultiplierProperty.Value -lt $script:LiveDialCatchUpMultiplierMinimum -or
         $catchUpMultiplierProperty.Value -gt $script:LiveDialCatchUpMultiplierMaximum)) {
        $problems.Add("CATCH_UP_MULTIPLIER '$($catchUpMultiplierProperty.Value)' is outside the safe band $($script:LiveDialCatchUpMultiplierMinimum)-$($script:LiveDialCatchUpMultiplierMaximum) (high multipliers caused the 2026-07 ARQ/restart storms)")
    }
    $sendCeilingProperty = $Config.PSObject.Properties['SendCeilingBytesPerSecond']
    if ($null -ne $sendCeilingProperty -and $null -ne $sendCeilingProperty.Value -and
        ($sendCeilingProperty.Value -lt 0 -or
         $sendCeilingProperty.Value -gt $script:LiveDialSendCeilingMaximumBytesPerSecond)) {
        $problems.Add("SEND_CEILING_BYTES_PER_SECOND '$($sendCeilingProperty.Value)' is outside 0-$($script:LiveDialSendCeilingMaximumBytesPerSecond) (0 = multiplier mode, max = 1000 Mbit/s)")
    }

    # CR-01: unlike SendCeilingBytesPerSecond, 0 is NOT a valid "off" sentinel here --
    # Get-CatchUpSendCeiling (lib/Pacer.psm1) falls back to this value verbatim whenever
    # ObservedBytesPerSecond <= 0 (cold start / pre-growth Draining), with no lower-bound
    # guard of its own. A 0 reaches pusher.ps1's pacing sleep as a division by zero
    # (uncaught OverflowException, crashes the pusher mid-stream); a negative value
    # silently disables the cold-start/drain bandwidth cap entirely (no throttle sleep is
    # ever applied) -- directly contradicting CLAUDE.md's "catch-up rate capped" constraint.
    $coldStartCeilingProperty = $Config.PSObject.Properties['ColdStartCatchUpCeilingBytesPerSecond']
    if ($null -ne $coldStartCeilingProperty -and $null -ne $coldStartCeilingProperty.Value -and
        $coldStartCeilingProperty.Value -le 0) {
        $problems.Add("COLD_START_CATCH_UP_CEILING_BYTES_PER_SECOND '$($coldStartCeilingProperty.Value)' must be a positive number of bytes/sec (0 or negative disables the cold-start bandwidth cap, or crashes the pacer via a division by zero)")
    }

    # RECORDING_START_STALE_AFTER_SECONDS (260809-ow9, START-STALE-01): a non-positive
    # threshold makes every recording look stale forever, so the pusher would never latch
    # onto any recording and would park in the waiting state through an entire service.
    # Property-existence guard mirrors the ColdStart precedent above so a partial config
    # object (missing this property entirely) stays valid.
    $recordingStartStaleAfterSecondsProperty = $Config.PSObject.Properties['RecordingStartStaleAfterSeconds']
    if ($null -ne $recordingStartStaleAfterSecondsProperty -and $null -ne $recordingStartStaleAfterSecondsProperty.Value -and
        $recordingStartStaleAfterSecondsProperty.Value -le 0) {
        $problems.Add("RECORDING_START_STALE_AFTER_SECONDS '$($recordingStartStaleAfterSecondsProperty.Value)' must be a positive number of seconds (0 or negative makes every recording look stale forever, so the pusher would never latch onto any recording and would park in the waiting state through an entire service)")
    }

    # WR-01 style: wrap the filesystem probe in try/catch so a TOCTOU race or an
    # unexpected Test-Path failure still returns a problem string, never throws
    # (matches this module's never-throw contract even on this validation path).
    try {
        if ([string]::IsNullOrWhiteSpace($Config.RecordingFolderPath) -or -not (Test-Path -LiteralPath $Config.RecordingFolderPath)) {
            $problems.Add("RECORDING_FOLDER_PATH '$($Config.RecordingFolderPath)' does not exist or is not readable")
        }
    } catch {
        $problems.Add("RECORDING_FOLDER_PATH '$($Config.RecordingFolderPath)' could not be checked: $($_.Exception.Message)")
    }

    # Unary comma (,) prevents PowerShell's pipeline/return enumeration from
    # unwrapping the array: without it, a zero-element array collapses to $null
    # and a one-element array collapses to a bare scalar string when the caller
    # assigns the result ($x = Test-PusherConfig ...) -- both silently break a
    # StrictMode caller's `.Count` access (pusher.ps1's config-error gate, D-08)
    # even though this function's own [OutputType([string[]])] promises an array.
    return , $problems.ToArray()
}

function Resolve-PusherConfigPaths {
    <#
    .SYNOPSIS
    Anchors .env-sourced RecordingFolderPath/StateFilePath to ScriptRoot when
    relative, reusing pusher.ps1's existing WR-03 IsPathRooted + Join-Path idiom
    verbatim (D-04) -- a Scheduled Task launches with CWD = System32, so a
    relative path must never be trusted as-is. An already-absolute path (e.g.
    an integration test's override) is left completely unchanged.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $ScriptRoot
    )

    $resolved = $Config.PSObject.Copy()

    if (-not [System.IO.Path]::IsPathRooted($resolved.RecordingFolderPath)) {
        $resolved.RecordingFolderPath = Join-Path $ScriptRoot $resolved.RecordingFolderPath
    }
    if (-not [System.IO.Path]::IsPathRooted($resolved.StateFilePath)) {
        $resolved.StateFilePath = Join-Path $ScriptRoot $resolved.StateFilePath
    }

    return $resolved
}

function Get-RedactedConfig {
    <#
    .SYNOPSIS
    Returns a shallow copy of Config with SrtPassphrase masked, so a caller can
    safely log-dump the whole object without leaking the SRT AES passphrase
    (D-07, T-04-02) -- a blank passphrase stays blank (nothing to redact), a
    set passphrase becomes a fixed placeholder string, never a substring/hash
    of the real value. The source Config object is never mutated.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Config
    )

    $redacted = $Config.PSObject.Copy()
    if ($redacted.PSObject.Properties['SrtPassphrase']) {
        $redacted.SrtPassphrase = if ([string]::IsNullOrEmpty($Config.SrtPassphrase)) { '' } else { '***REDACTED***' }
    }
    return $redacted
}

Export-ModuleMember -Function Read-DotEnvFile, Read-PusherConfig, Test-PusherConfig, Resolve-PusherConfigPaths, Get-RedactedConfig, Write-DotEnvFile, Read-LiveTunableOverrides, ConvertTo-BytesPerSecondFromMegabitsPerSecond, ConvertTo-MegabitsPerSecondFromBytesPerSecond

#!/bin/bash
# setup-vps.sh
#
# Generic relay installer for outage-proof-livestream: stands up a working relay
# on a FRESH, bare Ubuntu VPS -- no bonded WAN, no multi-WAN-bonding router, no
# encrypted tunnel between the church and the VPS, and no ssh port-forward. None
# of those are requirements, assumptions, or dependencies of this script.
#
# Change-aware: a re-run only touches what actually changed, so re-running this
# script while a stream is live restarts nothing that did not change. DRYRUN=1
# reports every action it WOULD take without touching the filesystem or systemd
# at all.
#
# Env-var knobs (all optional, defaults shown):
#   RELAY_TRANSPORT   tcp (default) or srt. Anything else fails loudly.
#   RELAY_PORT        8890 (default). Substituted into the unit template.
#   DRYRUN            0 (default). Set to 1 to preview with zero side effects.
#   SYSTEMD_DIR       /etc/systemd/system (default). Test seam only -- on a real
#                     systemd host this directory always exists; this script
#                     never creates it.
#   RELAY_ENV_FILE    /etc/default/outage-proof-relay (default). Test seam only,
#                     same rationale as SYSTEMD_DIR.
#
# Secrets: the relay env file holds YT_URL=<your rtmps:// ingest URL with stream
# key>. This script NEVER writes that value -- it only guarantees the file exists
# with chmod 600 permissions. Add the line yourself, e.g.:
#   echo 'YT_URL=rtmps://a.rtmp.youtube.com/live2/YOUR-STREAM-KEY' | sudo tee -a /etc/default/outage-proof-relay

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly UNIT_NAME="outage-proof-relay.service"

RELAY_TRANSPORT="${RELAY_TRANSPORT:-tcp}"
RELAY_PORT="${RELAY_PORT:-8890}"
DRYRUN="${DRYRUN:-0}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
RELAY_ENV_FILE="${RELAY_ENV_FILE:-/etc/default/outage-proof-relay}"

log() {
    echo "[setup-vps] $*"
}

run() {
    if [ "$DRYRUN" = "1" ]; then
        log "DRYRUN: $*"
    else
        "$@"
    fi
}

validate_transport() {
    case "$RELAY_TRANSPORT" in
        tcp|srt) ;;
        *)
            log "ERROR: RELAY_TRANSPORT must be 'tcp' or 'srt' (got '$RELAY_TRANSPORT')"
            exit 1
            ;;
    esac
}

ensure_ffmpeg() {
    if command -v ffmpeg >/dev/null 2>&1; then
        log "ffmpeg already present -- not installing anything."
    else
        log "ffmpeg not found -- installing."
        run apt-get update
        run apt-get install -y ffmpeg
    fi

    if [ "$RELAY_TRANSPORT" = "srt" ]; then
        if [ "$DRYRUN" = "1" ]; then
            log "DRYRUN: would probe 'ffmpeg -protocols' for srt support"
        elif command -v ffmpeg >/dev/null 2>&1 && ! ffmpeg -protocols 2>/dev/null | grep -qi '^ *srt$'; then
            log "ERROR: this ffmpeg build has no SRT protocol support. Install a libsrt-enabled ffmpeg build (e.g. from a PPA or a static build with --enable-libsrt), or use RELAY_TRANSPORT=tcp instead."
            exit 1
        fi
    fi
}

ensure_relay_env_file() {
    if [ -f "$RELAY_ENV_FILE" ]; then
        log "$RELAY_ENV_FILE already exists -- leaving its content untouched (operator-supplied secret)."
        return
    fi
    log "$RELAY_ENV_FILE is missing -- creating an empty, chmod-600 placeholder. Populate YT_URL before starting the relay (see this script's header comment)."
    run bash -c "umask 077 && touch '$RELAY_ENV_FILE' && chmod 600 '$RELAY_ENV_FILE'"
}

render_unit() {
    local template_path="$SCRIPT_DIR/outage-proof-relay-${RELAY_TRANSPORT}.service.template"
    local rendered_path
    rendered_path="$(mktemp)"
    sed "s/__RELAY_PORT__/${RELAY_PORT}/g" "$template_path" > "$rendered_path"
    echo "$rendered_path"
}

unit_content_changed() {
    local rendered_path="$1"
    local installed_path="$SYSTEMD_DIR/$UNIT_NAME"

    if [ ! -f "$installed_path" ]; then
        return 0
    fi
    if ! cmp -s "$rendered_path" "$installed_path"; then
        return 0
    fi
    return 1
}

install_unit_if_changed() {
    local rendered_path="$1"

    if unit_content_changed "$rendered_path"; then
        log "installing/updating $UNIT_NAME"
        run cp "$rendered_path" "$SYSTEMD_DIR/$UNIT_NAME"
        log "daemon-reload (unit file changed)"
        run systemctl daemon-reload
        return 0
    fi

    log "$UNIT_NAME unchanged -- skipping install and daemon-reload (preserves the live process)"
    return 1
}

enable_and_start() {
    local unit_changed="$1"

    run systemctl enable "$UNIT_NAME"

    local is_active
    is_active=$(systemctl is-active "$UNIT_NAME" 2>/dev/null || echo "inactive")
    if [ "$is_active" = "active" ] && [ "$unit_changed" != "0" ]; then
        log "$UNIT_NAME already active and unchanged -- not restarting"
        return
    fi

    run systemctl reset-failed "$UNIT_NAME"
    log "starting/restarting $UNIT_NAME"
    run systemctl restart "$UNIT_NAME"
}

main() {
    validate_transport
    log "outage-proof-livestream relay setup starting (transport=$RELAY_TRANSPORT port=$RELAY_PORT DRYRUN=$DRYRUN)"

    ensure_ffmpeg
    ensure_relay_env_file

    local rendered_path
    rendered_path="$(render_unit)"

    local unit_changed=1
    if [ "$DRYRUN" = "1" ]; then
        if unit_content_changed "$rendered_path"; then
            log "DRYRUN: would install/update $UNIT_NAME and daemon-reload"
        else
            log "DRYRUN: $UNIT_NAME unchanged -- would skip install and daemon-reload"
            unit_changed=0
        fi
    else
        if install_unit_if_changed "$rendered_path"; then
            unit_changed=1
        else
            unit_changed=0
        fi
    fi
    rm -f "$rendered_path"

    enable_and_start "$unit_changed"

    log "done. Verify with: systemctl status $UNIT_NAME"
    log "Remember to open port $RELAY_PORT/$([ "$RELAY_TRANSPORT" = "srt" ] && echo udp || echo tcp) in the VPS firewall."
}

main "$@"

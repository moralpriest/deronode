#!/usr/bin/env bash
# lib/rpc.sh — talk to the local daemon's JSON-RPC. Sourced by node.sh.

# rpc_call <method> <params_json> -> raw response on stdout
rpc_call() {
    local method="$1" params="${2:-}"
    local body
    if [ -n "$params" ]; then
        body="$(jq -nc --arg m "$method" --argjson p "$params" '{jsonrpc:"2.0",id:"1",method:$m,params:$p}')"
    else
        body="$(jq -nc --arg m "$method" '{jsonrpc:"2.0",id:"1",method:$m}')"
    fi
    curl -fsS -m 8 -X POST "http://$RPC_HOST$RPC_PATH/json_rpc" \
        -H 'Content-Type: application/json' \
        -d "$body" 2>/dev/null
}

# RPC_HOST like 127.0.0.1:10102 (path empty) or host:port/foo
parse_rpc_endpoint() {
    local bind="$1"
    case "$bind" in
        */*) RPC_HOST="${bind%%/*}"; RPC_PATH="/${bind#*/}" ;;
        *)   RPC_HOST="$bind"; RPC_PATH="" ;;
    esac
}

# get_node_info -> json result object or empty
get_node_info() {
    rpc_call "DERO.GetInfo" 2>/dev/null | jq -r '.result // empty' 2>/dev/null
}

node_running() {
    parse_rpc_endpoint "$CFG_RPC_BIND"
    [ -n "$(get_node_info 2>/dev/null)" ]
}

# daemon_release_number — the release number of the running daemon, derived from
# its DERO.GetInfo version string. A version like "3.6.0-152.DEROHE.STARGATE+..."
# maps to release 152. Empty when the node is not running or the version has no
# release component (caller falls through to a normal update in that case).
daemon_release_number() {
    node_running || return 0
    local ver
    ver="$(get_node_info 2>/dev/null | jq -r '.version // empty' 2>/dev/null)"
    [ -n "$ver" ] || return 0
    printf '%s' "$ver" | sed -n 's/.*-\([0-9][0-9]*\)\..*/\1/p'
}

# node_is_external — true when a derod is running whose binary is NOT the one
# deronode manages (i.e. system-installed via systemd etc.). Robust to deronode
# having a previously-downloaded copy in bin/ — we compare the running process
# image, not the existence of our own binary.
node_is_external() {
    node_running || return 1
    local pid image ours
    pid="$(pgrep -f 'derod-linux-amd64 --fastsync' | head -1)"
    [ -n "$pid" ] || return 1
    image="$(readlink "/proc/$pid/exe" 2>/dev/null)"
    image="${image% (deleted)}"
    [ -n "$image" ] || return 1
    ours="$(readlink -f "$BINARY_PATH" 2>/dev/null)"
    [ "$image" != "$ours" ]
}

# external_unit — echo the systemd unit name for an externally-installed derod
# (e.g. derod.service), or nothing when none is installed. Works even when the
# node is stopped — we detect the *installation*, not a running process.
external_unit() {
    local u
    u="$(systemctl list-unit-files --no-legend --type=service 2>/dev/null | awk '$1 != "deronode.service" && $1 ~ /^derod[^@]*\.service$/ {print $1; exit}')"
    if [ -n "$u" ]; then
        echo "$u"
        return 0
    fi
    for f in /etc/systemd/system/derod.service /usr/lib/systemd/system/derod.service; do
        [ -f "$f" ] && { echo "derod.service"; return 0; }
    done
    return 1
}

# external_installed — true when an external derod installation exists: a derod
# systemd unit is present, OR a derod is running whose binary is not ours.
external_installed() {
    external_unit >/dev/null 2>&1 || node_is_external
}

# external_is_system_unit — true when the unit lives in the system manager
# (needs sudo) vs the user manager. Takes the unit name from external_unit.
external_is_system_unit() {
    local unit
    unit="$(external_unit)" || return 1
    if systemctl --user list-unit-files --no-legend 2>/dev/null | grep -q "^$unit "; then
        return 1
    fi
    return 0
}

# print_status <bin> — one-line status line
print_status() {
    local bin="$1" info h st th peers ver
    if node_running; then
        info="$(get_node_info)"
        h="$(echo "$info" | jq -r '.height // 0')"
        st="$(echo "$info" | jq -r '.stableheight // 0')"
        th="$(echo "$info" | jq -r '.topoheight // 0')"
        peers="$(echo "$info" | jq -r '.incoming_connections_count // "?"')"
        ver="$(echo "$info" | jq -r '.version // empty' | sed 's/+.*//')"
        [ -n "$ver" ] && ver="  derohe $ver"
        if [ "$h" -ge "$th" ] && [ "$th" -gt 0 ]; then
            echo "${C_OK}● running  height $h/$th  peers $peers${ver}${C_RESET}"
        else
            echo "${C_WARN}● syncing  height $h/$th  stable $st  peers $peers${ver}${C_RESET}"
        fi
        tag="$(cat "$bin/.tag" 2>/dev/null || echo '?')"
        if external_installed; then
            echo "  derod system-installed (external, not managed by deronode) ($(external_unit))"
        elif [ -f "$bin" ]; then
            echo "  derod $tag  data: $DATA_DIR_REAL  log: $LOG_DIR_REAL"
        else
            echo "  derod system-installed (external, not managed by deronode)"
        fi
    else
        echo "${C_MUTE}○ stopped${C_RESET}"
        if external_installed; then
            echo "  derod system-installed (external) — stopped ($(external_unit))"
        elif [ -f "$bin/derod" ]; then
            echo "  derod $(cat "$bin/.tag" 2>/dev/null || echo '?') installed — run 'deronode start'"
        fi
    fi
}
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

# print_status <bin> — one-line status line
print_status() {
    local bin="$1" info h st th peers tag
    if node_running; then
        info="$(get_node_info)"
        h="$(echo "$info" | jq -r '.height // 0')"
        st="$(echo "$info" | jq -r '.stableheight // 0')"
        th="$(echo "$info" | jq -r '.topoheight // 0')"
        peers="$(echo "$info" | jq -r '.incoming_connections_count // "?"')"
        if [ "$h" -ge "$th" ] && [ "$th" -gt 0 ]; then
            echo "${C_OK}● running  height $h/$th  peers $peers${C_RESET}"
        else
            echo "${C_WARN}● syncing  height $h/$th  stable $st  peers $peers${C_RESET}"
        fi
        tag="$(cat "$bin/.tag" 2>/dev/null || echo '?')"
        if [ -f "$bin" ]; then
            echo "  derod $tag  data: $DATA_DIR_REAL  log: $LOG_DIR_REAL"
        else
            echo "  derod system-installed (external, not managed by deronode)"
        fi
    else
        echo "${C_MUTE}○ stopped${C_RESET}"
        [ -f "$bin/derod" ] && echo "  derod $(cat "$bin/.tag" 2>/dev/null || echo '?') installed — run 'deronode start'"
    fi
}
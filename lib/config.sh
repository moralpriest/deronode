#!/usr/bin/env bash
# lib/config.sh — load/save/validate config.json and build the derod argv.
# Sourced by node.sh. Every derod flag (Release152 has 20) maps to a CFG_* var
# plus a CLI override; omitted values are NOT passed to derod so upstream
# defaults apply.

# Defaults (data_dir/log_dir resolved lazily against INSTALL_DIR).
CFG_INTEGRATOR_ADDRESS=""
CFG_SYNC_PROFILE="pruned"
CFG_FASTSYNC=false
CFG_PRUNE_HISTORY=100000
CFG_NODE_TAG=""
CFG_GETWORK_BIND="127.0.0.1:10100"
CFG_DATA_DIR=""
CFG_LOG_DIR=""
CFG_RPC_BIND="127.0.0.1:10102"
CFG_P2P_BIND="0.0.0.0:10101"
CFG_MIN_PEERS=""
CFG_MAX_PEERS=""
CFG_SOCKS_PROXY=""
CFG_ADD_PRIORITY_NODE=()
CFG_ADD_EXCLUSIVE_NODE=()
CFG_CLOG_LEVEL=""
CFG_FLOG_LEVEL=""
CFG_TESTNET=false
CFG_DEBUG=false
CFG_TIME_IS_IN_SYNC=false
CFG_SYNC_NODE=false
CFG_EXTRA_ARGS=()
CFG_SNAPSHOT_DIR=""
CFG_SNAPSHOT_LEVEL=10

DATA_DIR_REAL=""   # resolved (never empty after resolve_paths)
LOG_DIR_REAL=""
SNAPSHOT_DIR_REAL=""

cfg_get() { jq -r "$1" "$CONFIG_FILE" 2>/dev/null || true; }
cfg_get_arr() { jq -r "$1[]?" "$CONFIG_FILE" 2>/dev/null || true; }

# Parse jq bool (true/false/null -> shell bool).
b2s() { [ "$1" = "true" ] && echo true || echo false; }

load_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    CFG_INTEGRATOR_ADDRESS="$(cfg_get '.integrator_address // ""')"
    CFG_SYNC_PROFILE="$(cfg_get '.sync_profile // "pruned"')"
    CFG_FASTSYNC="$(b2s "$(cfg_get '.fastsync // false')")"
    CFG_PRUNE_HISTORY="$(cfg_get '.prune_history // 100000')"
    [ "$CFG_PRUNE_HISTORY" = "null" ] && CFG_PRUNE_HISTORY=""
    CFG_NODE_TAG="$(cfg_get '.node_tag // ""')"
    CFG_GETWORK_BIND="$(cfg_get '.getwork_bind // "127.0.0.1:10100"')"
    CFG_DATA_DIR="$(cfg_get '.data_dir // ""')"
    CFG_LOG_DIR="$(cfg_get '.log_dir // ""')"
    CFG_RPC_BIND="$(cfg_get '.rpc_bind // "127.0.0.1:10102"')"
    CFG_P2P_BIND="$(cfg_get '.p2p_bind // "0.0.0.0:10101"')"
    CFG_MIN_PEERS="$(cfg_get '.min_peers // empty')"
    CFG_MAX_PEERS="$(cfg_get '.max_peers // empty')"
    CFG_SOCKS_PROXY="$(cfg_get '.socks_proxy // ""')"
    CFG_CLOG_LEVEL="$(cfg_get '.clog_level // empty')"
    CFG_FLOG_LEVEL="$(cfg_get '.flog_level // empty')"
    CFG_TESTNET="$(b2s "$(cfg_get '.testnet // false')")"
    CFG_DEBUG="$(b2s "$(cfg_get '.debug // false')")"
    CFG_TIME_IS_IN_SYNC="$(b2s "$(cfg_get '.time_is_in_sync // false')")"
    CFG_SYNC_NODE="$(b2s "$(cfg_get '.sync_node // false')")"
    readarray -t CFG_ADD_PRIORITY_NODE < <(cfg_get_arr '.add_priority_node')
    readarray -t CFG_ADD_EXCLUSIVE_NODE < <(cfg_get_arr '.add_exclusive_node')
    readarray -t CFG_EXTRA_ARGS < <(cfg_get_arr '.extra_args')
    CFG_SNAPSHOT_DIR="$(cfg_get '.snapshot_dir // ""')"
    CFG_SNAPSHOT_LEVEL="$(cfg_get '.snapshot_level // 10')"
    resolve_paths
}

resolve_paths() {
    DATA_DIR_REAL="${CFG_DATA_DIR:-$INSTALL_DIR/chain}"
    LOG_DIR_REAL="${CFG_LOG_DIR:-$INSTALL_DIR/logs}"
    if [ -n "$CFG_SNAPSHOT_DIR" ]; then
        SNAPSHOT_DIR_REAL="$CFG_SNAPSHOT_DIR"
    elif [ -n "$HOME" ]; then
        SNAPSHOT_DIR_REAL="$HOME/Crypto/dero/snapshots"
    else
        SNAPSHOT_DIR_REAL="$INSTALL_DIR/snapshots"
    fi
}

# If a bind equals a mainnet default while testnet is on, move it to the
# testnet port so the node actually listens where the user expects.
apply_testnet_defaults() {
    [ "$CFG_TESTNET" = "true" ] || return 0
    [ "$CFG_RPC_BIND"     = "127.0.0.1:10102" ] && CFG_RPC_BIND="127.0.0.1:40402"
    [ "$CFG_P2P_BIND"     = "0.0.0.0:10101" ]   && CFG_P2P_BIND="0.0.0.0:40401"
    [ "$CFG_GETWORK_BIND" = "127.0.0.1:10100" ] && CFG_GETWORK_BIND="127.0.0.1:40400"
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    local prio excl extra
    prio="$(printf '%s\n' "${CFG_ADD_PRIORITY_NODE[@]}" | jq -Rrs 'split("\n") | map(select(length>0))')"
    excl="$(printf '%s\n' "${CFG_ADD_EXCLUSIVE_NODE[@]}" | jq -Rrs 'split("\n") | map(select(length>0))')"
    extra="$(printf '%s\n' "${CFG_EXTRA_ARGS[@]}" | jq -Rrs 'split("\n") | map(select(length>0))')"
    jq -n \
        --arg ia "$CFG_INTEGRATOR_ADDRESS" \
        --arg sp "$CFG_SYNC_PROFILE" \
        --arg fs "$CFG_FASTSYNC" \
        --arg ph "$CFG_PRUNE_HISTORY" \
        --arg nt "$CFG_NODE_TAG" \
        --arg gw "$CFG_GETWORK_BIND" \
        --arg dd "$CFG_DATA_DIR" \
        --arg ld "$CFG_LOG_DIR" \
        --arg rb "$CFG_RPC_BIND" \
        --arg pb "$CFG_P2P_BIND" \
        --arg mn "$CFG_MIN_PEERS" \
        --arg mx "$CFG_MAX_PEERS" \
        --arg sp2 "$CFG_SOCKS_PROXY" \
        --arg cl "$CFG_CLOG_LEVEL" \
        --arg fl "$CFG_FLOG_LEVEL" \
        --arg tn "$CFG_TESTNET" \
        --arg db "$CFG_DEBUG" \
        --arg tis "$CFG_TIME_IS_IN_SYNC" \
        --arg sn "$CFG_SYNC_NODE" \
        --arg sd "$CFG_SNAPSHOT_DIR" \
        --arg sl "$CFG_SNAPSHOT_LEVEL" \
        --argjson prio "$prio" \
        --argjson excl "$excl" \
        --argjson extra "$extra" \
        '{integrator_address:$ia, sync_profile:$sp, fastsync:($fs=="true"),
          prune_history:(if $ph=="" then null else ($ph|tonumber) end),
          node_tag:$nt, getwork_bind:$gw, data_dir:$dd, log_dir:$ld,
          rpc_bind:$rb, p2p_bind:$pb,
          min_peers:(if $mn=="" then null else ($mn|tonumber) end),
          max_peers:(if $mx=="" then null else ($mx|tonumber) end),
          socks_proxy:$sp2,
          add_priority_node:$prio, add_exclusive_node:$excl,
          clog_level:(if $cl=="" then null else ($cl|tonumber) end),
          flog_level:(if $fl=="" then null else ($fl|tonumber) end),
          testnet:($tn=="true"), debug:($db=="true"), time_is_in_sync:($tis=="true"),
          sync_node:($sn=="true"), extra_args:$extra,
          snapshot_dir:$sd, snapshot_level:(if $sl=="" then 10 else ($sl|tonumber) end)}' \
        > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

validate_config() {
    [ -n "$CFG_INTEGRATOR_ADDRESS" ] || return 0
    case "$CFG_INTEGRATOR_ADDRESS" in
        dero1*|deroi1*|deto1*|detoi1*) ;;
        *)
            echo "${C_WARN}[!] integrator_address '$CFG_INTEGRATOR_ADDRESS' does not look like a DERO address." >&2
            ;;
    esac
}

# Build the derod argv into global array DEROD_ARGV.
build_derod_argv() {
    DEROD_ARGV=()
    [ "$CFG_TESTNET" = "true" ] && DEROD_ARGV+=(--testnet)
    [ "$CFG_DEBUG" = "true" ] && DEROD_ARGV+=(--debug)
    [ "$CFG_TIME_IS_IN_SYNC" = "true" ] && DEROD_ARGV+=(--timeisinsync)
    [ "$CFG_SYNC_NODE" = "true" ] && DEROD_ARGV+=(--sync-node)
    [ "$CFG_FASTSYNC" = "true" ] && DEROD_ARGV+=(--fastsync)
    [ -n "$CFG_PRUNE_HISTORY" ] && DEROD_ARGV+=(--prune-history="$CFG_PRUNE_HISTORY")
    [ -n "$CFG_SOCKS_PROXY" ] && DEROD_ARGV+=(--socks-proxy="$CFG_SOCKS_PROXY")
    [ -n "$DATA_DIR_REAL" ] && DEROD_ARGV+=(--data-dir="$DATA_DIR_REAL")
    [ -n "$CFG_P2P_BIND" ] && DEROD_ARGV+=(--p2p-bind="$CFG_P2P_BIND")
    [ -n "$CFG_RPC_BIND" ] && DEROD_ARGV+=(--rpc-bind="$CFG_RPC_BIND")
    [ -n "$CFG_GETWORK_BIND" ] && DEROD_ARGV+=(--getwork-bind="$CFG_GETWORK_BIND")
    local n
    for n in ${CFG_ADD_PRIORITY_NODE[@]+"${CFG_ADD_PRIORITY_NODE[@]}"}; do
        [ -n "$n" ] && DEROD_ARGV+=(--add-priority-node="$n")
    done
    for n in ${CFG_ADD_EXCLUSIVE_NODE[@]+"${CFG_ADD_EXCLUSIVE_NODE[@]}"}; do
        [ -n "$n" ] && DEROD_ARGV+=(--add-exclusive-node="$n")
    done
    [ -n "$CFG_MIN_PEERS" ] && DEROD_ARGV+=(--min-peers="$CFG_MIN_PEERS")
    [ -n "$CFG_MAX_PEERS" ] && DEROD_ARGV+=(--max-peers="$CFG_MAX_PEERS")
    [ -n "$CFG_NODE_TAG" ] && DEROD_ARGV+=(--node-tag="$CFG_NODE_TAG")
    [ -n "$CFG_INTEGRATOR_ADDRESS" ] && DEROD_ARGV+=(--integrator-address="$CFG_INTEGRATOR_ADDRESS")
    [ -n "$CFG_CLOG_LEVEL" ] && DEROD_ARGV+=(--clog-level="$CFG_CLOG_LEVEL")
    [ -n "$CFG_FLOG_LEVEL" ] && DEROD_ARGV+=(--flog-level="$CFG_FLOG_LEVEL")
    [ -n "$LOG_DIR_REAL" ] && DEROD_ARGV+=(--log-dir="$LOG_DIR_REAL")
    local a
    for a in ${CFG_EXTRA_ARGS[@]+"${CFG_EXTRA_ARGS[@]}"}; do
        [ -n "$a" ] && DEROD_ARGV+=("$a")
    done
}

print_argv() {
    printf '%s ' "$BINARY_PATH"
    printf '%q ' "${DEROD_ARGV[@]}"
    echo ""
}
#!/usr/bin/env bash
set -euo pipefail

DERONODE_VERSION="1.0.0"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$PROJECT_DIR/lib"
INSTALL_DIR="$PROJECT_DIR"
BIN_DIR="$PROJECT_DIR/bin"
CONFIG_FILE="$PROJECT_DIR/config.json"
CATALOG_FILE="$PROJECT_DIR/catalog.json"
BINARY_PATH="$BIN_DIR/derod/derod"

# shellcheck source=lib/platform.sh
source "$LIB_DIR/platform.sh"
# shellcheck source=lib/ui.sh
source "$LIB_DIR/ui.sh"
# shellcheck source=lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=lib/download.sh
source "$LIB_DIR/download.sh"
# shellcheck source=lib/rpc.sh
source "$LIB_DIR/rpc.sh"
# shellcheck source=lib/service.sh
source "$LIB_DIR/service.sh"
# shellcheck source=lib/snapshot.sh
source "$LIB_DIR/snapshot.sh"

detect_platform

# ── CLI state ──
ACTION="menu"
AS_SERVICE=false
DRY_RUN=false
RECONFIGURE=false
SNAPSHOT_OUT=""
SNAPSHOT_FROM=""
SNAPSHOT_MAX_RATIO=false
SNAPSHOT_KEEP_RUNNING=false
SNAPSHOT_YES=false

# ── Help ──
show_help() {
    cat <<'EOF'
Usage: deronode [command] [options]
  cross-platform DERO node installer & manager (derod only)

  Flag values accept both --flag=value and --flag value.

  Commands:
    start                Run derod (--service to install/start a background service)
    stop                 Stop derod
    status               Show sync status, binary tag, paths
    update               Fetch the latest DEROFDN release; restart if running
    snapshot             Create a privacy-hardened tar.zst of the chain state
    restore              Restore chain state from a snapshot (stops the node)
    --reconfigure        Re-run the first-run prompts (incl. data-dir / log-dir)

  Options:
    --dry-run            Resolve/download nothing; print the derod argv and exit
    --config=<path>      Config file (default ./config.json)
    --integrator-address=<addr>  10% rewards address
    --sync-profile=<p>   pruned | full | none (shortcut for fastsync/prune)
    --fastsync           Enable fast sync (bootstrap only)
    --no-fastsync        Disable fast sync
    --prune-history=<n>  Prune history to this topo height
    --node-tag=<name>    Public node identifier
    --getwork-bind=<ip:port>      Miner endpoint (default 127.0.0.1:10100)
    --data-dir=<dir>     Blockchain data location (configurable)
    --log-dir=<dir>      Log location (configurable)
    --rpc-bind=<ip:port> Daemon JSON-RPC (default 127.0.0.1:10102)
    --p2p-bind=<ip:port> P2P listen (default 0.0.0.0:10101)
    --min-peers=<n>      Target minimum peers
    --max-peers=<n>      Maximum peers
    --socks-proxy=<socks_ip:port> Route P2P through a proxy
    --add-priority-node=<ip:port>   Maintain a persistent connection (repeatable)
    --add-exclusive-node=<ip:port>  Connect to this peer only (repeatable)
    --clog-level=<0-127> Console log level
    --flog-level=<0-127> File log level
    --testnet            Run on testnet (swaps default ports)
    --debug              Verbose logging
    --time-is-in-sync    Tell the daemon the clock is correct
    --sync-node          Force sync from seed nodes
    --extra-arg=<raw>    Append a raw derod argument (repeatable)
    --level=<n>          Snapshot zstd level (default 10; --max-ratio forces 19)
    --max-ratio          Snapshot at maximum compression (zstd level 19)
    --out=<dir>          Snapshot output dir (overrides snapshot_dir)
    --keep-running       Allow snapshot while derod runs on this data dir
    --from=<archive>     Archive to restore (restore)
    --yes                Skip snapshot/restore confirmations
    --version | -h       Version / help

  Examples:
    deronode
    deronode start --service
    deronode status
    deronode --data-dir=/mnt/ssd/dero-chain --log-dir=/mnt/ssd/dero-logs start
    deronode --prune-history=50000 --rpc-bind=127.0.0.1:10102
EOF
}

# Space-form merge + flag parse. Mirrors deromine's two-pass approach.
parse_cli_args() {
    local -a norm=()
    local key
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --integrator-address|--sync-profile|--prune-history|--node-tag|--getwork-bind|--data-dir|--log-dir|--rpc-bind|--p2p-bind|--min-peers|--max-peers|--socks-proxy|--add-priority-node|--add-exclusive-node|--clog-level|--flog-level|--config|--extra-arg|--level|--out|--from)
                if [ $# -lt 2 ]; then echo "${C_ERR}[x] Missing value for $1${C_RESET}" >&2; exit 1; fi
                norm+=("$1=$2"); shift 2 ;;
            *) norm+=("$1"); shift ;;
        esac
    done
    set -- "${norm[@]}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --integrator-address=*) CFG_INTEGRATOR_ADDRESS="${1#*=}"; shift ;;
            --sync-profile=*) set_sync_profile "${1#*=}"; shift ;;
            --fastsync) CFG_FASTSYNC=true; shift ;;
            --no-fastsync) CFG_FASTSYNC=false; shift ;;
            --prune-history=*) CFG_PRUNE_HISTORY="${1#*=}"; shift ;;
            --node-tag=*) CFG_NODE_TAG="${1#*=}"; shift ;;
            --getwork-bind=*) CFG_GETWORK_BIND="${1#*=}"; shift ;;
            --data-dir=*) CFG_DATA_DIR="${1#*=}"; resolve_paths; shift ;;
            --log-dir=*) CFG_LOG_DIR="${1#*=}"; resolve_paths; shift ;;
            --rpc-bind=*) CFG_RPC_BIND="${1#*=}"; shift ;;
            --p2p-bind=*) CFG_P2P_BIND="${1#*=}"; shift ;;
            --min-peers=*) CFG_MIN_PEERS="${1#*=}"; shift ;;
            --max-peers=*) CFG_MAX_PEERS="${1#*=}"; shift ;;
            --socks-proxy=*) CFG_SOCKS_PROXY="${1#*=}"; shift ;;
            --add-priority-node=*) CFG_ADD_PRIORITY_NODE+=("${1#*=}"); shift ;;
            --add-exclusive-node=*) CFG_ADD_EXCLUSIVE_NODE+=("${1#*=}"); shift ;;
            --clog-level=*) CFG_CLOG_LEVEL="${1#*=}"; shift ;;
            --flog-level=*) CFG_FLOG_LEVEL="${1#*=}"; shift ;;
            --testnet) CFG_TESTNET=true; shift ;;
            --debug) CFG_DEBUG=true; shift ;;
            --time-is-in-sync) CFG_TIME_IS_IN_SYNC=true; shift ;;
            --sync-node) CFG_SYNC_NODE=true; shift ;;
            --extra-arg=*) CFG_EXTRA_ARGS+=("${1#*=}"); shift ;;
            --level=*) CFG_SNAPSHOT_LEVEL="${1#*=}"; shift ;;
            --max-ratio) SNAPSHOT_MAX_RATIO=true; shift ;;
            --out=*) SNAPSHOT_OUT="${1#*=}"; shift ;;
            --keep-running) SNAPSHOT_KEEP_RUNNING=true; shift ;;
            --from=*) SNAPSHOT_FROM="${1#*=}"; shift ;;
            --yes) SNAPSHOT_YES=true; shift ;;
            --config=*) CONFIG_FILE="${1#*=}"; shift ;;
            --dry-run) DRY_RUN=true; [ "$ACTION" = "menu" ] && ACTION="start"; shift ;;
            --service) AS_SERVICE=true; shift ;;
            --reconfigure) RECONFIGURE=true; ACTION="reconfigure"; shift ;;
            --version) echo "deronode $DERONODE_VERSION"; exit 0 ;;
            -h|--help|help|/\?) show_help; exit 0 ;;
            start) ACTION="start"; shift ;;
            stop) ACTION="stop"; shift ;;
            status) ACTION="status"; shift ;;
            update) ACTION="update"; shift ;;
            snapshot) ACTION="snapshot"; shift ;;
            restore) ACTION="restore"; shift ;;
            *) echo "${C_ERR}[x] Unknown: $1${C_RESET}" >&2; show_help >&2; exit 1 ;;
        esac
    done
}

set_sync_profile() {
    case "$1" in
        pruned) CFG_SYNC_PROFILE=pruned; CFG_FASTSYNC=true; CFG_PRUNE_HISTORY=100000 ;;
        full)   CFG_SYNC_PROFILE=full; CFG_FASTSYNC=false; CFG_PRUNE_HISTORY="" ;;
        none)   CFG_SYNC_PROFILE=none; CFG_FASTSYNC=false; CFG_PRUNE_HISTORY="" ;;
        *) echo "${C_ERR}[x] sync-profile must be pruned|full|none${C_RESET}" >&2; exit 1 ;;
    esac
}

# ── Configure prompts ──
confirm_disk() {
    local profile="$CFG_SYNC_PROFILE" need warn=0
    case "$profile" in
        pruned) need=50 ;;
        full)   need=230 ;;
        none)   return 0 ;;
        *)      return 0 ;;
    esac
    local free
    free="$(df -Pk "$DATA_DIR_REAL" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ -n "$free" ] && [ "$free" -lt $(( need * 1024 * 1024 )) ]; then
        echo "${C_WARN}[!] $need GB (${C_RESET}${C_BOLD}$profile${C_RESET}${C_WARN}) recommended for data-dir $DATA_DIR_REAL; this disk shows ~$(( free / 1024 / 1024 )) GB free.${C_RESET}" >&2
        [ "$(yesno "Continue anyway?" n)" = "n" ] && { echo "${C_ERR}[x] Aborted. Free space or pick a pruned profile.${C_RESET}" >&2; exit 1; }
    fi
}

configure() {
    local advanced=false
    echo "${C_INFO}[*] derod configuration (first run)${C_RESET}"
    echo ""
    ask CFG_INTEGRATOR_ADDRESS "Integrator address (dero1.../deto1..., empty = dev address)" "$CFG_INTEGRATOR_ADDRESS"
    [ -z "$CFG_INTEGRATOR_ADDRESS" ] && \
        echo "${C_WARN}[!] No integrator address: integrator-block rewards go to the upstream dev address.${C_RESET}"

    echo ""
    echo "  Sync profile:"
    echo "    ${C_BOLD}1) Pruned VPS${C_RESET}   --fastsync --prune-history=100000  (~50 GB) [recommended]"
    echo "    ${C_BOLD}2) Full archival${C_RESET} no prune, full history from genesis (230 GB+, plan 500 GB)"
    echo "    ${C_BOLD}3) Custom${C_RESET}       keep whatever --fastsync/--prune-history are set to"
    local pick
    ask pick "Choose" "1"
    case "$pick" in
        2) set_sync_profile full ;;
        3) : ;;
        *) set_sync_profile pruned ;;
    esac

    echo ""
    ask CFG_NODE_TAG "Node tag (public name, optional)" "$CFG_NODE_TAG"

    echo ""
    echo "  GETWORK (miner endpoint, port 10100):"
    echo "    ${C_BOLD}1) This machine only${C_RESET}  127.0.0.1:10100  (default)"
    echo "    ${C_BOLD}2) Off-host miners${C_RESET}    0.0.0.0:10100   (open 10100/tcp on the firewall)"
    echo "    ${C_BOLD}3) Custom${C_RESET}"
    ask pick "Choose" "1"
    case "$pick" in
        2) CFG_GETWORK_BIND="0.0.0.0:10100" ;;
        3) ask CFG_GETWORK_BIND "GETWORK bind" "$CFG_GETWORK_BIND" ;;
        *) CFG_GETWORK_BIND="127.0.0.1:10100" ;;
    esac

    echo ""
    if [ -f "$CONFIG_FILE" ]; then
        echo "  Paths (Enter keeps current):"
        ask CFG_DATA_DIR "Data dir" "$DATA_DIR_REAL"
        ask CFG_LOG_DIR "Log dir" "$LOG_DIR_REAL"
        resolve_paths
    else
        [ "$(yesno "Configure data-dir / log-dir now? (advanced)" n)" = "y" ] && advanced=true
        if $advanced; then
            ask CFG_DATA_DIR "Data dir" "$INSTALL_DIR/chain"
            ask CFG_LOG_DIR "Log dir" "$INSTALL_DIR/logs"
            resolve_paths
        else
            resolve_paths
        fi
    fi

    apply_testnet_defaults
    validate_config
    save_config
    confirm_disk
    echo "${C_OK}[*] Saved $CONFIG_FILE${C_RESET}"
}

# ── Menu ──
menu() {
    draw_banner
    if [ ! -f "$BINARY_PATH" ] && ! node_running; then
        echo "  No derod installed yet."
        echo ""
        echo "  [1] Configure & install derod"
        echo "  [q] Quit"
        local a
        ask a "Choose" "1"
        case "$a" in
            1|"") 
                [ -f "$CONFIG_FILE" ] || configure
                ensure_binary
                ;;
            *) exit 0 ;;
        esac
    fi

    while true; do
        print_status "$BIN_DIR/derod"
        echo ""
        echo "  ${C_BOLD}1)${C_RESET} Start (foreground)"
        echo "  ${C_BOLD}2)${C_RESET} Start as background service"
        echo "  ${C_BOLD}3)${C_RESET} Stop"
        echo "  ${C_BOLD}4)${C_RESET} Status"
        echo "  ${C_BOLD}5)${C_RESET} Update derod"
        echo "  ${C_BOLD}6)${C_RESET} Reconfigure"
        echo "  ${C_BOLD}7)${C_RESET} Show command line (dry-run)"
        echo "  ${C_BOLD}8)${C_RESET} Snapshot chain state (tar.zst)"
        echo "  ${C_BOLD}9)${C_RESET} Restore chain state from snapshot"
        echo "  ${C_BOLD}q)${C_RESET} Quit"
        local a
        ask a "Choose" ""
        case "$a" in
            1) ACTION=start; AS_SERVICE=false; return ;;
            2) ACTION=start; AS_SERVICE=true; return ;;
            3) ACTION=stop; return ;;
            4) ACTION=status; return ;;
            5) ACTION=update; return ;;
            6) RECONFIGURE=true; return ;;
            7) ACTION=start; DRY_RUN=true; return ;;
            8) ACTION=snapshot; return ;;
            9) ACTION=restore; return ;;
            q|Q) exit 0 ;;
            *) echo "${C_ERR}[x] Unknown choice${C_RESET}" >&2 ;;
        esac
    done
}

ensure_binary() {
    resolve_release || return 1
    if cached_tag_fresh; then return 0; fi
    fetch_derod || return 1
}

cmd_start() {
    if $DRY_RUN; then
        resolve_paths
        apply_testnet_defaults
        build_derod_argv
        echo "${C_MUTE}derod command line:${C_RESET}"
        print_argv
        exit 0
    fi
    if node_is_external; then
        echo "${C_WARN}[!] derod is system-installed (external) — manage it via your system service manager.${C_RESET}" >&2
        exit 0
    fi
    [ -f "$CONFIG_FILE" ] || { echo "${C_INFO}[*] No config yet — running first-run setup.${C_RESET}" >&2; configure; }
    ensure_binary || exit 1
    apply_testnet_defaults
    build_derod_argv
    mkdir -p "$DATA_DIR_REAL" "$LOG_DIR_REAL"
    if $AS_SERVICE; then
        service_install
    else
        exec "$BINARY_PATH" "${DEROD_ARGV[@]}"
    fi
}

cmd_stop() {
    if node_is_external; then
        echo "${C_WARN}[!] derod is system-installed (external) — manage it via your system service manager (e.g. systemctl stop derod).${C_RESET}" >&2
        exit 0
    fi
    service_stop
}

cmd_status() {
    draw_banner
    if node_running || [ -f "$BINARY_PATH" ]; then
        print_status "$BIN_DIR/derod"
    else
        echo "${C_MUTE}derod is not installed. Run 'deronode' or 'deronode start'.${C_RESET}"
        exit 0
    fi
}

cmd_update() {
    resolve_release || exit 1
    local old new was_running=false
    old="$(cat "$BIN_DIR/derod/.tag" 2>/dev/null || echo none)"
    if cached_tag_fresh; then
        echo "${C_OK}[*] Already at latest ($LAST_TAG).${C_RESET}"
        return 0
    fi
    echo "${C_INFO}[*] Updating derod $old -> $LAST_TAG${C_RESET}"
    if node_is_external; then
        cmd_update_external || exit 1
        return 0
    fi
    node_running && was_running=true
    if $was_running; then service_stop; fi
    fetch_derod || exit 1
    if $was_running; then
        echo "${C_INFO}[*] restarting with the new binary...${C_RESET}"
        service_install
    fi
}

# Update path for an externally-managed node (systemd etc.): download the new
# derod into bin/, back up + replace the running binary, then restart its unit.
cmd_update_external() {
    local pid bin unit ts
    pid="$(pgrep -f 'derod-linux-amd64 --fastsync' | head -1)"
    [ -n "$pid" ] || { echo "${C_ERR}[x] Could not find the running derod process${C_RESET}" >&2; return 1; }
    bin="$(readlink "/proc/$pid/exe" 2>/dev/null)"
    bin="${bin% (deleted)}"
    [ -n "$bin" ] && [ -f "$bin" ] || { echo "${C_ERR}[x] Could not resolve the running derod binary path${C_RESET}" >&2; return 1; }

    fetch_derod || return 1

    ts="$(date +%Y%m%d_%H%M%S)"
    cp -f "$bin" "$bin.bak-$ts" || { echo "${C_ERR}[x] Backup failed: $bin.bak-$ts${C_RESET}" >&2; return 1; }
    echo "${C_INFO}[*] backed up $bin -> $bin.bak-$ts${C_RESET}" >&2
    cp -f "$BINARY_PATH" "$bin" || { echo "${C_ERR}[x] Replace failed: $bin${C_RESET}" >&2; return 1; }
    chmod +x "$bin"
    echo "${C_OK}[*] replaced $bin with $LAST_TAG${C_RESET}" >&2

    unit="$(awk -F/ '/\.service$/ {print $NF}' "/proc/$pid/cgroup" 2>/dev/null | head -1)"
    if [ -n "$unit" ]; then
        echo "${C_INFO}[*] restarting $unit...${C_RESET}" >&2
        if command -v sudo >/dev/null 2>&1 && sudo -n systemctl restart "$unit" 2>/dev/null; then
            echo "${C_OK}[*] $unit restarted with $LAST_TAG${C_RESET}" >&2
        else
            echo "${C_WARN}[!] $unit is a system unit — restart it manually: sudo systemctl restart $unit${C_RESET}" >&2
        fi
    else
        echo "${C_WARN}[!] external node has no systemd unit — restart it manually${C_RESET}" >&2
    fi
}

cmd_reconfigure() {
    configure
    echo "${C_OK}[*] Done. Run 'deronode start' to launch.${C_RESET}"
}

cmd_snapshot() {
    resolve_paths
    SNAPSHOT_DIR="${SNAPSHOT_OUT:-$SNAPSHOT_DIR_REAL}"
    snapshot_pack || exit 1
}

cmd_restore() {
    resolve_paths
    snapshot_restore || exit 1
}

# ── Entry ──
# CLI must WIN over config.json, and load_config must read the file the user
# pointed at with --config. So: scan for --config, load the file, THEN parse
# the remaining flags as overrides.
entry_scan_config() {
    local a
    while [ $# -gt 0 ]; do
        case "$1" in
            --config=*) CONFIG_FILE="${1#*=}"; return 0 ;;
            --config) [ $# -ge 2 ] && { CONFIG_FILE="$2"; return 0; } ;;
            *) shift ;;
        esac
    done
}
entry_scan_config "$@"
load_config
parse_cli_args "$@"

case "$ACTION" in
    reconfigure) cmd_reconfigure ;;
    start)       cmd_start ;;
    stop)        cmd_stop ;;
    status)      cmd_status ;;
    update)      cmd_update ;;
    snapshot)    cmd_snapshot ;;
    restore)     cmd_restore ;;
    *)           menu; case "$ACTION" in
                     start)   cmd_start ;;
                     stop)    cmd_stop ;;
                     status)  cmd_status ;;
                     update)  cmd_update ;;
                     snapshot) cmd_snapshot ;;
                     restore) cmd_restore ;;
                 esac ;;
esac
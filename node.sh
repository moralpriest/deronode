#!/usr/bin/env bash
set -euo pipefail

DERONODE_VERSION="1.2.0"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$PROJECT_DIR/lib"
INSTALL_DIR="$PROJECT_DIR"
BIN_DIR="$PROJECT_DIR/bin"
CONFIG_FILE="$PROJECT_DIR/config.json"
CATALOG_FILE="$PROJECT_DIR/catalog.json"
# Windows cannot execute an extensionless file (CreateProcess/ShellExecute
# fail or pop the "open with" dialog), so the managed binary is derod.exe
# there — adjusted after detect_platform below.
BINARY_NAME="derod"
BINARY_PATH="$BIN_DIR/derod/$BINARY_NAME"

# shellcheck source=lib/platform.sh
source "$LIB_DIR/platform.sh"
# shellcheck source=lib/ui.sh
source "$LIB_DIR/ui.sh"
# shellcheck source=lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=lib/download.sh
source "$LIB_DIR/download.sh"
# shellcheck source=lib/build.sh
source "$LIB_DIR/build.sh"
# shellcheck source=lib/rpc.sh
source "$LIB_DIR/rpc.sh"
# shellcheck source=lib/service.sh
source "$LIB_DIR/service.sh"
# shellcheck source=lib/snapshot.sh
source "$LIB_DIR/snapshot.sh"

detect_platform
# Windows (incl. Git Bash/MSYS2/MINGW) needs the .exe suffix for the binary.
if [ "$OS" = "windows" ]; then
    BINARY_NAME="derod.exe"
    BINARY_PATH="$BIN_DIR/derod/$BINARY_NAME"
fi

# ── CLI state ──
ACTION="menu"
AS_SERVICE=false
DRY_RUN=false
RECONFIGURE=false
MENU_MODE=false   # true while driving the interactive menu (loop back after each action)
SNAPSHOT_OUT=""
SNAPSHOT_FROM=""
SNAPSHOT_MAX_RATIO=false
SNAPSHOT_KEEP_RUNNING=false
SNAPSHOT_YES=false
UPDATE_SOURCE="release"   # update source: release (download) | dev (community-dev compile)
SEND_ARCHIVE=""           # archive to share with thruflux (default: newest snapshot)
RECEIVE_CODE=""           # thruflux join code to receive

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
    update               Update derod; restart if running. --source=release (default,
                         download) or --source=dev (compile latest community-dev)
    build                Compile the latest community-dev source branch (Go required)
    snapshot             Create a privacy-hardened tar.zst of the chain state
    restore              Restore chain state from a snapshot (stops the node)
    resync               Wipe the chain and re-bootstrap via --fastsync
    logs                 Tail the node log (derod.log; follows live)
    uninstall            Remove derod + all node data (binary, chain, logs,
                         snapshots, config); keeps deronode itself
    send [<archive>]     Share a snapshot (or any file) with a friend via
                         thruflux: thru host, prints a join code (fast, encrypted
                         QUIC P2P). Defaults to the newest snapshot.
    receive <code>       Receive a thruflux transfer: thru join <code>
    --reconfigure        Re-run the first-run prompts (incl. data-dir / log-dir)

  Options:
    --dry-run            Resolve/download nothing; print the derod argv and exit
    --config=<path>      Config file (default ./config.json)
    --source=release|dev Update source (release download or community-dev compile)
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
    --out=<dir>          Snapshot output dir; receive output dir (default .)
    --keep-running       Allow snapshot while derod runs on this data dir
    --from=<archive>     Archive to restore (restore)
    --yes                Skip snapshot/restore/resync/uninstall confirmations
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
            --integrator-address|--sync-profile|--prune-history|--node-tag|--getwork-bind|--data-dir|--log-dir|--rpc-bind|--p2p-bind|--min-peers|--max-peers|--socks-proxy|--add-priority-node|--add-exclusive-node|--clog-level|--flog-level|--config|--extra-arg|--level|--out|--from|--source)
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
            --source=*) UPDATE_SOURCE="${1#*=}"; shift ;;
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
            build) ACTION="build"; shift ;;
            snapshot) ACTION="snapshot"; shift ;;
            restore) ACTION="restore"; shift ;;
            resync) ACTION="resync"; shift ;;
            logs) ACTION="logs"; shift ;;
            uninstall) ACTION="uninstall"; shift ;;
            send) ACTION="send"; shift
                  # Optional positional archive: `send <path>`. Only capture
                  # non-flag tokens (send --dry-run must not eat the flag).
                  if [ -n "${1:-}" ] && [ "${1#--}" = "${1:-}" ]; then SEND_ARCHIVE="$1"; shift; fi ;;
            receive) ACTION="receive"; shift
                  # Required positional join code: `receive <code>`.
                  if [ -n "${1:-}" ] && [ "${1#--}" = "${1:-}" ]; then RECEIVE_CODE="$1"; shift; fi ;;
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

    echo ""
    echo "  Run mode:"
    echo "    ${C_BOLD}1) Background system service${C_RESET}   auto-start on boot (systemd / LaunchAgent / background)"
    echo "    ${C_BOLD}2) Foreground${C_RESET}               run in this terminal"
    ask pick "Choose" "2"
    case "$pick" in
        1) AS_SERVICE=true ;;
        *) AS_SERVICE=false ;;
    esac

    apply_testnet_defaults
    validate_config
    save_config
    confirm_disk
    echo "${C_OK}[*] Saved $CONFIG_FILE${C_RESET}"
}

# ── Menu ──
menu() {
    draw_banner
    if [ ! -f "$BINARY_PATH" ] && ! node_running && ! external_installed; then
        echo "  No derod installed yet."
        echo ""
        echo "  [1] Configure & install derod"
        echo "  [q] Quit"
        local a
        ask a "Choose" "1"
        case "$a" in
            1|"")
                [ -f "$CONFIG_FILE" ] || configure
                # The install just finished — confirm the user actually wants
                # the node started now (interactive only; scripted runs
                # auto-continue). The configure run-mode answer (service vs
                # foreground) is honored via AS_SERVICE.
                if ensure_binary; then
                    if [ -t 0 ] && [ "$(yesno "derod installed. Start the node now?" y)" != "y" ]; then
                        return   # back to the menu — the binary now exists, full menu shows
                    fi
                    ACTION=start
                    return
                fi
                exit 1
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
        echo "  ${C_BOLD}5)${C_RESET} View node logs (tail -f)"
        echo "  ${C_BOLD}6)${C_RESET} Update derod (release or community-dev)"
        echo "  ${C_BOLD}7)${C_RESET} Build derod from community-dev source"
        echo "  ${C_BOLD}8)${C_RESET} Reconfigure"
        echo "  ${C_BOLD}9)${C_RESET} Show command line (dry-run)"
        echo "  ${C_BOLD}10)${C_RESET} Snapshot chain state (tar.zst)"
        echo "  ${C_BOLD}11)${C_RESET} Restore chain state from snapshot"
        echo "  ${C_BOLD}12)${C_RESET} Resync: wipe chain + re-bootstrap (fastsync)"
        echo "  ${C_BOLD}13)${C_RESET} Share snapshot (thruflux)"
        echo "  ${C_BOLD}14)${C_RESET} Receive snapshot (thruflux)"
        echo "  ${C_BOLD}15)${C_RESET} Uninstall: remove derod + all node data (keep deronode)"
        echo "  ${C_BOLD}q)${C_RESET} Quit"
        local a
        ask a "Choose" ""
        case "$a" in
            1) ACTION=start; AS_SERVICE=false; return ;;
            2) ACTION=start; AS_SERVICE=true; return ;;
            3) ACTION=stop; return ;;
            4) ACTION=status; return ;;
            5) ACTION=logs; return ;;
            6) echo "    Update source:"
               echo "      1) Latest release (download)"
               echo "      2) community-dev source (compile)"
               ask pick "Choose" "1"
               case "$pick" in
                   2) UPDATE_SOURCE=dev ;;
                   *) UPDATE_SOURCE=release ;;
               esac
               ACTION=update; return ;;
            7) ACTION=build; return ;;
            8) ACTION=reconfigure; return ;;
            9) ACTION=start; DRY_RUN=true; return ;;
            10) ACTION=snapshot; return ;;
            11) ACTION=restore; return ;;
            12) ACTION=resync; return ;;
            13) ACTION=send; return ;;
            14) echo "    Enter the join code:"
                ask code "Join code" ""
                if [ -n "$code" ]; then
                    RECEIVE_CODE="$code"
                    ACTION=receive; return
                fi
                echo "${C_ERR}[x] No join code entered${C_RESET}" >&2
                ;;
            15) ACTION=uninstall; return ;;
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
        # Menu option 7: show the argv and fall back to the menu; a plain CLI
        # --dry-run exits after printing (scripted callers need the exit code).
        $MENU_MODE && return 0
        exit 0
    fi
    if external_installed; then
        external_start
        return $?
    fi
    [ -f "$CONFIG_FILE" ] || { echo "${C_INFO}[*] No config yet — running first-run setup.${C_RESET}" >&2; configure; }
    ensure_binary || exit 1
    apply_testnet_defaults
    mkdir -p "$DATA_DIR_REAL" "$LOG_DIR_REAL"
    if $AS_SERVICE; then
        # service_install builds the argv itself (and short-circuits with
        # "already configured and running" before that), so the fastsync/prune
        # warnings don't print for a no-op.
        service_install
        return $?
    fi
    build_derod_argv
    # From the menu, run derod as a child so the menu is shown again once
    # the node exits. Plain CLI start keeps exec (exit code propagation).
    if $MENU_MODE; then
        "$BINARY_PATH" "${DEROD_ARGV[@]}" || true
    else
        exec "$BINARY_PATH" "${DEROD_ARGV[@]}"
    fi
}

cmd_stop() {
    if external_installed; then
        external_stop
        return $?
    fi
    service_stop
}

# cmd_logs — tail the node's log file live. derod writes its own structured
# log (--log-dir) as derod.log; launchd / background backends also capture
# stdout/stderr to derod.out.log + derod.err.log, which we fall back to.
cmd_logs() {
    resolve_paths
    local log="$LOG_DIR_REAL/derod.log"
    if [ -f "$log" ]; then
        echo "${C_INFO}[*] tailing $log (Ctrl-C to stop)${C_RESET}" >&2
        if $MENU_MODE; then
            tail -n 100 -f "$log"
            return 0
        fi
        exec tail -n 100 -f "$log"
    fi
    # No derod.log yet — service stdout/stderr captures (launchd / background).
    local -a files=()
    [ -f "$LOG_DIR_REAL/derod.out.log" ] && files+=("$LOG_DIR_REAL/derod.out.log")
    [ -f "$LOG_DIR_REAL/derod.err.log" ] && files+=("$LOG_DIR_REAL/derod.err.log")
    if [ "${#files[@]}" -gt 0 ]; then
        echo "${C_INFO}[*] tailing ${files[*]} (Ctrl-C to stop)${C_RESET}" >&2
        if $MENU_MODE; then
            tail -n 100 -f "${files[@]}"
            return 0
        fi
        exec tail -n 100 -f "${files[@]}"
    fi
    echo "${C_WARN}[!] no log files in $LOG_DIR_REAL — derod hasn't written logs yet (foreground start prints to the terminal).${C_RESET}" >&2
    if external_installed; then
        local unit
        unit="$(external_unit)" || unit="derod.service"
        echo "    externally-managed node — its logs live with its service manager (e.g. journalctl --user -u $unit -f)" >&2
    elif [ "$(service_backend)" = "systemd" ]; then
        echo "    systemd console stream: journalctl --user -u deronode.service -f" >&2
    fi
    return 1
}

# external_start — start a system-installed (external) derod via its service
# manager (sudo when system-level). No-op when already running. Never downloads
# or spawns a managed derod.
external_start() {
    local unit plist
    if node_running; then
        unit="$(external_unit || echo derod.service)"
        echo "${C_INFO}[*] external derod already running ($unit)${C_RESET}" >&2
        return 0
    fi
    unit="$(external_unit)" || { echo "${C_ERR}[x] No external derod unit found${C_RESET}" >&2; return 1; }
    echo "${C_INFO}[*] starting $unit...${C_RESET}" >&2
    if [ "$OS" = "darwin" ]; then
        # launchd: start a loaded user agent; load (sudo for daemons) otherwise.
        if launchctl list 2>/dev/null | awk -v u="$unit" '$3 == u {found=1} END {exit !found}'; then
            launchctl kickstart "gui/$(id -u)/$unit" 2>/dev/null \
                || launchctl start "$unit" 2>/dev/null
            echo "${C_OK}[*] $unit started${C_RESET}" >&2
            return 0
        fi
        for plist in "$HOME/Library/LaunchAgents/$unit.plist" "/Library/LaunchAgents/$unit.plist" "/Library/LaunchDaemons/$unit.plist"; do
            [ -f "$plist" ] || continue
            if launchctl load "$plist" 2>/dev/null || sudo -n launchctl load "$plist" 2>/dev/null; then
                echo "${C_OK}[*] $unit loaded + started${C_RESET}" >&2
                return 0
            fi
            if [ -t 0 ] && sudo launchctl load "$plist"; then
                echo "${C_OK}[*] $unit loaded + started${C_RESET}" >&2
                return 0
            fi
            echo "${C_WARN}[!] could not start $unit — run: sudo launchctl load $plist${C_RESET}" >&2
            return 1
        done
        echo "${C_WARN}[!] no plist found for $unit${C_RESET}" >&2
        return 1
    fi
    if external_is_system_unit; then
        if sudo -n systemctl start "$unit" 2>/dev/null; then
            echo "${C_OK}[*] $unit started${C_RESET}" >&2
            return 0
        fi
        if [ -t 0 ] && sudo systemctl start "$unit"; then
            echo "${C_OK}[*] $unit started${C_RESET}" >&2
            return 0
        fi
        echo "${C_WARN}[!] could not start $unit (needs sudo) — run: sudo systemctl start $unit${C_RESET}" >&2
        return 1
    fi
    if systemctl --user start "$unit" 2>/dev/null; then
        echo "${C_OK}[*] $unit started${C_RESET}" >&2
        return 0
    fi
    echo "${C_WARN}[!] could not start $unit — run: systemctl --user start $unit${C_RESET}" >&2
    return 1
}

# external_stop — stop a system-installed (external) derod: resolve its unit
# and stop via the service manager (sudo when system-level), else kill the bare
# process directly. Works whether the node is running or already stopped.
external_stop() {
    local unit pid plist
    unit="$(external_unit)"
    if [ -n "$unit" ]; then
        echo "${C_INFO}[*] stopping $unit...${C_RESET}" >&2
        if [ "$OS" = "darwin" ]; then
            if launchctl list 2>/dev/null | awk -v u="$unit" '$3 == u {found=1} END {exit !found}'; then
                launchctl kickstart -k "gui/$(id -u)/$unit" 2>/dev/null || true
                launchctl stop "$unit" 2>/dev/null || true
            fi
            for plist in "$HOME/Library/LaunchAgents/$unit.plist" "/Library/LaunchAgents/$unit.plist" "/Library/LaunchDaemons/$unit.plist"; do
                [ -f "$plist" ] || continue
                if launchctl unload "$plist" 2>/dev/null || sudo -n launchctl unload "$plist" 2>/dev/null; then
                    echo "${C_OK}[*] $unit stopped${C_RESET}" >&2
                    return 0
                fi
                if [ -t 0 ] && sudo launchctl unload "$plist"; then
                    echo "${C_OK}[*] $unit stopped${C_RESET}" >&2
                    return 0
                fi
                echo "${C_WARN}[!] could not stop $unit — run: sudo launchctl unload $plist${C_RESET}" >&2
                return 1
            done
            echo "${C_OK}[*] $unit stopped${C_RESET}" >&2
            return 0
        fi
        if external_is_system_unit; then
            if sudo -n systemctl stop "$unit" 2>/dev/null; then
                echo "${C_OK}[*] $unit stopped${C_RESET}" >&2
                return 0
            fi
            if [ -t 0 ] && sudo systemctl stop "$unit"; then
                echo "${C_OK}[*] $unit stopped${C_RESET}" >&2
                return 0
            fi
            echo "${C_WARN}[!] could not stop $unit (needs sudo) — run: sudo systemctl stop $unit${C_RESET}" >&2
            return 1
        fi
        if systemctl --user stop "$unit" 2>/dev/null; then
            echo "${C_OK}[*] $unit stopped${C_RESET}" >&2
            return 0
        fi
        echo "${C_WARN}[!] could not stop $unit — run: systemctl --user stop $unit${C_RESET}" >&2
        return 1
    fi
    # No unit — plain externally-launched process: kill it directly.
    pid="$(derod_pid)"
    [ -n "$pid" ] || { echo "${C_INFO}[*] no external derod running${C_RESET}" >&2; return 0; }
    kill "$pid" 2>/dev/null
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        sleep 1
    fi
    if kill -0 "$pid" 2>/dev/null; then
        echo "${C_WARN}[!] could not stop external derod (pid $pid) — no permission? stop it manually.${C_RESET}" >&2
        return 1
    fi
    echo "${C_OK}[*] stopped external derod (pid $pid)${C_RESET}" >&2
}

cmd_status() {
    draw_banner
    if node_running || [ -f "$BINARY_PATH" ] || external_installed; then
        print_status "$BIN_DIR/derod"
    else
        echo "${C_MUTE}derod is not installed. Run 'deronode' or 'deronode start'.${C_RESET}"
        exit 0
    fi
}

cmd_update() {
    # --source=dev routes the update through the community-dev compile path.
    if [ "${UPDATE_SOURCE:-release}" = "dev" ]; then
        cmd_build
        return $?
    fi
    resolve_release || exit 1
    local old new was_running=false
    old="$(cat "$BIN_DIR/derod/.tag" 2>/dev/null || echo none)"
    # An explicit `update` always fetches the latest release — including over a
    # community-dev source build, which is otherwise kept as fresh. Skip both
    # "already at latest" short-circuits when the installed binary is a source
    # build so the user can switch back to the release.
    if ! is_source_build && cached_tag_fresh; then
        echo "${C_OK}[*] Already at latest ($LAST_TAG).${C_RESET}"
        return 0
    fi
    # If the running daemon already reports the latest release, skip download and
    # install entirely. This covers externally-managed nodes whose bin/ cache tag
    # may be stale or absent even though the running binary is current.
    if ! is_source_build && [ -n "$LAST_TAG" ]; then
        local run_rel latest_rel
        run_rel="$(daemon_release_number)"
        latest_rel="$(printf '%s' "$LAST_TAG" | grep -oE '[0-9]+$' | head -1)"
        if [ -n "$run_rel" ] && [ -n "$latest_rel" ] && [ "$run_rel" = "$latest_rel" ]; then
            echo "${C_OK}[*] Already at latest ($LAST_TAG).${C_RESET}"
            return 0
        fi
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

# Update path for an externally-managed node (systemd unit / launchd agent):
# download the new derod into bin/, back up + replace the running binary, then
# restart its unit/agent. Process/binary resolution and the restart are
# platform-agnostic (Linux /proc + systemd, macOS lsof + launchctl).
cmd_update_external() {
    local pid bin unit ts
    pid="$(derod_pid)"
    [ -n "$pid" ] || { echo "${C_ERR}[x] Could not find the running derod process${C_RESET}" >&2; return 1; }
    bin="$(process_exe "$pid")"
    [ -n "$bin" ] && [ -f "$bin" ] || { echo "${C_ERR}[x] Could not resolve the running derod binary path${C_RESET}" >&2; return 1; }

    fetch_derod || return 1

    ts="$(date +%Y%m%d_%H%M%S)"
    cp -f "$bin" "$bin.bak-$ts" || { echo "${C_ERR}[x] Backup failed: $bin.bak-$ts${C_RESET}" >&2; return 1; }
    echo "${C_INFO}[*] backed up $bin -> $bin.bak-$ts${C_RESET}" >&2
    cp -f "$BINARY_PATH" "$bin" || { echo "${C_ERR}[x] Replace failed: $bin${C_RESET}" >&2; return 1; }
    chmod +x "$bin"
    echo "${C_OK}[*] replaced $bin with $LAST_TAG${C_RESET}" >&2

    if [ "$OS" = "darwin" ]; then
        # launchd: kickstart -k restarts a loaded agent; otherwise tell the user.
        unit="$(external_unit)"
        if [ -n "$unit" ]; then
            echo "${C_INFO}[*] restarting $unit...${C_RESET}" >&2
            if launchctl kickstart -k "gui/$(id -u)/$unit" 2>/dev/null; then
                echo "${C_OK}[*] $unit restarted with $LAST_TAG${C_RESET}" >&2
            else
                echo "${C_WARN}[!] restart $unit manually: launchctl kickstart -k gui/$(id -u)/$unit${C_RESET}" >&2
            fi
        else
            echo "${C_WARN}[!] external node has no launchd agent — restart it manually${C_RESET}" >&2
        fi
        return 0
    fi

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

# cmd_build — compile the latest DEROFDN/derohe community-dev source branch
# with the local Go toolchain and install it as bin/derod/derod (an
# alternative to downloading a release). Restarts a running node like update.
# Refuses on externally-managed nodes (we never replace binaries we don't own).
cmd_build() {
    if $DRY_RUN; then
        echo "${C_INFO}[*] dry-run: would clone $DEV_REPO ($DEV_BRANCH) and 'go build ./cmd/derod' into $BINARY_PATH${C_RESET}"
        return 0
    fi
    if external_installed; then
        echo "${C_ERR}[x] build only works on a deronode-managed node (an external derod is installed).${C_RESET}" >&2
        return 1
    fi
    if ! have_go; then
        echo "${C_ERR}[x] Go toolchain not found — install Go 1.17+ (https://go.dev/dl/) to build derod from source.${C_RESET}" >&2
        return 1
    fi
    local old was_running=false
    old="$(cat "$BIN_DIR/derod/.tag" 2>/dev/null || echo none)"
    echo "${C_INFO}[*] Building derod $old -> $DEV_BRANCH${C_RESET}"
    node_running && was_running=true
    if $was_running; then service_stop; fi
    build_derod_from_source || exit 1
    if $was_running; then
        echo "${C_INFO}[*] restarting with the freshly-built binary...${C_RESET}"
        service_install
    fi
}

cmd_reconfigure() {
    configure
    # Continue straight into `start` after asking questions, same as the
    # first-run install flow. Only when nothing is running — a live node
    # must be stopped/restarted by the user instead.
    if node_running; then
        echo "${C_WARN}[!] derod is running — stop it first (deronode stop) to apply the new config.${C_RESET}" >&2
        return 0
    fi
    cmd_start
}

# cmd_resync — wipe the chain data and re-bootstrap via --fastsync. This is the
# "start over" path: a fresh chain (or one broken by a bad prune) gets a clean
# fastsync bootstrap. Refuses on externally-managed nodes (we never touch data
# we don't own). Stops a running node first, deletes the chain dir, forces
# fastsync on and prune off (a fresh chain can't prune), then starts.
cmd_resync() {
    resolve_paths
    if external_installed; then
        echo "${C_ERR}[x] resync only works on a deronode-managed node (an external derod is installed).${C_RESET}" >&2
        return 1
    fi
    if $DRY_RUN; then
        echo "${C_INFO}[*] dry-run: would wipe $(snapshot_chain_dir) and re-bootstrap via --fastsync${C_RESET}"
        return 0
    fi
    local chain_dir size
    chain_dir="$(snapshot_chain_dir)"
    if [ -d "$chain_dir" ]; then
        size="$(du -sh "$chain_dir" 2>/dev/null | awk '{print $1}')"
        echo "${C_WARN}[!] This deletes the chain data at $chain_dir${C_RESET}" >&2
        [ -n "$size" ] && echo "${C_WARN}[!]   ($size) and re-bootstraps via --fastsync.${C_RESET}" >&2
        if ! $SNAPSHOT_YES && [ "$(yesno "Continue?" n)" != "y" ]; then
            echo "${C_ERR}[x] Aborted.${C_RESET}" >&2
            return 1
        fi
        if node_running; then
            echo "${C_INFO}[*] stopping derod...${C_RESET}" >&2
            cmd_stop || return 1
        fi
        echo "${C_INFO}[*] wiping chain data...${C_RESET}" >&2
        rm -rf "$chain_dir"
    fi
    # Fresh bootstrap: fastsync on, no prune (derod can't prune an empty chain).
    CFG_FASTSYNC=true
    CFG_PRUNE_HISTORY=""
    save_config
    echo "${C_OK}[*] chain reset — bootstrapping via fastsync.${C_RESET}" >&2
    cmd_start
}

# cmd_uninstall — remove the managed node completely: stop it, remove the
# service unit, and delete the binary, chain data, logs, snapshots, and
# config.json. Keeps the deronode tool itself so the menu returns to the
# fresh "No derod installed yet" first-run state. Refuses on
# externally-managed nodes (we never touch data we don't own).
cmd_uninstall() {
    resolve_paths
    if external_installed; then
        echo "${C_ERR}[x] uninstall only works on a deronode-managed node (an external derod is installed).${C_RESET}" >&2
        return 1
    fi
    if $DRY_RUN; then
        echo "${C_INFO}[*] dry-run: would stop derod, remove the service unit, and delete $DATA_DIR_REAL, $BIN_DIR, $LOG_DIR_REAL, $SNAPSHOT_DIR_REAL, $CONFIG_FILE${C_RESET}"
        return 0
    fi
    echo "${C_WARN}[!] This removes the derod binary, chain data, logs, snapshots, and config.json.${C_RESET}" >&2
    if ! $SNAPSHOT_YES && [ "$(yesno "Continue?" n)" != "y" ]; then
        echo "${C_ERR}[x] Aborted.${C_RESET}" >&2
        return 1
    fi
    # Safety guard: never wipe / or an empty path even if config.json was
    # pointed at something pathological.
    local dir
    for dir in "$DATA_DIR_REAL" "$BIN_DIR" "$LOG_DIR_REAL" "$SNAPSHOT_DIR_REAL"; do
        if [ -z "$dir" ] || [ "$dir" = "/" ]; then
            echo "${C_ERR}[x] Refusing to uninstall: $dir is not a removable path.${C_RESET}" >&2
            return 1
        fi
    done
    echo "${C_INFO}[*] stopping derod...${C_RESET}" >&2
    service_remove
    echo "${C_INFO}[*] removing node data...${C_RESET}" >&2
    rm -rf "$DATA_DIR_REAL" "$BIN_DIR" "$LOG_DIR_REAL" "$SNAPSHOT_DIR_REAL"
    rm -f "$CONFIG_FILE" "$CONFIG_FILE.bak" "$INSTALL_DIR/derod.pid" "$INSTALL_DIR/run-derod.sh" "$INSTALL_DIR/run-derod.ps1"
    echo "${C_OK}[*] derod removed — deronode stays installed. Re-run the menu to configure a fresh node.${C_RESET}"
}

# thruflux is a peer-to-peer QUIC file-transfer CLI (thru host / thru join).
# We shell out to it for `send`/`receive`; it must be installed separately.
#
# NOTE: the upstream one-line installers (install_linux.sh / install_macos.sh
# / install_windows.ps1) are currently BROKEN — they download `thru` from a
# github.com/.../raw/refs/heads/main/... URL that returns 404 (GitHub serves
# large blobs differently on that route). The binaries exist at the
# raw.githubusercontent.com/.../main/... equivalent, so we fetch them
# directly instead of piping the installer.
thru_binary_url() {
    case "$OS" in
        darwin)  echo "https://raw.githubusercontent.com/samsungplay/Thruflux/main/frontend/binaries/macos/thru_mac" ;;
        windows) echo "https://raw.githubusercontent.com/samsungplay/Thruflux/main/frontend/binaries/windows/thru_windows.exe" ;;
        *)       echo "https://raw.githubusercontent.com/samsungplay/Thruflux/main/frontend/binaries/linux/thru_linux" ;;
    esac
}

thru_install_hint() {
    local url="$(thru_binary_url)" bin_dir="$HOME/.local/bin"
    if [ "$OS" = "windows" ]; then
        echo "  mkdir -p '$bin_dir' && curl -fsSL '$url' -o '$bin_dir/thru.exe'"
    else
        echo "  mkdir -p '$bin_dir' && curl -fsSL '$url' -o '$bin_dir/thru' && chmod +x '$bin_dir/thru'"
    fi
}

# Install the thruflux CLI: download the static binary into ~/.local/bin
# (deronode already puts its launcher there) and raise the UDP socket buffers
# so thruflux can actually use them (matches the upstream installer's tuning;
# best-effort, needs root). Prints progress; returns 0 on success.
thru_install() {
    local url="$(thru_binary_url)" bin_dir="$HOME/.local/bin" target="thru"
    [ "$OS" = "windows" ] && target="thru.exe"
    mkdir -p "$bin_dir" || return 1
    echo "${C_INFO}[*] downloading thruflux...${C_RESET}" >&2
    curl -fsSL --progress-bar "$url" -o "$bin_dir/$target" || return 1
    chmod +x "$bin_dir/$target" 2>/dev/null || true
    # Best-effort UDP buffer tuning (16 MiB like the upstream installer).
    if [ "$OS" = "linux" ] && command -v sysctl >/dev/null 2>&1; then
        if [ "$(id -u)" -eq 0 ]; then
            sysctl -w net.core.rmem_max=16777216 net.core.wmem_max=16777216 \
                   net.core.rmem_default=16777216 net.core.wmem_default=16777216 >/dev/null 2>&1 || true
        elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            sudo sysctl -w net.core.rmem_max=16777216 net.core.wmem_max=16777216 \
                 net.core.rmem_default=16777216 net.core.wmem_default=16777216 >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

# Ensure the thruflux CLI is available. Interactive runs are asked to install
# it on the spot (default yes); piped/scripted runs and non-tty invocations
# only get the manual install hint, so nothing is ever installed unattended.
# Returns 0 when `thru` is usable, 1 otherwise.
thru_ensure() {
    command -v thru >/dev/null 2>&1 && return 0
    echo "${C_ERR}[x] thruflux CLI (thru) not found.${C_RESET}" >&2
    if [ -t 0 ] && [ "$(yesno "Install thruflux now?" y)" = "y" ]; then
        if thru_install; then
            # Make it usable for the rest of this session even when
            # ~/.local/bin is not on PATH yet (deronode's installer adds it
            # to the shell rc, but that only applies to new shells).
            if ! command -v thru >/dev/null 2>&1; then
                export PATH="$HOME/.local/bin:$PATH"
            fi
            if command -v thru >/dev/null 2>&1; then
                echo "${C_OK}[*] thruflux installed: $(command -v thru)${C_RESET}" >&2
            else
                echo "${C_OK}[*] thruflux installed at $HOME/.local/bin/$([ "$OS" = "windows" ] && echo thru.exe || echo thru) — add ~/.local/bin to your PATH.${C_RESET}" >&2
            fi
            return 0
        fi
        echo "${C_ERR}[x] thruflux install failed — install it manually with:${C_RESET}" >&2
    fi
    thru_install_hint >&2
    return 1
}

# cmd_send — share a snapshot (or any file) with a friend over the internet,
# fast + encrypted, via thruflux: `thru host <archive>` prints a join code the
# friend uses with `thru join <code>` (or `deronode receive <code>`). Defaults
# to the newest snapshot in the snapshot dir; pass an explicit path to send
# any file. Needs the thruflux CLI (see thru_install_hint).
cmd_send() {
    resolve_paths
    local archive="$SEND_ARCHIVE"
    if [ -z "$archive" ]; then
        archive="$(snapshot_latest_archive)"
        if [ -z "$archive" ]; then
            echo "${C_ERR}[x] no snapshot found in ${SNAPSHOT_DIR_REAL:-$INSTALL_DIR/snapshots} — pass a file: deronode send <path>${C_RESET}" >&2
            return 1
        fi
        echo "${C_INFO}[*] using latest snapshot: $(basename "$archive")${C_RESET}" >&2
    fi
    if [ ! -f "$archive" ]; then
        echo "${C_ERR}[x] file not found: $archive${C_RESET}" >&2
        return 1
    fi
    # Host the archive together with its .sha256 / .manifest.json siblings
    # (when present) so the receiver can verify the restore automatically —
    # thruflux supports any number of files in one host session.
    local -a files=("$archive")
    [ -f "$archive.sha256" ] && files+=("$archive.sha256")
    [ -f "$archive.manifest.json" ] && files+=("$archive.manifest.json")
    if $DRY_RUN; then
        echo "${C_INFO}[*] dry-run: would run: thru host ${files[*]}${C_RESET}"
        echo "${C_INFO}[*] your friend then runs: thru join <code> --out <dir>  (or: deronode receive <code>)${C_RESET}"
        return 0
    fi
    thru_ensure || return 1
    echo "${C_INFO}[*] hosting ${files[*]} — share the join code with your friend${C_RESET}" >&2
    thru host "${files[@]}"
}

# cmd_receive — receive a thruflux transfer from a friend: `thru join <code>`
# writes the files into --out (default .). Needs the thruflux CLI.
cmd_receive() {
    if [ -z "$RECEIVE_CODE" ]; then
        echo "${C_ERR}[x] usage: deronode receive <code> [--out <dir>]${C_RESET}" >&2
        return 1
    fi
    if $DRY_RUN; then
        echo "${C_INFO}[*] dry-run: would run: thru join $RECEIVE_CODE --out ${SNAPSHOT_OUT:-.}${C_RESET}"
        return 0
    fi
    thru_ensure || return 1
    local out="${SNAPSHOT_OUT:-.}"
    thru join "$RECEIVE_CODE" --out "$out" || return 1

    # Integrated restore: if the transfer carried a deronode snapshot
    # (dero-mainnet-*.tar.zst, with its .sha256/.manifest siblings when the
    # sender used `deronode send`), propose restoring it right away —
    # mirroring cmd_snapshot's stop/restore/restart flow. Interactive only,
    # so piped/scripted runs never touch the node.
    local received
    received="$(ls -1t "$out"/dero-mainnet-*.tar.zst 2>/dev/null | head -1)"
    if [ -z "$received" ]; then
        echo "${C_MUTE}[*] transfer complete — saved to $out (not a deronode snapshot, nothing to restore).${C_RESET}"
        return 0
    fi
    if ! snapshot_stdin_tty; then
        echo "${C_INFO}[*] received snapshot: $(basename "$received") — restore it with: deronode restore --from \"$received\"${C_RESET}"
        return 0
    fi
    resolve_paths
    SNAPSHOT_FROM="$received"
    if ! snapshot_running_on_data_dir; then
        # Node is stopped: reuse the normal restore flow (confirm, restore,
        # then offer to start the node).
        cmd_restore
        return $?
    fi
    if [ "$(yesno "derod is running on $DATA_DIR_REAL — stop it, restore the received snapshot, then restart?" y)" != "y" ]; then
        echo "${C_INFO}[*] received snapshot saved to $received — restore it later with: deronode restore --from \"$received\"${C_RESET}"
        return 0
    fi
    echo "${C_INFO}[*] stopping derod...${C_RESET}"
    cmd_stop || exit 1
    # The user just confirmed the stop+restore, so skip restore's second
    # confirm and the no-.sha256 wall; sha256 verification failures still abort.
    SNAPSHOT_YES=true
    if ! snapshot_restore; then
        echo "${C_INFO}[*] restarting derod...${C_RESET}"
        node_is_external && external_start || service_install
        return 1
    fi
    echo "${C_INFO}[*] restarting derod...${C_RESET}"
    if node_is_external; then external_start; else service_install; fi
}

cmd_snapshot() {
    resolve_paths
    SNAPSHOT_DIR="${SNAPSHOT_OUT:-$SNAPSHOT_DIR_REAL}"
    # If a snapshot already exists, present the latest one (name + timestamp)
    # and confirm a new one. Names are timestamped, so a new archive never
    # overwrites; this guards the menu against accidental re-snapshots.
    # Interactive-only (piped/scripted runs and --dry-run proceed straight to
    # snapshot_pack). Declining keeps the existing snapshot and exits 0.
    if ! $DRY_RUN && snapshot_stdin_tty; then
        latest="$(snapshot_latest_archive 2>/dev/null || true)"
        if [ -n "$latest" ]; then
            stamp="$(snapshot_archive_stamp "$latest")"
            if [ "$(yesno "Latest snapshot: $(basename "$latest") ($stamp) — create a new one?" y)" != "y" ]; then
                echo "${C_MUTE}[*] keeping existing snapshot — nothing created.${C_RESET}"
                return 0
            fi
        fi
    fi
    # Snapshot needs the chain quiet. If derod is running against our data dir
    # (and --keep-running wasn't passed), offer to stop it, snapshot, then
    # restart. Only prompts on an interactive terminal so piped/scripted calls
    # never auto-stop the node; declining falls through to the library guard.
    if ! $DRY_RUN \
       && snapshot_running_on_data_dir \
       && [ "${SNAPSHOT_KEEP_RUNNING:-false}" != "true" ] \
       && snapshot_stdin_tty \
       && [ "$(yesno "derod is running on $DATA_DIR_REAL - stop it, snapshot, then restart?" y)" = "y" ]; then
        echo "${C_INFO}[*] stopping derod...${C_RESET}"
        cmd_stop || exit 1
        snapshot_pack || exit 1
        echo "${C_INFO}[*] restarting derod...${C_RESET}"
        if node_is_external; then
            external_start
        else
            service_install
        fi
        return $?
    fi
    snapshot_pack || exit 1
}

cmd_restore() {
    resolve_paths
    snapshot_restore || exit 1
    # Restore replaces the chain state and refuses while any derod runs, so the
    # node is guaranteed stopped here. Offer to bring it back up — interactive
    # only, and never with --yes, so piped/scripted restores keep their old
    # behavior (restore but leave the node stopped).
    if [ "${SNAPSHOT_YES:-false}" != "true" ] \
       && snapshot_stdin_tty \
       && [ "$(yesno "Restore complete. Start the node now?" y)" = "y" ]; then
        echo "${C_INFO}[*] starting derod...${C_RESET}"
        cmd_start || exit 1
    fi
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
    build)       cmd_build ;;
    snapshot)    cmd_snapshot ;;
    restore)     cmd_restore ;;
    resync)      cmd_resync ;;
    logs)        cmd_logs ;;
    uninstall)   cmd_uninstall ;;
    send)         cmd_send ;;
    receive)      cmd_receive ;;
    *)           # Menu-driven: dispatch the chosen action, then come back to
                 # the menu instead of exiting (q in the menu quits). Nonzero
                 # action exits are swallowed so a failure shows the menu again
                 # rather than kicking the user out.
                 MENU_MODE=true
                 while true; do
                     menu
                     case "$ACTION" in
                         start)       cmd_start       || true ;;
                         stop)        cmd_stop        || true ;;
                         status)      cmd_status      || true ;;
                         update)      cmd_update      || true ;;
                         build)       cmd_build       || true ;;
                         snapshot)    cmd_snapshot    || true ;;
                         restore)     cmd_restore     || true ;;
                         resync)      cmd_resync      || true ;;
                         logs)        cmd_logs        || true ;;
                         uninstall)   cmd_uninstall   || true ;;
                         send)         cmd_send        || true ;;
                         receive)      cmd_receive     || true ;;
                         reconfigure) cmd_reconfigure || true ;;
                     esac
                 done ;;
esac
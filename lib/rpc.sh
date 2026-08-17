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

# realpath_p <path> — canonical absolute path. GNU readlink -f is Linux-only
# (macOS readlink lacks -f), so fall back to resolving dirname + basename.
realpath_p() {
    local p="$1" d f
    if readlink -f "$p" >/dev/null 2>&1; then
        readlink -f "$p"
    elif [ -e "$p" ]; then
        d="$(cd -P "$(dirname "$p")" >/dev/null 2>&1 && pwd)" || d="$(dirname "$p")"
        f="$(basename "$p")"
        printf '%s/%s\n' "$d" "$f"
    else
        printf '%s\n' "$p"
    fi
}

# derod_pid — pid of the first running derod daemon, any platform. We match the
# executable name (comm) so a "deronode" path never matches, and any binary
# flavor (derod-linux-amd64 / derod-darwin-* / derod-windows-*) is found.
derod_pid() {
    if [ "$OS" = "linux" ]; then
        local pid comm
        while IFS= read -r pid; do
            comm="$(cat "/proc/$pid/comm" 2>/dev/null)"
            case "$comm" in
                derod*) echo "$pid"; return 0 ;;
            esac
        done < <(pgrep -f '[d]erod' 2>/dev/null)
    else
        ps -axo pid=,comm= 2>/dev/null | while read -r pid comm; do
            case "$comm" in
                derod*) echo "$pid"; return 0 ;;
            esac
        done
    fi
}

# process_exe <pid> — absolute path of a running process's executable. Linux:
# /proc/$pid/exe. macOS: lsof reports the mapped executable (ps truncates).
process_exe() {
    local pid="$1" exe
    if [ "$OS" = "linux" ]; then
        exe="$(readlink "/proc/$pid/exe" 2>/dev/null)"
        printf '%s' "${exe% (deleted)}"
    else
        lsof -a -p "$pid" -Fn 2>/dev/null | sed -n 's/^n\(\/.*\)$/\1/p' | head -1
    fi
}

# process_cwd <pid> — a running process's working directory. Linux:
# /proc/$pid/cwd. macOS: lsof -d cwd.
process_cwd() {
    local pid="$1"
    if [ "$OS" = "linux" ]; then
        readlink "/proc/$pid/cwd" 2>/dev/null
    else
        lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n\(.*\)$/\1/p' | head -1
    fi
}

# node_is_external — true when a derod is running whose binary is NOT the one
# deronode manages (i.e. system-installed via systemd etc.). Robust to deronode
# having a previously-downloaded copy in bin/ — we compare the running process
# image, not the existence of our own binary.
node_is_external() {
    node_running || return 1
    local pid image ours
    pid="$(derod_pid)"
    [ -n "$pid" ] || return 1
    image="$(process_exe "$pid")"
    [ -n "$image" ] || return 1
    ours="$(realpath_p "$BINARY_PATH")"
    [ "$image" != "$ours" ]
}

# external_data_dir_from_unit <unitfile> — the data dir root encoded in a systemd
# unit: WorkingDirectory=, fallback --data-dir= from ExecStart. Empty when absent.
external_data_dir_from_unit() {
    local f="$1" dir="" flag
    [ -f "$f" ] || return 1
    dir="$(awk -F= '/^WorkingDirectory=/{print $2; exit}' "$f")"
    if [ -z "$dir" ]; then
        flag="$(grep -oE -- '--data-dir=[^ ]+' "$f" | head -1)"
        [ -n "$flag" ] && dir="${flag#--data-dir=}"
    fi
    [ -n "$dir" ] && echo "$dir"
}

# external_data_dir_from_plist <plist> — the data dir root encoded in a macOS
# launchd plist: WorkingDirectory= (via PlistBuddy), fallback --data-dir= from
# ProgramArguments. Empty when absent.
external_data_dir_from_plist() {
    local f="$1" dir="" flag
    [ -f "$f" ] || return 1
    if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
        dir="$(/usr/libexec/PlistBuddy -c 'Print :WorkingDirectory' "$f" 2>/dev/null)"
    fi
    if [ -z "$dir" ]; then
        # Portable fallback (also covers Linux smoke tests / non-macOS):
        # WorkingDirectory, then --data-dir= from ProgramArguments.
        dir="$(grep -oE '<key>WorkingDirectory</key>[[:space:]]*<string>[^<]+</string>' "$f" 2>/dev/null | sed -n 's/.*<string>\([^<]*\)<\/string>.*/\1/p' | head -1)"
    fi
    if [ -z "$dir" ]; then
        # Stop at space or XML angle brackets so a single-line plist value like
        # --data-dir=/srv/dero/node</string> does not over-capture.
        flag="$(grep -oE -- '--data-dir=[^ <>]+' "$f" | head -1)"
        [ -n "$flag" ] && dir="${flag#--data-dir=}"
    fi
    [ -n "$dir" ] && echo "$dir"
}

# external_data_dir — echo the data dir root for an externally-installed derod.
# derod's data dir defaults to its working directory, so we take the running
# process's cwd when the node is up, else the unit/agent's WorkingDirectory=
# (fallback --data-dir= from ExecStart). Echoes $DATA_DIR_REAL when no external
# install is present.
external_data_dir() {
    local pid unit dir
    pid="$(derod_pid)"
    if [ -n "$pid" ]; then
        dir="$(process_cwd "$pid")"
        [ -n "$dir" ] && { echo "$dir"; return 0; }
    fi
    unit="$(external_unit)" || { echo "$DATA_DIR_REAL"; return 1; }
    case "$OS" in
        darwin)
            for f in "$HOME/Library/LaunchAgents/$unit.plist" "/Library/LaunchAgents/$unit.plist" "/Library/LaunchDaemons/$unit.plist"; do
                [ -f "$f" ] && dir="$(external_data_dir_from_plist "$f")" && break
            done
            ;;
        *)
            if [ -f "/etc/systemd/system/$unit" ]; then
                dir="$(external_data_dir_from_unit "/etc/systemd/system/$unit")"
            elif [ -f "/usr/lib/systemd/system/$unit" ]; then
                dir="$(external_data_dir_from_unit "/usr/lib/systemd/system/$unit")"
            fi
            ;;
    esac
    [ -n "$dir" ] || dir="$DATA_DIR_REAL"
    echo "$dir"
    [ "$dir" != "$DATA_DIR_REAL" ]
}

# external_unit — echo the unit/agent name for an externally-installed derod
# (e.g. derod.service on Linux, a derod launchd agent on macOS), or nothing
# when none is installed. Works even when the node is stopped — we detect the
# *installation*, not a running process. Our own deronode-managed unit/agent
# (deronode.service / org.deronode.derod) is never treated as external.
external_unit() {
    local u
    case "$OS" in
        darwin)
            u="$(launchctl list 2>/dev/null | awk '$3 ~ /derod/ && $3 != "org.deronode.derod" {print $3; exit}')"
            if [ -n "$u" ]; then
                echo "$u"
                return 0
            fi
            for f in "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
                u="$(find "$f" -maxdepth 1 -name '*derod*.plist' ! -name 'org.deronode.derod.plist' 2>/dev/null | head -1)"
                [ -n "$u" ] && { echo "$(basename "$u" .plist)"; return 0; }
            done
            return 1
            ;;
        *)
            u="$(systemctl list-unit-files --no-legend --type=service 2>/dev/null | awk '$1 != "deronode.service" && $1 ~ /^derod[^@]*\.service$/ {print $1; exit}')"
            if [ -n "$u" ]; then
                echo "$u"
                return 0
            fi
            for f in /etc/systemd/system/derod.service /usr/lib/systemd/system/derod.service; do
                [ -f "$f" ] && { echo "derod.service"; return 0; }
            done
            return 1
            ;;
    esac
}

# external_installed — true when an external derod installation exists: a derod
# systemd unit is present, OR a derod is running whose binary is not ours.
external_installed() {
    external_unit >/dev/null 2>&1 || node_is_external
}

# external_is_system_unit — true when the unit/agent lives in the system
# manager (needs sudo) vs the user manager. Linux: systemd system vs user
# unit. macOS: LaunchDaemon (/Library/LaunchDaemons) vs user LaunchAgent
# (~/Library/LaunchAgents).
external_is_system_unit() {
    local unit
    unit="$(external_unit)" || return 1
    case "$OS" in
        darwin)
            [ -f "/Library/LaunchDaemons/$unit.plist" ] && return 0
            return 1
            ;;
        *)
            if systemctl --user list-unit-files --no-legend 2>/dev/null | grep -q "^$unit "; then
                return 1
            fi
            return 0
            ;;
    esac
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
        local unit
        if external_installed; then
            unit="$(external_unit)"
            if [ -n "$unit" ]; then
                echo "  external derod: $unit  (not managed by deronode)"
            else
                echo "  external derod  (not managed by deronode)"
            fi
        elif [ -f "$bin" ]; then
            echo "  derod $tag  data: $DATA_DIR_REAL  log: $LOG_DIR_REAL"
        else
            echo "  derod running — managed binary missing (run 'deronode update')"
        fi
    else
        echo "${C_MUTE}○ stopped${C_RESET}"
        if external_installed; then
            unit="$(external_unit)"
            if [ -n "$unit" ]; then
                echo "  external derod: $unit — stopped"
            else
                echo "  external derod — stopped"
            fi
        elif [ -f "$bin/derod" ]; then
            echo "  derod $(cat "$bin/.tag" 2>/dev/null || echo '?') installed — run 'deronode start'"
        fi
    fi
}
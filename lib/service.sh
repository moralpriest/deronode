#!/usr/bin/env bash
# lib/service.sh — start/stop/status/install/remove for the derod process.
# Backend selection: systemd user unit (Linux), LaunchAgent (macOS),
# nohup + pid file (fallback / Windows background). Sourced by node.sh.

# Derod runs via a wrapper that embeds the resolved argv so systemd does not
# need deronode installed for the unit to work.
write_run_wrapper() {
    local wrapper="$INSTALL_DIR/run-derod.sh"
    mkdir -p "$(dirname "$wrapper")"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        printf 'exec "%s" ' "$BINARY_PATH"
        printf '%q ' "${DEROD_ARGV[@]}"
        echo ''
    } > "$wrapper"
    chmod +x "$wrapper"
}

service_backend() {
    if [ "$OS" = "linux" ] && command -v systemctl >/dev/null 2>&1 && systemctl --user is-system-running >/dev/null 2>&1; then
        echo systemd
    elif [ "$OS" = "darwin" ]; then
        echo launchd
    else
        echo pid
    fi
}

service_install() {
    write_run_wrapper
    local backend
    backend="$(service_backend)"
    case "$backend" in
        systemd)
            local unit="$HOME/.config/systemd/user/deronode.service"
            mkdir -p "$(dirname "$unit")"
            cat > "$unit" <<EOF
[Unit]
Description=DERO node (deronode)
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/run-derod.sh
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
            systemctl --user daemon-reload
            systemctl --user enable deronode.service >/dev/null 2>&1 || true
            systemctl --user start deronode.service >/dev/null 2>&1 || true
            echo "${C_OK}[*] installed + started systemd user unit deronode.service${C_RESET}"
            ;;
        launchd)
            local plist="$HOME/Library/LaunchAgents/org.deronode.derod.plist"
            mkdir -p "$(dirname "$plist")"
            cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>org.deronode.derod</string>
    <key>ProgramArguments</key>
    <array><string>$INSTALL_DIR/run-derod.sh</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$LOG_DIR_REAL/derod.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR_REAL/derod.log</string>
</dict>
</plist>
EOF
            launchctl unload "$plist" >/dev/null 2>&1 || true
            launchctl load "$plist" >/dev/null 2>&1 || true
            echo "${C_OK}[*] installed + started LaunchAgent org.deronode.derod${C_RESET}"
            ;;
        *)
            start_pid
            ;;
    esac
}

start_pid() {
    mkdir -p "$LOG_DIR_REAL"
    write_run_wrapper
    nohup "$INSTALL_DIR/run-derod.sh" >> "$LOG_DIR_REAL/derod.log" 2>&1 &
    echo $! > "$INSTALL_DIR/derod.pid"
    echo "${C_OK}[*] derod started in background (pid $(cat "$INSTALL_DIR/derod.pid"))${C_RESET}"
    echo "    log: $LOG_DIR_REAL/derod.log"
}

service_stop() {
    local backend
    backend="$(service_backend)"
    case "$backend" in
        systemd)
            systemctl --user stop deronode.service >/dev/null 2>&1 || true
            ;;
        launchd)
            launchctl unload "$HOME/Library/LaunchAgents/org.deronode.derod.plist" >/dev/null 2>&1 || true
            ;;
    esac
    # Safety net: regardless of backend, never leave OUR binary running.
    [ -f "$INSTALL_DIR/derod.pid" ] && kill "$(cat "$INSTALL_DIR/derod.pid")" 2>/dev/null || true
    pkill -f "$BINARY_PATH" 2>/dev/null || true
    rm -f "$INSTALL_DIR/derod.pid"
    echo "${C_OK}[*] derod stopped${C_RESET}"
}

service_remove() {
    service_stop
    case "$(service_backend)" in
        systemd)
            systemctl --user disable deronode.service >/dev/null 2>&1 || true
            rm -f "$HOME/.config/systemd/user/deronode.service"
            systemctl --user daemon-reload >/dev/null 2>&1 || true
            echo "${C_MUTE}[*] systemd unit removed${C_RESET}" ;;
        launchd)
            rm -f "$HOME/Library/LaunchAgents/org.deronode.derod.plist"
            echo "${C_MUTE}[*] LaunchAgent removed${C_RESET}" ;;
        *) echo "${C_MUTE}[*] pid backend has no unit to remove${C_RESET}" ;;
    esac
    rm -f "$INSTALL_DIR/derod.pid"
}
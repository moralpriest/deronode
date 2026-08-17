#!/usr/bin/env bash
# lib/platform.sh — OS / arch / Termux detection. Sourced by node.sh.

OS=""
ARCH=""
IS_TERMUX=false

detect_platform() {
    OS="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    case "$OS" in
        linux|darwin|freebsd|windows) ;;
        # Git Bash / MSYS2 / MINGW / Cygwin all report a windows-like uname.
        mingw*|msys*|cygwin*) OS="windows" ;;
        *) OS="linux" ;;
    esac

    local m
    m="$(uname -m 2>/dev/null || echo x86_64)"
    case "$m" in
        x86_64|amd64|x64)        ARCH="amd64" ;;
        aarch64|arm64|armv8*)     ARCH="aarch64" ;;
        armv7l|armv6l|armv5tel|arm) ARCH="arm" ;;
        *)                       ARCH="amd64" ;;
    esac

    IS_TERMUX=false
    if [ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *com.termux* ]] && [ -d "$PREFIX/bin" ]; then
        IS_TERMUX=true
    fi
}

# Translate internal os/arch to a catalog key. darwin + universal covers both.
catalog_os() {
    case "$OS" in
        darwin) echo darwin ;;
        *)      echo "$OS" ;;
    esac
}

catalog_arch() {
    [ "$OS" = "darwin" ] && { echo "*"; return; }
    echo "$ARCH"
}
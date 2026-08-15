#!/usr/bin/env bash
# lib/ui.sh — ANSI helpers, banner, and interactive prompts. Sourced by node.sh.

if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
    C_INFO=$'\033[36m'; C_MUTE=$'\033[90m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_OK=""; C_WARN=""; C_ERR=""; C_INFO=""; C_MUTE=""
fi

has_unicode() {
    [ "$(locale charmap 2>/dev/null)" = "UTF-8" ]
}

draw_banner() {
    local v="$DERONODE_VERSION"
    echo "${C_BOLD}${C_INFO}"
    echo "  deronode v$v — DERO node installer & manager"
    echo ""
}

# ask <varname> <prompt> <default> — default shown in brackets, Enter accepts it.
ask() {
    local var="$1" prompt="$2" def="${3:-}" ans
    if [ -n "$def" ]; then
        printf '%s [%s]: ' "$prompt" "$def" >&2
    else
        printf '%s: ' "$prompt" >&2
    fi
    IFS= read -r ans || true
    ans="${ans:-$def}"
    printf -v "$var" '%s' "$ans"
}

# yesno <prompt> <default:y|n> -> echoes y/n
yesno() {
    local prompt="$1" def="${2:-n}" ans
    local hint
    [ "$def" = "y" ] && hint="Y/n" || hint="y/N"
    printf '%s [%s]: ' "$prompt" "$hint" >&2
    IFS= read -r ans || true
    ans="${ans:-$def}"
    case "$ans" in
        y|Y|yes|YES) echo y ;;
        *) echo n ;;
    esac
}
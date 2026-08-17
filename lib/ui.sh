#!/usr/bin/env bash
# lib/ui.sh — ANSI helpers, banner, and interactive prompts. Sourced by node.sh.

if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
    C_INFO=$'\033[36m'; C_MUTE=$'\033[90m'
    C_BANNER=$'\033[35m'; C_NAME=$'\033[37m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_OK=""; C_WARN=""; C_ERR=""; C_INFO=""; C_MUTE=""
    C_BANNER=""; C_NAME=""
fi

has_unicode() {
    [ "$(locale charmap 2>/dev/null)" = "UTF-8" ]
}

# Box-drawing chars (ASCII fallback when the terminal is not UTF-8).
if has_unicode; then
    B_TL='╔'; B_TR='╗'; B_BL='╚'; B_BR='╝'; B_H='═'; B_V='║'
    MENU_DOT='·'
else
    B_TL='+'; B_TR='+'; B_BL='+'; B_BR='+'; B_H='='; B_V='|'
    MENU_DOT='-'
fi

# rep <char> <count> — repeat a (possibly multi-byte) character.
rep() { printf '%*s' "$2" '' | sed "s/ /$1/g"; }

draw_banner() {
    local v="$DERONODE_VERSION"
    local title="deronode v$v"
    local subtitle="DERO node installer & manager"
    local menu_hint="[ MENU ]  start ${MENU_DOT} stop ${MENU_DOT} status ${MENU_DOT} update ${MENU_DOT} build ${MENU_DOT} snapshot ${MENU_DOT} restore ${MENU_DOT} resync ${MENU_DOT} logs ${MENU_DOT} quit"
    local width="${COLUMNS:-80}"
    local inner=$((width - 4)); [ "$inner" -lt 30 ] && inner=30
    local top bot title_pad sub_pad hint_pad
    top="${B_TL}$(rep "$B_H" "$inner")${B_TR}"
    bot="${B_BL}$(rep "$B_H" "$inner")${B_BR}"
    title_pad=$((inner - 4 - ${#title}));   [ "$title_pad" -lt 0 ] && title_pad=0
    sub_pad=$((inner - 4 - ${#subtitle}));  [ "$sub_pad" -lt 0 ] && sub_pad=0
    hint_pad=$((inner - 4 - ${#menu_hint})); [ "$hint_pad" -lt 0 ] && hint_pad=0
    echo "${C_BANNER}$top${C_RESET}"
    echo "${C_BANNER}${B_V}  ${C_NAME}${title}${C_RESET}${C_BANNER}$(rep ' ' "$title_pad")  ${B_V}${C_RESET}"
    echo "${C_BANNER}${B_V}  ${C_DIM}${subtitle}${C_RESET}${C_BANNER}$(rep ' ' "$sub_pad")  ${B_V}${C_RESET}"
    echo "${C_BANNER}$bot${C_RESET}"
    echo "${C_DIM}${menu_hint}${C_RESET}"
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
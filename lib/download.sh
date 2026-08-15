#!/usr/bin/env bash
# lib/download.sh — resolve the latest DEROFDN release, download derod,
# verify checksum.txt, extract only the daemon, cache under bin/derod.
# Sourced by node.sh.

GH_DL="https://github.com/DEROFDN/derohe/releases/download"
REPO="DEROFDN/derohe"

LAST_TAG=""
LAST_ASSET=""

# Resolve the release tag and the archive name for this host from catalog.json.
# Sets LAST_TAG / LAST_ASSET. Returns 1 when the catalog has no match.
resolve_release() {
    local cat_os cat_arch attempt
    cat_os="$(catalog_os)"
    cat_arch="$(catalog_arch)"

    LAST_ASSET="$(jq -r --arg os "$cat_os" --arg arch "$cat_arch" '
        .assets[] | select(.os == $os) | select(.arch == "*" or .arch == $arch) | .archive
    ' "$CATALOG_FILE" | head -1)"
    [ -n "$LAST_ASSET" ] || { echo "${C_ERR}[x] No catalog asset for $OS/$ARCH${C_RESET}" >&2; return 1; }

    # Resolve the latest tag from the releases/latest redirect (CDN — no GitHub
    # API quota, immune to unauthenticated rate limits). Retry on network blips.
    LAST_TAG=""
    for attempt in 1 2 3; do
        loc="$(curl -fsSI -m 15 "https://github.com/$REPO/releases/latest" 2>/dev/null | awk 'tolower($1) ~ /^location:/ {print $2}' | tr -d '\r' | head -1)"
        LAST_TAG="$(printf '%s' "$loc" | sed -n 's#.*/tag/##p')"
        [ -n "$LAST_TAG" ] && [ "$LAST_TAG" != "null" ] && break
        [ "$attempt" -lt 3 ] && sleep 1
    done
    [ -n "$LAST_TAG" ] && [ "$LAST_TAG" != "null" ] || { echo "${C_ERR}[x] Could not resolve the latest release tag for $REPO${C_RESET}" >&2; return 1; }
}

# bin/derod/.tag holds the tag the cached binary came from. Fresh when it
# matches a resolved tag, or within the freshness window.
cached_tag_fresh() {
    local tagfile="$BIN_DIR/derod/.tag"
    [ -f "$BIN_DIR/derod/derod" ] || return 1
    [ -f "$tagfile" ] || return 1
    [ "$(cat "$tagfile" 2>/dev/null)" = "$LAST_TAG" ] && return 0
    # Fall back to a freshness window so repeated runs skip the release API.
    local tf="$BIN_DIR/derod/.tagtime" now secs
    if [ -f "$tf" ]; then
        now="$(date +%s)"; secs="$(cat "$tf" 2>/dev/null || echo 0)"
        [ $(( now - secs )) -lt 600 ] && return 0
    fi
    return 1
}

verify_checksum() {
    local archive="$1" checksum="$2" name="$3" want got bits
    # Accepts "hex  file", "sha256:hex  file", "sha512:hex  file", and
    # "file  hex" with either a 64-char (sha256) or 128-char (sha512) hash.
    # DEROFDN's checksum.txt ships 128-char SHA-512 hashes.
    want="$(awk -v n="$name" '
        { c=$1; f=$2; if (f=="") { c=$NF; f=$1 }
          gsub(/^sha256:/,"",c); gsub(/^sha512:/,"",c)
          if (f==n && c ~ /^[0-9a-f]{64}$/) { print c; exit }
          if (c==n && f ~ /^[0-9a-f]{64}$/) { print f; exit }
          if (f==n && c ~ /^[0-9a-f]{128}$/) { print c; exit }
          if (c==n && f ~ /^[0-9a-f]{128}$/) { print f; exit } }' "$checksum")"
    [ -n "$want" ] || return 2
    case "${#want}" in
        64)  got="$( (sha256sum "$archive" 2>/dev/null || shasum -a 256 "$archive" 2>/dev/null) | awk '{print $1}')" ;;
        128) got="$( (sha512sum "$archive" 2>/dev/null || shasum -a 512 "$archive" 2>/dev/null) | awk '{print $1}')" ;;
        *) return 2 ;;
    esac
    [ -n "$got" ] || return 3
    [ "$got" = "$want" ]
}

find_derod_in() {
    local dir="$1"
    find "$dir" -type f -name 'derod*' 2>/dev/null | head -1
}

# Download + verify + extract + lift the daemon into bin/derod/derod.
fetch_derod() {
    mkdir -p "$BIN_DIR/derod"
    local tmp ar url checksum cs_name
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/deronode.XXXXXX")"
    ar="$tmp/$LAST_ASSET"
    url="$GH_DL/$LAST_TAG/$LAST_ASSET"

    echo "${C_INFO}[*] Downloading $LAST_ASSET (tag $LAST_TAG)${C_RESET}" >&2
    curl -fL "$url" -o "$ar" || { rm -rf "$tmp"; echo "${C_ERR}[x] Download failed${C_RESET}" >&2; return 1; }

    checksum="$tmp/checksum.txt"
    if curl -fsL "$GH_DL/$LAST_TAG/checksum.txt" -o "$checksum" 2>/dev/null; then
        if verify_checksum "$ar" "$checksum" "$LAST_ASSET"; then
            echo "${C_OK}[*] checksum verified against checksum.txt${C_RESET}" >&2
        else
            echo "${C_WARN}[!] checksum mismatch or not listed — continuing but verify manually.${C_RESET}" >&2
        fi
    else
        echo "${C_WARN}[!] no checksum.txt asset; skipping verification${C_RESET}" >&2
    fi

    echo "${C_INFO}[*] Extracting derod...${C_RESET}" >&2
    mkdir -p "$tmp/x"
    case "$LAST_ASSET" in
        *.zip)    unzip -o "$ar" -d "$tmp/x" >/dev/null 2>&1 || { rm -rf "$tmp"; echo "${C_ERR}[x] unzip failed${C_RESET}" >&2; return 1; } ;;
        *.tar.gz|*.tgz) tar -xzf "$ar" -C "$tmp/x" 2>/dev/null || { rm -rf "$tmp"; echo "${C_ERR}[x] tar failed${C_RESET}" >&2; return 1; } ;;
        *.tar)    tar -xf "$ar" -C "$tmp/x" 2>/dev/null || { rm -rf "$tmp"; echo "${C_ERR}[x] tar failed${C_RESET}" >&2; return 1; } ;;
        *) rm -rf "$tmp"; echo "${C_ERR}[x] Unknown archive type${C_RESET}" >&2; return 1 ;;
    esac

    local found
    found="$(find_derod_in "$tmp/x")"
    if [ -z "$found" ]; then
        rm -rf "$tmp"
        echo "${C_ERR}[x] derod binary not found in $LAST_ASSET${C_RESET}" >&2
        return 1
    fi

    # Verify it is a real executable (ELF/Mach-O/MZ), not a truncated download.
    local magic ok=1
    magic="$(head -c 4 "$found" | od -An -tx1 | tr -d ' \n')"
    case "$magic" in
        7f454c46|cffaedfe|cafebabe|feedface|feedfacf|4d5a) ok=0 ;;
    esac
    if [ "$ok" -ne 0 ]; then
        rm -rf "$tmp"
        echo "${C_ERR}[x] Extracted derod failed the executable magic check${C_RESET}" >&2
        return 1
    fi

    cp -f "$found" "$BIN_DIR/derod/derod"
    chmod +x "$BIN_DIR/derod/derod"
    printf '%s\n' "$LAST_TAG" > "$BIN_DIR/derod/.tag"
    date +%s > "$BIN_DIR/derod/.tagtime"
    printf '%s\n' "$LAST_ASSET" > "$BIN_DIR/derod/.asset"
    rm -rf "$tmp"
    echo "${C_OK}[*] derod $LAST_TAG ready: $BIN_DIR/derod/derod${C_RESET}" >&2
}
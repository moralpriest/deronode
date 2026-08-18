#!/usr/bin/env bash
# lib/snapshot.sh — privacy-hardened snapshot & restore of the chain state.
# Archive: standard .tar.zst via GNU tar (explicit include list + excludes)
# compressed with zstd. Restore extracts with rargz when present, else tar.
# Sourced by node.sh. Globals expected from config.sh/rpc.sh/ui.sh.

# Only these members are ever packed; everything else (peers, config, ban
# lists, pool settings) is excluded so no PII / identity ever leaves the box.
SNAPSHOT_INCLUDE=(balances bltx_store topo.map)
SNAPSHOT_EXCLUDE=(peers.json trusted_peers.json ban_list.json config.json config_pool.json)

# Directory that holds the chain state: data_dir/mainnet (derod always
# appends the network subdir).  The flat layout (chain state directly in base)
# only applies when the external unit's data dir already IS the mainnet store
# (base/topo.map present, no nested mainnet/ subdir).
snapshot_chain_dir() {
    local base ext=""
    if external_installed 2>/dev/null; then
        base="$(external_data_dir 2>/dev/null)"
        [ -n "$base" ] || base="$DATA_DIR_REAL"
        ext=true
    else
        base="$DATA_DIR_REAL"
    fi
    if [ -d "$base/mainnet" ] && [ -e "$base/mainnet/topo.map" ]; then
        echo "$base/mainnet"
    elif [ -n "$ext" ] && [ -e "$base/topo.map" ] && [ ! -d "$base/mainnet" ]; then
        echo "$base"
    else
        echo "$base/mainnet"
    fi
}

# Current chain height from the live daemon (only meaningful with --keep-running).
snapshot_height() {
    if node_running 2>/dev/null; then
        get_node_info 2>/dev/null | jq -r '.height // empty' 2>/dev/null
    fi
}

# PIDs of actual derod daemon processes. We match the executable name (comm)
# rather than the full cmdline, because cmdline matches falsely hit unrelated
# processes whose paths contain "deronode". Linux uses /proc/$pid/comm (no
# truncation); other platforms use ps (BSD comm is truncated to 16 chars, but
# every derod binary starts with "derod").
snapshot_derod_pids() {
    local pid comm
    if [ "$OS" = "linux" ]; then
        while IFS= read -r pid; do
            comm="$(cat "/proc/$pid/comm" 2>/dev/null)"
            case "$comm" in
                derod*) echo "$pid" ;;
            esac
        done < <(pgrep -f '[d]erod' 2>/dev/null)
    else
        ps -axo pid=,comm= 2>/dev/null | while read -r pid comm; do
            case "$comm" in
                derod*) echo "$pid" ;;
            esac
        done
    fi
}

# True when a derod is running against THIS data dir: RPC live on the
# configured bind, our pid file present, or a derod process whose cmdline
# references our data-dir.
snapshot_running_on_data_dir() {
    if node_running 2>/dev/null; then return 0; fi
    [ -f "$INSTALL_DIR/derod.pid" ] && return 0
    local pid
    if [ "$OS" = "linux" ]; then
        while IFS= read -r pid; do
            if grep -qa -- "--data-dir=$DATA_DIR_REAL" "/proc/$pid/cmdline" 2>/dev/null; then return 0; fi
        done < <(snapshot_derod_pids)
    else
        while IFS= read -r pid; do
            if ps -o args= -p "$pid" 2>/dev/null | grep -q -- "--data-dir=$DATA_DIR_REAL"; then return 0; fi
        done < <(snapshot_derod_pids)
    fi
    return 1
}

# True when ANY derod daemon is running. Restore replaces chain state, so
# refuse broadly rather than only when it collides with our data-dir.
snapshot_any_derod_running() {
    if node_running 2>/dev/null; then return 0; fi
    [ -f "$INSTALL_DIR/derod.pid" ] && return 0
    [ -n "$(snapshot_derod_pids)" ]
}

# Approximate raw size (bytes) of the included members.
snapshot_size_raw() {
    local dir item total=0 sz
    dir="$(snapshot_chain_dir)"
    for item in "${SNAPSHOT_INCLUDE[@]}"; do
        if [ -e "$dir/$item" ]; then
            sz="$(du -sk "$dir/$item" 2>/dev/null | awk '{print $1}')"
            total=$(( total + ${sz:-0} * 1024 ))
        fi
    done
    echo "$total"
}

snapshot_sha256_hex() {  # <file> -> hex
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# snapshot_verify_sha256 <archivebasename> <dir> — checks "<name>.sha256" next
# to the archive (sha256sum -c format).
snapshot_verify_sha256() {
    local name="$1" dir="$2" tool
    if command -v sha256sum >/dev/null 2>&1; then tool=sha256sum; else tool="shasum -a 256"; fi
    ( cd "$dir" && $tool -c "$name.sha256" >/dev/null 2>&1 )
}

# True when stdin is an interactive terminal (prompts allowed). Separated so
# the smoke suite can force the interactive branch.
snapshot_stdin_tty() {
    [ -t 0 ]
}

snapshot_pack() {
    local chain_dir out_dir level ts height name raw_size exc e out sha
    chain_dir="$(snapshot_chain_dir)"
    out_dir="${SNAPSHOT_DIR:-${SNAPSHOT_DIR_REAL:-$INSTALL_DIR/snapshots}}"
    level="${CFG_SNAPSHOT_LEVEL:-10}"
    [ "${SNAPSHOT_MAX_RATIO:-false}" = "true" ] && level=19

    if [ ! -d "$chain_dir" ]; then
        echo "${C_ERR}[x] chain data not found at $chain_dir (nothing to snapshot)${C_RESET}" >&2
        return 1
    fi
    local missing=""
    for item in "${SNAPSHOT_INCLUDE[@]}"; do
        [ -e "$chain_dir/$item" ] || missing="$missing $item"
    done
    if [ -n "$missing" ]; then
        echo "${C_ERR}[x] chain dir incomplete at $chain_dir — missing:${missing}${C_RESET}" >&2
        return 1
    fi
    if snapshot_running_on_data_dir && [ "${SNAPSHOT_KEEP_RUNNING:-false}" != "true" ]; then
        echo "${C_ERR}[x] derod is running on $DATA_DIR_REAL — stop it (deronode stop) or pass --keep-running for a live snapshot.${C_RESET}" >&2
        return 1
    fi

    ts="$(date +%Y%m%d-%H%M)"
    height="$(snapshot_height)"
    name="dero-mainnet-$ts"
    [ -n "$height" ] && name="$name-h$height"
    name="$name.tar.zst"
    raw_size="$(snapshot_size_raw)"

    if [ "${DRY_RUN:-false}" = "true" ]; then
        echo "${C_INFO}[*] dry-run: would snapshot $chain_dir${C_RESET}"
        echo "    archive : $out_dir/$name"
        echo "    includes: ${SNAPSHOT_INCLUDE[*]}"
        echo "    excludes: ${SNAPSHOT_EXCLUDE[*]}"
        echo "    bytes_raw: $raw_size   zstd level: $level"
        return 0
    fi

    if ! command -v tar >/dev/null 2>&1; then
        echo "${C_ERR}[x] snapshot needs tar${C_RESET}" >&2
        return 1
    fi
    if ! command -v zstd >/dev/null 2>&1; then
        echo "${C_ERR}[x] snapshot needs the zstd CLI (brew install zstd / winget install zstandard)${C_RESET}" >&2
        return 1
    fi

    mkdir -p "$out_dir"
    out="$out_dir/$name"
    echo "${C_INFO}[*] snapshotting $chain_dir -> $out${C_RESET}"
    echo "    includes: ${SNAPSHOT_INCLUDE[*]}   excludes: ${SNAPSHOT_EXCLUDE[*]}"

    exc=()
    for e in "${SNAPSHOT_EXCLUDE[@]}"; do exc+=(--exclude="$e"); done

    local zstd_opts="-T0 -$level --long=27"
    if snapshot_stdin_tty 2>/dev/null; then
        zstd_opts="$zstd_opts --progress"
    else
        zstd_opts="$zstd_opts -q"
    fi

    local ok=false
    if tar "${exc[@]}" -C "$chain_dir" -cf - "${SNAPSHOT_INCLUDE[@]}" \
            | zstd $zstd_opts -o "$out.tmp"; then
        ok=true
    fi
    if $ok; then
        mv "$out.tmp" "$out"
    else
        rm -f "$out.tmp"
        echo "${C_ERR}[x] snapshot failed — see the tar/zstd error above${C_RESET}" >&2
        return 1
    fi

    ( cd "$out_dir" && printf '%s  %s\n' \
        "$(snapshot_sha256_hex "$(basename "$out")")" \
        "$(basename "$out")" > "$out.sha256" )

    sha="$(awk '{print $1}' "$out.sha256")"
    local h th info
    h=null; th=null
    if [ -n "$height" ] && node_running 2>/dev/null; then
        info="$(get_node_info)"
        h="$(echo "$info" | jq -r '.height // 0')"
        th="$(echo "$info" | jq -r '.topoheight // 0')"
    fi
    jq -n \
        --arg artifact "$name" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson height "$h" \
        --argjson topoheight "$th" \
        --arg sha "$sha" \
        --argjson bytes_raw "$raw_size" \
        --argjson bytes_zst "$(wc -c < "$out")" \
        --argjson zstd_level "$level" \
        --argjson includes "$(printf '%s\n' "${SNAPSHOT_INCLUDE[@]}" | jq -Rrs 'split("\n")|map(select(length>0))')" \
        --argjson excludes "$(printf '%s\n' "${SNAPSHOT_EXCLUDE[@]}" | jq -Rrs 'split("\n")|map(select(length>0))')" \
        '{artifact:$artifact, created:$created, height:$height, topoheight:$topoheight,
          sha256:$sha, bytes_raw:$bytes_raw, bytes_zst:$bytes_zst, zstd_level:$zstd_level,
          includes:$includes, excludes:$excludes}' > "$out.manifest.json"

    echo "${C_OK}[*] done: $name${C_RESET}"
    echo "    sha256: $sha"
    echo "    archive: $out"
    return 0
}

# Newest dero-mainnet-*.tar.zst in the snapshot dir, by mtime (newest name as a
# tie-break/fallback). Echoes the path or nothing when no snapshot exists.
snapshot_latest_archive() {
    local dir="${SNAPSHOT_DIR:-${SNAPSHOT_DIR_REAL:-$INSTALL_DIR/snapshots}}"
    [ -d "$dir" ] || return 1
    ls -1t "$dir"/dero-mainnet-*.tar.zst 2>/dev/null | head -1
}

# Human-readable timestamp for an archive, for the "a snapshot already exists"
# prompt. Prefers the timestamp baked into the name
# (dero-mainnet-YYYYMMDD-HHMM[-h<height>].tar.zst), falls back to the file
# mtime (date -r works on both GNU and BSD), then 'unknown'.
snapshot_archive_stamp() {
    local f="$1" stamp
    stamp="$(basename "$f" | sed -n 's/^dero-mainnet-\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)-\([0-9]\{2\}\)\([0-9]\{2\}\).*/\1-\2-\3 \4:\5/p')"
    if [ -n "$stamp" ]; then
        echo "$stamp"
    elif date -r "$f" '+%Y-%m-%d %H:%M' >/dev/null 2>&1; then
        date -r "$f" '+%Y-%m-%d %H:%M'
    else
        echo "unknown"
    fi
}

snapshot_restore() {
    local archive="$SNAPSHOT_FROM" chain_dir mani_h bak ts tmp ok item
    if [ -z "$archive" ]; then
        archive="$(snapshot_latest_archive)"
        if [ -z "$archive" ]; then
            echo "${C_ERR}[x] no snapshot found in ${SNAPSHOT_DIR:-${SNAPSHOT_DIR_REAL:-$INSTALL_DIR/snapshots}} — pass --from=<archive>${C_RESET}" >&2
            return 1
        fi
        echo "${C_INFO}[*] using latest snapshot: $(basename "$archive")${C_RESET}"
    fi
    if [ ! -f "$archive" ]; then
        echo "${C_ERR}[x] archive not found: $archive${C_RESET}" >&2
        return 1
    fi
    chain_dir="$(snapshot_chain_dir)"

    if snapshot_any_derod_running; then
        echo "${C_ERR}[x] derod is running — restore replaces chain state. Stop it first (deronode stop).${C_RESET}" >&2
        return 1
    fi

    if [ -f "$archive.sha256" ]; then
        if snapshot_verify_sha256 "$(basename "$archive")" "$(dirname "$archive")"; then
            echo "${C_OK}[*] sha256 verified against $(basename "$archive").sha256${C_RESET}"
        else
            echo "${C_ERR}[x] sha256 verification failed for $archive${C_RESET}" >&2
            return 1
        fi
    else
        echo "${C_WARN}[!] no .sha256 next to archive — skipping verification${C_RESET}" >&2
        if [ "${SNAPSHOT_YES:-false}" != "true" ] && [ "$(yesno "Continue without verification?" n)" != "y" ]; then
            return 1
        fi
    fi

    mani_h=""
    if [ -f "$archive.manifest.json" ]; then
        mani_h="$(jq -r '.height // empty' "$archive.manifest.json")"
        echo "    manifest: height ${mani_h:-unknown}"
    fi

    if [ "${SNAPSHOT_YES:-false}" != "true" ]; then
        echo "    target : $chain_dir"
        echo "    archive: $archive"
        if [ "$(yesno "Restore $archive into $chain_dir? (current chain moved to .bak)" n)" != "y" ]; then
            echo "${C_MUTE}[*] aborted${C_RESET}"
            return 1
        fi
    fi

    ts="$(date +%Y%m%d-%H%M%S)"
    bak=""
    if [ -d "$chain_dir" ]; then
        bak="$chain_dir.bak-$ts"
        mv "$chain_dir" "$bak"
        echo "${C_MUTE}[*] moved $chain_dir -> $bak${C_RESET}"
    fi
    mkdir -p "$chain_dir"

    tmp="$(mktemp -d)"
    ok=0
    if command -v rargz >/dev/null 2>&1; then
        echo "${C_MUTE}[*] extracting with rargz...${C_RESET}"
        rargz --extract -o "$tmp" "$archive" >/dev/null 2>&1 && ok=1 || ok=0
    else
        echo "${C_MUTE}[*] extracting with tar --zstd...${C_RESET}"
        tar --zstd -xf "$archive" -C "$tmp" >/dev/null 2>&1 && ok=1 || ok=0
    fi
    if [ "$ok" -eq 0 ]; then
        rm -rf "$tmp"
        echo "${C_ERR}[x] extraction failed; restoring previous chain${C_RESET}" >&2
        [ -n "$bak" ] && mv "$bak" "$chain_dir"
        return 1
    fi
    for item in "${SNAPSHOT_INCLUDE[@]}"; do
        if [ ! -e "$tmp/$item" ]; then
            rm -rf "$tmp"
            echo "${C_ERR}[x] archive missing $item; restoring previous chain${C_RESET}" >&2
            [ -n "$bak" ] && mv "$bak" "$chain_dir"
            return 1
        fi
    done
    mv "$tmp"/* "$chain_dir"/ 2>/dev/null || mv "$tmp"/.[!.]* "$chain_dir"/ 2>/dev/null || true
    rmdir "$tmp" 2>/dev/null || true

    if [ -f "$chain_dir/topo.map" ]; then
        local sz
        sz="$(wc -c < "$chain_dir/topo.map" 2>/dev/null)"
        echo "${C_OK}[*] restored into $chain_dir (topo.map: ${sz:-?} bytes)${C_RESET}"
    else
        rm -rf "$chain_dir"
        echo "${C_ERR}[x] archive missing topo.map after extract; restoring previous chain${C_RESET}" >&2
        [ -n "$bak" ] && mv "$bak" "$chain_dir"
        return 1
    fi
    if [ -n "$bak" ]; then
        echo "${C_MUTE}    keep $bak until the node reaches height >= ${mani_h:-?}, then delete it manually.${C_RESET}"
    fi
    return 0
}
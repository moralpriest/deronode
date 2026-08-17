#!/usr/bin/env bash
# lib/build.sh — compile derod from the DEROFDN/derohe community-dev branch
# with the local Go toolchain and lift the binary into bin/derod/derod, as an
# alternative to the release download. Sourced by node.sh.

DEV_REPO="https://github.com/DEROFDN/derohe.git"
DEV_BRANCH="community-dev"
# The source checkout lives under bin/ (gitignored); the built binary goes
# through the same bin/derod/derod path the release download uses.
SRC_DIR="$BIN_DIR/src/derohe"
DEV_SHA=""

# True when the Go toolchain is on PATH.
have_go() {
    command -v go >/dev/null 2>&1
}

# Resolve the latest community-dev commit sha (network). Sets DEV_SHA.
# Returns 1 when the branch cannot be resolved (offline / repo moved).
resolve_dev_sha() {
    DEV_SHA=""
    local sha
    sha="$(git ls-remote "$DEV_REPO" "refs/heads/$DEV_BRANCH" 2>/dev/null | awk '{print $1}' | head -1)"
    [ -n "$sha" ] || { echo "${C_ERR}[x] Could not resolve the latest $DEV_BRANCH commit for $DEV_REPO${C_RESET}" >&2; return 1; }
    DEV_SHA="$sha"
}

# True when the installed binary came from a source build (community-dev),
# not a release download. start/status keep such a build until the user
# explicitly runs `update` (back to a release) or `build` again.
is_source_build() {
    [ -f "$BIN_DIR/derod/.asset" ] && [ "$(cat "$BIN_DIR/derod/.asset" 2>/dev/null)" = "community-dev" ]
}

# Clone (shallow, branch) or fast-forward the community-dev checkout in
# SRC_DIR. Sets DEV_SHA to the checked-out short sha.
sync_dev_source() {
    if [ -d "$SRC_DIR/.git" ]; then
        echo "${C_INFO}[*] updating $DEV_BRANCH checkout at $SRC_DIR${C_RESET}" >&2
        git -C "$SRC_DIR" fetch origin "$DEV_BRANCH" >/dev/null 2>&1 || { echo "${C_ERR}[x] git fetch failed — offline?${C_RESET}" >&2; return 1; }
        git -C "$SRC_DIR" reset --hard "origin/$DEV_BRANCH" >/dev/null 2>&1 || { echo "${C_ERR}[x] git reset failed${C_RESET}" >&2; return 1; }
    else
        echo "${C_INFO}[*] cloning $DEV_REPO ($DEV_BRANCH, shallow)...${C_RESET}" >&2
        mkdir -p "$(dirname "$SRC_DIR")"
        git clone --depth 1 --branch "$DEV_BRANCH" "$DEV_REPO" "$SRC_DIR" >/dev/null 2>&1 || { echo "${C_ERR}[x] git clone failed — offline?${C_RESET}" >&2; return 1; }
    fi
    DEV_SHA="$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    [ -n "$DEV_SHA" ] || { echo "${C_ERR}[x] could not read the $DEV_BRANCH revision${C_RESET}" >&2; return 1; }
}

# Compile derod from the checkout and lift it into bin/derod/derod, marking
# the install as a source build (is_source_build) so it is kept until an
# explicit `update`.
build_derod_from_source() {
    have_go || { echo "${C_ERR}[x] Go toolchain not found — install Go 1.17+ (https://go.dev/dl/) to build derod from source${C_RESET}" >&2; return 1; }
    sync_dev_source || return 1
    echo "${C_INFO}[*] building derod from $DEV_BRANCH@$DEV_SHA (go build ./cmd/derod)...${C_RESET}" >&2
    ( cd "$SRC_DIR" && go build -o derod ./cmd/derod ) || { echo "${C_ERR}[x] go build failed — see the output above${C_RESET}" >&2; return 1; }
    local found
    found="$(find_derod_in "$SRC_DIR")"
    [ -n "$found" ] || { echo "${C_ERR}[x] derod binary not found after build${C_RESET}" >&2; return 1; }

    # Same executable-magic sanity check the release download uses.
    local magic ok=1
    magic="$(head -c 4 "$found" | od -An -tx1 | tr -d ' \n')"
    case "$magic" in
        7f454c46|cffaedfe|cafebabe|feedface|feedfacf|4d5a) ok=0 ;;
    esac
    if [ "$ok" -ne 0 ]; then
        echo "${C_ERR}[x] Built derod failed the executable magic check${C_RESET}" >&2
        return 1
    fi

    mkdir -p "$BIN_DIR/derod"
    cp -f "$found" "$BIN_DIR/derod/derod"
    chmod +x "$BIN_DIR/derod/derod"
    printf 'community-dev@%s\n' "$DEV_SHA" > "$BIN_DIR/derod/.tag"
    printf 'community-dev\n' > "$BIN_DIR/derod/.asset"
    date +%s > "$BIN_DIR/derod/.tagtime"
    echo "${C_OK}[*] derod built from community-dev@$DEV_SHA: $BIN_DIR/derod/derod${C_RESET}" >&2
}

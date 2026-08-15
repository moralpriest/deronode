#!/usr/bin/env bash
# deronode bash smoke tests — non-interactive verification of the bash path.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

PASS=0
FAIL=0
pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== deronode bash smoke tests ==="
echo ""

# 1. Prerequisites
echo "1. Prerequisites:"
if command -v jq >/dev/null 2>&1; then pass "jq available"; else fail "jq available"; fi
if command -v curl >/dev/null 2>&1; then pass "curl available"; else fail "curl available"; fi

# 2. Catalog validation
echo ""
echo "2. Catalog validation:"
if jq -e . catalog.json >/dev/null 2>&1; then pass "catalog.json parses as valid JSON"; else fail "catalog.json parses as valid JSON"; fi
if [ "$(jq -r '.repo' catalog.json)" = "DEROFDN/derohe" ]; then pass "catalog points at DEROFDN/derohe"; else fail "catalog points at DEROFDN/derohe"; fi
missing=0
while IFS= read -r line; do
    os=${line%% *}; rest=${line#* }; arch=${rest%% *}; archive=${rest#* }
    if ! jq -e --arg os "$os" --arg arch "$arch" '.assets[] | select(.os == $os and (.arch == "*" or .arch == $arch))' catalog.json >/dev/null 2>&1; then
        echo "    missing asset for $os/$arch"
        missing=1
    fi
    if [ -z "$archive" ]; then
        echo "    empty archive for $os/$arch"
        missing=1
    fi
done <<'EOF'
linux amd64
linux aarch64
darwin any
windows amd64
freebsd amd64
EOF
if [ "$missing" -eq 0 ]; then pass "catalog covers linux/darwin/windows/freebsd"; else fail "catalog covers linux/darwin/windows/freebsd"; fi

# 3. config.example.json valid with all 22 keys
echo ""
echo "3. Config schema:"
if jq -e . config.example.json >/dev/null 2>&1; then pass "config.example.json parses"; else fail "config.example.json parses"; fi
need_keys='["integrator_address","sync_profile","fastsync","prune_history","node_tag","getwork_bind","data_dir","log_dir","rpc_bind","p2p_bind","min_peers","max_peers","socks_proxy","add_priority_node","add_exclusive_node","clog_level","flog_level","testnet","debug","time_is_in_sync","sync_node","extra_args","snapshot_dir","snapshot_level"]'
if jq -e --argjson want "$need_keys" '($want - (keys)) | length == 0' config.example.json >/dev/null 2>&1; then
    pass "config.example.json has all 24 keys"
else
    fail "config.example.json has all 24 keys"
fi

# 4. Installers expose safe PowerShell prerequisite handling.
echo ""
echo "4. Installer safety:"
if grep -q 'install_pwsh_if_missing' install.sh && grep -q 'DERONODE_SKIP_PWSH' install.sh && grep -q 'DERONODE_AUTO_INSTALL_PWSH' install.sh && grep -q '/dev/tty' install.sh && grep -q 'packages.microsoft.com/config/fedora' install.sh && grep -q 'brew install --cask powershell' install.sh; then pass "bash installer handles missing pwsh safely"; else fail "bash installer handles missing pwsh safely"; fi
if grep -qi 'not packaged for Termux' install.sh && grep -q 'com.termux' install.sh && ! grep -q 'pkg install.*powershell' install.sh; then pass "bash installer never attempts pwsh install on Termux"; else fail "bash installer never attempts pwsh install on Termux"; fi
if grep -q 'reset --hard' install.sh && grep -q 'pull --ff-only' install.sh; then pass "installer recovers from diverged clone on update"; else fail "installer recovers from diverged clone on update"; fi
if grep -q 'Install-PwshIfMissing' install.ps1 && grep -q 'Microsoft.PowerShell' install.ps1; then pass "PowerShell installer handles missing pwsh"; else fail "PowerShell installer handles missing pwsh"; fi

# 5. Version + help through both runners
echo ""
echo "5. CLI basics:"
ver=$(./deronode --version 2>&1 | head -1)
if [[ "$ver" =~ ^deronode\ [0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pass "launcher --version prints '$ver'"
else
    fail "launcher --version prints '$ver'"
fi
bash_ver=$(bash ./node.sh --version 2>&1 | head -1)
if [[ "$bash_ver" =~ ^deronode\ [0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pass "bash runner --version prints '$bash_ver'"
else
    fail "bash runner --version prints '$bash_ver'"
fi
bash_help=$(bash ./node.sh --help 2>&1)
for token in "--integrator-address" "--sync-profile" "--getwork-bind" "--data-dir" "--log-dir" "--rpc-bind" "--p2p-bind" "--prune-history" "--add-priority-node" "--add-exclusive-node" "--socks-proxy" "--clog-level" "--flog-level" "--testnet" "--time-is-in-sync" "--extra-arg" "--config=" "derod only" "snapshot" "restore" "--level" "--max-ratio" "--out" "--keep-running" "--from" "--yes"; do
    if [[ "$bash_help" != *"$token"* ]]; then fail "help documents '$token'"; else pass "help documents '$token'"; fi
done

# 6. CLI parse (both forms) — extracts the REAL parse_cli_args + set_sync_profile.
echo ""
echo "6. Flag parsing:"
INSTALL_DIR="$PROJECT_DIR"
LIB_DIR="$PROJECT_DIR/lib"
CONFIG_FILE="$PROJECT_DIR/config.json"
CATALOG_FILE="$PROJECT_DIR/catalog.json"
BINARY_PATH="$PROJECT_DIR/bin/derod/derod"
source "$LIB_DIR/platform.sh"
source "$LIB_DIR/ui.sh"
source "$LIB_DIR/config.sh"
detect_platform
eval "$(sed -n '/^parse_cli_args()/,/^}/p' node.sh)"
eval "$(sed -n '/^set_sync_profile()/,/^}/p' node.sh)"
cli_reset() {
    CFG_INTEGRATOR_ADDRESS=""; CFG_SYNC_PROFILE="pruned"; CFG_FASTSYNC=false
    CFG_PRUNE_HISTORY=100000; CFG_NODE_TAG=""; CFG_GETWORK_BIND="127.0.0.1:10100"
    CFG_DATA_DIR=""; CFG_LOG_DIR=""; CFG_RPC_BIND="127.0.0.1:10102"; CFG_P2P_BIND="0.0.0.0:10101"
    CFG_MIN_PEERS=""; CFG_MAX_PEERS=""; CFG_SOCKS_PROXY=""
    CFG_ADD_PRIORITY_NODE=(); CFG_ADD_EXCLUSIVE_NODE=(); CFG_CLOG_LEVEL=""; CFG_FLOG_LEVEL=""
    CFG_TESTNET=false; CFG_DEBUG=false; CFG_TIME_IS_IN_SYNC=false; CFG_SYNC_NODE=false
    CFG_EXTRA_ARGS=(); DATA_DIR_REAL=""; LOG_DIR_REAL=""; CONFIG_FILE="$PROJECT_DIR/config.json"
    ACTION=""; AS_SERVICE=false; DRY_RUN=false
}
cli_reset; parse_cli_args --getwork-bind 0.0.0.0:10100
if [ "$CFG_GETWORK_BIND" = "0.0.0.0:10100" ]; then pass "--getwork-bind 0.0.0.0:10100 (space)"; else fail "--getwork-bind (space) (got '$CFG_GETWORK_BIND')"; fi
cli_reset; parse_cli_args --prune-history=50000
if [ "$CFG_PRUNE_HISTORY" = "50000" ]; then pass "--prune-history=50000 (equals)"; else fail "--prune-history=50000 (got '$CFG_PRUNE_HISTORY')"; fi
cli_reset; parse_cli_args --data-dir /mnt/ssd/dero --log-dir /mnt/ssd/logs
if [ "$DATA_DIR_REAL" = "/mnt/ssd/dero" ] && [ "$LOG_DIR_REAL" = "/mnt/ssd/logs" ]; then pass "--data-dir/--log-dir (space) resolve paths"; else fail "--data-dir/--log-dir (data='$DATA_DIR_REAL' log='$LOG_DIR_REAL')"; fi
cli_reset; parse_cli_args --sync-profile full
if [ "$CFG_FASTSYNC" = "false" ] && [ -z "$CFG_PRUNE_HISTORY" ]; then pass "--sync-profile full disables fastsync/prune"; else fail "--sync-profile full (fast=$CFG_FASTSYNC prune='$CFG_PRUNE_HISTORY')"; fi
cli_reset; parse_cli_args --add-priority-node a:1 --add-priority-node b:2
if [ "${CFG_ADD_PRIORITY_NODE[0]}" = "a:1" ] && [ "${CFG_ADD_PRIORITY_NODE[1]}" = "b:2" ]; then pass "--add-priority-node repeatable"; else fail "--add-priority-node repeatable"; fi
cli_reset; parse_cli_args --extra-arg "--rpc-public" --extra-arg "--tor-port=9051"
if [ "${CFG_EXTRA_ARGS[0]}" = "--rpc-public" ] && [ "${CFG_EXTRA_ARGS[1]}" = "--tor-port=9051" ]; then pass "--extra-arg passthrough"; else fail "--extra-arg passthrough"; fi
cli_reset; parse_cli_args --config /tmp/custom.json
if [ "$CONFIG_FILE" = "/tmp/custom.json" ]; then pass "--config overrides config path"; else fail "--config (got '$CONFIG_FILE')"; fi

# 7. argv builder across sync profiles + testnet + passthrough
echo ""
echo "7. derod argv builder:"
argv_str() { local IFS=' '; echo "${DEROD_ARGV[*]}"; }
cli_reset; set_sync_profile pruned; resolve_paths; build_derod_argv
av=$(argv_str)
if [[ "$av" == *--fastsync* ]] && [[ "$av" == *--prune-history=100000* ]] && [[ "$av" == *--data-dir=* ]] && [[ "$av" == *--log-dir=* ]] && [[ "$av" == *--rpc-bind=127.0.0.1:10102* ]] && [[ "$av" == *--p2p-bind=0.0.0.0:10101* ]] && [[ "$av" == *--getwork-bind=127.0.0.1:10100* ]]; then
    pass "pruned argv has fastsync/prune/paths/ports"
else
    fail "pruned argv ($av)"
fi
cli_reset; set_sync_profile full; resolve_paths; build_derod_argv
av=$(argv_str)
if [[ "$av" != *--fastsync* ]] && [[ "$av" != *--prune-history* ]]; then pass "full argv omits fastsync/prune"; else fail "full argv omits fastsync/prune ($av)"; fi
cli_reset; set_sync_profile pruned; CFG_TESTNET=true; resolve_paths; apply_testnet_defaults; build_derod_argv
av=$(argv_str)
if [[ "$av" == *--testnet* ]] && [[ "$av" == *--rpc-bind=127.0.0.1:40402* ]] && [[ "$av" == *--p2p-bind=0.0.0.0:40401* ]] && [[ "$av" == *--getwork-bind=127.0.0.1:40400* ]]; then
    pass "testnet argv swaps default ports"
else
    fail "testnet argv ($av)"
fi
cli_reset; set_sync_profile none; CFG_INTEGRATOR_ADDRESS="dero1qy0deadbeef"; CFG_NODE_TAG="my-node"; CFG_MIN_PEERS=8; CFG_MAX_PEERS=64; CFG_CLOG_LEVEL=2; CFG_FLOG_LEVEL=1; CFG_EXTRA_ARGS=("--rpc-public"); resolve_paths; build_derod_argv
av=$(argv_str)
if [[ "$av" == *--integrator-address=dero1qy0deadbeef* ]] && [[ "$av" == *--node-tag=my-node* ]] && [[ "$av" == *--min-peers=8* ]] && [[ "$av" == *--max-peers=64* ]] && [[ "$av" == *--clog-level=2* ]] && [[ "$av" == *--flog-level=1* ]] && [[ "$av" == *--rpc-public* ]]; then
    pass "none argv honors integrator/tag/peers/logs/extra"
else
    fail "none argv ($av)"
fi

# 8. Checksum parser (3 formats)
echo ""
echo "8. Checksum parsing:"
eval "$(sed -n '/^verify_checksum()/,/^}/p' lib/download.sh)"
tmp_cs=$(mktemp -d)
fake=$(mktemp "$tmp_cs/archive.XXXXXX")
fake=$(mktemp "$tmp_cs/archive.XXXXXX")
printf 'x' > "$fake"
realhex=$(sha256sum "$fake" | awk '{print $1}')
printf '%s  dero_linux_amd64.tar.gz\n' "$realhex" > "$tmp_cs/cs1"
printf 'sha256:%s  dero_linux_amd64.tar.gz\n' "$realhex" > "$tmp_cs/cs2"
printf 'dero_linux_amd64.tar.gz  %s\n' "$realhex" > "$tmp_cs/cs3"
realhex512=$(sha512sum "$fake" | awk '{print $1}')
printf '%s  dero_linux_amd64.tar.gz\n' "$realhex512" > "$tmp_cs/cs4"
if (set +e; verify_checksum "$fake" "$tmp_cs/cs1" "dero_linux_amd64.tar.gz"); then pass "checksum: 'hex  file' recognized"; else fail "checksum: 'hex  file' recognized"; fi
if (set +e; verify_checksum "$fake" "$tmp_cs/cs2" "dero_linux_amd64.tar.gz"); then pass "checksum: 'sha256:hex  file' recognized"; else fail "checksum: 'sha256:hex  file' recognized"; fi
if (set +e; verify_checksum "$fake" "$tmp_cs/cs3" "dero_linux_amd64.tar.gz"); then pass "checksum: 'file  hex' recognized"; else fail "checksum: 'file  hex' recognized"; fi
if (set +e; verify_checksum "$fake" "$tmp_cs/cs4" "dero_linux_amd64.tar.gz"); then pass "checksum: 128-char sha512 (DEROFDN format) recognized"; else fail "checksum: 128-char sha512 (DEROFDN format) recognized"; fi
rm -rf "$tmp_cs"
unset -f verify_checksum

# 9. resolve_release asset selection (network-stubbed, real catalog)
echo ""
echo "9. Release resolution:"
if grep -q 'json_rpc' "$PROJECT_DIR/lib/rpc.sh"; then pass "rpc_call targets /json_rpc"; else fail "rpc_call targets /json_rpc"; fi
eval "$(sed -n '/^catalog_os()/,/^}/p' lib/platform.sh)"
eval "$(sed -n '/^catalog_arch()/,/^}/p' lib/platform.sh)"
eval "$(sed -n '/^resolve_release()/,/^}/p' lib/download.sh)"
DERONODE_VERSION="1.0.0"
GH_DL="https://github.com/DEROFDN/derohe/releases/download"
REPO="DEROFDN/derohe"
# Stub curl: fake the GitHub releases/latest redirect so this test needs no network.
stub_curl() {
    if [[ "$*" == *releases/latest* ]]; then printf 'HTTP/2 302\r\nlocation: https://github.com/DEROFDN/derohe/releases/tag/Release152\r\n\r\n'; return 0; fi
    command curl "$@"
}
curl() { stub_curl "$@"; }
if resolve_release; then
    pass "resolve_release picks an asset for $OS/$ARCH"
    case "$OS/$ARCH" in
        linux/amd64)  [ "$LAST_ASSET" = "dero_linux_amd64.tar.gz" ] && pass "linux/amd64 -> $LAST_ASSET" || fail "linux/amd64 archive ($LAST_ASSET)" ;;
        linux/aarch64) [ "$LAST_ASSET" = "dero_linux_arm64.tar.gz" ] && pass "linux/aarch64 -> $LAST_ASSET" || fail "linux/aarch64 archive ($LAST_ASSET)" ;;
        darwin/*)     [ "$LAST_ASSET" = "dero_darwin_universal.tar.gz" ] && pass "darwin -> $LAST_ASSET" || fail "darwin archive ($LAST_ASSET)" ;;
        windows/*)    [ "$LAST_ASSET" = "dero_windows_amd64.zip" ] && pass "windows -> $LAST_ASSET" || fail "windows archive ($LAST_ASSET)" ;;
        freebsd/*)    [ "$LAST_ASSET" = "dero_freebsd_amd64.tar.gz" ] && pass "freebsd -> $LAST_ASSET" || fail "freebsd archive ($LAST_ASSET)" ;;
        *)            pass "asset resolved ($LAST_ASSET)" ;;
    esac
else
    fail "resolve_release picks an asset for $OS/$ARCH"
fi
unset -f resolve_release

# 10. Dry-run is offline (no download, no config, no dirs created)
echo ""
echo "10. Dry-run is offline:"
DRYCFG="$PROJECT_DIR/.dry-test.json"
rm -f "$DRYCFG"; rm -rf "$PROJECT_DIR/bin" "$PROJECT_DIR/drydata"
out=$(bash ./node.sh --config="$DRYCFG" --dry-run --sync-profile=pruned \
    --integrator-address=dero1qyshrhaf0cev402lqw2g2slqf2v3r2rjq2xh03xgd852cjhrgdyqcqq0letdh \
    --data-dir="$PROJECT_DIR/drydata" --log-dir="$PROJECT_DIR/drylogs" 2>&1)
rc=$?
[ $rc -eq 0 ] && pass "--dry-run exits 0" || fail "--dry-run exits 0 (rc=$rc)"
echo "$out" | grep -q -- '--prune-history=100000' && pass "pruned profile in argv" || fail "pruned profile in argv"
echo "$out" | grep -q -- "--data-dir=$PROJECT_DIR/drydata" && pass "data-dir override in argv" || fail "data-dir override in argv"
[ ! -d "$PROJECT_DIR/bin" ] && pass "no bin/ created" || fail "no bin/ created"
[ ! -d "$PROJECT_DIR/drydata" ] && pass "no data dir created" || fail "no data dir created"
[ ! -f "$DRYCFG" ] && pass "no config file written" || fail "no config file written"
rm -rf "$PROJECT_DIR/bin" "$PROJECT_DIR/drydata" "$PROJECT_DIR/drylogs"; rm -f "$DRYCFG"

# 11. Snapshot/restore offline fixture (no network, no real derod)
echo ""
echo "11. Snapshot/restore offline fixture:"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/ui.sh"
source "$LIB_DIR/rpc.sh"
source "$LIB_DIR/snapshot.sh"
SNAPFIX="$(mktemp -d)"
SNAPCHAIN="$SNAPFIX/chain"
mkdir -p "$SNAPCHAIN/balances/ab" "$SNAPCHAIN/bltx_store/b1"
printf 'blob' > "$SNAPCHAIN/balances/ab/x1"
printf 'blob2' > "$SNAPCHAIN/bltx_store/b1/y1"
printf 'topomapdata' > "$SNAPCHAIN/topo.map"
for decoy in peers.json trusted_peers.json ban_list.json config.json config_pool.json; do printf '{}' > "$SNAPCHAIN/$decoy"; done
DATA_DIR_REAL="$SNAPCHAIN"
CFG_RPC_BIND="127.0.0.1:39998"
CFG_SNAPSHOT_LEVEL=1
SNAPSHOT_DIR="$SNAPFIX/out"
SNAPSHOT_OUT=""
SNAPSHOT_MAX_RATIO=false
SNAPSHOT_KEEP_RUNNING=false
SNAPSHOT_YES=false
DRY_RUN=false
mkdir -p "$SNAPSHOT_DIR"
if snapshot_pack; then pass "snapshot_pack runs offline"; else fail "snapshot_pack runs offline"; fi
SNAPARCH="$(ls "$SNAPSHOT_DIR"/dero-mainnet-*.tar.zst 2>/dev/null | head -1)"
[ -n "$SNAPARCH" ] && pass "archive created" || fail "archive created"
[ -f "$SNAPARCH.sha256" ] && pass ".sha256 written" || fail ".sha256 written"
[ -f "$SNAPARCH.manifest.json" ] && pass ".manifest.json written" || fail ".manifest.json written"
decoy_bad=0
for decoy in peers.json trusted_peers.json ban_list.json config.json config_pool.json; do
    if tar -tf "$SNAPARCH" | grep -q -- "$decoy"; then decoy_bad=1; fail "archive excludes $decoy"; else pass "archive excludes $decoy"; fi
done
[ "$decoy_bad" -eq 0 ] && pass "no identity files in archive"
for item in balances bltx_store topo.map; do
    if tar -tf "$SNAPARCH" | grep -qE "^$item(/|$)"; then pass "archive includes $item"; else fail "archive includes $item"; fi
done
if ( cd "$SNAPSHOT_DIR" && sha256sum -c "$(basename "$SNAPARCH").sha256" >/dev/null 2>&1 ); then pass "archive sha256 verifies"; else fail "archive sha256 verifies"; fi
if jq -e '.height == null' "$SNAPARCH.manifest.json" >/dev/null 2>&1 \
    && jq -e --argjson inc '["balances","bltx_store","topo.map"]' '.includes == $inc' "$SNAPARCH.manifest.json" >/dev/null 2>&1; then
    pass "manifest is chain-facts-only"
else
    fail "manifest is chain-facts-only"
fi
if grep -qE '"hostname"|"node_tag"|"integrator"|"ip"|"user"|"host"' "$SNAPARCH.manifest.json"; then
    fail "manifest has no identity fields"
else
    pass "manifest has no identity fields"
fi
# dry-run writes nothing
rm -rf "$SNAPSHOT_DIR"; mkdir -p "$SNAPSHOT_DIR"
DRY_RUN=true
if snapshot_pack >/dev/null 2>&1; then pass "snapshot dry-run exits 0"; else fail "snapshot dry-run exits 0"; fi
DRY_RUN=false
[ -z "$(ls "$SNAPSHOT_DIR" 2>/dev/null)" ] && pass "snapshot dry-run writes nothing" || fail "snapshot dry-run writes nothing"
# running guard refuses; --keep-running overrides
touch "$PROJECT_DIR/derod.pid"
if snapshot_pack >/dev/null 2>&1; then fail "snapshot refuses while pidfile present"; else pass "snapshot refuses while pidfile present"; fi
SNAPSHOT_KEEP_RUNNING=true
if snapshot_pack >/dev/null 2>&1; then pass "snapshot --keep-running overrides guard"; else fail "snapshot --keep-running overrides guard"; fi
SNAPSHOT_KEEP_RUNNING=false
rm -f "$PROJECT_DIR/derod.pid"
# restore into a fresh dir (stub the broad "any derod" guard: the live node is up)
SNAPREST="$(mktemp -d)"
DATA_DIR_REAL="$SNAPREST"
SNAPSHOT_YES=true
SNAPSHOT_FROM="$SNAPARCH"
snapshot_any_derod_running() { return 1; }
if snapshot_restore >/dev/null 2>&1; then pass "restore runs offline"; else fail "restore runs offline"; fi
[ -f "$SNAPREST/balances/ab/x1" ] && [ -f "$SNAPREST/bltx_store/b1/y1" ] && [ -f "$SNAPREST/topo.map" ] && pass "restore reproduces includes" || fail "restore reproduces includes"
[ ! -e "$SNAPREST/peers.json" ] && [ ! -e "$SNAPREST/config.json" ] && pass "restore omits decoys" || fail "restore omits decoys"
[ -n "$(ls -d "$SNAPREST".bak-* 2>/dev/null | head -1)" ] && pass "restore keeps .bak" || fail "restore keeps .bak"
if grep -q 'tar --zstd' "$LIB_DIR/snapshot.sh" && grep -q 'rargz --extract' "$LIB_DIR/snapshot.sh"; then pass "restore falls back to tar, rargz optional"; else fail "restore falls back to tar, rargz optional"; fi
rm -rf "$SNAPFIX" "$SNAPREST" "$SNAPREST".bak-*
unset -f snapshot_pack snapshot_restore snapshot_chain_dir snapshot_height snapshot_derod_pids snapshot_running_on_data_dir snapshot_any_derod_running snapshot_size_raw snapshot_sha256_hex snapshot_verify_sha256

# 12. Live download (only with DERONODE_LIVE=1) — fetches, verifies, never starts.
# Isolated from the live node: --config points RPC at a dead port so node_running
# can't see it and update never tries service_stop/restart.
if [ "${DERONODE_LIVE:-0}" = "1" ]; then
    echo ""
    echo "12. Live download test:"
    LIVECFG="$PROJECT_DIR/.live-test.json"
    echo '{"rpc_bind":"127.0.0.1:39999"}' > "$LIVECFG"
    rm -rf "$PROJECT_DIR/bin"
    before_pids="$(pgrep -f 'derod-linux-amd64' | sort | tr '\n' ' ')"
    if out=$(bash ./node.sh --config="$LIVECFG" update 2>&1); then
        pass "update fetches release"
    else
        fail "update fetches release (network blocked?)"
        echo "$out" | tail -5
        rm -f "$LIVECFG"
        exit 1
    fi
    [ -x "$PROJECT_DIR/bin/derod/derod" ] && pass "derod binary installed + executable" || fail "derod binary installed + executable"
    [ -f "$PROJECT_DIR/bin/derod/.tag" ] && [ -s "$PROJECT_DIR/bin/derod/.tag" ] && pass ".tag records release" || fail ".tag records release"
    sz=$(stat -c%s "$PROJECT_DIR/bin/derod/derod" 2>/dev/null || echo 0)
    [ "$sz" -gt 1000000 ] && pass "binary size sane ($sz bytes)" || fail "binary size sane ($sz bytes)"
    magic=$(head -c4 "$PROJECT_DIR/bin/derod/derod" | od -An -tx1 | tr -d ' \n')
    [ "$magic" = "7f454c46" ] && pass "ELF magic 7f454c46" || fail "ELF magic (got $magic)"
    [ ! -f "$PROJECT_DIR/derod.pid" ] && pass "no pid file written" || fail "no pid file written"
    after_pids="$(pgrep -f 'derod-linux-amd64' | sort | tr '\n' ' ')"
    [ "$before_pids" = "$after_pids" ] && pass "live node pids unchanged" || fail "live node pids changed (before:[$before_pids] after:[$after_pids])"
    if out2=$(bash ./node.sh --config="$LIVECFG" update 2>&1) && echo "$out2" | grep -q "Already at latest"; then
        pass "second update is a cache hit"
    else
        fail "second update is a cache hit"
    fi
    if pwsh -NoProfile -File node.ps1 --config="$LIVECFG" update 2>&1 | grep -q "Already at latest"; then
        pass "ps update reuses bash cache"
    else
        fail "ps update reuses bash cache"
    fi
    if bash ./node.sh --config="$LIVECFG" status >/dev/null 2>&1; then
        pass "status runs with installed bin"
    else
        fail "status runs with installed bin"
    fi
    rm -f "$LIVECFG"
fi

echo ""
echo "=== results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
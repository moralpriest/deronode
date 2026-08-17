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
if grep -q 'DERONODE_VERSION="1.1.0"' node.sh && grep -q "DeronodeVersion = '1.1.0'" node.ps1; then
    pass "version is 1.1.0 in both runners"
else
    fail "version is 1.1.0 in both runners"
fi
if grep -q 'resync' lib/ui.sh && grep -q 'logs' lib/ui.sh && grep -q 'build' lib/ui.ps1 && grep -q 'resync' lib/ui.ps1; then
    pass "menu hint lists build/resync/logs (both UIs)"
else
    fail "menu hint lists build/resync/logs (both UIs)"
fi
bash_help=$(bash ./node.sh --help 2>&1)
for token in "--integrator-address" "--sync-profile" "--getwork-bind" "--data-dir" "--log-dir" "--rpc-bind" "--p2p-bind" "--prune-history" "--add-priority-node" "--add-exclusive-node" "--socks-proxy" "--clog-level" "--flog-level" "--testnet" "--time-is-in-sync" "--extra-arg" "--config=" "--source=" "derod only" "snapshot" "restore" "build" "community-dev" "--level" "--max-ratio" "--out" "--keep-running" "--from" "--yes"; do
    if [[ "$bash_help" != *"$token"* ]]; then fail "help documents '$token'"; else pass "help documents '$token'"; fi
done

# 6. CLI parse (both forms) — extracts the REAL parse_cli_args + set_sync_profile.
echo ""
echo "6. Flag parsing:"
INSTALL_DIR="$PROJECT_DIR"
LIB_DIR="$PROJECT_DIR/lib"
CONFIG_FILE="$PROJECT_DIR/config.json"
CATALOG_FILE="$PROJECT_DIR/catalog.json"
BINARY_NAME="derod"
BINARY_PATH="$PROJECT_DIR/bin/derod/$BINARY_NAME"
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
cli_reset; parse_cli_args --source=dev
if [ "$UPDATE_SOURCE" = "dev" ]; then pass "--source=dev sets update source"; else fail "--source=dev (got '$UPDATE_SOURCE')"; fi
cli_reset; parse_cli_args --source release
if [ "$UPDATE_SOURCE" = "release" ]; then pass "--source release (space)"; else fail "--source release (got '$UPDATE_SOURCE')"; fi
# null prune_history round-trips to "no prune" (absent keeps the 100000 default)
NULLCFG="$(mktemp)"
printf '%s\n' '{"fastsync":true,"prune_history":null}' > "$NULLCFG"
cli_reset; CONFIG_FILE="$NULLCFG"; load_config
if [ -z "$CFG_PRUNE_HISTORY" ] && [ "$CFG_FASTSYNC" = "true" ]; then pass "null prune_history means no prune flag"; else fail "null prune_history means no prune flag (prune='$CFG_PRUNE_HISTORY' fast=$CFG_FASTSYNC)"; fi
printf '%s\n' '{"fastsync":true}' > "$NULLCFG"
cli_reset; CONFIG_FILE="$NULLCFG"; load_config
if [ "$CFG_PRUNE_HISTORY" = "100000" ]; then pass "absent prune_history keeps the default"; else fail "absent prune_history keeps the default (got '$CFG_PRUNE_HISTORY')"; fi
rm -f "$NULLCFG"
# snapshot dir defaults next to the install (same tree as the derod binary),
# not to the old ~/Crypto/dero external-node path.
cli_reset; CFG_SNAPSHOT_DIR=""; resolve_paths
if [ "$SNAPSHOT_DIR_REAL" = "$INSTALL_DIR/snapshots" ]; then pass "snapshot dir defaults to <install>/snapshots"; else fail "snapshot dir defaults to <install>/snapshots (got '$SNAPSHOT_DIR_REAL')"; fi
CFG_SNAPSHOT_DIR="/custom/out"; resolve_paths
if [ "$SNAPSHOT_DIR_REAL" = "/custom/out" ]; then pass "explicit snapshot_dir wins"; else fail "explicit snapshot_dir wins (got '$SNAPSHOT_DIR_REAL')"; fi

# 7. argv builder across sync profiles + testnet + passthrough
echo ""
echo "7. derod argv builder:"
argv_str() { local IFS=' '; echo "${DEROD_ARGV[*]}"; }
# Chain that already has blocks (topo.map exists): --prune-history applies but
# --fastsync is bootstrap-only, so it is dropped with a warning.
PRUNECH="$(mktemp -d)"
mkdir -p "$PRUNECH/mainnet"
printf 'x' > "$PRUNECH/mainnet/topo.map"
cli_reset; set_sync_profile pruned; CFG_DATA_DIR="$PRUNECH"; resolve_paths
WARN2="$(mktemp)"
build_derod_argv 2>"$WARN2"
av=$(argv_str)
if [[ "$av" != *--fastsync* ]] && [[ "$av" == *--prune-history=100000* ]] && [[ "$av" == *--data-dir=* ]] && [[ "$av" == *--log-dir=* ]] && [[ "$av" == *--rpc-bind=127.0.0.1:10102* ]] && [[ "$av" == *--p2p-bind=0.0.0.0:10101* ]] && [[ "$av" == *--getwork-bind=127.0.0.1:10100* ]] && grep -q 'skipping --fastsync' "$WARN2"; then
    pass "established chain skips --fastsync but keeps --prune-history/paths/ports"
else
    fail "established chain skips --fastsync (av: $av, warn: $(tr '\n' ' ' < "$WARN2"))"
fi
rm -rf "$PRUNECH"; rm -f "$WARN2"
# Chain already pruned (bltx_store's oldest NON-genesis block is at/above the
# prune point): --prune-history is dropped too — re-running it would redo the
# multi-hour prune rewrite on every start. derod names blocks
# <hash>.block_<diff>_<ver>_<height>, keeps the genesis block (height 0) after
# pruning, and leaves a rolling window of recent blocks near the tip.
PRUNEDCH="$(mktemp -d)"
mkdir -p "$PRUNEDCH/mainnet/bltx_store/f0/27"
printf 'x' > "$PRUNEDCH/mainnet/topo.map"
# Genesis block (height 0) + a prune-point block (99980): only genesis sits below
# the 100000 prune point, so the chain is treated as already pruned.
printf 'x' > "$PRUNEDCH/mainnet/bltx_store/f0/27/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc.block_1_1_0"
printf 'x' > "$PRUNEDCH/mainnet/bltx_store/f0/27/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.block_100000_1_99980"
cli_reset; set_sync_profile pruned; CFG_DATA_DIR="$PRUNEDCH"; resolve_paths
WARN3="$(mktemp)"
build_derod_argv 2>"$WARN3"
av=$(argv_str)
if [[ "$av" != *--prune-history* ]] && grep -q 'already pruned' "$WARN3"; then
    pass "pruned chain skips --prune-history"
else
    fail "pruned chain skips --prune-history (av: $av, warn: $(tr '\n' ' ' < "$WARN3"))"
fi
rm -rf "$PRUNEDCH"; rm -f "$WARN3"
# Chain with old blocks still in bltx_store (never pruned): --prune-history
# still applies. Genesis (0) plus a real early block (1) below the prune point.
UNPRUNEDCH="$(mktemp -d)"
mkdir -p "$UNPRUNEDCH/mainnet/bltx_store/f0/27"
printf 'x' > "$UNPRUNEDCH/mainnet/topo.map"
printf 'x' > "$UNPRUNEDCH/mainnet/bltx_store/f0/27/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.block_1_1_0"
printf 'x' > "$UNPRUNEDCH/mainnet/bltx_store/f0/27/dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd.block_1_1_1"
cli_reset; set_sync_profile pruned; CFG_DATA_DIR="$UNPRUNEDCH"; resolve_paths
WARN4="$(mktemp)"
build_derod_argv 2>"$WARN4"
av=$(argv_str)
if [[ "$av" == *--prune-history=100000* ]] && ! grep -q 'already pruned' "$WARN4"; then
    pass "unpruned chain keeps --prune-history"
else
    fail "unpruned chain keeps --prune-history (av: $av, warn: $(tr '\n' ' ' < "$WARN4"))"
fi
rm -rf "$UNPRUNEDCH"; rm -f "$WARN4"
# Fresh chain (no topo.map): derod can't prune <50 blocks, so --prune-history
# is deferred — the flag is dropped and a warning is printed.
FRESHCH="$(mktemp -d)"
mkdir -p "$FRESHCH/mainnet"
cli_reset; set_sync_profile pruned; CFG_DATA_DIR="$FRESHCH"; resolve_paths
WARN="$(mktemp)"
build_derod_argv 2>"$WARN"
av=$(argv_str)
if [[ "$av" == *--fastsync* ]] && [[ "$av" != *--prune-history* ]] && grep -q 'deferring --prune-history' "$WARN"; then
    pass "fresh chain defers --prune-history"
else
    fail "fresh chain defers --prune-history (av: $av, warn: $(tr '\n' ' ' < "$WARN"))"
fi
rm -rf "$FRESHCH"; rm -f "$WARN"
cli_reset; set_sync_profile full; resolve_paths; build_derod_argv
av=$(argv_str)
if [[ "$av" != *--fastsync* ]] && [[ "$av" != *--prune-history* ]]; then pass "full argv omits fastsync/prune"; else fail "full argv omits fastsync/prune ($av)"; fi
# Testnet on a fresh chain dir (no topo.map): fastsync applies, prune deferred.
TNETCH="$(mktemp -d)"
cli_reset; set_sync_profile pruned; CFG_DATA_DIR="$TNETCH"; CFG_TESTNET=true; resolve_paths; apply_testnet_defaults; build_derod_argv
av=$(argv_str)
if [[ "$av" == *--testnet* ]] && [[ "$av" == *--fastsync* ]] && [[ "$av" != *--prune-history* ]] && [[ "$av" == *--rpc-bind=127.0.0.1:40402* ]] && [[ "$av" == *--p2p-bind=0.0.0.0:40401* ]] && [[ "$av" == *--getwork-bind=127.0.0.1:40400* ]]; then
    pass "testnet argv swaps default ports"
else
    fail "testnet argv ($av)"
fi
rm -rf "$TNETCH"
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
DERONODE_VERSION="1.1.0"
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

# 10. Dry-run is offline (no download, no config, no dirs created). Run from an
# isolated temp copy of the runner so the test can assert 'no bin/ created'
# without touching (or deleting!) the real project bin/ — a previous version
# rm -rf'd $PROJECT_DIR/bin, nuking a user's installed derod on every smoke run.
echo ""
echo "10. Dry-run is offline:"
DRYTMP="$PROJECT_DIR/.dry-run-test"
rm -rf "$DRYTMP"; mkdir -p "$DRYTMP"
cp node.sh catalog.json "$DRYTMP"/
cp -r lib "$DRYTMP"/
DRYCFG="$DRYTMP/.dry-test.json"
out=$(bash "$DRYTMP/node.sh" --config="$DRYCFG" --dry-run --sync-profile=pruned \
    --integrator-address=dero1qyshrhaf0cev402lqw2g2slqf2v3r2rjq2xh03xgd852cjhrgdyqcqq0letdh \
    --data-dir="$DRYTMP/drydata" --log-dir="$DRYTMP/drylogs" 2>&1)
rc=$?
[ $rc -eq 0 ] && pass "--dry-run exits 0" || fail "--dry-run exits 0 (rc=$rc)"
# The drydata dir is fresh (no topo.map) so prune is deferred and --fastsync
# is kept in the argv.
echo "$out" | grep -q -- '--prune-history=100000' && fail "pruned profile in argv deferred on fresh chain" || pass "pruned profile in argv deferred on fresh chain"
echo "$out" | grep -q -- '--fastsync' && pass "fresh chain argv keeps --fastsync" || fail "fresh chain argv keeps --fastsync"
echo "$out" | grep -q -- "--data-dir=$DRYTMP/drydata" && pass "data-dir override in argv" || fail "data-dir override in argv"
[ ! -d "$DRYTMP/bin" ] && pass "no bin/ created" || fail "no bin/ created"
[ ! -d "$DRYTMP/drydata" ] && pass "no data dir created" || fail "no data dir created"
[ ! -f "$DRYCFG" ] && pass "no config file written" || fail "no config file written"
rm -rf "$DRYTMP"

# 11. Snapshot/restore offline fixture (no network, no real derod)
echo ""
echo "11. Snapshot/restore offline fixture:"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/ui.sh"
source "$LIB_DIR/rpc.sh"
source "$LIB_DIR/snapshot.sh"
# Isolate the offline fixture from any real external install on this machine
# (including a stale derod.pid a crashed start may have left behind).
external_installed() { return 1; }
rm -f "$PROJECT_DIR/derod.pid"
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
# restore without --from auto-picks the latest snapshot
SNAPLAT="$(mktemp -d)"
mkdir -p "$SNAPLAT/balances/ab" "$SNAPLAT/bltx_store/b1"
printf 'oldblob' > "$SNAPLAT/balances/ab/x1"
printf 'oldtopo' > "$SNAPLAT/topo.map"
DATA_DIR_REAL="$SNAPLAT"
SNAPSHOT_YES=true
SNAPSHOT_FROM=""
snapshot_any_derod_running() { return 1; }
if snapshot_restore >/tmp/snaprest.out 2>&1; then pass "restore without --from auto-picks latest"; else fail "restore without --from auto-picks latest"; fi
grep -q 'using latest snapshot' /tmp/snaprest.out && pass "restore reports latest snapshot name" || fail "restore reports latest snapshot name"
[ -f "$SNAPLAT/balances/ab/x1" ] && [ "$(cat "$SNAPLAT/balances/ab/x1")" = "blob" ] && pass "auto-picked archive restores newer content" || fail "auto-picked archive restores newer content"
# restore with an empty snapshot dir errors clearly
EMPTYDIR="$(mktemp -d)"
DATA_DIR_REAL="$EMPTYDIR"
SNAPSHOT_DIR="$EMPTYDIR/out"
mkdir -p "$SNAPSHOT_DIR"
if snapshot_restore >/tmp/snapempty.out 2>&1; then fail "restore with empty snapshot dir refuses"; else pass "restore with empty snapshot dir refuses"; fi
grep -q 'no snapshot found' /tmp/snapempty.out && pass "empty snapshot dir error is clear" || fail "empty snapshot dir error is clear"
SNAPSHOT_DIR=""
rm -rf "$SNAPLAT" "$SNAPLAT".bak-* "$EMPTYDIR" "$EMPTYDIR".bak-*; rm -f /tmp/snaprest.out /tmp/snapempty.out
if grep -q 'tar --zstd' "$LIB_DIR/snapshot.sh" && grep -q 'rargz --extract' "$LIB_DIR/snapshot.sh"; then pass "restore falls back to tar, rargz optional"; else fail "restore falls back to tar, rargz optional"; fi
# external data-dir resolution (stub unit files)
EXTUNIT="$(mktemp)"
printf '[Service]\nWorkingDirectory=/home/priest/Crypto/dero/node\n' > "$EXTUNIT"
ddir="$(external_data_dir_from_unit "$EXTUNIT")"
[ "$ddir" = "/home/priest/Crypto/dero/node" ] && pass "external_data_dir_from_unit reads WorkingDirectory" || fail "external_data_dir_from_unit reads WorkingDirectory (got '$ddir')"
printf '[Service]\nExecStart=/usr/bin/derod --data-dir=/srv/dero/node\n' > "$EXTUNIT"
ddir="$(external_data_dir_from_unit "$EXTUNIT")"
[ "$ddir" = "/srv/dero/node" ] && pass "external_data_dir_from_unit falls back to --data-dir" || fail "external_data_dir_from_unit falls back to --data-dir (got '$ddir')"
rm -f "$EXTUNIT"
# macOS launchd plist data-dir resolution
EXTPLIST="$(mktemp)"
printf '%s' '<?xml version="1.0"?><plist><dict><key>WorkingDirectory</key><string>/Users/priest/Crypto/dero/node</string></dict></plist>' > "$EXTPLIST"
ddir="$(external_data_dir_from_plist "$EXTPLIST" || true)"
[ "$ddir" = "/Users/priest/Crypto/dero/node" ] && pass "external_data_dir_from_plist reads WorkingDirectory" || fail "external_data_dir_from_plist reads WorkingDirectory (got '$ddir')"
printf '%s' '<?xml version="1.0"?><plist><dict><key>ProgramArguments</key><array><string>/usr/bin/derod</string><string>--data-dir=/srv/dero/node</string></array></dict></plist>' > "$EXTPLIST"
ddir="$(external_data_dir_from_plist "$EXTPLIST" || true)"
[ "$ddir" = "/srv/dero/node" ] && pass "external_data_dir_from_plist falls back to --data-dir" || fail "external_data_dir_from_plist falls back to --data-dir (got '$ddir')"
rm -f "$EXTPLIST"
# external_unit on macOS never treats our own org.deronode.derod agent as external
if grep -q 'org.deronode.derod' "$LIB_DIR/rpc.sh" && grep -q 'external_unit()' "$LIB_DIR/rpc.sh"; then pass "external_unit excludes our own launchd agent on macOS"; else fail "external_unit excludes our own launchd agent on macOS"; fi
# cmd_update_external resolves the binary portably (no /proc-only) and restarts launchd on macOS
if grep -q 'derod_pid' node.sh && grep -q 'process_exe' node.sh && grep -q 'launchctl kickstart' node.sh; then pass "cmd_update_external is portable (derod_pid/process_exe + launchctl)"; else fail "cmd_update_external is portable (derod_pid/process_exe + launchctl)"; fi
# snapshot_chain_dir resolves the external node's real data dir
EXTSNAP="$(mktemp -d)"
mkdir -p "$EXTSNAP/node/mainnet"
printf 'x' > "$EXTSNAP/node/mainnet/topo.map"
DATA_DIR_REAL="$SNAPFIX/decoy"
external_installed() { return 0; }
external_data_dir() { echo "$EXTSNAP/node"; }
c="$(snapshot_chain_dir)"
[ "$c" = "$EXTSNAP/node/mainnet" ] && pass "snapshot_chain_dir resolves external data dir" || fail "snapshot_chain_dir resolves external data dir (got '$c')"
external_installed() { return 1; }
c="$(snapshot_chain_dir)"
[ "$c" = "$DATA_DIR_REAL" ] && pass "snapshot_chain_dir falls back to DATA_DIR_REAL" || fail "snapshot_chain_dir falls back to DATA_DIR_REAL (got '$c')"
# missing-member pre-check fails clearly (external_installed stays stubbed off)
INCOMPLETE="$(mktemp -d)"
mkdir -p "$INCOMPLETE/balances/ab"
printf 'blob' > "$INCOMPLETE/balances/ab/x1"
printf 'topomapdata' > "$INCOMPLETE/topo.map"
DATA_DIR_REAL="$INCOMPLETE"
ERROUT="$(mktemp)"
if snapshot_pack 2>"$ERROUT"; then fail "snapshot_pack rejects incomplete chain dir"; else pass "snapshot_pack rejects incomplete chain dir"; fi
grep -q 'incomplete' "$ERROUT" && grep -q 'bltx_store' "$ERROUT" && pass "missing-member error names the member" || fail "missing-member error names the member (err: $(tr '\n' ' ' < "$ERROUT"))"
rm -rf "$INCOMPLETE"; rm -f "$ERROUT"
rm -rf "$SNAPFIX" "$SNAPREST" "$SNAPREST".bak-* "$EXTSNAP"
unset -f snapshot_pack snapshot_restore snapshot_chain_dir snapshot_height snapshot_derod_pids snapshot_running_on_data_dir snapshot_any_derod_running snapshot_size_raw snapshot_sha256_hex snapshot_verify_sha256 external_data_dir_from_unit external_data_dir_from_plist external_installed external_data_dir

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

# 13. Running daemon at latest skips download (network-stubbed)
echo ""
echo "13. Update skips when running daemon is at latest:"
eval "$(sed -n '/^daemon_release_number()/,/^}/p' lib/rpc.sh)"
eval "$(sed -n '/^cmd_update()/,/^}/p' node.sh)"
# Stub RPC + release plumbing so the guard short-circuits with no network.
node_running() { return 0; }
parse_rpc_endpoint() { :; }
get_node_info() { printf '%s\n' '{"version":"3.6.0-152.DEROHE.STARGATE+14082026"}'; }
resolve_release() { LAST_TAG="Release152"; return 0; }
cached_tag_fresh() { return 1; }
is_source_build() { return 1; }   # not a community-dev source build
node_is_external() { return 1; }
fetch_derod() { echo "FETCH_DEROD_CALLED" >&2; return 0; }
service_stop() { echo "SERVICE_STOP_CALLED" >&2; return 0; }
service_install() { echo "SERVICE_INSTALL_CALLED" >&2; return 0; }
cmd_update_external() { echo "CMD_UPDATE_EXTERNAL_CALLED" >&2; return 1; }
BIN_DIR="$(mktemp -d)"
C_OK=''; C_RESET=''; C_INFO=''; C_ERR=''; C_WARN=''
rel=$(daemon_release_number)
[ "$rel" = "152" ] && pass "daemon_release_number extracts 152 from 3.6.0-152.DEROHE.STARGATE" || fail "daemon_release_number extracts 152 (got '$rel')"
if out=$(cmd_update 2>&1); then
    echo "$out" | grep -q "Already at latest (Release152)" && pass "cmd_update reports Already at latest when running at latest" || fail "cmd_update reports Already at latest when running at latest"
    echo "$out" | grep -q "Updating derod" && fail "no download when running at latest" || pass "no download when running at latest"
else
    fail "cmd_update exits 0 when running at latest (out: $out)"
fi
# Guard fails open: a running older release still proceeds to the download path.
get_node_info() { printf '%s\n' '{"version":"3.6.0-151.DEROHE.STARGATE+14082020"}'; }
if out=$(cmd_update 2>&1) && echo "$out" | grep -q "Updating derod none -> Release152"; then
    pass "older running release still updates"
else
    fail "older running release still updates (out: $out)"
fi
rm -rf "$BIN_DIR"
unset -f daemon_release_number cmd_update node_running parse_rpc_endpoint get_node_info resolve_release cached_tag_fresh is_source_build node_is_external fetch_derod service_stop service_install cmd_update_external

# 13b. Archive cache: an already-downloaded archive is not fetched again
echo ""
echo "13b. Archive download cache:"
source "$LIB_DIR/download.sh"
FAKEDIR="$(mktemp -d)"
mkdir -p "$FAKEDIR/x"
printf '\177ELFfake' > "$FAKEDIR/x/derod"
FAKE_ASSET="dero_fake_linux_amd64.tar.gz"
FAKE_ARCHIVE="$FAKEDIR/$FAKE_ASSET"
tar -czf "$FAKE_ARCHIVE" -C "$FAKEDIR/x" derod
FAKE_SHA512="$( (sha512sum "$FAKE_ARCHIVE" 2>/dev/null || shasum -a 512 "$FAKE_ARCHIVE") | awk '{print $1}' )"
CACHEBIN="$(mktemp -d)"
BIN_DIR="$CACHEBIN"
LAST_TAG="Release999"
LAST_ASSET="$FAKE_ASSET"
C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_RESET=''
DLCOUNT=0
stub_curl() {
    local -a c=("$@")
    local i u o="" is_cs=0
    for u in "${c[@]}"; do case "$u" in *checksum.txt*) is_cs=1 ;; esac; done
    for ((i=0; i<${#c[@]}; i++)); do [ "${c[$i]}" = "-o" ] && { o="${c[$((i+1))]}"; break; }; done
    if [ "$is_cs" = "1" ]; then
        printf '%s  %s\n' "$FAKE_SHA512" "$FAKE_ASSET" > "$o"
    else
        cp "$FAKE_ARCHIVE" "$o"; DLCOUNT=$((DLCOUNT+1))
    fi
    return 0
}
curl() { stub_curl "$@"; }
if fetch_derod 2>/dev/null; then
    [ "$DLCOUNT" = "1" ] && pass "first fetch downloads the archive" || fail "first fetch downloads the archive (count=$DLCOUNT)"
    [ -f "$BIN_DIR/archives/$LAST_TAG/$FAKE_ASSET" ] && pass "archive cached under bin/archives/<tag>" || fail "archive cached under bin/archives/<tag>"
else
    fail "first fetch downloads the archive"
fi
# Wipe the installed binary (forces a reinstall) — the cached archive is reused.
# Note: fetch_derod runs in the current shell (not $( )) so DLCOUNT persists.
CACHEOUT="$(mktemp)"
rm -f "$BIN_DIR/derod/derod" "$BIN_DIR/derod/.tag" "$BIN_DIR/derod/.tagtime" "$BIN_DIR/derod/.asset"
fetch_derod 2>"$CACHEOUT"
out="$(cat "$CACHEOUT")"
if [ "$DLCOUNT" = "1" ] && echo "$out" | grep -q "Reusing cached"; then
    pass "reinstall reuses cached archive (no re-download)"
else
    fail "reinstall reuses cached archive (count=$DLCOUNT out: $(tr '\n' ' ' <<<"$out"))"
fi
# A corrupt cached archive fails checksum and is re-downloaded.
printf 'garbage' > "$BIN_DIR/archives/$LAST_TAG/$FAKE_ASSET"
rm -f "$BIN_DIR/derod/derod" "$BIN_DIR/derod/.tag" "$BIN_DIR/derod/.tagtime" "$BIN_DIR/derod/.asset"
fetch_derod 2>"$CACHEOUT"
out="$(cat "$CACHEOUT")"
if [ "$DLCOUNT" = "2" ] && echo "$out" | grep -q "cached archive failed checksum"; then
    pass "corrupt cached archive is re-downloaded"
else
    fail "corrupt cached archive is re-downloaded (count=$DLCOUNT out: $(tr '\n' ' ' <<<"$out"))"
fi
# A timestamped .bak of the previous binary is kept before replacing it.
rm -f "$BIN_DIR/derod"/derod.bak-*
if fetch_derod 2>/dev/null && [ -n "$(ls "$BIN_DIR/derod"/derod.bak-* 2>/dev/null | head -1)" ] && [ -f "$BIN_DIR/derod/derod" ]; then
    pass "update backs up previous binary with timestamp (.bak)"
else
    fail "update backs up previous binary with timestamp (.bak)"
fi
# Only the newest 3 binary backups are kept; older ones are pruned.
eval "$(sed -n '/^prune_derod_backups()/,/^}/p' lib/download.sh)"
PDIR="$(mktemp -d)"
for t in 20260101_000000 20260201_000000 20260301_000000 20260401_000000 20260501_000000; do
    touch "$PDIR/derod.bak-$t"
done
prune_derod_backups "$PDIR"
if [ "$(ls "$PDIR"/derod.bak-* | wc -l | tr -d ' ')" = "3" ] \
   && [ -f "$PDIR/derod.bak-20260501_000000" ] && [ ! -f "$PDIR/derod.bak-20260101_000000" ]; then
    pass "binary backups pruned to newest 3"
else
    fail "binary backups pruned to newest 3"
fi
rm -rf "$PDIR"; unset -f prune_derod_backups
rm -rf "$FAKEDIR" "$CACHEBIN"; rm -f "$CACHEOUT"
unset -f fetch_derod resolve_release verify_checksum find_derod_in cached_tag_fresh stub_curl curl

# 13c. Service backend detection: a degraded systemd session still uses systemd
# (a failed unrelated unit must not demote to the pid fallback); only an
# unreachable bus falls back.
echo ""
echo "13c. Service backend detection:"
eval "$(sed -n '/^service_backend()/,/^}/p' lib/service.sh)"
OS=linux
systemctl() { echo "degraded"; return 1; }
if [ "$(service_backend)" = "systemd" ]; then
    pass "degraded systemd session still selects systemd"
else
    fail "degraded systemd session still selects systemd (got $(service_backend))"
fi
systemctl() { echo "Failed to connect to bus: No such file or directory" >&2; return 1; }
if [ "$(service_backend)" = "pid" ]; then
    pass "unreachable systemd bus falls back to pid"
else
    fail "unreachable systemd bus falls back to pid (got $(service_backend))"
fi
if grep -q 'org.deronode.derod is already configured and running' lib/service.sh \
   && grep -q 'launchctl list' lib/service.sh; then
    pass "launchd install is idempotent (already-configured message)"
else
    fail "launchd install is idempotent (already-configured message)"
fi
OS=darwin
if [ "$(service_backend)" = "launchd" ]; then
    pass "darwin selects launchd"
else
    fail "darwin selects launchd (got $(service_backend))"
fi
unset -f systemctl service_backend

# 13d. Service install idempotency: an already-configured unit is reported, not
# reinstalled; only a stopped-but-installed unit gets started.
eval "$(sed -n '/^service_install()/,/^}/p' lib/service.sh)"
write_run_wrapper() { :; }
service_backend() { echo systemd; }
apply_testnet_defaults() { :; }
build_derod_argv() { :; }
INSTALL_DIR="$PROJECT_DIR"
C_OK=''; C_MUTE=''; C_ERR=''; C_RESET=''
SVDIR="$(mktemp -d)"
SVHOME_SAVE="$HOME"; HOME="$SVDIR"
mkdir -p "$SVDIR/.config/systemd/user"
SVCORDER="$(mktemp)"
# installed + active -> reports already-configured, no start/reload calls
systemctl() { echo "systemctl $*" >> "$SVCORDER"; [ "$2" = "is-active" ]; }
: > "$SVDIR/.config/systemd/user/deronode.service"
out="$(service_install 2>&1)"
if echo "$out" | grep -q "already configured and running" && ! grep -q 'start deronode' "$SVCORDER"; then
    pass "installed + running unit: reports already configured, no reinstall"
else
    fail "installed + running unit: reports already configured, no reinstall (out: $out calls: $(tr '\n' ' ' < "$SVCORDER"))"
fi
# installed + stopped -> starts it, no daemon-reload
: > "$SVCORDER"
systemctl() { echo "systemctl $*" >> "$SVCORDER"; if [ "$2" = "is-active" ]; then return 1; fi; [ "$2" = "start" ]; }
out="$(service_install 2>&1)"
if echo "$out" | grep -q "already configured - starting" && grep -q 'start deronode' "$SVCORDER" && ! grep -q 'daemon-reload' "$SVCORDER"; then
    pass "installed + stopped unit: starts it, no reinstall"
else
    fail "installed + stopped unit: starts it, no reinstall (out: $out calls: $(tr '\n' ' ' < "$SVCORDER"))"
fi
# not installed -> full install path
: > "$SVCORDER"
rm -f "$SVDIR/.config/systemd/user/deronode.service"
systemctl() { echo "systemctl $*" >> "$SVCORDER"; [ "$2" = "start" ]; }
out="$(service_install 2>&1)"
if echo "$out" | grep -q "installed + started" && grep -q 'daemon-reload' "$SVCORDER"; then
    pass "no unit: full install path"
else
    fail "no unit: full install path (out: $out calls: $(tr '\n' ' ' < "$SVCORDER"))"
fi
rm -rf "$SVDIR"; rm -f "$SVCORDER"; HOME="$SVHOME_SAVE"
unset -f service_install write_run_wrapper service_backend apply_testnet_defaults build_derod_argv systemctl

# 14. Menu option 7 (reconfigure) is dispatched after the menu
echo ""
echo "14. Menu reconfigure dispatch:"
menu_src="$(sed -n '/^menu()/,/^}/p' node.sh)"
echo "$menu_src" | grep -q '7) ACTION=reconfigure' && pass "menu option 7 sets ACTION=reconfigure" || fail "menu option 7 sets ACTION=reconfigure"
entry_src="$(sed -n '/^case "\$ACTION" in/,$p' node.sh)"
echo "$entry_src" | grep -q 'reconfigure) cmd_reconfigure ;;' && pass "post-menu case dispatches reconfigure" || fail "post-menu case dispatches reconfigure"
# first-run install (menu option 1 with no derod): asks to start the node,
# then continues into start on yes
first_run="$(sed -n '/^menu()/,/^}/p' node.sh)"
if echo "$first_run" | grep -q 'No derod installed yet' && echo "$first_run" | grep -q 'ensure_binary; then' && echo "$first_run" | grep -q 'Start the node now' && echo "$first_run" | grep -q 'ACTION=start'; then
    pass "first-run install prompts to start the node, then continues into start"
else
    fail "first-run install prompts to start the node, then continues into start"
fi
# first-run install honors the configure run-mode answer (service vs foreground)
cfg_src="$(sed -n '/^configure()/,/^}/p' node.sh)"
if echo "$cfg_src" | grep -q 'Background system service' && echo "$cfg_src" | grep -q 'AS_SERVICE=true' && echo "$cfg_src" | grep -q 'ask pick "Choose" "2"'; then
    pass "configure offers system-service install (run mode question)"
else
    fail "configure offers system-service install (run mode question)"
fi
# The first-run branch (before the menu's while loop) sets ACTION=start and
# never ASSIGNS AS_SERVICE, so the configure answer survives into cmd_start.
first_run_branch="$(echo "$first_run" | sed -n '1,/while true/p')"
if echo "$first_run_branch" | grep -q 'ACTION=start' && ! echo "$first_run_branch" | grep -q 'AS_SERVICE='; then
    pass "first-run install keeps configure's service/foreground choice"
else
    fail "first-run install keeps configure's service/foreground choice"
fi
# Windows binary naming + PE magic check fixes (community-dev build path)
plat="$(cat "$LIB_DIR/platform.sh")"
if echo "$plat" | grep -q 'mingw\*|msys\*|cygwin\*' && echo "$plat" | grep -q 'OS="windows"'; then
    pass "platform.sh detects Git Bash/MSYS/MINGW as windows"
else
    fail "platform.sh detects Git Bash/MSYS/MINGW as windows"
fi
node_top="$(sed -n '1,/^source .*ui.sh/p' node.sh)"
if echo "$node_top" | grep -q 'BINARY_NAME="derod"' && grep -q '\[ "$OS" = "windows" \]' node.sh && grep -q 'BINARY_NAME="derod.exe"' node.sh; then
    pass "node.sh names the Windows binary derod.exe"
else
    fail "node.sh names the Windows binary derod.exe"
fi
if grep -q '\$BINARY_NAME' "$LIB_DIR/download.sh" && grep -q '\$BINARY_NAME' "$LIB_DIR/build.sh"; then
    pass "download/build install sites use the platform binary name"
else
    fail "download/build install sites use the platform binary name"
fi
if grep -q '4d5a\*' "$LIB_DIR/build.sh" && grep -q '4d5a\*' "$LIB_DIR/download.sh"; then
    pass "magic check accepts PE 'MZ' (4d5a*) prefix"
else
    fail "magic check accepts PE 'MZ' (4d5a*) prefix"
fi
# reconfigure also continues straight into start (only when nothing is running)
reconf="$(sed -n '/^cmd_reconfigure()/,/^}/p' node.sh)"
if echo "$reconf" | grep -q 'cmd_start' && echo "$reconf" | grep -q 'node_running; then'; then
    pass "reconfigure continues into start when stopped"
else
    fail "reconfigure continues into start when stopped"
fi
# resync command: parse, menu, dispatch, wipe+fastsync+start
if grep -q 'resync) ACTION="resync"' node.sh && grep -q '11) ACTION=resync' node.sh && grep -qE 'resync\) +cmd_resync ;;' node.sh; then
    pass "resync wired into parse/menu/dispatch"
else
    fail "resync wired into parse/menu/dispatch"
fi
# build command (compile community-dev source): parse, menu, dispatch
if grep -q 'build) ACTION="build"' node.sh && grep -q '6) ACTION=build' node.sh && grep -qE 'build\) +cmd_build ;;' node.sh; then
    pass "build wired into parse/menu/dispatch"
else
    fail "build wired into parse/menu/dispatch"
fi
build_src="$(sed -n '/^cmd_build()/,/^}/p' node.sh)"
if echo "$build_src" | grep -q 'build_derod_from_source' && echo "$build_src" | grep -q 'service_stop' && echo "$build_src" | grep -q 'service_install' && echo "$build_src" | grep -q 'external_installed'; then
    pass "cmd_build stops+runs+builds+restarts, refuses external"
else
    fail "cmd_build stops+runs+builds+restarts, refuses external"
fi
if echo "$build_src" | grep -q 'have_go' && echo "$build_src" | grep -q 'Go toolchain not found'; then
    pass "cmd_build guards on the Go toolchain"
else
    fail "cmd_build guards on the Go toolchain"
fi
build_lib_src="$(sed -n '/^build_derod_from_source()/,/^}/p' lib/build.sh)"
if echo "$build_lib_src" | grep -q 'bak-\$' && echo "$build_lib_src" | grep -q 'backed up previous binary'; then
    pass "source build backs up previous binary with timestamp"
else
    fail "source build backs up previous binary with timestamp"
fi
# build lib: clone community-dev, go build ./cmd/derod, magic-check, marker
bld="$(cat "$LIB_DIR/build.sh")"
if echo "$bld" | grep -q 'git clone --depth 1 --branch "$DEV_BRANCH"' && echo "$bld" | grep -q 'go build -o derod ./cmd/derod' && echo "$bld" | grep -q 'community-dev@' && echo "$bld" | grep -q 'is_source_build'; then
    pass "lib/build.sh clones community-dev + go builds derod + marks source"
else
    fail "lib/build.sh clones community-dev + go builds derod + marks source"
fi
if echo "$bld" | grep -q 'find_derod_in' && echo "$bld" | grep -q 'magic check'; then
    pass "lib/build.sh reuses find_derod_in + magic check"
else
    fail "lib/build.sh reuses find_derod_in + magic check"
fi
# source builds are kept by start (cached_tag_fresh) but replaced by update
if grep -q 'is_source_build && return 0' "$LIB_DIR/download.sh" && grep -q '! is_source_build && cached_tag_fresh' node.sh; then
    pass "start keeps source build; update swaps back to release"
else
    fail "start keeps source build; update swaps back to release"
fi
# update --source=dev routes through the community-dev compile path; menu
# option 5 offers the release-vs-community-dev choice.
if grep -q '"\${UPDATE_SOURCE:-release}" = "dev"' node.sh && grep -q 'cmd_build' node.sh && grep -q 'Update source:' node.sh && grep -q '2) community-dev source (compile)' node.sh; then
    pass "update --source=dev routes to cmd_build (menu option 5 offers the choice)"
else
    fail "update --source=dev routes to cmd_build (menu option 5 offers the choice)"
fi
upd_src="$(sed -n '/^cmd_update()/,/^}/p' node.sh)"
if echo "$upd_src" | grep -q 'UPDATE_SOURCE' && echo "$upd_src" | grep -q 'cmd_build'; then
    pass "cmd_update dispatches dev source to the build path"
else
    fail "cmd_update dispatches dev source to the build path"
fi
# menu-driven entry loops back to the menu after each action (no exit)
if echo "$entry_src" | grep -q 'while true; do' && echo "$entry_src" | grep -q 'MENU_MODE=true'; then
    pass "menu-driven entry loops back to the menu"
else
    fail "menu-driven entry loops back to the menu"
fi
# cmd_start runs foreground derod as a child (no exec) so the menu returns
start_src="$(sed -n '/^cmd_start()/,/^}/p' node.sh)"
if echo "$start_src" | grep -q 'MENU_MODE' && echo "$start_src" | grep -q 'exec "\$BINARY_PATH"'; then
    pass "cmd_start keeps exec only for CLI (menu mode returns to menu)"
else
    fail "cmd_start keeps exec only for CLI (menu mode returns to menu)"
fi
resync_body="$(sed -n '/^cmd_resync()/,/^}/p' node.sh)"
if echo "$resync_body" | grep -q 'snapshot_chain_dir' && echo "$resync_body" | grep -q 'rm -rf' && echo "$resync_body" | grep -q 'CFG_FASTSYNC=true' && echo "$resync_body" | grep -q 'CFG_PRUNE_HISTORY=""' && echo "$resync_body" | grep -q 'cmd_start'; then
    pass "resync wipes chain then fastsync-bootstraps and starts"
else
    fail "resync wipes chain then fastsync-bootstraps and starts"
fi
# logs command: parse, menu, dispatch, tail selection
if grep -q 'logs) ACTION="logs"' node.sh && grep -q '12) ACTION=logs' node.sh && grep -q 'logs).*cmd_logs ;;' node.sh; then
    pass "logs wired into parse/menu/dispatch"
else
    fail "logs wired into parse/menu/dispatch"
fi
logs_src="$(sed -n '/^cmd_logs()/,/^}/p' node.sh)"
if echo "$logs_src" | grep -q 'tail -n 100 -f' && echo "$logs_src" | grep -q 'derod.out.log' && echo "$logs_src" | grep -q 'MENU_MODE'; then
    pass "cmd_logs tails derod.log and falls back to out/err captures"
else
    fail "cmd_logs tails derod.log and falls back to out/err captures"
fi
# uninstall command: parse, menu, dispatch, stop+wipe, keep deronode
if grep -q 'uninstall) ACTION="uninstall"' node.sh && grep -q '13) ACTION=uninstall' node.sh && grep -qE 'uninstall\) +cmd_uninstall ;;' node.sh; then
    pass "uninstall wired into parse/menu/dispatch"
else
    fail "uninstall wired into parse/menu/dispatch"
fi
uninst_src="$(sed -n '/^cmd_uninstall()/,/^}/p' node.sh)"
if echo "$uninst_src" | grep -q 'service_remove' && echo "$uninst_src" | grep -q 'rm -rf' && echo "$uninst_src" | grep -q 'DATA_DIR_REAL' && echo "$uninst_src" | grep -q 'CONFIG_FILE'; then
    pass "cmd_uninstall removes service + binary/chain/logs/snapshots/config"
else
    fail "cmd_uninstall removes service + binary/chain/logs/snapshots/config"
fi
if echo "$uninst_src" | grep -q 'external_installed' && echo "$uninst_src" | grep -q 'yesno'; then
    pass "cmd_uninstall refuses external + confirms before wiping"
else
    fail "cmd_uninstall refuses external + confirms before wiping"
fi
if echo "$uninst_src" | grep -q 'Refusing to uninstall' && echo "$uninst_src" | grep -q 'is not a removable path'; then
    pass "cmd_uninstall guards against wiping / or empty paths"
else
    fail "cmd_uninstall guards against wiping / or empty paths"
fi
if echo "$uninst_src" | grep -q 'stays installed' && echo "$uninst_src" | grep -q 'DRY_RUN'; then
    pass "cmd_uninstall keeps deronode itself + supports dry-run"
else
    fail "cmd_uninstall keeps deronode itself + supports dry-run"
fi
# send/receive (thruflux): parse, menu, dispatch, host/join wrappers
if grep -q 'send) ACTION="send"' node.sh && grep -q '14) ACTION=send' node.sh && grep -qE 'send\) +cmd_send ;;' node.sh && grep -qE 'receive\) +cmd_receive ;;' node.sh; then
    pass "send/receive wired into parse/menu/dispatch"
else
    fail "send/receive wired into parse/menu/dispatch"
fi
# menu option 15: receive — prompts for the join code, then dispatches receive
if grep -q '15)' node.sh && grep -q 'Receive snapshot from a friend' node.sh && grep -q 'Join code' node.sh && grep -q 'ACTION=receive; return' node.sh; then
    pass "menu option 15 prompts for the join code and dispatches receive"
else
    fail "menu option 15 prompts for the join code and dispatches receive"
fi
send_src="$(sed -n '/^cmd_send()/,/^}/p' node.sh)"
if echo "$send_src" | grep -q 'thru host' && echo "$send_src" | grep -q 'snapshot_latest_archive' && echo "$send_src" | grep -q 'thru_ensure'; then
    pass "cmd_send hosts the newest snapshot via thruflux"
else
    fail "cmd_send hosts the newest snapshot via thruflux"
fi
recv_src="$(sed -n '/^cmd_receive()/,/^}/p' node.sh)"
if echo "$recv_src" | grep -q 'thru join' && echo "$recv_src" | grep -q 'RECEIVE_CODE' && echo "$recv_src" | grep -q 'thru_ensure'; then
    pass "cmd_receive joins a thruflux code"
else
    fail "cmd_receive joins a thruflux code"
fi
# send hosts the archive with its checksum/manifest siblings so the receiver
# can verify the restore automatically
if echo "$send_src" | grep -q '\.sha256' && echo "$send_src" | grep -q '\.manifest\.json' && echo "$send_src" | grep -q 'files+=('; then
    pass "cmd_send hosts the archive with its .sha256/.manifest siblings"
else
    fail "cmd_send hosts the archive with its .sha256/.manifest siblings"
fi
# receive detects a dero snapshot in the transfer and proposes restoring it
if echo "$recv_src" | grep -q 'dero-mainnet-\*\.tar\.zst' && echo "$recv_src" | grep -q 'SNAPSHOT_FROM=' && echo "$recv_src" | grep -q 'snapshot_running_on_data_dir'; then
    pass "cmd_receive detects a received snapshot and proposes restoring it"
else
    fail "cmd_receive detects a received snapshot and proposes restoring it"
fi
# ...and that offer is interactive-only, with stop/restore/restart handling
if echo "$recv_src" | grep -q 'snapshot_stdin_tty' && echo "$recv_src" | grep -q 'restore --from' && echo "$recv_src" | grep -q 'stop it, restore the received snapshot, then restart'; then
    pass "cmd_receive restore offer is interactive-only + stops/restarts the node"
else
    fail "cmd_receive restore offer is interactive-only + stops/restarts the node"
fi
if grep -q 'thru_install_hint' node.sh && grep -q 'samsungplay/Thruflux' node.sh; then
    pass "send/receive hint at installing thruflux per-OS"
else
    fail "send/receive hint at installing thruflux per-OS"
fi
thru_ensure_src="$(sed -n '/^thru_ensure()/,/^}/p' node.sh)"
if echo "$thru_ensure_src" | grep -q 'Install thruflux now' && echo "$thru_ensure_src" | grep -q 'thru_install'; then
    pass "thru_ensure proposes installing thruflux on a tty"
else
    fail "thru_ensure proposes installing thruflux on a tty"
fi
if echo "$thru_ensure_src" | grep -q '\[ -t 0 \]' && echo "$thru_ensure_src" | grep -q 'yesno'; then
    pass "thru_ensure only prompts on a tty (scripted runs get the hint only)"
else
    fail "thru_ensure only prompts on a tty (scripted runs get the hint only)"
fi
thru_url_src="$(sed -n '/^thru_binary_url()/,/^}/p' node.sh)"
if echo "$thru_url_src" | grep -q 'raw.githubusercontent.com/samsungplay/Thruflux/main/frontend/binaries' \
   && echo "$thru_url_src" | grep -q 'thru_linux' && echo "$thru_url_src" | grep -q 'thru_mac' && echo "$thru_url_src" | grep -q 'thru_windows.exe'; then
    pass "thru_binary_url maps each OS to a raw.githubusercontent binary (upstream 404 workaround)"
else
    fail "thru_binary_url maps each OS to a raw.githubusercontent binary (upstream 404 workaround)"
fi
thru_install_src="$(sed -n '/^thru_install()/,/^}/p' node.sh)"
if echo "$thru_install_src" | grep -q '.local/bin' && echo "$thru_install_src" | grep -q 'chmod +x' && echo "$thru_install_src" | grep -q 'curl -fsSL'; then
    pass "thru_install drops the binary into ~/.local/bin + makes it executable"
else
    fail "thru_install drops the binary into ~/.local/bin + makes it executable"
fi
if echo "$thru_install_src" | grep -q 'sysctl' && echo "$thru_install_src" | grep -q '16777216'; then
    pass "thru_install raises UDP buffers best-effort (16 MiB)"
else
    fail "thru_install raises UDP buffers best-effort (16 MiB)"
fi
if echo "$thru_ensure_src" | grep -q 'export PATH=' && echo "$thru_ensure_src" | grep -q 'command -v thru'; then
    pass "thru_ensure adds ~/.local/bin to PATH after install"
else
    fail "thru_ensure adds ~/.local/bin to PATH after install"
fi
if grep -q 'thru_binary_url' node.sh && grep -q 'install_linux.sh' node.sh; then
    pass "code comments document the broken upstream installer URL (404)"
else
    fail "code comments document the broken upstream installer URL (404)"
fi

# 15. Snapshot prompts — confirm-new-snapshot + prompt-to-stop (stub-extracted
# from node.sh). yesno answers dispatch on the prompt text: the confirm-new
# prompt starts with "Latest snapshot:", the stop prompt with "derod is running".
echo ""
echo "15. Snapshot prompts:"
eval "$(sed -n '/^cmd_snapshot()/,/^}/p' node.sh)"
snapshot_running_on_data_dir() { return 0; }
snapshot_stdin_tty() { return 0; }
resolve_paths() { :; }
yesno() { case "$1" in Latest*) echo "$SNAP_NEW" ;; *) echo "$SNAP_STOP" ;; esac; }
cmd_stop() { echo "STOP_CALLED" >> "$ORDER"; }
snapshot_pack() { echo "SNAPSHOT_PACK_CALLED" >> "$ORDER"; return 0; }
node_is_external() { return 1; }
service_install() { echo "SERVICE_INSTALL_CALLED" >> "$ORDER"; return 0; }
external_start() { echo "EXTERNAL_START_CALLED" >> "$ORDER"; return 0; }
snapshot_latest_archive() { echo "$LATEST_ARC"; }
snapshot_archive_stamp() { echo "2026-08-17 01:12"; }
C_OK=''; C_RESET=''; C_INFO=''; C_ERR=''; C_WARN=''; C_MUTE=''
DRY_RUN=false
SNAPSHOT_KEEP_RUNNING=false
SNAPSHOT_OUT=""
SNAPSHOT_DIR_REAL="$SNAPFIX/out2"
DATA_DIR_REAL="$SNAPCHAIN"
LATEST_ARC="$SNAPFIX/out2/dero-mainnet-20260817-0112.tar.zst"
SNAP_NEW=y; SNAP_STOP=y
ORDER="$(mktemp)"

cmd_snapshot
stop_ln=$(grep -n '^STOP_CALLED$' "$ORDER" | cut -d: -f1)
pack_ln=$(grep -n '^SNAPSHOT_PACK_CALLED$' "$ORDER" | cut -d: -f1)
inst_ln=$(grep -n '^SERVICE_INSTALL_CALLED$' "$ORDER" | cut -d: -f1)
if [ -n "$stop_ln" ] && [ -n "$pack_ln" ] && [ -n "$inst_ln" ] && [ "$stop_ln" -lt "$pack_ln" ] && [ "$pack_ln" -lt "$inst_ln" ]; then
    pass "existing snapshot + yes: stop -> snapshot -> restart order"
else
    fail "existing snapshot + yes: stop -> snapshot -> restart order (order: $(tr '\n' ' ' < "$ORDER"))"
fi

: > "$ORDER"; SNAP_NEW=n; cmd_snapshot
if ! grep -q '^SNAPSHOT_PACK_CALLED$' "$ORDER" && ! grep -q '^STOP_CALLED$' "$ORDER"; then
    pass "existing snapshot + no: keeps it, nothing created"
else
    fail "existing snapshot + no: keeps it, nothing created (order: $(tr '\n' ' ' < "$ORDER"))"
fi

: > "$ORDER"; SNAP_NEW=y; SNAP_STOP=n; cmd_snapshot
if grep -q '^SNAPSHOT_PACK_CALLED$' "$ORDER" && ! grep -q '^STOP_CALLED$' "$ORDER"; then
    pass "existing snapshot: yes to new, no to stop -> snapshot without stopping"
else
    fail "existing snapshot: yes to new, no to stop -> snapshot without stopping"
fi

: > "$ORDER"; snapshot_stdin_tty() { return 1; }; SNAP_NEW=n; SNAP_STOP=n; cmd_snapshot
if grep -q '^SNAPSHOT_PACK_CALLED$' "$ORDER" && ! grep -q '^STOP_CALLED$' "$ORDER"; then
    pass "non-interactive: no prompts even with existing snapshot"
else
    fail "non-interactive: no prompts even with existing snapshot"
fi

: > "$ORDER"; snapshot_stdin_tty() { return 0; }; SNAPSHOT_KEEP_RUNNING=true; SNAP_NEW=y; SNAP_STOP=y; cmd_snapshot
if grep -q '^SNAPSHOT_PACK_CALLED$' "$ORDER" && ! grep -q '^STOP_CALLED$' "$ORDER"; then
    pass "--keep-running: no stop prompt"
else
    fail "--keep-running: no stop prompt"
fi
SNAPSHOT_KEEP_RUNNING=false

: > "$ORDER"; DRY_RUN=true; SNAP_NEW=n; SNAP_STOP=n; cmd_snapshot
if grep -q '^SNAPSHOT_PACK_CALLED$' "$ORDER" && ! grep -q '^STOP_CALLED$' "$ORDER"; then
    pass "dry-run: no prompts"
else
    fail "dry-run: no prompts"
fi
DRY_RUN=false

: > "$ORDER"; LATEST_ARC=""; SNAP_NEW=n; SNAP_STOP=n; cmd_snapshot
if grep -q '^SNAPSHOT_PACK_CALLED$' "$ORDER" && ! grep -q '^STOP_CALLED$' "$ORDER"; then
    pass "no existing snapshot: confirm skipped, no to stop proceeds"
else
    fail "no existing snapshot: confirm skipped, no to stop proceeds"
fi
rm -f "$ORDER"
unset -f cmd_snapshot snapshot_running_on_data_dir snapshot_stdin_tty resolve_paths yesno cmd_stop snapshot_pack node_is_external service_install external_start snapshot_latest_archive snapshot_archive_stamp

# 15b. snapshot_archive_stamp parses the timestamped archive name (real function)
eval "$(sed -n '/^snapshot_archive_stamp()/,/^}/p' lib/snapshot.sh)"
if [ "$(snapshot_archive_stamp "dero-mainnet-20260817-0112-h123456.tar.zst")" = "2026-08-17 01:12" ]; then
    pass "snapshot_archive_stamp parses timestamped name"
else
    fail "snapshot_archive_stamp parses timestamped name"
fi
unset -f snapshot_archive_stamp

# 15c. Restore prompt-to-start: after a successful restore, cmd_restore offers
# to start the node (interactive + no --yes only; failures never start).
eval "$(sed -n '/^cmd_restore()/,/^}/p' node.sh)"
resolve_paths() { :; }
snapshot_stdin_tty() { return 0; }
yesno() { echo "$REST_ANS"; }
snapshot_restore() { echo "RESTORE_CALLED" >> "$ORDER"; return 0; }
cmd_start() { echo "START_CALLED" >> "$ORDER"; return 0; }
C_INFO=''; C_ERR=''
SNAPSHOT_YES=false
ORDER="$(mktemp)"

REST_ANS=y; cmd_restore
rest_ln=$(grep -n '^RESTORE_CALLED$' "$ORDER" | cut -d: -f1)
start_ln=$(grep -n '^START_CALLED$' "$ORDER" | cut -d: -f1)
if [ -n "$rest_ln" ] && [ -n "$start_ln" ] && [ "$rest_ln" -lt "$start_ln" ]; then
    pass "restore + yes: restores then starts the node"
else
    fail "restore + yes: restores then starts the node (order: $(tr '\n' ' ' < "$ORDER"))"
fi

: > "$ORDER"; REST_ANS=n; cmd_restore
if grep -q '^RESTORE_CALLED$' "$ORDER" && ! grep -q '^START_CALLED$' "$ORDER"; then
    pass "restore + no: restores without starting"
else
    fail "restore + no: restores without starting"
fi

: > "$ORDER"; snapshot_stdin_tty() { return 1; }; REST_ANS=y; cmd_restore
if grep -q '^RESTORE_CALLED$' "$ORDER" && ! grep -q '^START_CALLED$' "$ORDER"; then
    pass "restore non-interactive: no start prompt"
else
    fail "restore non-interactive: no start prompt"
fi

: > "$ORDER"; snapshot_stdin_tty() { return 0; }; SNAPSHOT_YES=true; REST_ANS=y; cmd_restore
if grep -q '^RESTORE_CALLED$' "$ORDER" && ! grep -q '^START_CALLED$' "$ORDER"; then
    pass "restore --yes: no start prompt"
else
    fail "restore --yes: no start prompt"
fi
SNAPSHOT_YES=false

: > "$ORDER"; snapshot_restore() { echo "RESTORE_FAILED" >> "$ORDER"; return 1; }
if ( cmd_restore ) 2>/dev/null; then
    fail "restore failure: no start prompt"
else
    if grep -q '^RESTORE_FAILED$' "$ORDER" && ! grep -q '^START_CALLED$' "$ORDER"; then
        pass "restore failure: no start prompt"
    else
        fail "restore failure: no start prompt"
    fi
fi
rm -f "$ORDER"
unset -f cmd_restore resolve_paths snapshot_stdin_tty yesno snapshot_restore cmd_start

echo ""
echo "=== results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
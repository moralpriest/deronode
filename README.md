# deronode — all-in-one DERO node installer & manager

Install, update, and run a **derod** (DERO daemon) node on Linux, macOS, or
Windows — derod only, no explorer/wallet/miner. Downloads the latest release
from [DEROFDN/derohe](https://github.com/DEROFDN/derohe) and verifies it
against the release `checksum.txt`.

## Install with AI

Copy the prompt below into your agent to have it install and start a node
non-interactively.

```markdown
Install deronode (a full sibling of deromine) by running:

    curl -fsSL https://raw.githubusercontent.com/moralpriest/deronode/main/install.sh | bash

Then configure and start a pruned node (fast-sync, ~50 GB, VPS-friendly):

    deronode --integrator-address=<YOUR_DERO_ADDRESS> --sync-profile=pruned start --service

Explain what happened: which derod release was fetched (from
DEROFDN/derohe latest), where it was installed (~/.local/share/deronode), the
data/log dirs, and how to check sync:

    deronode status
```

> Replace `<YOUR_DERO_ADDRESS>` with a `dero1...`/`deroi1...` address. If you
> leave the integrator address empty, integrator-block rewards go to the
> upstream dev address.

## Quick install (manual)

**Linux / macOS** (PowerShell 7 preferred, bash fallback automatic):

```bash
curl -fsSL https://raw.githubusercontent.com/moralpriest/deronode/main/install.sh | bash
deronode
```

**Windows / any OS with PowerShell:**

```powershell
irm https://raw.githubusercontent.com/moralpriest/deronode/main/install.ps1 | iex
deronode
```

Idempotent: re-running pulls the latest version and never touches your chain
data, `config.json`, or logs (all gitignored).

## Usage

```
deronode                        interactive menu
deronode start                  run derod in the foreground
deronode start --service        install + start a background service
deronode stop                   stop derod
deronode status                 sync height, peers, binary tag, paths
deronode update                 update derod: --source=release (default) or --source=dev
deronode build                  compile the latest community-dev source branch (needs Go)
deronode snapshot               create a privacy-hardened tar.zst of the chain state
deronode restore --from=<file>  restore chain state from a snapshot (stops the node)
deronode resync                 wipe the chain and re-bootstrap via --fastsync
deronode logs                   tail the node log live (Ctrl-C to stop)
deronode --reconfigure          re-run the first-run prompts (incl. data-dir / log-dir)
deronode --dry-run              resolve nothing; print the derod command line
deronode --help                 full flag reference
```

Every derod flag works as a CLI override and is persisted to `config.json`.
Both `--flag=value` and `--flag value` are accepted.

The interactive menu (`deronode` with no arguments) returns to the menu after
each action completes — stop, status, update, build, snapshot, restore, resync,
logs, even foreground `start` (once the node exits) — so you stay in the menu
until you press `q`.

### Building from source (community-dev)

`deronode update` also takes a source choice: `--source=release` (default,
release download) or `--source=dev` (compile the latest community-dev). The
menu's "Update derod" option asks `1) Latest release (download)` vs
`2) community-dev source (compile)` before running.

`deronode build` (menu option 6) compiles derod from the latest
[DEROFDN/derohe](https://github.com/DEROFDN/derohe) **`community-dev`** branch
with your local Go toolchain (`go build ./cmd/derod`), then installs the binary
into `bin/derod/derod` exactly like a release download. It shallow-clones the
branch into `bin/src/derohe` (kept for incremental rebuilds — later `build`
runs just fetch + reset), needs Go 1.17+ (`https://go.dev/dl/`), and restarts
a running node after the build, mirroring `update`.

A source-built binary is marked and kept: `start`/`status` never silently
replace it with a release download, so a community-dev node stays on
community-dev until you explicitly run `deronode update --source=release`
(which swaps back to the latest release; `--source=dev` rebuilds instead).
`status` shows the binary as `community-dev@<commit>`. Build refuses on
externally-managed (system-installed) nodes.

`deronode logs` (menu option 12) tails the node's log live: derod's own
structured `derod.log` (written via `--log-dir`) when present, otherwise the
newest of the stdout/stderr captures (`derod.out.log`/`derod.err.log`) that
launchd / background backends write. If nothing exists yet it exits 1 and
suggests the right stream (`journalctl --user -u deronode.service -f` for the
systemd console output). Ctrl-C stops the tail; from the menu it returns to
the prompt.

First-run setup asks a **run mode** question — `1) Background system service`
(auto-start on boot) or `2) Foreground` — so the node can be installed as a
service on any OS without needing to remember `--service`. Answering `1`
installs and starts a systemd user unit on Linux, a LaunchAgent on macOS, or a
background process on Windows; `2` runs in the terminal. The same question is
re-asked by `--reconfigure`/menu option 7.

### Snapshots

`deronode snapshot` packs only the chain state needed to resync:
`balances/`, `bltx_store/`, and `topo.map`. Peer lists, ban lists, and any
config files are **never** included, so no identity or PII leaves the box.
Output is a standard `dero-mainnet-YYYYMMDD-HHMM[-h<height>].tar.zst` plus a
`.sha256` checksum and a chain-facts-only `.manifest.json` (artifact, timestamps,
height, sizes, includes/excludes — no hostname, node tag, or IP).

```bash
deronode snapshot                        # zstd level 10 -> <install>/snapshots
deronode snapshot --max-ratio            # level 19 (smaller, slower)
deronode snapshot --out=/mnt/backup      # explicit output dir
deronode snapshot --keep-running         # allow while derod runs on this data dir
deronode restore --from=./dero-mainnet-20260815-0001.tar.zst   # refuses while any derod runs
```

Restore moves the current chain to `chain.bak-<timestamp>`, verifies the
archive checksum (skips only with explicit confirmation), and extracts with
`rargz` when installed, else plain `tar --zstd`. Keep the `.bak` until the node
reaches the snapshot height, then delete it manually.

### Common examples

```bash
# Off-host miners (open 10100/tcp on the firewall):
deronode start --service --getwork-bind=0.0.0.0:10100

# Full archival node, chain on another disk:
deronode --sync-profile=full --data-dir=/mnt/ssd/dero-chain --log-dir=/mnt/ssd/dero-logs start --service

# Testnet (default ports swap to 40400/40401/40402):
deronode --testnet start

# Repeatable raw passthrough for flags deronode does not model yet:
deronode --extra-arg=--rpc-public --extra-arg=--tor-port=9051 start
```

## Configuration

`config.json` (written on first run / `--reconfigure`) maps to the 20 derod
flags in `DEROFDN/derohe` Release 152. Omitted keys are NOT passed to derod,
so upstream defaults apply.

| Key | derod flag | Default |
|-----|-----------|---------|
| `integrator_address` | `--integrator-address` | *(empty = dev address)* |
| `sync_profile` | shortcut → `--fastsync` / `--prune-history` | `pruned` |
| `fastsync` | `--fastsync` | `true` |
| `prune_history` | `--prune-history` | `100000` |
| `node_tag` | `--node-tag` | *(empty)* |
| `getwork_bind` | `--getwork-bind` | `127.0.0.1:10100` |
| `data_dir` | `--data-dir` | `~/.local/share/deronode/chain` |
| `log_dir` | `--log-dir` | `~/.local/share/deronode/logs` |
| `rpc_bind` | `--rpc-bind` | `127.0.0.1:10102` |
| `p2p_bind` | `--p2p-bind` | `0.0.0.0:10101` |
| `min_peers` / `max_peers` | `--min-peers` / `--max-peers` | *(unset)* |
| `socks_proxy` | `--socks-proxy` | *(empty)* |
| `add_priority_node` | `--add-priority-node` (repeatable) | `[]` |
| `add_exclusive_node` | `--add-exclusive-node` (repeatable) | `[]` |
| `clog_level` / `flog_level` | `--clog-level` / `--flog-level` | *(unset)* |
| `testnet` | `--testnet` | `false` |
| `debug` | `--debug` | `false` |
| `time_is_in_sync` | `--timeisinsync` | `false` |
| `sync_node` | `--sync-node` | `false` |
| `extra_args` | raw passthrough (repeatable) | `[]` |
| `snapshot_dir` | snapshot output dir | `<install>/snapshots` |
| `snapshot_level` | snapshot zstd level | `10` |

With `testnet: true`, default binds move to `40400`/`40401`/`40402`
automatically. `sync_profile` is a convenience shortcut only:
`pruned` → fastsync + prune 100000, `full` → neither, `none` → neither with
no prune. Explicit `--fastsync`/`--prune-history` flags win over the profile.

Both flags are **bootstrap-aware** — derod only honors `--fastsync` while the
chain is fresh, and refuses to prune an empty chain:

- **Fresh chain** (no `topo.map` yet): `--fastsync` is passed; `--prune-history`
  is **deferred** with a warning (derod exits with `We need atleast 50 blocks
  to prune` on an empty chain).
- **Chain already has blocks** (`topo.map` exists): `--fastsync` is **skipped**
  with a warning — it would only redo the bootstrap — and pruning applies.

So the first start bootstraps via fastsync, and later starts just resume + prune.
`resync` wipes the chain and forces exactly the fresh `--fastsync` bootstrap
(confirmations skipped with `--yes`).

`--prune-history` is also **once-per-chain**: derod's prune is a full rewrite of
`balances` (a multi-hour block-by-block replay on a synced chain), and it re-runs
it on *every* start that passes the flag. deronode detects an already-pruned
chain from `bltx_store` (block files are `<hash>.block_<diff>_<ver>_<height>`;
a completed prune deletes everything below the prune point, leaving only the
genesis block at height 0 plus a rolling window of recent blocks near the tip)
and **skips the flag** with a warning — restarting a pruned node no longer
redoes the rewrite. The lowest *non-genesis* height still on disk is the prune
floor (genesis is always kept, so it is excluded). Raise `--prune-history` (or
`resync`) to force a deeper prune.

## Sync profiles

| Profile | Flags | Disk (blockchain only) |
|---------|-------|------------------------|
| **Pruned** (recommended, VPS) | `--fastsync --prune-history=100000` | ~50 GB |
| **Full archival** | (no prune, full history from genesis) | 230 GB+, plan 500 GB |

## How it works

- `deronode` launcher prefers PowerShell 7 (`node.ps1`) and falls back to bash
  (`node.sh`) on Termux / minimal systems. `deronode.cmd` does the same on
  Windows.
- `install.sh` / `install.ps1` clone the repo into `~/.local/share/deronode`,
  symlink the launcher onto `PATH` (`~/.local/bin`, `$PREFIX/bin` on Termux),
  and are fully idempotent. `DERONODE_SKIP_PWSH=1` / `DERONODE_AUTO_INSTALL_PWSH=1`
  control PowerShell auto-install.
- `catalog.json` maps OS/arch → GitHub release archive; `lib/download.sh`
  resolves the latest tag, verifies `checksum.txt`, extracts only `derod`
  (validated by ELF/Mach-O/MZ magic), and caches it as `bin/derod/derod`.
  The downloaded archive is kept in `bin/archives/<tag>/`, so re-installing or
  re-updating the same release reuses the cached file instead of downloading
  the ~44 MB archive again (still re-verified against `checksum.txt`).
- Service backends: systemd **user** unit (`~/.config/systemd/user/deronode.service`),
  macOS LaunchAgent (`org.deronode.derod`), nohup+pid fallback.

## Troubleshooting

- **Node shows `stopped` but you started it with `--service`**: check
  `systemctl --user status deronode` or the log at
  `~/.local/share/deronode/logs/derod.log`.
- **Sync stuck / slow**: confirm disk space (`df -h`), then `deronode stop`
  and `deronode --prune-history=50000 start --service`.
- **Fastsync crash `We need atleast 50 blocks to prune`**: this is derod
  refusing to prune an empty chain. Either just re-run `deronode start` (a
  fresh chain now bootstraps without the prune flag), or start over cleanly
  with `deronode resync`.
- **Miner can't reach the node**: run with `--getwork-bind=0.0.0.0:10100`
  and open TCP 10100 on the firewall.
- **Checksum warnings**: deronode verifies `checksum.txt` when present and
  warns on mismatch but still installs; verify manually before opening ports.

## Development

```bash
bash scripts/smoke-test.sh        # bash path + catalog/config/argv/checksum/snapshot
pwsh scripts/smoke-test.ps1       # PowerShell path
DERONODE_LIVE=1 bash scripts/smoke-test.sh   # includes a real ~45 MB download
```

Repo layout:

```
catalog.json        OS/arch → DEROFDN release assets
config.example.json config schema (24 keys incl. snapshot)
deronode            unified launcher (pwsh-first, bash fallback)
deronode.cmd        Windows launcher
node.sh / node.ps1  runners (bash + PowerShell)
install.sh / install.ps1  one-line installers (idempotent)
lib/                platform, ui, config, download, build, rpc, service, snapshot
scripts/smoke-test.* non-interactive verification
scripts/snapshot.* / restore.*  standalone snapshot/restore wrappers
```
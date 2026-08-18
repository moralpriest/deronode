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
deronode uninstall              remove derod + all node data (binary, chain, logs,
                                 snapshots, config); keeps deronode itself
                                 (prompts for confirmation; --yes skips it)
deronode send [<archive>]        share a snapshot (or any file) via thruflux
                                  — prints a join code (fast, encrypted QUIC
                                  P2P); defaults to the newest snapshot (menu option 13)
                                  (thruflux CLI: https://github.com/samsungplay/Thruflux)
deronode receive <code>          receive a thruflux transfer into --out (default .);
                                  menu option 14 prompts for the join code instead
deronode --reconfigure          re-run the first-run prompts (incl. data-dir / log-dir)
deronode --dry-run              resolve nothing; print the derod command line
deronode --help                 full flag reference
```

Every derod flag works as a CLI override and is persisted to `config.json`.
Both `--flag=value` and `--flag value` are accepted.

The interactive menu (`deronode` with no arguments) returns to the menu after
each action completes — stop, status, update, build, snapshot, restore, resync,
logs, uninstall, send, even foreground `start` (once the node exits) — so you
stay in the menu until you press `q`.

### Building from source (community-dev)

`deronode update` also takes a source choice: `--source=release` (default,
release download) or `--source=dev` (compile the latest community-dev). The
menu's "Update derod" option asks `1) Latest release (download)` vs
`2) community-dev source (compile)` before running.

Before replacing the current binary, both update paths (release download and
source build — plus the external-node path) copy it to
`derod.bak-YYYYMMDD_HHMMSS` next to the new binary, so a bad update is always
reversible; the previous binary is never silently destroyed. Only the newest
3 backups are kept — older `derod.bak-*` files are pruned automatically.

`deronode build` (menu option 6) compiles derod from the latest
[DEROFDN/derohe](https://github.com/DEROFDN/derohe) **`community-dev`** branch
with your local Go toolchain (`go build ./cmd/derod`), then installs the binary
into `bin/derod/derod` (Windows: `derod.exe`) exactly like a release download.
It shallow-clones the branch into `bin/src/derohe` (kept for incremental
rebuilds — later `build` runs just fetch + reset), needs Go 1.17+
(`https://go.dev/dl/`), and restarts a running node after the build, mirroring
`update`. The executable-magic sanity check accepts both ELF (`7f454c46`) and
PE (`MZ` = `4d5a...`) binaries, so builds work on Windows too.

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
re-asked by `--reconfigure`/menu option 8. After the first-run download+install
finishes, it asks **"Bootstrap the chain"** — choose between a fresh sync from
genesis (fastsync), restoring from a local snapshot (`.tar.zst`), or receiving
a snapshot via thruflux (join code). A fresh sync then asks **"Start the node
now?"** before launching (piped/scripted runs skip the prompt). On Windows the
binary is `derod.exe` — an extensionless file can't be executed there and would
pop the "How do you want to open this file?" dialog instead of starting the node.

### Snapshots

`deronode snapshot` packs only the chain state needed to resync:
`balances/`, `bltx_store/`, and `topo.map`. Peer lists, ban lists, and any
config files are **never** included, so no identity or PII leaves the box.
Output is a standard `dero-mainnet-YYYYMMDD-HHMM[-h<height>].tar.zst` plus a
`.sha256` checksum and a chain-facts-only `.manifest.json` (artifact, timestamps,
height, sizes, includes/excludes — no hostname, node tag, or IP).

If a snapshot already exists, an interactive run presents the newest one with
its timestamp and confirms before creating another
(`Latest snapshot: dero-mainnet-20260817-0112.tar.zst (2026-08-17 01:12) —
create a new one? [Y/n]`). Archives are timestamped, so a new snapshot never
overwrites the old one; declining keeps the existing archive and creates
nothing. The prompt only appears on an interactive terminal — piped or
scripted runs pack straight away.

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

Once the restore completes, an interactive run asks
`Restore complete. Start the node now? [Y/n]` (default yes) and launches the
node — external installs via their systemd unit, managed ones via the normal
start path. Restore refuses while any derod runs, so the node is guaranteed
stopped at that point. The prompt only appears on an interactive terminal and
never with `--yes`, so scripted restores restore and leave the node stopped,
as before.

### Sending a snapshot to a friend

`deronode send` shares your latest snapshot (or any file: `deronode send
<path>`) with anyone, over the internet, fast and encrypted — it shells out to
[thruflux](https://github.com/samsungplay/Thruflux), a peer-to-peer QUIC file
transfer CLI. The sender runs `thru host <archive>` (which deronode invokes)
and gets a high-entropy join code; the friend runs `thru join <code>` — or
`deronode receive <code>` — on any OS and downloads directly peer-to-peer
(ICE NAT traversal with TURN fallback; nothing is uploaded to a cloud).
Thruflux uses encrypted QUIC streams with WSS signaling, so the transfer is
secure against MITM and the relay never sees plaintext. For guaranteed
capacity you can self-host the signaling server (`thru server`).

```bash
deronode send                     # newest snapshot -> join code to share
deronode send /path/to/file.bin   # any file, same flow
deronode receive ABCDEFGH         # receiver side; files land in ./ (or --out <dir>)
                                   # also menu option 14 — it asks for the join code
```

`deronode send` hosts the snapshot's `.sha256` and `.manifest.json` alongside
the archive (thruflux supports any number of files in one session), so the
receiver gets everything in a single transfer and the checksum verifies
automatically. After `deronode receive` completes, an interactive run
detects a deronode snapshot (`dero-mainnet-*.tar.zst`) in the received files
and asks to restore it right away: if derod is running it offers to stop it,
restore, then restart (mirroring the snapshot flow); if the node is already
stopped it runs the normal restore confirmation and offers to start it
afterwards. Piped/scripted runs never touch the node — they print the
received snapshot name and the `deronode restore --from <path>` command to
run later.

`thru` must be installed once per machine. When it's missing, deronode asks
**"Install thruflux now?"** (default yes) and downloads the static binary
itself into `~/.local/bin` on confirmation (raising UDP buffers to 16 MiB
best-effort on Linux) — scripted/piped runs never install unattended and
just print the manual download hint. deronode fetches the binary directly
from `raw.githubusercontent.com` because the upstream one-line installers
currently 404: they download `thru` from a
`github.com/.../raw/refs/heads/main/...` URL that GitHub no longer serves
for large blobs. Manual install, if you prefer:

```bash
# Linux:   curl -fsSL https://raw.githubusercontent.com/samsungplay/Thruflux/main/frontend/binaries/linux/thru_linux \
#            -o ~/.local/bin/thru && chmod +x ~/.local/bin/thru
# macOS:   curl -fsSL https://raw.githubusercontent.com/samsungplay/Thruflux/main/frontend/binaries/macos/thru_mac \
#            -o ~/.local/bin/thru && chmod +x ~/.local/bin/thru
# Windows: curl -fsSL https://raw.githubusercontent.com/samsungplay/Thruflux/main/frontend/binaries/windows/thru_windows.exe \
#            -o ~/.local/bin/thru.exe
```

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

### Uninstall

`deronode uninstall` (menu option 15) removes the managed node completely:
it stops derod, deletes the service unit (systemd user unit / LaunchAgent /
pid fallback), and removes the binary, chain data, logs, snapshots, and
`config.json`. deronode itself stays installed — the next run shows the
fresh "No derod installed yet" first-run screen, so you can re-configure a
brand-new node. It refuses on externally-managed nodes (an external derod is
installed elsewhere and we never touch data we don't own). The wipe is
confirmed interactively (`--yes` skips the confirmation), supports
`--dry-run`, and uninstall from the menu returns to the first-run screen
instead of quitting.

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
- **Service fails under PowerShell on Linux** (`status=203/EXEC`, or a
  `Start-Process -WindowStyle ... not supported` error): both are fixed — the
  background wrapper is written with a pwsh shebang + exec bit, and the pid
  fallback no longer passes `-WindowStyle` off Windows. Just re-run
  `deronode start --service`; a `degraded` systemd session no longer demotes
  to the pid fallback either.
- **`start --service` when it's already a service**: re-running is safe and
  idempotent — it reports `deronode.service is already configured and running`
  (or `- starting it` if installed but stopped) instead of re-installing, and
  it does so without printing the fastsync/prune warnings (nothing is being
  started). The wrapper is rewritten with the current flags whenever it
  actually installs or starts.
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
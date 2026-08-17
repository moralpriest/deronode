# Manual testing guide

The tool ships two automated suites (bash + PowerShell) and is validated end-to-end.
This guide walks through the manual checks so you can see each behavior yourself.

The mainnet node runs on ports 10100/10102 supervised by systemd
(`derod.service`). Manual live tests below never touch it unless you
explicitly stop it first.

## 1. Offline (no network, no mainnet impact)

```bash
cd ~/Projects/deronode

# Full smoke suites — self-contained, wipe and recreate their own bin/
bash scripts/smoke-test.sh              # expect: 173 passed, 0 failed
pwsh -NoProfile -File scripts/smoke-test.ps1   # expect: 144 passed, 0 failed

# Dry-run — offline proof: prints the exact derod argv, writes nothing
bash node.sh --dry-run --sync-profile=pruned --data-dir=/tmp/d1 --log-dir=/tmp/d2
pwsh ./node.ps1 --dry-run --sync-profile=full
```

After the dry-runs confirm: no `bin/`, no `config.json`, and no `/tmp/d1`
were created.

## 1b. Snapshot/restore smoke

The default snapshot dir is `<install>/snapshots` — the same tree as the
`bin/derod/derod` binary — not the old `~/Crypto/dero/snapshots` external-node
path. `snapshot_dir` in config.json (or `--out=`) still overrides it.
(Sections 6 bash / 6 ps cover the default + explicit override.)

Both suites include an offline snapshot fixture (section 11 bash / 6c ps):
it builds a fake chain dir (3 members + 5 decoy files), packs it, and asserts
the archive contains only `balances`/`bltx_store`/`topo.map`, the 5 identity
files are absent, the `.sha256` verifies, the manifest carries no identity
fields, dry-run writes nothing, the running guard refuses then `--keep-running`
overrides, and restore reproduces the includes while omitting decoys and
keeping a `.bak-<ts>`.

When the snapshot is triggered interactively while the node is running against
the data dir (e.g. menu option 9), the wrapper now prompts
`stop it, snapshot, then restart? [Y/n]`; answering yes stops the node, packs
the snapshot, then restarts it (external via its systemd unit, managed via
service install). The prompt only appears on an interactive terminal — piped or
scripted `deronode snapshot` calls never auto-stop and fall through to the
library guard, which keeps refusing unless `--keep-running` is passed.
(Sections 15 bash / 10 ps cover this prompt-to-stop flow.)

A second interactive guard sits in front of it: if a snapshot already exists in
the snapshot dir, the wrapper presents the newest one with its timestamp
(`Latest snapshot: dero-mainnet-20260817-0112.tar.zst (2026-08-17 01:12) —
create a new one? [Y/n]`). Answering no keeps the existing archive and creates
nothing — names are timestamped, so a new snapshot never overwrites the old
one. Non-interactive runs and `--dry-run` skip the prompt and pack directly.
(Sections 15 bash / 10 ps cover the confirm flow; 15b also unit-tests the
timestamp parsing of `snapshot_archive_stamp`.)

After a successful restore, an interactive run (without `--yes`) asks
`Restore complete. Start the node now? [Y/n]` and starts the node — external
installs via their systemd unit, managed ones via the normal start path.
Restore refuses while any derod runs, so the node is always stopped at that
point. Piped/scripted restores and `--yes` skip the prompt and leave the node
stopped. (Section 15c bash / 10 ps cover the start prompt: yes, no,
non-interactive, `--yes`, and a failed restore never starting.)

For an externally-installed derod (systemd unit), the snapshot/restore target is
auto-resolved to the external node's real data dir — the running process's cwd,
or the unit's `WorkingDirectory=` (fallback `--data-dir=` from ExecStart) when
stopped — instead of deronode's configured `data_dir`. This fixes the failure
where snapshot tars an empty scaffold and reports a bare `[x] snapshot failed`.
`snapshot_pack` now pre-validates that `balances`/`bltx_store`/`topo.map` exist
in the resolved chain dir and names any missing member in its error.
(Sections 11 bash / 6c ps cover external data-dir resolution and the
missing-member pre-check.)

`restore` without `--from` auto-picks the newest `dero-mainnet-*.tar.zst` in the
snapshot dir and reports which archive it chose; it errors with `no snapshot
found in <dir>` when the dir is empty. (Sections 11 bash / 6c ps cover both.)

Every command/flag also works on macOS and Windows, not just Linux:

- **PowerShell 5.1 + Core**: `lib/platform.ps1` computes `$script:IsWindows/`
  `IsLinux/IsMacOS` via `Set-Variable` because plain `$script:IsWindows = ...`
  throws on PS 6+ (the auto-vars are read-only constants there) and the vars
  don't exist on 5.1. `Get-PwshPlatform` uses the script-scoped forms.
- **External node on macOS**: `start`/`stop`/`update` route to the launchd
  agent (`launchctl kickstart/load/unload`, sudo for LaunchDaemons) and
  `Get-ExternalUnit`/`Test-ExternalSystemUnit`/`Get-ExternalDataDir` detect
  agents and read plist `WorkingDirectory`/`--data-dir` (bash +
  PowerShell). Our own `org.deronode.derod` agent is never treated as external.
- **External node on Windows**: the process table captures
  `Win32_Process.ExecutablePath`, so `Test-ExternalNode` and
  `Update-ExternalNode` resolve the running binary without `/proc`.
- **Portable process probes**: `derod_pid`/`process_exe`/`process_cwd` (bash)
  and `Get-ProcessExe`/`Get-ProcessCwd` (PS) use `/proc` on Linux, `lsof` on
  macOS, and CIM on Windows; `cmd_update_external` no longer hardcodes
  `derod-linux-amd64` or `/proc/<pid>/cgroup`.

New tests: bash section 11 adds `external_data_dir_from_plist`
(WorkingDirectory + `--data-dir` fallback) and source-greps that `external_unit`
excludes our launchd agent and `cmd_update_external` is portable; PS sections
4/6c/8 add `Get-DataDirFromPlist`, the `Set-Variable` guard, launchd routing in
`Start`/`Stop`/`Update-ExternalNode`, and the Windows `ExecutablePath` capture.

First-run flow: when the menu's "Configure & install derod" finishes the
download it asks **"derod installed. Start the node now?"** (interactive
only — piped/scripted runs skip the prompt) and, on yes, continues into
`start` (foreground or service per the run-mode answer) instead of bouncing
back to the menu prompt. (Sections 14 bash / 9 ps cover the prompt +
transition.)

Windows binary naming: on Windows the managed binary is `derod.exe`, not
`derod` — an extensionless file cannot be executed there (CreateProcess/
ShellExecute fail or pop the "How do you want to open this file?" dialog,
which silently broke the first-run auto-start). `node.ps1`/`node.sh` derive
`BinaryPath`/`BINARY_PATH` from the platform, and every install site
(download/build libs, cache-fresh check, status probe) uses that name.
`lib/platform.sh` also maps Git Bash / MSYS2 / MINGW / Cygwin unames to
`windows`. The executable-magic sanity check accepts PE binaries too: magic
is the first **four** bytes hexed, so the `MZ` check is a `4d5a*` prefix
match, not an exact `4d5a` one — previously every Windows build/download
failed with "failed the executable magic check". (Sections 14 bash / 9 ps
cover the naming + magic fix greps.)

Prune round-trip: an explicit `"prune_history": null` in config.json means
"no --prune-history flag" (needed to bootstrap a fresh chain — derod exits
with `Error pruning blockchain: We need atleast 50 blocks to prune` when asked
to prune an empty chain). `lib/config.sh` previously re-coerced the saved null
back to 100000 via `// 100000`; it now distinguishes absent (default 100000)
from explicit null (no flag), matching `config.ps1`. (Sections 6 bash / 6 ps
cover the null round-trip.)

Fresh-chain flag balancing: both fastsync and prune are bootstrap-aware and
keyed off the chain dir's `topo.map`. When the chain dir has no `topo.map` yet
(fresh chain), `build_derod_argv`/`Build-DerodArgv` pass `--fastsync` and drop
`--prune-history` with a warning — derod refuses to prune <50 blocks and would
exit instead of bootstrapping. Once `topo.map` exists (chain has blocks), the
opposite happens: `--prune-history` applies and `--fastsync` is dropped with a
warning, because fastsync is a bootstrap-only flag and re-running it on a
synced chain redoes the bootstrap — the fix for "starting the node re-runs
fastsync every time". Use `deronode resync` to force a fresh fastsync
bootstrap. (Sections 7 bash / 6 ps cover the argv balancing, including the
dry-run: fresh dir keeps `--fastsync`, established dir skips it.)

Prune is also once-per-chain: derod's `--prune-history` is a full rewrite of
`balances` (hours of block-by-block replay on a synced chain) that re-runs on
every start passing the flag. `build_derod_argv`/`Build-DerodArgv` now detect an
already-pruned chain from `bltx_store` — derod names block files
`<hash>.block_<diff>_<ver>_<height>`, and a completed prune deletes everything
below the prune point, leaving only the genesis block (height 0) plus a rolling
window of recent blocks near the tip. `chain_min_block_height`/
`Get-ChainMinBlockHeight` therefore take the minimum `height` field *excluding*
genesis (height 0 is always kept, so including it would make every pruned chain
look unpruned), and the flag is skipped with a warning when that floor is
already at/above `prune_history - 1000`. (Sections 7 bash / 6 ps cover both the
pruned-chain skip and the unpruned-chain keep; the fixtures include a genesis
block at height 0 to match real pruned chains.)

Build from source: `deronode build` (menu option 6) compiles the latest
DEROFDN/derohe **`community-dev`** branch with the local Go toolchain
(`go build ./cmd/derod`) and installs the binary into `bin/derod/derod`, same
as a release download. It shallow-clones into `bin/src/derohe` (later builds
just fetch + reset), guards on Go 1.17+ being installed, restarts a running
node after building (mirroring `update`), and refuses on externally-managed
nodes. The install is marked via `bin/derod/.asset` = `community-dev`:
`start`/`status` keep it (a source build is always "fresh" to
`cached_tag_fresh`/`Test-CacheFresh`), while an explicit `update` skips those
short-circuits and swaps back to the latest release. (Sections 14 bash / 9 ps
cover the parse/menu/dispatch wiring and the keep-vs-swap logic.)

`update` itself takes a **source choice**: `deronode update --source=dev`
routes through the community-dev compile path (identical to `build`), while
the default `--source=release` fetches the release download. The menu's
"Update derod" option (5) asks `1) Latest release (download)` vs
`2) community-dev source (compile)` before dispatching. (Sections 6 + 14 bash
/ 6 + 9 ps cover the `--source` parse and the dev-source routing.)

Resync command: `deronode resync` (menu option 11) wipes the chain data and
re-bootstraps via `--fastsync` — the "start over" path for a broken or unwanted
chain. It confirms first (`--yes` skips), stops a running node, deletes the
chain dir, forces `fastsync: true` + `prune_history: null` in the config, then
continues into `start`. Refuses on externally-managed nodes, and `--dry-run`
only prints the plan. (Sections 14 bash / 9 ps cover the wiring and wipe logic.)

Reconfigure continues into start: after `--reconfigure`/menu option 7 finishes
asking questions, it continues straight into `start` (like first-run install)
instead of printing "Done. Run 'deronode start' to launch." — unless derod is
already running, in which case it tells you to stop it first. (Sections 14
bash / 9 ps cover both branches.)

Run mode is part of the install questions: `configure`/`Configure` ends with a
"Run mode" prompt — `1) Background system service` (auto-start on boot) or
`2) Foreground` — and the answer feeds the existing `AS_SERVICE`/`AsService`
flag, so the node is installed as a systemd user unit (Linux), LaunchAgent
(macOS), or background process (Windows) right from first-run instead of only
via `deronode start --service`. The first-run and reconfigure continuations
into `start` carry the answer through. (Sections 14 bash / 9 ps cover the
question + that first-run keeps the choice.)

Service install under PowerShell is portable to Linux: `Write-RunWrapper`
writes `run-derod.ps1` with a `#!/usr/bin/env pwsh` shebang + exec bit (no
`status=203/EXEC`) and splats the argv (`@derodArgs`) instead of a comma list,
which derod rejects with its usage screen. `Start-Background` only passes
`-WindowStyle` on Windows — PowerShell on Linux/macOS rejects the parameter —
and only writes `derod.pid` when a pid actually exists (a crashed start must
not leave a stale empty pid file that the running-guards treat as "running").
`Get-ServiceBackend`/`service_backend` keep systemd for `degraded` sessions (a
failed *unrelated* unit must not demote to the pid fallback); only an
unreachable/offline bus falls back. `systemctl --user start` failures are now
surfaced with a `journalctl --user -u deronode.service` hint instead of
printing success. (Section 1 ps greps the wrapper/backend wiring; 13c bash
stub-tests the backend detection.)

Service install is idempotent and quiet: when the unit file already exists,
`start --service` reports `deronode.service is already configured and running`
(or `... - starting it` when the unit is installed but stopped) instead of
re-installing. The macOS LaunchAgent gets the same treatment
(`org.deronode.derod is already configured...`), detected via `launchctl list`.
(13c bash + section 1 ps grep the launchd branch.) `Install-Service`/`service_install` check that state *before*
building the wrapper, so the fastsync/prune warnings don't print for a no-op
— and the argv is built there (not in `Start-Node`/`cmd_start`), so a service
start prints them once and only when it actually installs. Building the argv
inside `service_install` also fixes the update/build/snapshot restart paths,
which previously wrote the wrapper with a stale/empty argv. (Section 13d bash
stub-tests the three branches: running, stopped, not installed; section 1 ps
greps the wiring.)

Archive cache: `fetch_derod`/`Invoke-FetchDerod` keep the downloaded release
archive under `bin/archives/<tag>/` instead of deleting it after install. A
later install/update of the same tag reuses the cached file ("Reusing cached
…") — no re-download — while still re-verifying it against `checksum.txt`; a
corrupt cache fails the checksum and is discarded + re-fetched, and an offline
run falls back to the cached archive when `checksum.txt` can't be fetched.
(Section 13b bash covers the cache hit + corrupt-cache re-download; PS section
8 source-greps the wiring.)

Menu returns to the menu: `deronode` with no arguments is an interactive loop.
Every action is dispatched and then the menu is shown again — stop, status,
update, snapshot, restore, resync, logs, even foreground `start` (run as a
child, so the menu reappears when the node exits). Nonzero action exits are
swallowed in menu mode so a failure can't kick you out; only `q` quits. Plain
CLI invocations (`deronode start` etc.) keep their old single-shot exit
behavior. (Sections 14 bash / 9 ps cover the loop + menu-mode start.)

Logs command: `deronode logs` (menu option 12) tails the node log live —
derod's own structured `derod.log` (written via `--log-dir`) when present,
otherwise the newest of the stdout/stderr captures (`derod.out.log` /
`derod.err.log`) that launchd / background backends write. No log file yet →
exits 1 and suggests the right stream (`journalctl --user -u deronode.service
-f` for the systemd console output). `tail` follows live; Ctrl-C stops it and
menu mode returns to the prompt. (Sections 14 bash / 9 ps cover the
parse/menu/dispatch wiring and the tail-selection logic.)

Manual smoke against the real (stopped) node:

```bash
# stop the node first, then:
bash node.sh snapshot --out=/tmp/snap
ls -la /tmp/snap                            # .tar.zst + .sha256 + .manifest.json
cat /tmp/snap/*.manifest.json               # no hostname / node_tag / ip / user
tar -tf /tmp/snap/*.tar.zst                 # only balances/ bltx_store/ topo.map

# restore into a scratch data dir:
bash node.sh --data-dir=/tmp/restore-chain --log-dir=/tmp/restore-logs \
  restore --from=/tmp/snap/dero-mainnet-*.tar.zst --yes
ls /tmp/restore-chain/mainnet               # balances/ bltx_store/ topo.map only
```

Restore refuses while **any** derod runs (it replaces chain state); stop the
mainnet node first, or use `--keep-running` only for snapshots (never restore).

## 2. Live test (real download + real derod)

Your mainnet node occupies 10100/10102 via `derod.service`. Pick one:

### A. Stop mainnet first (cleanest — the validated path)

```bash
systemctl stop derod.service            # sim + monitor stay down; leave them

bash node.sh --config=/tmp/deronode-e2e.json \
  --integrator-address=<your-address> --sync-profile=full \
  --data-dir=/tmp/d1 --log-dir=/tmp/d2 start
bash node.sh --config=/tmp/deronode-e2e.json status   # "● running height X/Y"
bash node.sh --config=/tmp/deronode-e2e.json stop     # kills the test node
ss -tlnp | grep -E ':1010[012]'          # empty → test node gone

systemctl start derod.service           # restore mainnet
ss -tlnp | grep -E ':1010[012]'          # 10102 + 10100 back
```

### B. Keep mainnet running — non-conflicting ports

```bash
bash node.sh --config=/tmp/deronode-e2e.json \
  --rpc-bind=127.0.0.1:19102 --p2p-bind=0.0.0.0:19101 --getwork-bind=127.0.0.1:19100 \
  --sync-profile=full --data-dir=/tmp/d1 --log-dir=/tmp/d2 start
# status / stop as above; the config persists the custom ports,
# so later runs don't need them repeated.
```

## 3. Re-verify the two fixed bugs

- **Status detection:** run `status` while the test node is up — it must say
  `● running`. (The old `lib/rpc.sh` bug omitted `/json_rpc` and falsely showed
  `○ stopped` even when the daemon was live.)
- **Stop actually kills:** after `stop`, `pgrep -af derod-linux-amd64` must show
  only the mainnet pid (or none in option A before you `systemctl start`).
  (The old `service_stop` only acted in one backend branch and no-opped when no
  systemd unit existed.)

## 4. Checksum verification

`node.sh update` downloads the latest DEROFDN release and verifies it against
the release's `checksum.txt`, which ships 128-char SHA-512 hashes:

```bash
bash node.sh update
# expect: "[*] checksum verified against checksum.txt"
# (a "[!] checksum mismatch" warning means something is wrong — do not use the binary)
```

## Notes and gotchas

- First `start` on a fresh data dir bootstraps via fastsync; height climbs
  1-by-1 on a clean chain and `peers 0` is normal until seeds are reached.
  Later starts on the same chain drop `--fastsync` ("chain already bootstrapped
  … skipping --fastsync") — fastsync only runs while bootstrapping, never on
  an established chain.
- `--prune-history` on a fresh chain with fewer than ~50 blocks makes derod exit
  with "Error pruning blockchain: We need atleast 50 blocks to prune". deronode
  now defers the flag automatically on a fresh chain (see above), so a clean-dir
  start bootstraps fine; pruning applies on the next start once blocks exist.
- Clean up after a live test:

```bash
rm -rf /tmp/d1 /tmp/d2 /tmp/deronode-e2e.json
```
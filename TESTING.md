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
bash scripts/smoke-test.sh              # expect: 88 passed, 0 failed
pwsh -NoProfile -File scripts/smoke-test.ps1   # expect: 72 passed, 0 failed

# Dry-run — offline proof: prints the exact derod argv, writes nothing
bash node.sh --dry-run --sync-profile=pruned --data-dir=/tmp/d1 --log-dir=/tmp/d2
pwsh ./node.ps1 --dry-run --sync-profile=full
```

After the dry-runs confirm: no `bin/`, no `config.json`, and no `/tmp/d1`
were created.

## 1b. Snapshot/restore smoke

Both suites include an offline snapshot fixture (section 11 bash / 6c ps):
it builds a fake chain dir (3 members + 5 decoy files), packs it, and asserts
the archive contains only `balances`/`bltx_store`/`topo.map`, the 5 identity
files are absent, the `.sha256` verifies, the manifest carries no identity
fields, dry-run writes nothing, the running guard refuses then `--keep-running`
overrides, and restore reproduces the includes while omitting decoys and
keeping a `.bak-<ts>`.

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
- `--prune-history` on a fresh chain with fewer than ~50 blocks makes derod exit
  with "Error pruning blockchain: We need atleast 50 blocks to prune". That is a
  derod limitation, not a deronode bug — use `--sync-profile=full` for clean-dir
  tests.
- Clean up after a live test:

```bash
rm -rf /tmp/d1 /tmp/d2 /tmp/deronode-e2e.json
```
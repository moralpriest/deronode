# Snapshot roadmap (not implemented)

The current snapshot feature ships a single self-contained `.tar.zst` archive
(privacy-hardened: `balances/`, `bltx_store/`, `topo.map` only) with a `.sha256`
checksum and a chain-facts-only `.manifest.json`. Pack requires the `zstd` CLI;
restore extracts with `rargz` when present, else `tar --zstd`. This page tracks
ideas deliberately left out of v1.

## 1. Cloud upload (S3 / R2 / B2)

- Keep the manifest chain-facts-only as it is today; never add `hostname`,
  `node_tag`, `integrator_address`, or public IP even when uploading.
- A small sync CLI (next to `scripts/snapshot.sh|.ps1`) could:
  - upload `<archive>.tar.zst` + `.sha256` + `.manifest.json`
  - maintain a remote manifest with a pruning policy (keep last N)
  - support `--since=<height>` to only send deltas once chain storage is
    split into immutable shards (see 2)
- Credentials stay in the user's env / OS keyring — not in `config.json`.

## 2. Immutable sharded chain storage + delta snapshots

- Today `bltx_store` is rewritten in place, so a full re-pack is the safe move.
- If derod's chain files ever become append-only/immutable per block range,
  snapshot could:
  - shard `bltx_store` into `bltx_store/<range>.part` files
  - upload only new shards since the last snapshot height
  - store per-shard sha256 in the manifest (delta integrity)
- Until then, `snapshot` stays full + atomic (pack to `.tmp`, hash, rename).

## 3. rargz upstream PR (deferred)

- `fibnas/rargz` is used as the **optional** extractor: standard `.tar.zst`
  archives extract with plain `tar --zstd` when rargz is absent, so nothing is
  blocked on it.
- Reading rargz `src/main.rs`: the CLI takes a single positional `input`
  PathBuf and has no `--exclude`; its walker does not follow symlinked dirs and
  its tar builder writes deterministic headers. The privacy-mandatory exclude
  list is therefore impossible through rargz today — that is why v1 packs with
  GNU `tar --exclude`.
- Deferred PR idea (after this feature is tested): add `--exclude <glob>` and
  multi-path support to rargz so it can be the packer too. Not started yet.

## 4. Restore UX polish

- Auto-resume: after restore, `deronode start` should pick up the `.bak`
  cleanup task (delete `chain.bak-*` once the node reaches the manifest height).
- Dry-run restore preview (`--dry-run`) that prints what would be replaced
  without touching the chain dir.
- Mirror/verify command: re-check a downloaded archive's `.sha256` + manifest
  before it is used.

## Status

None of the above is implemented. v1 intentionally stops at a single,
self-contained, verifiable, privacy-hardened archive.

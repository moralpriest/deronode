#!/usr/bin/env bash
# scripts/snapshot.sh — standalone snapshot wrapper: `deronode snapshot`.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec bash ./node.sh snapshot "$@"
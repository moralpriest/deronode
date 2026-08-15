#!/usr/bin/env bash
# scripts/restore.sh — standalone restore wrapper: `deronode restore`.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec bash ./node.sh restore "$@"
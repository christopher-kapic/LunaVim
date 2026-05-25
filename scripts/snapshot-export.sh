#!/usr/bin/env bash
# Copy the current user's <config>/lazy-lock.json onto
# snapshots/default.json so the next run of :LvimSyncCorePlugins applies
# this exact commit set. Intended for maintainer use after verifying a
# fresh install — see snapshots/README.md.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: snapshot-export.sh [-h|--help]

Copy the current user's <config>/lazy-lock.json onto snapshots/default.json.

Environment:
  LUNAVIM_CONFIG_DIR  Source config dir (default: ~/.config/lvim)
  LUNARVIM_CONFIG_DIR Legacy alias for LUNAVIM_CONFIG_DIR
USAGE
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

CONFIG_DIR="${LUNAVIM_CONFIG_DIR:-${LUNARVIM_CONFIG_DIR:-"$HOME/.config/lvim"}}"
SRC="$CONFIG_DIR/lazy-lock.json"

# Resolve the snapshot destination relative to this script so the export
# works regardless of where the user invokes it from. `cd "$(dirname …)"`
# uses POSIX `cd`/`pwd` (no realpath dependency) to canonicalize the path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DST="$REPO_ROOT/snapshots/default.json"

if [[ ! -f "$SRC" ]]; then
  printf 'error: %s does not exist; run :Lazy sync first\n' "$SRC" >&2
  exit 1
fi

mkdir -p "$(dirname "$DST")"
cp "$SRC" "$DST"
printf 'wrote %s from %s\n' "$DST" "$SRC"

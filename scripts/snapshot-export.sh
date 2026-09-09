#!/usr/bin/env bash
# Copy the current user's <config>/lazy-lock.json onto
# snapshots/default.json so the next run of :LvimSyncCorePlugins applies
# this exact commit set. Intended for maintainer use after verifying a
# fresh install — see snapshots/README.md.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: snapshot-export.sh [-h|--help]

Copy the current user's <config>/lazy-lock.json onto snapshots/default.json,
filtered down to the plugins in LunaVim's own core spec.

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

# Filter the lock down to the core plugin spec before writing.
#
# `lazy-lock.json` records EVERY plugin lazy.nvim manages for the exporting
# maintainer, including anything they added through `lvim.plugins` in their own
# config.lua. Copying it verbatim is how `git-blame.nvim` and `mini.map` — two
# plugins in no LunaVim spec — ended up pinned in `snapshots/default.json` and
# shipped to every user of `:LvimSyncCorePlugins`.
#
# The allow-list is derived from `lua/lvim/plugins/spec.lua` at export time
# (rather than hardcoded here) so it cannot drift from the spec. We ask a
# headless Neovim for the key each entry occupies in the lock file, which is
# lazy.nvim's `plugin.name`: the explicit `name = "..."` when the spec sets one,
# otherwise the repo basename.
#
# nvim-treesitter is excluded on purpose. `spec.lua` selects its branch by
# Neovim version (`master` on 0.11, `main` on 0.12+), so a single pinned commit
# is wrong for one of the two supported versions — pinning a `main` commit and
# then restoring it onto a `master` checkout is exactly the failure this
# exclusion prevents. Parser and plugin updates flow through `:TSUpdate` and the
# spec's own branch selection instead.
ALLOW="$(
  nvim --headless -u NONE \
    --cmd "set rtp+=$REPO_ROOT" \
    -c 'lua
      local ok, spec = pcall(require, "lvim.plugins.spec")
      if not ok then
        vim.cmd("cquit 1")
      end
      local out = {}
      for _, entry in ipairs(spec) do
        local name = entry.name
        if not name then
          name = tostring(entry[1]):match("[^/]+$")
        end
        if name and name ~= "treesitter" then
          out[#out + 1] = name
        end
      end
      io.stdout:write(table.concat(out, "\n"))
    ' \
    -c q 2>/dev/null
)"

if [[ -z "$ALLOW" ]]; then
  printf 'error: could not derive the core plugin list from %s/lua/lvim/plugins/spec.lua\n' "$REPO_ROOT" >&2
  exit 1
fi

mkdir -p "$(dirname "$DST")"

ALLOW="$ALLOW" python3 - "$SRC" "$DST" <<'PYFILTER'
import json, os, sys

src, dst = sys.argv[1], sys.argv[2]
allow = {n for n in os.environ["ALLOW"].split("\n") if n}

with open(src) as fh:
    lock = json.load(fh)

kept = {k: v for k, v in lock.items() if k in allow}
dropped = sorted(set(lock) - set(kept))
missing = sorted(allow - set(kept))

with open(dst, "w") as fh:
    fh.write("{\n")
    items = sorted(kept.items())
    for i, (k, v) in enumerate(items):
        tail = "" if i == len(items) - 1 else ","
        fh.write('  %s: { "branch": %s, "commit": %s }%s\n'
                 % (json.dumps(k), json.dumps(v.get("branch")), json.dumps(v.get("commit")), tail))
    fh.write("}\n")

print("kept %d core entries" % len(kept))
if dropped:
    print("dropped %d non-core entries: %s" % (len(dropped), ", ".join(dropped)))
if missing:
    print("WARNING: %d core plugins absent from the lock (not installed?): %s"
          % (len(missing), ", ".join(missing)))
PYFILTER

printf 'wrote %s from %s\n' "$DST" "$SRC"

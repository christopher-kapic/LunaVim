# LunaVim plugin snapshots

A *snapshot* is a saved `lazy-lock.json` — a JSON object mapping every
managed plugin name to a `{branch, commit}` pair. It is the same shape
lazy.nvim writes to `<config>/lazy-lock.json`, so a snapshot file can be
swapped in directly.

## `default.json`

`snapshots/default.json` is the curated, known-good commit set for the
LunaVim core plugin spec. It is what `:LvimSyncCorePlugins` applies.

Behavior of `:LvimSyncCorePlugins`:

- If `snapshots/default.json` is **non-empty**, the command copies it onto
  the user's `<config>/lazy-lock.json` (after a confirmation prompt
  unless invoked as `:LvimSyncCorePlugins!`) and then runs
  `require('lazy').restore()` so every plugin checks out the pinned
  commit.
- If `snapshots/default.json` is **empty** (`{}`, the initial state), the
  command falls back to `require('lazy').sync()` — install/update against
  the spec's default branches with no pin.

The file is checked in as `{}` initially. The Phase 7 installer (or a
maintainer running `scripts/snapshot-export.sh`) populates it from the
actual installed commits once the core spec is stable.

## `scripts/snapshot-export.sh`

`scripts/snapshot-export.sh` copies the current user's
`<config>/lazy-lock.json` to `snapshots/default.json`. It is **not** run
automatically — it is the maintainer workflow for refreshing the pinned
set:

1. Update plugins locally (`:Lazy sync`).
2. Verify the editor works as expected.
3. Run `scripts/snapshot-export.sh` from the LunaVim checkout.
4. Commit the resulting `snapshots/default.json` change.

The script respects `LUNAVIM_CONFIG_DIR` / `LUNARVIM_CONFIG_DIR` for
locating the source lockfile; it defaults to `~/.config/lvim`.

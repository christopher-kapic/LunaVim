# LunaVim

[![ci](https://github.com/christopher-kapic/LunaVim/actions/workflows/ci.yml/badge.svg)](https://github.com/christopher-kapic/LunaVim/actions/workflows/ci.yml)

A "just works" Neovim distribution, spiritually descended from
[LunarVim](https://github.com/LunarVim/LunarVim) and rebuilt against current
Neovim and plugin APIs. The executable, config directory, and user-facing
surfaces are still `lvim` — old muscle memory carries over.

## Why LunaVim

- LunarVim was a great "drop in and code" Neovim distro, but development
  has stalled and it no longer keeps up with current Neovim releases or
  plugin APIs.
- LunaVim is a fresh rewrite that keeps the same shape: a global `lvim`
  table, `lvim.builtin.*` toggles, `lvim.plugins`, `lvim.lsp`, the same
  `:Lvim*` commands, and the same `~/.config/lvim/config.lua` entry
  point.
- Built on a current plugin set: `lazy.nvim`, `mason.nvim` +
  `nvim-lspconfig`, `nvim-treesitter`, `telescope.nvim`, `nvim-tree.lua`,
  `gitsigns.nvim`, `which-key.nvim`, `lualine.nvim`,
  `bufferline.nvim`, `toggleterm.nvim`, `mini.comment`,
  `indent-blankline.nvim`.
- Linux and macOS supported today.

## Requirements

- **Neovim 0.11 or newer** (`nvim --version`).
- **git** on `PATH`.
- A C compiler (`cc` / `gcc` / `clang`) and the `tree-sitter` CLI —
  `nvim-treesitter` needs both to build and update parsers.
- **Optional but recommended:**
  - [`ripgrep`](https://github.com/BurntSushi/ripgrep) (`rg`) — used by
    telescope's live grep.
  - [`fd`](https://github.com/sharkdp/fd) — faster file-finding for
    telescope.
  - A [Nerd Font](https://www.nerdfonts.com/) for icons in the
    statusline, bufferline, and tree.

## Install

One-liner (downloads and runs [`scripts/install.sh`](scripts/install.sh)):

```bash
curl -L https://raw.githubusercontent.com/christopher-kapic/LunaVim/main/scripts/install.sh | bash
```

This clones LunaVim into `~/.local/share/lunavim`, installs the core
plugin set, and writes the `lvim` launcher to `~/.local/bin/lvim`. Make
sure `~/.local/bin` is on your `PATH`, then run:

```bash
lvim
```


If the installer detects an existing LunarVim or CKLunarVim install (or
any foreign `~/.local/bin/lvim` launcher), it refuses to overwrite the
launcher and prints removal guidance — see
[Migrating from LunarVim / CKLunarVim](#migrating-from-lunarvim--cklunarvim).
Re-run with `--force` to overwrite anyway.

## Upgrade

Two options, both safe to re-run:

- **In Neovim:** `:LvimUpdate` runs `git pull --rebase --autostash` in
  the LunaVim base dir to pull the latest source. Follow it with
  `:LvimSyncCorePlugins` to apply the refreshed plugin snapshot.
- **From the shell:** re-run the installer. It's idempotent —
  it fast-forwards the existing checkout, rewrites the `lvim` launcher,
  and exits.

```bash
curl -L https://raw.githubusercontent.com/christopher-kapic/LunaVim/main/scripts/install.sh | bash
```

After updating LunaVim itself, run `:LvimSyncCorePlugins` inside Neovim
to apply the pinned plugin snapshot.

## Uninstall

[`scripts/uninstall.sh`](scripts/uninstall.sh) removes LunaVim. By
default it leaves `~/.config/lvim/` and `~/.cache/lvim/` alone, and
will not delete a foreign `lvim` launcher (e.g. one left over from
LunarVim).

```bash
bash ~/.local/share/lunavim/scripts/uninstall.sh
```

Useful flags:

- `--dry-run` — print the removal plan without touching disk.
- `--yes` — skip confirmation prompts.
- `--purge` — also remove `~/.config/lvim/` and `~/.cache/lvim/`.
- `--keep-config` — explicit: never touch `~/.config/lvim/` even with
  `--purge`.
- `--force` — remove the launcher even if it doesn't match LunaVim's
  template (use only if you're sure).

Run `bash ~/.local/share/lunavim/scripts/uninstall.sh --help` for the
full reference.

## Configuration

LunaVim reads `~/.config/lvim/config.lua` (override with
`LUNAVIM_CONFIG_DIR` or the legacy `LUNARVIM_CONFIG_DIR`). The file
mutates the global `lvim` table; defaults are merged with your values,
so you only specify what you want to change.

Minimal example:

```lua
-- ~/.config/lvim/config.lua

lvim.leader = "space"
lvim.colorscheme = "tokyonight"
lvim.format_on_save = true

-- Toggle a built-in module
lvim.builtin.bufferline.active = false

-- Add extra plugins (appended after the core spec)
lvim.plugins = {
  { "tpope/vim-surround" },
}

-- LSP servers managed via mason
lvim.lsp.ensure_installed = { "lua_ls", "pyright" }

-- A custom keymap
lvim.keys.normal_mode["<leader>w"] = "<cmd>w<cr>"
```

After editing, run `:LvimReload` (or restart `lvim`) to apply changes.

Useful commands:

| Command                 | Effect                                            |
| ----------------------- | ------------------------------------------------- |
| `:LvimInfo`             | Show paths, versions, and active config.          |
| `:LvimReload`           | Reload config, then reapply options, keymaps, and autocmds. |
| `:LvimUpdate`           | Pull the latest LunaVim (git pull --rebase).      |
| `:LvimSyncCorePlugins`  | Apply the pinned plugin snapshot.                 |
| `:LvimCacheReset`       | Clear the lazy.nvim cache.                        |
| `:checkhealth lvim`     | Diagnose install/runtime issues.                  |

## LunarVim compatibility

LunaVim accepts LunarVim's environment variables as aliases. `LUNAVIM_*`
takes precedence; if unset, `LUNARVIM_*` is consulted:

| LunaVim                | LunarVim alias         | Default                       |
| ---------------------- | ---------------------- | ----------------------------- |
| `LUNAVIM_BASE_DIR`     | `LUNARVIM_BASE_DIR`    | `~/.local/share/lunavim`      |
| `LUNAVIM_RUNTIME_DIR`  | `LUNARVIM_RUNTIME_DIR` | `~/.local/share/lunavim`      |
| `LUNAVIM_CONFIG_DIR`   | `LUNARVIM_CONFIG_DIR`  | `~/.config/lvim`              |
| `LUNAVIM_CACHE_DIR`    | `LUNARVIM_CACHE_DIR`   | `~/.cache/lvim`               |

Most existing `~/.config/lvim/config.lua` files from a recent LunarVim
should load without changes. If yours doesn't, see
`:checkhealth lvim` and open an issue.

### Migrating from LunarVim / CKLunarVim

LunarVim and CKLunarVim install to `~/.local/share/lunarvim` (note the
`lunarvim` spelling — LunaVim uses `lunavim`), share the launcher path
`~/.local/bin/lvim`, and may install a `lvim.desktop` entry on Linux.
Remove the old install before running the LunaVim installer.

**Preferred — use the LunarVim/CKLunarVim uninstaller if it's still on
disk:**

```bash
lv_base="${LUNARVIM_BASE_DIR:-${LUNARVIM_RUNTIME_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/lunarvim}/lvim}"
[ -f "$lv_base/utils/installer/uninstall.sh" ] \
  && bash "$lv_base/utils/installer/uninstall.sh"
```

**Manual cleanup fallback:**

```bash
rm -rf "${LUNARVIM_RUNTIME_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/lunarvim}"
rm -rf "${LUNARVIM_CACHE_DIR:-$HOME/.cache/lvim}"
rm -f  "$HOME/.local/bin/lvim"

if command -v xdg-desktop-menu >/dev/null 2>&1; then
  xdg-desktop-menu uninstall lvim.desktop 2>/dev/null || true
fi
rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/applications/lvim.desktop"
find "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" -name "lvim.svg" -type f -delete 2>/dev/null || true
```

Your `~/.config/lvim/config.lua` is left untouched by either path — keep
it in place to reuse with LunaVim.

## Status

**Alpha.** The architecture, plugin set, and `lvim` API surface are in
place and the integration smoke (boot → LSP attach → telescope → tree →
gitsigns) passes in CI, but defaults are still being tuned and rough
edges are expected. File issues liberally.

## Contributing

The full rewrite is tracked in [`plan.md`](plan.md), which contains the
architecture, compatibility contract, dependency direction, and per-phase
acceptance criteria. PRs and bug reports are welcome — please run
`make verify` before opening a PR.

## License

To be finalized; LunaVim will ship under an OSI-approved permissive
license (MIT or Apache-2.0) before leaving alpha.

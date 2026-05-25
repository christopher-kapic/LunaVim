-- Phase 6: nvim-tree.lua configuration.
--
-- Reads the live `lvim.builtin.nvimtree.setup` subtree (so user overrides
-- applied in config.lua before plugin load flow through) and forwards it to
-- `require('nvim-tree').setup(opts)`. Netrw is disabled BEFORE the setup
-- call: nvim-tree's README and `:help nvim-tree-netrw` both prescribe this
-- ordering so the hijack-netrw path is not racing against netrw's own
-- load-time autocommands.
--
-- The `<leader>e` toggle keymap lives in `lua/lvim/core/keymaps.lua` (same
-- pattern as the `<leader>f*` telescope group) so the mapping exists before
-- nvim-tree's plugin code loads — pressing the key triggers lazy.nvim's
-- `cmd = "NvimTreeToggle"` stub, which loads the plugin and forwards the
-- toggle invocation.
--
-- Directory-arg open (`./bin/lvim some/dir`):
-- We delegate to nvim-tree's own hijack-netrw flow rather than registering a
-- VimEnter autocmd that fires `:NvimTreeOpen <abs>`. The old explicit-open
-- approach (`attach_dir_open()`) placed the tree as a SIDE PANEL on
-- `view.side`, which collides with other right-side panels (e.g.
-- `mini.map`) — pressing `<C-l>` from the main window then jumps to the
-- nearer side panel (the minimap) rather than the tree. The hijack flow
-- instead replaces the would-be netrw view with nvim-tree IN THE INITIAL
-- WINDOW (matching the upstream-reference layout), and the first `<CR>`
-- on a file splits to create the main window — leaving tree-on-side and
-- minimap-on-side as the two distinct panels they should be.
--
-- Two pieces have to fall into place for the hijack to fire on the
-- directory-arg path:
--   1. `disable_netrw = true` + `hijack_netrw = true` in
--      `lvim.builtin.nvimtree.setup` (seeded in `lvim/config/defaults.lua`)
--      so nvim-tree registers its `BufEnter`/`BufNewFile` handler that
--      calls `open_on_directory` when it sees a directory buffer.
--   2. `vim.g.loaded_netrw = 1` + `vim.g.loaded_netrwPlugin = 1` set
--      BEFORE Neovim's `plugin/netrw.vim` sources, which happens at
--      runtime-resolution time (very early). Setting these from
--      `lvim/core/options.lua` (which runs before `lvim.core.plugins`)
--      is too late — Neovim resolves and sources netrw before any of
--      our Lua runs, so the flags have to land at the module-top of a
--      plugin path Lua already exposes. Setting them inside this
--      module's `M.setup()` (called when lazy loads nvim-tree on
--      `User DirOpened`) keeps the contract simple: nvim-tree's own
--      docs recommend this pairing.
-- The actual dir-buffer hijack is driven by LunaVim's `User DirOpened`
-- event (fired by `lvim/core/autocmds.lua` from the BufEnter handler when
-- the entered buffer name is a directory) which is registered as a
-- `lazy.nvim` load-trigger on the nvim-tree spec entry. After load, that
-- handler re-emits the originating BufEnter so nvim-tree's freshly-
-- registered `BufEnter`/`BufNewFile` autocmd sees the directory buffer
-- and calls `open_on_directory`. End-to-end: `lvim some/dir` →
-- `User DirOpened` lazy-loads nvim-tree → `BufEnter` re-emit fires
-- nvim-tree's hijack → tree opens in the initial window.
--
-- In-tree keymaps (`on_attach`):
-- nvim-tree's modern setup interprets a user-supplied `on_attach` as a full
-- replacement for the default mappings, so we call
-- `api.config.mappings.default_on_attach(bufnr)` first and then add the
-- handful of extras ported from the upstream reference's
-- `lua/lvim/core/nvimtree.lua:281-310`:
--   * `l` / `o` / `<CR>` → open node (file or directory)
--   * `v`                → open file in vertical split
--   * `h`                → close the parent directory
--   * `C`                → change tree root to the selected directory
--   * `gtg` / `gtf`      → telescope live_grep / find_files rooted at the
--                          selected node's directory
-- The telescope launchers reach for `telescope.builtin` lazily so the in-
-- tree mappings exist (and behave gracefully) even before telescope itself
-- is loaded — lazy.nvim's `cmd = "Telescope"` stub doesn't help us here
-- because we want to call the picker directly with a `cwd` arg, not via
-- `:Telescope`. The `pcall(require, "telescope.builtin")` falls through if
-- telescope hasn't been installed yet, mirroring the pcall pattern that
-- every other module uses for optional dependencies.
--
-- A `pcall` guards the require so the smoke harness (`install.missing = false`,
-- nvim-tree not on disk) does not raise when the lazy `config = setup("nvimtree")`
-- callback fires.
local M = {}

local function start_telescope(picker_name)
  local api_ok, api = pcall(require, "nvim-tree.api")
  if not api_ok then
    return
  end
  local node = api.tree.get_node_under_cursor()
  if not node then
    return
  end
  local abspath = node.link_to or node.absolute_path
  if not abspath then
    return
  end
  local is_folder = node.open ~= nil
  local basedir = is_folder and abspath or vim.fn.fnamemodify(abspath, ":h")
  local ok, builtin = pcall(require, "telescope.builtin")
  if not ok then
    return
  end
  builtin[picker_name]({ cwd = basedir })
end

local function on_attach(bufnr)
  local ok, api = pcall(require, "nvim-tree.api")
  if not ok then
    return
  end

  -- Defining `on_attach` opts out of the default mappings entirely
  -- (kcl-confirmed: nvim-tree treats `on_attach ~= nil` as "user owns the
  -- map table"). Call `default_on_attach` first so `Enter`, `a`, `d`, etc.
  -- still work, then layer our extras on top.
  api.config.mappings.default_on_attach(bufnr)

  -- nvim-tree's default `e → Rename: Basename` is registered with
  -- `nowait = true`, which makes a bare `e` press fire instantly inside
  -- the tree buffer — beating the `<leader>e` (`Toggle file explorer`)
  -- global sequence resolution, since `<leader>` is `<space>` and the
  -- nowait buffer-local wins ambiguity races. Unmapping `e` here lets
  -- the global `<leader>e` reach `:NvimTreeToggle` even when the tree
  -- buffer is focused, so the same shortcut closes the tree from
  -- inside it that opened it from outside it. Users who want rename
  -- can use the default `r` mapping (`Rename`).
  pcall(vim.keymap.del, "n", "e", { buffer = bufnr })

  local function opts(desc)
    return { desc = "nvim-tree: " .. desc, buffer = bufnr, noremap = true, silent = true, nowait = true }
  end

  -- Wrap each node-action in a node-existence guard. nvim-tree's
  -- `api.node.*` helpers assume the cursor is on a valid node line and
  -- raise `attempt to index local 'node' (a nil value)` when invoked on
  -- blank lines (e.g. above the tree contents or after a filter narrows
  -- the visible nodes). The canonical "is there a node here?" lookup
  -- is `api.tree.get_node_under_cursor()` (the older
  -- `nvim-tree.lib.get_node_at_cursor` was moved to an internal-only
  -- path in current nvim-tree releases and is no longer exposed on the
  -- `lib` module).
  local function with_node(action)
    return function()
      if not api.tree.get_node_under_cursor() then
        return
      end
      action()
    end
  end

  vim.keymap.set("n", "l", with_node(api.node.open.edit), opts("Open"))
  vim.keymap.set("n", "o", with_node(api.node.open.edit), opts("Open"))
  vim.keymap.set("n", "<CR>", with_node(api.node.open.edit), opts("Open"))
  vim.keymap.set("n", "v", with_node(api.node.open.vertical), opts("Open: Vertical Split"))
  vim.keymap.set("n", "h", with_node(api.node.navigate.parent_close), opts("Close Directory"))
  vim.keymap.set("n", "C", with_node(api.tree.change_root_to_node), opts("CD"))
  vim.keymap.set("n", "gtg", function()
    start_telescope("live_grep")
  end, opts("Telescope Live Grep"))
  vim.keymap.set("n", "gtf", function()
    start_telescope("find_files")
  end, opts("Telescope Find File"))
end

function M.setup(_)
  vim.g.loaded_netrw = 1
  vim.g.loaded_netrwPlugin = 1

  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.nvimtree) or {}
  local opts = vim.deepcopy(builtin.setup or {})

  -- Default the on_attach to our LunarVim-flavored variant when the user
  -- hasn't supplied one. We attach it here (rather than in
  -- `lvim/config/defaults.lua`) so the function identity is fresh per
  -- module-require — putting a function value in the defaults table risks
  -- losing it across `vim.deepcopy` (deepcopy preserves functions, but the
  -- defaults table is also the user-override merge target and we'd rather
  -- not commit users to a stable function reference there). A user wanting
  -- the upstream default-only mapping set can set
  -- `lvim.builtin.nvimtree.setup.on_attach = false` (or any non-nil value
  -- of their own) in their config.lua and the line below leaves theirs
  -- alone.
  if opts.on_attach == nil then
    opts.on_attach = on_attach
  end

  local ok, nvim_tree = pcall(require, "nvim-tree")
  if not ok then
    return
  end
  nvim_tree.setup(opts)
end

return M

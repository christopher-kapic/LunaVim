-- Phase 6: nvim-navic (LSP-based breadcrumbs) configuration.
--
-- Forwards `lvim.builtin.breadcrumbs.options` to `require('nvim-navic').setup`,
-- then arms the winbar with navic's location string via the
-- `%{%v:lua.<expr>%}` form. The outer `%{%...%}` causes Neovim to re-evaluate
-- the expression on every redraw (the inner `%{...}` is statusline syntax),
-- so the breadcrumb updates as the cursor moves without us having to register
-- a CursorMoved autocmd.
--
-- This module is invoked via the lazy `config = setup("breadcrumbs")` callback
-- (see `lvim/plugins/spec.lua`), which fires once when something `require`s
-- `nvim-navic`. The on_attach in `lvim/lsp/handlers.lua` is the canonical
-- trigger: a documentSymbol-providing LSP client attaches, the handler calls
-- `require('nvim-navic')`, lazy loads the plugin, and this `setup()` runs
-- exactly once for the session. Setting `vim.opt.winbar` (global, not
-- `opt_local`) at this point is the "once at setup" prescribed by the step:
-- every subsequent buffer inherits the winbar from the global option.
--
-- A `pcall` guards the require so the smoke harness (`install.missing = false`,
-- nvim-navic not on disk) does not raise when the lazy `config` callback fires
-- — matching the pattern used by sibling Phase 6 modules.
local M = {}

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.breadcrumbs) or {}
  local opts = vim.deepcopy(builtin.options or {})

  local ok, navic = pcall(require, "nvim-navic")
  if not ok then
    return
  end
  navic.setup(opts)
  vim.opt.winbar = "%{%v:lua.require'nvim-navic'.get_location()%}"
end

return M

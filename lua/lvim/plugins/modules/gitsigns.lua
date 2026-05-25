-- Phase 6: gitsigns.nvim configuration.
--
-- Reads the live `lvim.builtin.gitsigns` subtree (so user overrides applied
-- in config.lua before plugin load flow through), strips the `active` toggle
-- (it's the spec gate's input, not a gitsigns option), and forwards the rest
-- to `require('gitsigns').setup(opts)`. The setup shape used in defaults.lua
-- matches the canonical kcl-confirmed surface: top-level `signs`,
-- `signs_staged`, `signcolumn`, `current_line_blame_opts`, etc.
--
-- The `<leader>g{j,k,p,b}` mappings live in `lua/lvim/core/keymaps.lua` —
-- they use the `<cmd>Gitsigns ...<CR>` form so the mappings exist before
-- gitsigns' plugin code loads. Pressing one triggers lazy.nvim's
-- `event = "BufReadPre"` rule (the first BufRead loads gitsigns and
-- registers the `:Gitsigns` user command), then forwards the subcommand.
--
-- A `pcall` guards the require so the smoke harness (`install.missing = false`,
-- gitsigns not on disk) does not raise when the lazy `config = setup("gitsigns")`
-- callback fires from the `event = "BufReadPre"` trigger.
local M = {}

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.gitsigns) or {}

  local opts = vim.deepcopy(builtin)
  opts.active = nil

  local ok, gitsigns = pcall(require, "gitsigns")
  if not ok then
    return
  end
  gitsigns.setup(opts)
end

return M

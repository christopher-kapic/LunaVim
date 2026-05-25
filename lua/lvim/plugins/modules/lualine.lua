-- Phase 6: lualine.nvim configuration.
--
-- Reads the live `lvim.builtin.lualine` subtree (so user overrides applied
-- in config.lua before plugin load flow through), strips the `active`
-- toggle (it's the spec gate's input, not a lualine option), and forwards
-- the rest to `require('lualine').setup(opts)`. The setup shape used in
-- defaults.lua matches the canonical kcl-confirmed surface:
-- `{ options = { theme, ..., separators }, sections = { lualine_a..z } }`.
--
-- A `pcall` guards the require so the smoke harness (`install.missing = false`,
-- lualine not on disk) does not raise when the lazy `config = setup("lualine")`
-- callback fires from the `event = "VeryLazy"` trigger.
local M = {}

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.lualine) or {}

  local opts = vim.deepcopy(builtin)
  opts.active = nil

  local ok, lualine = pcall(require, "lualine")
  if not ok then
    return
  end
  lualine.setup(opts)
end

return M

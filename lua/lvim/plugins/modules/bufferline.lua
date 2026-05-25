-- Phase 6: bufferline.nvim configuration.
--
-- Reads the live `lvim.builtin.bufferline` subtree (so user overrides applied
-- in config.lua before plugin load flow through), strips the `active` toggle
-- (it's the spec gate's input, not a bufferline option), and forwards the
-- rest to `require('bufferline').setup(opts)`. The setup shape used in
-- defaults.lua matches the canonical kcl-confirmed surface:
-- `{ options = { diagnostics, offsets, ... } }`.
--
-- A `pcall` guards the require so the smoke harness (`install.missing = false`,
-- bufferline not on disk) does not raise when the lazy `config = setup("bufferline")`
-- callback fires from the `event = "VeryLazy"` trigger.
local M = {}

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.bufferline) or {}

  local opts = vim.deepcopy(builtin)
  opts.active = nil

  local ok, bufferline = pcall(require, "bufferline")
  if not ok then
    return
  end
  bufferline.setup(opts)
end

return M

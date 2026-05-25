-- Phase 6: telescope.nvim configuration.
--
-- Reads the live `lvim.builtin.telescope` subtree (so user overrides applied
-- in config.lua before plugin load flow through), strips the `active` toggle
-- (it's the spec gate's input, not a telescope option), and forwards the rest
-- to `require('telescope').setup(opts)`. The setup call uses the structured
-- shape kcl-confirmed as canonical for telescope.nvim:
-- `{ defaults = {...}, pickers = {...}, extensions = {...} }`.
--
-- A `pcall` guards the require so the smoke harness (`install.missing = false`,
-- telescope not on disk) does not raise when the lazy `config = setup("telescope")`
-- callback fires from any code path that triggers the `cmd = "Telescope"`
-- stub — most checks never reach it, but a defensive guard mirrors every
-- other module under `lvim/plugins/modules/`.
local M = {}

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.telescope) or {}

  local opts = vim.deepcopy(builtin)
  opts.active = nil

  local ok, telescope = pcall(require, "telescope")
  if not ok then
    return
  end
  telescope.setup(opts)
end

return M

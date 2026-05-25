-- Phase 6: which-key.nvim configuration.
--
-- which-key v3 redesigned the registration API: the legacy nested dictionary
-- + `register()` form is deprecated, and the documented entry points are
-- `require('which-key').setup(opts)` plus `require('which-key').add(spec)`
-- with a flat spec array (kcl-confirmed against the upstream `README.md`
-- and `lua/which-key/init.lua`). This module follows that path and keeps
-- the two concerns split:
--   * `_G.lvim.builtin.whichkey.setup`    → forwarded to `which-key.setup`.
--   * `_G.lvim.builtin.whichkey.mappings` → forwarded to `which-key.add`.
-- We deliberately do not use `opts.spec` because `add()` composes better
-- across reloads (a user can call `require('which-key').add({...})` from
-- their own config after our defaults are in place, without having to
-- restate them).
--
-- A `pcall` guards the require so the smoke harness (`install.missing = false`,
-- which-key not on disk) does not raise when the lazy `config = setup("whichkey")`
-- callback fires from the `event = "VeryLazy"` trigger. The same defensive
-- guard is used by every other module under `lvim/plugins/modules/`.
local M = {}

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.whichkey) or {}

  local opts = vim.deepcopy(builtin.setup or {})
  local mappings = vim.deepcopy(builtin.mappings or {})

  local ok, which_key = pcall(require, "which-key")
  if not ok then
    return
  end
  which_key.setup(opts)
  if #mappings > 0 then
    which_key.add(mappings)
  end
end

return M

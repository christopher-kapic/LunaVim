-- Phase 6: indent-blankline.nvim (v3 / `ibl`) configuration.
--
-- v3 of indent-blankline introduced a hard module rename: the canonical
-- entry is `require('ibl')`, not the v2 `require('indent_blankline')` (which
-- in v3 only exists as a deprecation stub that errors on require). The
-- config table is also deeply nested now — `indent`, `scope`, `whitespace`,
-- `exclude` — instead of v2's flat options table plus `vim.g.indent_blankline_*`
-- globals. `lvim.builtin.indentlines.options` already follows this v3 shape,
-- so the whole subtree is forwarded verbatim to `require('ibl').setup(opts)`.
-- Users override individual nested keys (`options.indent.char`,
-- `options.scope.enabled`, ...) in their config.lua by direct assignment
-- against the live `_G.lvim` table (the user's `config.lua` is just `loadfile`d
-- and run — see `lvim/config/loader.lua` — so leaf assignments mutate the
-- defaults in place rather than producing a separate override table that
-- needs merging). Each unset nested key keeps its default from defaults.lua.
--
-- A `pcall` guards the require so the smoke harness (`install.missing = false`,
-- indent-blankline not on disk) does not raise when the lazy
-- `config = setup("indentlines")` callback fires from the
-- `event = { "BufReadPost", "BufNewFile" }` trigger.
local M = {}

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.indentlines) or {}
  local opts = vim.deepcopy(builtin.options or {})

  local ok, ibl = pcall(require, "ibl")
  if not ok then
    return
  end
  ibl.setup(opts)
end

return M

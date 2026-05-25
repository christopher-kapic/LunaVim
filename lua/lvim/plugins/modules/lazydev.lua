-- Phase 4.4: lazydev.nvim feeds the active lua_ls client extra
-- `Lua.workspace.library` entries at runtime so editing `.lua` files inside
-- LunaVim's own source tree gives completion for `vim.api.*` and for
-- LunaVim's own modules.
--
-- Per `kcl ask lazydev-nvim`: the recommended integration is via lazydev's
-- own `library` array, NOT by setting `Lua.workspace.library` on lua_ls
-- directly. lazydev dynamically injects its configured paths into the active
-- lua_ls client's settings, so the lua_ls server config in `lvim.lsp.servers`
-- intentionally leaves `Lua.workspace.library` alone.
--
-- The spec entry pins `ft = "lua"` so lazydev is only loaded when a Lua
-- buffer opens — there is no value loading it for any other filetype.
--
-- Library defaults:
--   1. `vim.env.VIMRUNTIME` — lazydev injects this automatically (it's the
--      first entry in its internal libs list, sourced from `options.runtime`)
--      and dedupes by path, so listing it here is redundant-but-safe. We keep
--      the explicit entry so the smoke harness has a stable, observable
--      contract that any future refactor must preserve.
--   2. `{ path = get_lvim_base_dir(), words = { "lvim" } }` — mirrors the
--      lazydev README's distribution recipe `{ path = "LazyVim", words = { "LazyVim" } }`.
--      `words` matches a literal substring anywhere on a buffer line, so this
--      trigger fires for both the LunaVim source tree (`require("lvim.X")`,
--      `lvim.builtin.X`, etc.) and the typical user config in
--      `~/.config/lvim/config.lua` (`lvim.leader = " "`, `lvim.format_on_save = true`,
--      ...). A `mods = { "lvim" }` trigger would only fire on `require("lvim.*")`
--      and miss the user-config case entirely, defeating the goal. A plain-string
--      entry would force eager injection of the whole LunaVim tree on every
--      `.lua` buffer regardless of whether it references LunaVim at all.
local M = {}

function M.setup(_)
  local ok, lazydev = pcall(require, "lazydev")
  if not ok then
    return
  end

  -- Read the live `_G.lvim.builtin.lazydev` subtree (minus `active`, the
  -- spec gate's input) instead of the empty `opts = {}` lazy passes in.
  -- Matches the every-other-module pattern (`terminal.lua`, `treesitter.lua`,
  -- `whichkey.lua`, ...): user overrides in `config.lua` mutate the live
  -- builtin table BEFORE plugin load, and we pick them up here.
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.lazydev) or {}
  local opts = vim.deepcopy(builtin)
  opts.active = nil

  -- Build the library array as a list-concat of defaults + user entries so
  -- `vim.tbl_deep_extend("force", ...)` (which overwrites array fields rather
  -- than concatenating them) doesn't drop our defaults the moment the user
  -- passes their own `library` table.
  local library = { vim.env.VIMRUNTIME }
  if _G.get_lvim_base_dir then
    table.insert(library, { path = _G.get_lvim_base_dir(), words = { "lvim" } })
  end
  for _, entry in ipairs(opts.library or {}) do
    table.insert(library, entry)
  end

  local rest = vim.deepcopy(opts)
  rest.library = nil

  lazydev.setup(vim.tbl_deep_extend("force", { library = library }, rest))
end

return M

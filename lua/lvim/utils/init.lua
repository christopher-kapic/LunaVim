local M = {}

-- Deep-merge semantics chosen for LunaVim:
--
--   vim.tbl_deep_extend("force", defaults, user)
--
-- "force" means user values win over defaults at every level, but list-like
-- tables are REPLACED wholesale rather than concatenated. This matches
-- LunarVim's historical behavior (e.g. setting `lvim.builtin.telescope.pickers
-- = { ... }` replaces the picker list rather than appending to defaults) and
-- is what existing LunarVim users expect when porting their configs over.
--
-- If a future use case needs list concatenation, add a dedicated helper
-- rather than changing this default — silently shifting merge semantics
-- breaks user configs in hard-to-debug ways.
function M.deep_extend_force_keep_user(defaults, user_overrides)
  defaults = defaults or {}
  user_overrides = user_overrides or {}
  return vim.tbl_deep_extend("force", defaults, user_overrides)
end

-- Programmatic API: merge a whole `builtin` overrides table into the live
-- `lvim.builtin` table using the deep-merge semantics above.
--
-- The normal user-config flow mutates `lvim` directly (e.g.
-- `lvim.builtin.telescope.active = false`), so the loader does NOT need to
-- call this. It exists for callers that build an overrides table
-- programmatically (a plugin, a profile, a test fixture) and want a single
-- entry point to apply it:
--
--   lvim.utils.merge_builtin_overrides({
--     telescope = { active = false, defaults = { custom = 1 } },
--   })
--
-- Mutates `_G.lvim.builtin` IN PLACE so callers holding a reference to that
-- table (e.g. `local b = lvim.builtin` taken earlier) keep observing the
-- merged state. Reassigning the field would silently leave such references
-- pointing at a stale snapshot, which has been a long-standing source of
-- LunarVim "why is my override not applied?" bug reports.
function M.merge_builtin_overrides(overrides)
  if type(overrides) ~= "table" then
    error("lvim.utils.merge_builtin_overrides: overrides must be a table", 2)
  end

  if type(_G.lvim) ~= "table" or type(_G.lvim.builtin) ~= "table" then
    error("lvim.utils.merge_builtin_overrides: lvim.builtin is not initialized", 2)
  end

  local merged = M.deep_extend_force_keep_user(_G.lvim.builtin, overrides)
  for key, value in pairs(merged) do
    _G.lvim.builtin[key] = value
  end
  return _G.lvim.builtin
end

return M

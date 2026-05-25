local M = {}

-- Build the plugin spec lazy.nvim will see, by combining:
--   1. the core spec in `lvim.plugins.spec` (LunaVim builtins),
--   2. minus entries whose `name` matches a `lvim.builtin.<name>.active = false`
--      override the user set in their config,
--   3. with `lvim.plugins` (user-added specs) appended.
--
-- Append-after-core is the LunarVim contract: user specs cannot silently
-- shadow a core plugin by id collision. To replace a core plugin, the user
-- disables it (`lvim.builtin.telescope.active = false`) and then adds their
-- own entry to `lvim.plugins`. If they skip the disable step lazy.nvim will
-- surface the duplicate id rather than us picking a winner.
--
-- Filtering matches only on `spec.name`. The Phase 2 core spec sets `name`
-- explicitly on every builtin so the toggle keys are predictable; entries
-- without `name` are passed through untouched.
function M.final_spec()
  local core = require("lvim.plugins.spec")
  local lvim = _G.lvim or {}
  local builtin = lvim.builtin or {}
  local user_plugins = lvim.plugins or {}

  local result = {}
  for _, spec in ipairs(core) do
    local name = spec.name
    local toggle = name and builtin[name] or nil
    if not (type(toggle) == "table" and toggle.active == false) then
      table.insert(result, spec)
    end
  end

  for _, spec in ipairs(user_plugins) do
    table.insert(result, spec)
  end

  return result
end

return M

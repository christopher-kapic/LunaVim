-- Compatibility shim for LunarVim's three historical reload helpers:
--
--   require_safe(name)
--     pcall-wrapped require. On failure, emits a vim.notify at WARN level
--     containing the failed module name and the underlying error, and
--     returns nil. On success returns the loaded module. Used throughout
--     LunarVim's bootstrap to keep a single broken module from aborting
--     startup — callers `if not m then return end` and move on.
--
--   require_clean(name)
--     Drops package.loaded[name] so the next require re-evaluates the file
--     from disk, then loads it through require_safe so reload errors stay
--     non-fatal. Use when a module's top-level state needs to be rebuilt
--     (e.g. after rewriting its source on disk).
--
--   reload(name)
--     Alias for require_clean. LunarVim historically had a deeper
--     in-place table-replacement variant (see the upstream reference in
--     `references/` — `lua/lvim/utils/modules.lua`) so that callers
--     holding a reference to `package.loaded[name]` kept observing live
--     state. That deep variant interacts badly with current plugin APIs
--     (lazy.nvim caches module tables by identity), so for now `reload`
--     and `require_clean` share the same semantics. Revisit if a
--     concrete behavior gap surfaces.
--
-- All three are exposed as globals from `lvim/init.lua:start()` after
-- `config.load_defaults()` so that user config and any subsequently-loaded
-- core/plugin modules can call them without an explicit `require`.

local M = {}

function M.require_safe(name)
  local ok, module = pcall(require, name)
  if not ok then
    vim.notify(
      string.format("lvim: failed to require '%s': %s", name, module),
      vim.log.levels.WARN
    )
    return nil
  end
  return module
end

function M.require_clean(name)
  package.loaded[name] = nil
  return M.require_safe(name)
end

M.reload = M.require_clean

return M

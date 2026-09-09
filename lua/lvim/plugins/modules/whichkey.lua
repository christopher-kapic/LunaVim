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

-- Generic "hide a binding whose backing tool is not available" gate.
--
-- Keyed on what the binding DOES, not on the key it happens to sit at. The
-- lazygit check used to require the lhs to be exactly `<leader>gg`, so a user
-- who moved lazygit to another key lost the gate and got a popup row that
-- errors on press. Matching the rhs fixes that, and makes the group-emptying
-- logic in `filter_mappings` testable at any nesting depth.
--
-- `require` detection uses the frontier pattern `%f[%w_]`, which matches the
-- transition into a word character, so `myrequire('dap')` is not a require of
-- dap. The closing quote or bracket immediately after the name is what stops a
-- probe for `dap` from matching `dapui`, which is also why dapui is tested
-- first. Long-bracket forms are covered because `require([[dap]])` and
-- `require([=[dap]=])` are both valid Lua.
--
-- This is a heuristic over strings, not a parser: a binding that merely prints
-- the text `require('dap')` is also treated as needing dap. That trade is
-- deliberate -- the cost is one hidden mapping in an unrealistic case, versus a
-- popup row that errors on press in a realistic one.
local function requires_module(rhs, name)
  local patterns = {
    "%f[%w_]require%s*%(%s*['\"]" .. name .. "['\"]",
    "%f[%w_]require%s*['\"]" .. name .. "['\"]",
    "%f[%w_]require%s*%(?%s*%[=*%[" .. name .. "%]=*%]",
  }
  for _, pattern in ipairs(patterns) do
    if rhs:find(pattern) then
      return true
    end
  end
  return false
end

-- Is the plugin providing `module` installed, WITHOUT loading it?
--
-- `pcall(require, "dap")` is not usable here. lazy.nvim intercepts `require`,
-- so probing that way LOADS nvim-dap -- and which-key's own setup runs at
-- `VeryLazy` and inspects every mapping, so merely having the `<leader>d`
-- group in the defaults would drag the debugger in on every startup. That
-- defeats the `lazy = true` contract the dap spec documents, for a plugin most
-- sessions never use.
--
-- Instead ask lazy.nvim's own config what it knows. `lazy.core.config` is
-- lazy's internal module, not a managed plugin, so requiring it triggers no
-- plugin load. A spec entry alone is not enough -- with `install.missing =
-- false` a plugin can be specced but absent from disk -- so the directory is
-- stat'd too.
local MODULE_TO_PLUGIN = {
  dap = "dap",
  dapui = "nvim-dap-ui",
}

local function plugin_available(module)
  -- Already loaded by something else: definitely available.
  if package.loaded[module] then
    return true
  end

  local ok, lazy_config = pcall(require, "lazy.core.config")
  if not ok or type(lazy_config.plugins) ~= "table" then
    -- No lazy.nvim (the smoke harness re-requires this module standalone).
    -- Fall back to "not available" so a gated mapping is hidden rather than
    -- offered and broken.
    return false
  end

  local spec = lazy_config.plugins[MODULE_TO_PLUGIN[module] or module]
  if not spec or not spec.dir then
    return false
  end

  local uv = vim.uv or vim.loop
  return uv.fs_stat(spec.dir) ~= nil
end

local function mapping_enabled(entry)
  local rhs = entry[2]

  if type(rhs) ~= "string" then
    return true
  end

  -- LunaVim's own dap helper (`<leader>dU` routes through it so the parent
  -- spec's config callback runs). Checked before the generic require probes
  -- because the rhs names our module, not dap itself.
  if rhs:find("lvim.plugins.modules.dap", 1, true) then
    return plugin_available("dap")
  end

  -- dapui before dap: "dap" is a prefix of "dapui".
  if requires_module(rhs, "dapui") then
    return plugin_available("dapui")
  end

  if requires_module(rhs, "dap") then
    return plugin_available("dap")
  end

  -- Match LunaVim's OWN lazygit call, by module path and function together.
  -- A bare `toggle_lazygit` substring would also hide a user's unrelated
  -- `require('my.plugin').toggle_lazygit()` binding, or any mapping that merely
  -- contains that text as data.
  if rhs:find("lvim.plugins.modules.terminal", 1, true) and rhs:find("toggle_lazygit", 1, true) then
    return vim.fn.executable("lazygit") == 1
  end

  return true
end

-- Every prefix of `lhs` that could name a group, shortest first.
--
-- `<leader>xyz` belongs to both `<leader>xy` and `<leader>x`, so a filtered
-- child has to mark BOTH as having had children. Matching only the single
-- character after `<leader>` attributed it to `<leader>x` alone, which left a
-- nested `<leader>xy` group standing after every one of its bindings had been
-- filtered away -- a which-key row that opens onto nothing.
local function group_prefixes(lhs)
  local body = lhs:match("^<leader>(.+)$")
  if not body then
    return {}
  end
  local out = {}
  -- Stop one short of the full LHS: a binding is not its own group.
  for i = 1, #body - 1 do
    out[#out + 1] = "<leader>" .. body:sub(1, i)
  end
  return out
end

-- Drop bindings whose backing plugin is absent, and drop a group label only
-- when every binding that lived under it was dropped.
--
-- The case this exists for: the `<leader>d` Debug group, whose every binding
-- calls `require('dap')`. With nvim-dap not installed they are all filtered,
-- and leaving the label behind would put a Debug row in the which-key popup
-- that opens onto nothing. The lazygit binding is gated the same way.
--
-- A group with NO child bindings at all is kept. It is not an emptied group,
-- it is a user's deliberate label -- `table.insert(lvim.builtin.whichkey.mappings,
-- { "<leader>x", group = "Extra" })` is the documented way to declare a prefix
-- before binding anything under it, and an earlier version of this function
-- discarded exactly that, silently losing user config. `had_children` is what
-- separates "emptied by filtering" from "never had any".
local function filter_mappings(mappings)
  local kept = {}
  local had_children = {}
  local enabled_groups = {}

  for _, entry in ipairs(mappings) do
    if entry.group ~= nil then
      kept[#kept + 1] = entry
    else
      local prefixes = group_prefixes(entry[1])
      for _, prefix in ipairs(prefixes) do
        had_children[prefix] = true
      end
      if mapping_enabled(entry) then
        kept[#kept + 1] = entry
        for _, prefix in ipairs(prefixes) do
          enabled_groups[prefix] = true
        end
      end
    end
  end

  local result = {}
  for _, entry in ipairs(kept) do
    local emptied = entry.group ~= nil and had_children[entry[1]] and not enabled_groups[entry[1]]
    if not emptied then
      result[#result + 1] = entry
    end
  end

  return result
end

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.whichkey) or {}

  local opts = vim.deepcopy(builtin.setup or {})
  local mappings = filter_mappings(vim.deepcopy(builtin.mappings or {}))

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

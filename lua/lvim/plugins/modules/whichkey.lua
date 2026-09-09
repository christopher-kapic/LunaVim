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

local function has_module(name)
  local ok = pcall(require, name)
  return ok
end

local function mapping_enabled(entry)
  local lhs = entry[1]
  local rhs = entry[2]

  if lhs == "<leader>gg" and rhs == "<cmd>lua require('lvim.plugins.modules.terminal').toggle_lazygit()<cr>" then
    return vim.fn.executable("lazygit") == 1
  end

  if type(rhs) ~= "string" then
    return true
  end

  -- Match the spellings Lua accepts for requiring a module, since these rhs
  -- strings are user-editable: require'dap', require "dap", require('dap'),
  -- require([[dap]]), require([=[dap]=]).
  --
  -- `%f[%w_]` is Lua's frontier pattern, matching the transition into a word
  -- character. It is what stops `myrequire('dap')` from counting as a require
  -- of dap. The closing quote/bracket right after the name is what stops
  -- `dapui` from matching a search for `dap`.
  --
  -- This is a heuristic over strings, not a parser: a binding that merely
  -- prints the text `require('dap')` would also be treated as needing dap.
  -- That trade is deliberate -- the cost is one hidden mapping in an
  -- unrealistic case, versus a popup row that errors on press in a realistic
  -- one.
  local function requires_module(name)
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

  if requires_module("dapui") then
    return has_module("dapui")
  end

  if requires_module("dap") then
    return has_module("dap")
  end

  return true
end

-- Every prefix of `lhs` that could name a group, longest first.
--
-- `<leader>dar` belongs to both `<leader>da` and `<leader>d`, so a filtered
-- child has to mark BOTH as having had children. Matching only the single
-- character after `<leader>` attributed `<leader>dar` to `<leader>d` alone,
-- which left a nested `<leader>da` group standing after every one of its
-- bindings was filtered away — a which-key row that opens onto nothing.
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
-- The case this exists for: the `<leader>d` Debug group's entries all call
-- `require('dap')`. With nvim-dap not installed they are filtered out, and
-- leaving the group label behind would put a Debug row in the which-key popup
-- that opens onto nothing.
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

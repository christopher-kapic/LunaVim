-- Structural invariants over `lvim.builtin.whichkey.mappings`, printed as one
-- `WK_MAPS` line for `check_phase_6_whichkey_defaults_mappings_full_list`.
--
-- Lives in a file rather than inline in the smoke script because getting the
-- semantics right takes more than a legible one-liner, and getting them wrong
-- is what made the check fire on correct config.
--
-- The valuable assertion is the duplicate one: `which-key.add()` calls
-- `vim.keymap.set` per row, so two rows resolving to the same mapping means one
-- silently overwrites the other. What "the same mapping" means is the whole
-- problem, and it is not "the same LHS string":
--
--   1. SCOPE IS (LHS, MODE, BUFFER). `<leader>/` bound to `gcc` in normal mode
--      and to `gc` in visual mode are two bindings, not a collision. Keying on
--      LHS alone failed CI on exactly that correct configuration.
--   2. A TOP-LEVEL STRING MODE SPLITS PER CHARACTER -- `mode = "nx"` is two
--      modes (which-key's `mappings.lua:277-278`, mirrored by `entry_modes` in
--      `lvim/plugins/modules/whichkey.lua`). A LIST does NOT: each element must
--      already be one shortname, so `mode = { "nx" }` is invalid input that
--      which-key hands straight to `vim.keymap.set`, which rejects it.
--   3. SHORT MODE NAMES OVERLAP. `v` is Visual+Select while `x` is Visual only;
--      `!` is Insert+Command; `""` is Normal+Visual+Select+Operator. A
--      `mode = "v"` row and a `mode = "x"` row on one LHS DO collide even
--      though the strings differ, so everything is expanded to primitives
--      before comparison. (`l` is the separate language-mapping table, not an
--      alias for `i`/`c`, so it stays as itself.)
--   4. LHS NOTATION IS CANONICALISED BY NEOVIM. `<C-a>` and `<C-A>` are one
--      mapping, and `<leader>x` is whatever mapleader expands to. Comparing
--      raw strings would miss both, so each LHS is run through
--      `nvim_replace_termcodes` first.
--
-- Emits: WK_MAPS <has_enough> <dupe_count> <malformed_count> <dupes> <malformed>

local mappings = lvim.builtin.whichkey.mappings

-- Every mode shortname `vim.keymap.set` accepts, mapped to the primitive modes
-- it actually installs into. Anything absent from this table is not a mode.
local PRIMITIVES = {
  n = { "n" },
  x = { "x" },
  s = { "s" },
  o = { "o" },
  i = { "i" },
  c = { "c" },
  t = { "t" },
  l = { "l" },
  v = { "x", "s" },
  ["!"] = { "i", "c" },
  [""] = { "n", "x", "s", "o" },
}

local seen, dupes, malformed = {}, {}, {}

---The mode shortnames a row asks for, or nil when the spec is not valid input.
local function shortnames(spec)
  if spec == nil then
    -- which-key's `add()` defaults to normal mode.
    return { "n" }
  end

  if type(spec) == "string" then
    if spec == "" then
      return { "" }
    end
    return vim.split(spec, "")
  end

  if type(spec) ~= "table" then
    return nil
  end

  local names = {}
  for _, one in ipairs(spec) do
    -- A list element is one shortname, never a string to split. A non-string
    -- would otherwise be coerced by `..` and slip through as a valid mode.
    if type(one) ~= "string" then
      return nil
    end
    names[#names + 1] = one
  end

  if #names == 0 then
    return nil
  end
  return names
end

---`lhs` as Neovim will store it, so equivalent spellings compare equal.
local function canonical(lhs)
  local ok, replaced = pcall(vim.api.nvim_replace_termcodes, lhs, true, true, true)
  return ok and replaced or lhs
end

for _, entry in ipairs(mappings) do
  local lhs = type(entry) == "table" and entry[1] or nil
  local rhs = type(entry) == "table" and entry[2] or nil
  local group = type(entry) == "table" and entry.group or nil

  if type(lhs) ~= "string" then
    malformed[#malformed + 1] = tostring(lhs)
  elseif type(entry) == "table" and entry.cond == false then
    -- which-key skips the row entirely, so it can collide with nothing.
    local _ = lhs
  elseif not (type(group) == "string" or type(rhs) == "string" or type(rhs) == "function") then
    -- A row is either a group label or a real binding. `group = false` and
    -- `rhs = false` are neither -- which-key registers nothing for them.
    malformed[#malformed + 1] = lhs
  else
    local names = shortnames(entry.mode)
    local modes = names and {} or nil

    if names then
      for _, name in ipairs(names) do
        local expansion = PRIMITIVES[name]
        if not expansion then
          modes = nil
          break
        end
        for _, primitive in ipairs(expansion) do
          -- Within ONE row, overlapping primitives are redundant, not a
          -- collision: `mode = "vx"` installs the same rhs into Visual twice.
          -- Only cross-row collisions lose a binding.
          modes[primitive] = true
        end
      end
    end

    if not modes then
      malformed[#malformed + 1] = lhs
    else
      local buffer = tostring(entry.buffer)
      for primitive in pairs(modes) do
        local key = primitive .. " " .. buffer .. " " .. canonical(lhs)
        if seen[key] then
          dupes[#dupes + 1] = primitive .. " " .. lhs
        else
          seen[key] = true
        end
      end
    end
  end
end

table.sort(dupes)

print("WK_MAPS", #mappings >= 20, #dupes, #malformed, table.concat(dupes, ","), table.concat(malformed, ","))

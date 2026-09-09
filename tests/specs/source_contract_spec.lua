-- Static source contracts.
--
-- These assertions read repository files and never boot Neovim as a
-- subprocess: "this module exists and dispatches into that plugin", "lvim.start()
-- still wires in this require", "nothing hardcodes a setting lazydev owns at
-- runtime". They lived in `scripts/lvim-smoke.sh` only because that is where the
-- rest of their phase's checks lived -- every one was a `grep` inside a bash
-- function, paying nothing for the shell and costing a reader two languages to
-- follow one contract.
--
-- Everything here is a source-level guard, deliberately. Each has a behavioural
-- sibling that boots a real Neovim (still in the smoke script); these exist to
-- fail FIRST, with a precise message, when a refactor moves or renames the thing
-- the behavioural check is about to require. "lua/lvim/lsp/format.lua is
-- missing" beats the same regression arriving as a Lua traceback out of a
-- headless boot.
--
-- Adding to this file is right when the contract is genuinely textual. A
-- contract about what the code DOES at runtime belongs in a spec that calls it,
-- or in the smoke script if it needs a real `lvim.start()`.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function path(rel)
  return root .. "/" .. rel
end

local function lines(rel)
  local p = path(rel)
  assert.is_true(vim.fn.filereadable(p) == 1, rel .. " is missing")
  return vim.fn.readfile(p)
end

-- Blank out everything in a Lua source that is prose, preserving line numbers.
--
-- Matching a comment is exactly how a static check goes quietly vacuous. The
-- shell versions of these checks grepped whole files, and five plugin modules
-- document their dispatch in a header comment as `require('telescope').setup(opts)`
-- while the code itself spells it `pcall(require, "telescope")` -- so those
-- checks were passing on prose, and stayed green when the real dispatch was
-- deleted.
--
-- Dropping lines that START with `--` is not enough to fix that. It leaves
-- three ways for prose to satisfy a contract: a trailing comment after code,
-- the interior of a `--[[ ]]` block (whose lines do not begin with `--`), and a
-- long string holding a documentation block. So scan properly: line comments,
-- long comments and long strings are replaced by spaces; newlines survive so
-- reported line numbers still point at the real file.
--
-- Short strings are deliberately KEPT. `require("ibl")` is the very thing these
-- contracts match on, and a plugin name is always a short string; a require
-- spelled inside a long string is documentation by construction.
local function long_bracket_at(text, i)
  if text:sub(i, i) ~= "[" then
    return nil
  end
  local j = i + 1
  while text:sub(j, j) == "=" do
    j = j + 1
  end
  if text:sub(j, j) ~= "[" then
    return nil
  end
  return j - i - 1, j + 1
end

local function blanked(chunk)
  return (chunk:gsub("[^\n]", " "))
end

local function strip_prose(text)
  local out, i, n = {}, 1, #text

  -- Skip from `i` to just past the close of a long bracket opened at `after`.
  local function skip_long(level, after)
    local _, close_end = text:find("]" .. string.rep("=", level) .. "]", after, true)
    return (close_end or n) + 1
  end

  while i <= n do
    local c = text:sub(i, i)
    if c == "-" and text:sub(i + 1, i + 1) == "-" then
      local level, after = long_bracket_at(text, i + 2)
      local stop
      if level then
        stop = skip_long(level, after)
      else
        stop = text:find("\n", i, true) or (n + 1)
      end
      out[#out + 1] = blanked(text:sub(i, stop - 1))
      i = stop
    elseif c == '"' or c == "'" then
      local j, closed = i + 1, false
      while j <= n and not closed do
        local d = text:sub(j, j)
        if d == "\\" then
          j = j + 2
        elseif d == c then
          j, closed = j + 1, true
        elseif d == "\n" then
          closed = true -- unterminated; the string ends at the line break
        else
          j = j + 1
        end
      end
      out[#out + 1] = text:sub(i, j - 1)
      i = j
    else
      local level, after = long_bracket_at(text, i)
      if level then
        local stop = skip_long(level, after)
        out[#out + 1] = blanked(text:sub(i, stop - 1))
        i = stop
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
  end

  return table.concat(out)
end

local function code(rel)
  local out = {}
  for n, line in ipairs(vim.split(strip_prose(table.concat(lines(rel), "\n")), "\n")) do
    out[#out + 1] = { n = n, text = line }
  end
  return out
end

-- Does any code line match this Vim regex? (vim.regex rather than Lua patterns
-- so alternation and character classes port over from the shell `grep -E`
-- versions literally, instead of fanning out into a list of Lua patterns.)
local function code_matches(rel, re)
  local rx = vim.regex(re)
  for _, line in ipairs(code(rel)) do
    if rx:match_str(line.text) then
      return line.n
    end
  end
  return nil
end

-- grep -F, restricted to code: a plain substring, no pattern interpretation.
local function code_contains(rel, literal)
  for _, line in ipairs(code(rel)) do
    if line.text:find(literal, 1, true) then
      return line.n
    end
  end
  return nil
end

local function assert_code_contains(rel, literal, why)
  assert.is_true(
    code_contains(rel, literal) ~= nil,
    rel .. " does not " .. why .. " (no code line contains " .. vim.inspect(literal) .. ")"
  )
end

local function refute_code_matches(rel, re, why)
  local n = code_matches(rel, re)
  assert.is_nil(n, n and (rel .. ":" .. n .. " " .. why) or nil)
end

-- Does the module require this plugin, under exactly the name the plugin
-- publishes?
--
-- The paren is optional because `require "x"` is valid Lua and the shell
-- version of the indent-blankline ban accepted it; a regression is a regression
-- whichever call syntax it uses.
local function requires_plugin(rel, plugin)
  local escaped = plugin:gsub("[.-]", "\\%0") -- vim-regex-escape `.` and `-`
  return code_matches(rel, ([==[require\s*[(,]\=\s*["']%s["']]==]):format(escaped))
end

-- Does the module call `<the required plugin>.<method>(...)`?
--
-- Tying the call back to the require is the whole point. Asserting "requires
-- telescope" and "something calls .setup()" as two independent facts lets a
-- module keep `pcall(require, "telescope")`, delete `telescope.setup(opts)`,
-- and still pass on an unrelated `other.setup(opts)` -- weaker than the shell
-- check it replaces, which at least demanded the two appear together.
--
-- Both spellings in use are accepted: the direct `require("x").setup(...)`, and
-- a handle bound by `local h = require("x")` or `local ok, h = pcall(require, "x")`.
local function calls_on_plugin(rel, plugin, method)
  local name = plugin:gsub("%p", "%%%0") -- Lua-pattern-escape the plugin name
  local required = "require%s*%(?%s*[\"']" .. name .. "[\"']%s*%)?"
  local source = code(rel)
  local handles = {}

  for _, line in ipairs(source) do
    if line.text:match(required .. "%s*%.%s*" .. method .. "%s*%(") then
      return line.n
    end
    for handle in line.text:gmatch("([%w_]+)%s*=%s*" .. required) do
      handles[handle] = true
    end
    for handle in line.text:gmatch("([%w_]+)%s*=%s*pcall%s*%(%s*require%s*,%s*[\"']" .. name .. "[\"']") do
      handles[handle] = true
    end
  end

  for _, line in ipairs(source) do
    for handle in pairs(handles) do
      if line.text:match("%f[%w_]" .. handle .. "%s*%.%s*" .. method .. "%s*%(") then
        return line.n
      end
    end
  end

  return nil
end

describe("repository layout", function()
  -- Phase 2.4 acceptance: the snapshot file, its README, and the maintainer
  -- export helper must all be present, with the script marked executable.
  it("ships the snapshot artifacts", function()
    assert.is_true(vim.fn.filereadable(path("snapshots/default.json")) == 1, "snapshots/default.json is missing")
    assert.is_true(vim.fn.filereadable(path("snapshots/README.md")) == 1, "snapshots/README.md is missing")
    assert.is_true(
      vim.fn.executable(path("scripts/snapshot-export.sh")) == 1,
      "scripts/snapshot-export.sh is missing or not executable"
    )
  end)

  -- The literal acceptance command from the step description reads
  -- `tests/fixtures/sample.tsx`. Pin its presence and prescribed content so a
  -- regression that deletes/renames it (or rewrites its body) is caught here
  -- rather than at the acceptance command's `grep -F '{/*'`.
  it("ships the sample.tsx fixture with its prescribed body", function()
    assert.is_true(
      vim.tbl_contains(lines("tests/fixtures/sample.tsx"), "const x = 1;"),
      "tests/fixtures/sample.tsx does not contain the prescribed body"
    )
  end)
end)

describe("lvim.start() wiring", function()
  -- Each of these has a behavioural sibling in the smoke script proving the
  -- effect holds after a full boot -- but a boot cannot distinguish "setup() ran
  -- from init.lua" from "setup() ran from some autocmd". Reading the file pins
  -- the wiring LOCATION, so dropping the require is caught even when something
  -- else happens to leave the same observable state behind.
  local wiring = {
    { "lvim.core.keymaps", "leader and the default map set" },
    { "lvim.core.autocmds", "the User FileOpened/DirOpened emitters" },
    { "lvim.lsp", "the LSP orchestrator (mason + lspconfig setup)" },
  }

  for _, entry in ipairs(wiring) do
    local module, why = entry[1], entry[2]
    it("calls " .. module .. ".setup() for " .. why, function()
      assert_code_contains("lua/lvim/init.lua", ('require("%s").setup()'):format(module), "wire in " .. module)
    end)
  end
end)

describe("lsp modules", function()
  -- Pin the module surface at the file level so a regression that moved,
  -- renamed or dropped one -- making the orchestrator's require error -- is
  -- caught before the runtime checks try to observe its effects.
  it("handlers.lua exports make_capabilities and make_on_attach", function()
    assert_code_contains("lua/lvim/lsp/handlers.lua", "function M.make_capabilities", "export make_capabilities")
    assert_code_contains("lua/lvim/lsp/handlers.lua", "function M.make_on_attach", "export make_on_attach")
  end)

  it("format.lua exports setup and owns the lvim_format_on_save augroup", function()
    assert_code_contains("lua/lvim/lsp/format.lua", "function M.setup", "export M.setup")
    assert_code_contains("lua/lvim/lsp/format.lua", "lvim_format_on_save", "register the lvim_format_on_save augroup")
  end)

  it("diagnostics.lua configures diagnostics and defines signs", function()
    assert_code_contains("lua/lvim/lsp/diagnostics.lua", "vim.diagnostic.config", "call vim.diagnostic.config")
    assert_code_contains("lua/lvim/lsp/diagnostics.lua", "sign_define", "call vim.fn.sign_define")
  end)

  -- A regression that removed this require would leave the diagnostic defaults
  -- un-applied, because nothing else calls them.
  it("the orchestrator wires in diagnostics.setup()", function()
    assert_code_contains(
      "lua/lvim/lsp/init.lua",
      'require("lvim.lsp.diagnostics").setup()',
      "wire diagnostics.setup() into lvim.lsp.setup()"
    )
  end)

  -- lazydev is the recommended lua_ls integration and injects paths into the
  -- active client's settings AT RUNTIME. A static `Lua.workspace.library`
  -- anywhere in the per-server config flow would shadow that injection, so
  -- prove none exists. User config may still set one under
  -- `lvim.lsp.servers.lua_ls`, which is by design.
  --
  -- The pattern matches a workspace SETTING -- `workspace.library`, or
  -- `workspace` as a table key -- rather than the bare word. Matching the bare
  -- word made this fire on `<cmd>Telescope lsp_dynamic_workspace_symbols<cr>`
  -- in the which-key spec, a picker name with nothing to do with lua_ls.
  local workspace_setting = [==[workspace\s*\.\s*library\|["']\=workspace["']\=\s*=\|\[["']workspace["']\]]==]

  for _, file in ipairs({
    "lua/lvim/lsp/init.lua",
    "lua/lvim/lsp/handlers.lua",
    "lua/lvim/config/defaults.lua",
  }) do
    it(file .. " hardcodes no workspace setting (lazydev owns it)", function()
      refute_code_matches(file, workspace_setting, "hardcodes a workspace setting, which conflicts with lazydev")
    end)
  end
end)

describe("plugin modules dispatch into their plugin", function()
  -- A regression that left a Phase 0 stub in place would silently drop the
  -- user's `lvim.builtin.<name>` config on the floor: the spec gate would still
  -- load the plugin, but its `config` callback would be a no-op. Two things are
  -- pinned per module -- that it requires the plugin under exactly the name the
  -- plugin publishes, and that it forwards into that handle's `setup()`.
  local modules = {
    { file = "lazydev", plugin = "lazydev" },
    { file = "telescope", plugin = "telescope" },
    { file = "lualine", plugin = "lualine" },
    { file = "bufferline", plugin = "bufferline" },
    { file = "gitsigns", plugin = "gitsigns" },
    { file = "terminal", plugin = "toggleterm" },
    { file = "whichkey", plugin = "which-key" },
    { file = "indentlines", plugin = "ibl" },
    -- mini.nvim explicitly disallows requiring the `mini` umbrella; the
    -- submodule name is the contract.
    { file = "comment", plugin = "mini.comment" },
  }

  for _, m in ipairs(modules) do
    local rel = "lua/lvim/plugins/modules/" .. m.file .. ".lua"

    it(m.file .. ".lua requires " .. m.plugin .. " and forwards to its setup()", function()
      assert.is_true(
        requires_plugin(rel, m.plugin) ~= nil,
        rel .. ' never requires the "' .. m.plugin .. '" plugin outside of comments'
      )
      assert.is_true(
        calls_on_plugin(rel, m.plugin, "setup") ~= nil,
        rel .. " never calls setup() on the " .. m.plugin .. " handle it required"
      )
    end)
  end

  -- which-key v3 deprecated `register()` in favour of `add()`. Pin the v3
  -- entrypoint so a regression that fell back to the deprecated dictionary form
  -- surfaces here: it would register no leader groups at all.
  it("whichkey.lua uses the which-key v3 add() API, not register()", function()
    local rel = "lua/lvim/plugins/modules/whichkey.lua"
    assert.is_true(
      calls_on_plugin(rel, "which-key", "add") ~= nil,
      rel .. " never calls add() on the which-key handle (the v3 API)"
    )
    local n = calls_on_plugin(rel, "which-key", "register")
    assert.is_nil(n, n and (rel .. ":" .. n .. " calls which-key.register(), which v3 replaced with add()") or nil)
  end)

  -- indent-blankline v3 renamed its module from `indent_blankline` to `ibl`;
  -- the v2 name now errors with a hard migration message, so a resurrected v2
  -- require would raise inside the config callback rather than quietly no-op.
  it("indentlines.lua does not resurrect the v2 indent_blankline require", function()
    refute_code_matches(
      "lua/lvim/plugins/modules/indentlines.lua",
      [==[require\s*[(,]\=\s*["']indent_blankline["']]==],
      'still references the v2 require("indent_blankline")'
    )
  end)
end)

describe("commands", function()
  -- The cheapest acceptance signal for Phase 5.3: if a future refactor renames
  -- or drops the schedule_tsupdate plumbing, this fails before any behavioural
  -- check has to fire.
  it(":LvimSyncCorePlugins still reaches TSUpdate", function()
    assert_code_contains("lua/lvim/core/commands.lua", "TSUpdate", "reference TSUpdate")
  end)
end)

-- Coverage for `lvim.plugins.modules.whichkey`'s mapping filter.
--
-- The filter hides bindings whose backing tool is absent (today: the lazygit
-- binding, gated on the `lazygit` executable) and then hides any group label
-- whose bindings were all hidden, so the popup never shows a row that opens
-- onto nothing.
--
-- `vim.fn.executable` is stubbed rather than depending on whether lazygit
-- happens to be installed on the machine running the suite.
--
-- Two regressions this pins, both of which shipped green:
--   * a user-declared group with no child bindings was discarded as if it had
--     been emptied by filtering, silently losing user config;
--   * a nested group (`<leader>da`) survived after all its children were
--     filtered, because children were attributed only to the single-character
--     prefix `<leader>d`;
--   * children were attributed by lhs alone, ignoring `mode`, so a surviving
--     binding in one mode kept another mode's emptied group label alive.

-- `seen` is keyed by lhs and `by_mode` by `<mode> <lhs>`. The mappings list
-- holds several lhs values that exist in both normal and visual mode
-- (`<leader>/`, `<leader>la`, `<leader>gr`, `<leader>gs`), so an lhs-only view
-- cannot tell which of the two survived.
local function capture(mappings)
  local captured
  package.loaded["which-key"] = {
    setup = function() end,
    add = function(spec)
      captured = spec
    end,
  }
  package.loaded["lvim.plugins.modules.whichkey"] = nil
  _G.lvim.builtin.whichkey.mappings = mappings
  require("lvim.plugins.modules.whichkey").setup({})
  local seen = {}
  local by_mode = {}
  for _, entry in ipairs(captured or {}) do
    local value = entry.group or entry[2] or true
    seen[entry[1]] = value
    -- which-key splits a string mode per character, so `"nx"` is two modes.
    local modes = entry.mode
    if type(modes) == "string" and #modes > 0 then
      modes = vim.split(modes, "")
    elseif type(modes) ~= "table" or #modes == 0 then
      modes = { "n" }
    end
    for _, mode in ipairs(modes) do
      by_mode[mode .. " " .. entry[1]] = value
    end
  end
  return seen, captured or {}, by_mode
end

describe("whichkey filter_mappings", function()
  local real_executable

  before_each(function()
    require("lvim.config").load_defaults()
    -- Pin the gated tool as ABSENT so the filtering cases are deterministic.
    real_executable = vim.fn.executable
    vim.fn.executable = function(name)
      if name == "lazygit" then
        return 0
      end
      return real_executable(name)
    end
  end)

  after_each(function()
    vim.fn.executable = real_executable
    package.loaded["which-key"] = nil
    package.loaded["lvim.plugins.modules.whichkey"] = nil
  end)

  it("keeps a user-declared group that has no child bindings", function()
    local seen = capture({
      { "<leader>x", group = "Extra" },
    })
    assert.equals("Extra", seen["<leader>x"])
  end)

  it("drops a group whose every child was filtered out", function()
    local seen = capture({
      { "<leader>k", group = "Gated" },
      { "<leader>kk", "<cmd>lua require('lvim.plugins.modules.terminal').toggle_lazygit()<cr>", desc = "Lazygit" },
    })
    assert.is_nil(seen["<leader>k"])
    assert.is_nil(seen["<leader>kk"])
  end)

  it("drops a NESTED group whose every child was filtered out", function()
    local seen = capture({
      { "<leader>k", group = "Gated" },
      { "<leader>ka", group = "Advanced" },
      { "<leader>kar", "<cmd>lua require('lvim.plugins.modules.terminal').toggle_lazygit()<cr>", desc = "Lazygit" },
    })
    assert.is_nil(seen["<leader>ka"], "nested group should drop with its only child")
    assert.is_nil(seen["<leader>k"], "outer group should drop too")
  end)

  it("keeps a group when at least one child survives", function()
    local seen = capture({
      { "<leader>k", group = "Gated" },
      { "<leader>kk", "<cmd>lua require('lvim.plugins.modules.terminal').toggle_lazygit()<cr>", desc = "Lazygit" },
      { "<leader>kh", "<cmd>echo 'hi'<cr>", desc = "Harmless" },
    })
    assert.equals("Gated", seen["<leader>k"])
    assert.is_nil(seen["<leader>kk"])
    assert.equals("<cmd>echo 'hi'<cr>", seen["<leader>kh"])
  end)

  it("gates on what the binding does, not on the key it sits at", function()
    -- The gate used to require the lhs to be exactly `<leader>gg`, so moving
    -- lazygit to another key silently lost the check and left a row that
    -- errors on press.
    local seen = capture({
      {
        "<leader>zz",
        "<cmd>lua require('lvim.plugins.modules.terminal').toggle_lazygit()<cr>",
        desc = "Lazygit moved",
      },
    })
    assert.is_nil(seen["<leader>zz"])
  end)

  it("keeps the gated binding when the tool IS available", function()
    vim.fn.executable = function(name)
      if name == "lazygit" then
        return 1
      end
      return real_executable(name)
    end
    local seen = capture({
      { "<leader>k", group = "Gated" },
      { "<leader>kk", "<cmd>lua require('lvim.plugins.modules.terminal').toggle_lazygit()<cr>", desc = "Lazygit" },
    })
    assert.equals("Gated", seen["<leader>k"])
    assert.is_not_nil(seen["<leader>kk"])
  end)

  it("forwards every surviving default mapping, not a subset", function()
    require("lvim.config").load_defaults()
    local defaults = vim.deepcopy(_G.lvim.builtin.whichkey.mappings)
    local _, captured, kept_by_mode = capture(vim.deepcopy(defaults))

    -- With lazygit stubbed absent, `<leader>gg` is the only default entry
    -- allowed to be missing.
    local dropped = {}
    local kept = {}
    for _, e in ipairs(captured) do
      kept[e[1]] = true
    end
    -- Compare per mode: several default lhs values exist in both normal and
    -- visual mode, and an lhs-only check would let one of the pair vanish.
    for _, e in ipairs(defaults) do
      if not kept_by_mode[(e.mode or "n") .. " " .. e[1]] then
        dropped[#dropped + 1] = e[1]
      end
    end
    for _, lhs in ipairs(dropped) do
      assert.is_true(
        lhs == "<leader>gg" or lhs:match("^<leader>d") ~= nil,
        string.format("unexpectedly dropped %q from the forwarded mapping list", lhs)
      )
    end

    -- The loop above only bounds what MAY be dropped; on its own a filter that
    -- dropped nothing would satisfy it. Assert the gated binding actually was
    -- dropped, so the check fails if filtering stops working entirely.
    assert.is_nil(kept["<leader>gg"], "expected the lazygit binding to be filtered out")
    assert.is_nil(kept["<leader>dt"], "expected the dap bindings to be filtered out")
    assert.is_nil(kept["<leader>d"], "expected the emptied Debug group to be dropped")
    assert.is_true(#dropped > 0, "expected filtering to drop the gated bindings")
  end)

  it("does not gate an unrelated binding that merely mentions toggle_lazygit", function()
    -- The gate matches LunaVim's own terminal-module call. A bare
    -- `toggle_lazygit` substring would also hide a user's own helper of the
    -- same name, or a mapping carrying that text as data.
    local seen = capture({
      { "<leader>p1", "<cmd>lua require('my.plugin').toggle_lazygit()<cr>", desc = "Someone else's" },
      { "<leader>p2", "<cmd>echo 'toggle_lazygit'<cr>", desc = "Just text" },
    })
    assert.is_not_nil(seen["<leader>p1"], "another plugin's toggle_lazygit is not ours")
    assert.is_not_nil(seen["<leader>p2"], "the bare string is not a lazygit binding")
  end)

  it("keeps ungated bindings untouched", function()
    local seen = capture({
      { "<leader>z", "<cmd>echo 'no tool needed'<cr>" },
    })
    assert.is_not_nil(seen["<leader>z"])
  end)

  it("does not let one mode's surviving child rescue another mode's group", function()
    local _, _, by_mode = capture({
      { "<leader>k", group = "Gated", mode = "x" },
      { "<leader>kk", "<cmd>lua require('lvim.plugins.modules.terminal').toggle_lazygit()<cr>", mode = "x" },
      -- Same lhs, different mode, and it survives. It must not keep the
      -- visual-mode group label alive.
      { "<leader>k", group = "Fine" },
      { "<leader>kh", "<cmd>echo 'hi'<cr>" },
    })
    assert.is_nil(by_mode["x <leader>k"], "the emptied visual group should drop")
    assert.equals("Fine", by_mode["n <leader>k"], "the normal group still has a child")
  end)

  it("does not let one mode's dead child empty another mode's group", function()
    local _, _, by_mode = capture({
      { "<leader>k", group = "Fine", mode = "x" },
      { "<leader>kh", "<cmd>echo 'hi'<cr>", mode = "x" },
      { "<leader>k", group = "Gated" },
      { "<leader>kk", "<cmd>lua require('lvim.plugins.modules.terminal').toggle_lazygit()<cr>" },
    })
    assert.equals("Fine", by_mode["x <leader>k"], "the visual group still has a child")
    assert.is_nil(by_mode["n <leader>k"], "the emptied normal group should drop")
  end)

  it("splits a string mode per character, the way which-key does", function()
    -- `mode = "nx"` is two modes to which-key (`which-key/mappings.lua:278`).
    -- Treating it as the single mode "nx" would leave the child unable to
    -- match its group, and the group would drop as if it had been emptied.
    local _, _, by_mode = capture({
      { "<leader>k", group = "Both", mode = "n" },
      { "<leader>kh", "<cmd>echo 'hi'<cr>", mode = "nx" },
    })
    assert.equals("Both", by_mode["n <leader>k"], "the group's own mode has a surviving child")
  end)

  it("narrows a multi-mode group to the modes that still have children", function()
    -- which-key registers a `mode = { "n", "x" }` group independently in each
    -- mode, so the modes empty independently too. Keeping the row whole would
    -- leave a visual row that opens onto nothing; dropping it whole would lose
    -- a label normal mode still earns.
    local _, captured, by_mode = capture({
      { "<leader>k", group = "Mixed", mode = { "n", "x" } },
      { "<leader>kk", "<cmd>lua require('lvim.plugins.modules.terminal').toggle_lazygit()<cr>", mode = "x" },
      { "<leader>kh", "<cmd>echo 'hi'<cr>" },
    })
    assert.equals("Mixed", by_mode["n <leader>k"], "normal mode still has a surviving child")
    assert.is_nil(by_mode["x <leader>k"], "visual mode lost its only child")

    for _, entry in ipairs(captured) do
      if entry.group == "Mixed" then
        assert.same({ "n" }, entry.mode)
      end
    end
  end)

  it("keeps a mode of a multi-mode group that has no children at all", function()
    -- Same rule as a single-mode childless group: a label with no children was
    -- declared deliberately, it was not emptied by filtering.
    local _, captured, by_mode = capture({
      { "<leader>k", group = "Mixed", mode = { "n", "x" } },
      { "<leader>kh", "<cmd>echo 'hi'<cr>", mode = "x" },
    })
    assert.equals("Mixed", by_mode["x <leader>k"], "visual mode has a surviving child")
    assert.equals("Mixed", by_mode["n <leader>k"], "normal mode never had children to lose")

    for _, entry in ipairs(captured) do
      if entry.group == "Mixed" then
        assert.same({ "n", "x" }, entry.mode, "an entry that loses no mode is not rewritten")
      end
    end
  end)

  it("drops a multi-mode group emptied in every mode it names", function()
    local _, _, by_mode = capture({
      { "<leader>k", group = "Mixed", mode = { "n", "x" } },
      { "<leader>kn", "<cmd>lua require('lvim.plugins.modules.terminal').toggle_lazygit()<cr>" },
      { "<leader>kx", "<cmd>lua require('lvim.plugins.modules.terminal').toggle_lazygit()<cr>", mode = "x" },
    })
    assert.is_nil(by_mode["n <leader>k"])
    assert.is_nil(by_mode["x <leader>k"])
  end)

  it("leaves the user's own mode spelling alone when no mode is narrowed", function()
    -- Rewriting `mode = "nx"` into `{ "n", "x" }` when nothing was filtered
    -- would churn a table the user wrote and which-key already understands.
    local _, captured = capture({
      { "<leader>k", group = "Mixed", mode = "nx" },
      { "<leader>kh", "<cmd>echo 'hi'<cr>", mode = "nx" },
    })
    for _, entry in ipairs(captured) do
      if entry.group == "Mixed" then
        assert.equals("nx", entry.mode)
      end
    end
  end)

  it("ships the visual-mode leader bindings ported from the reference vmappings", function()
    require("lvim.config").load_defaults()
    local _, _, by_mode = capture(vim.deepcopy(_G.lvim.builtin.whichkey.mappings))

    -- `references/CKLunarVim/lua/lvim/core/which-key.lua:78-85`. Without
    -- these, `<leader>/` in visual mode falls through to `<Space>` + `/` and
    -- starts a search instead of commenting the selection.
    assert.equals("gc", by_mode["x <leader>/"], "visual comment toggle")
    assert.is_not_nil(by_mode["x <leader>la"], "visual code action")
    assert.is_not_nil(by_mode["x <leader>gr"], "visual reset hunk")
    assert.is_not_nil(by_mode["x <leader>gs"], "visual stage hunk")

    -- which-key keeps one tree per mode, so the normal-mode group rows do not
    -- label the visual prefixes.
    assert.equals("LSP", by_mode["x <leader>l"])
    assert.equals("Git", by_mode["x <leader>g"])

    -- The visual hunk bindings must pass the selection explicitly; called
    -- bare, gitsigns acts on the cursor hunk and silently ignores the range.
    for _, lhs in ipairs({ "<leader>gr", "<leader>gs" }) do
      assert.is_truthy(
        by_mode["x " .. lhs]:find("vim.fn.line('v')", 1, true),
        string.format("visual %s must pass the selection range to gitsigns", lhs)
      )
    end
  end)

  it("marks the delegating comment bindings as remappable", function()
    require("lvim.config").load_defaults()
    -- `gcc`/`gc` are themselves mappings, so a `noremap` binding would resolve
    -- to the built-in `g` prefix and do nothing useful.
    for _, entry in ipairs(_G.lvim.builtin.whichkey.mappings) do
      if entry[1] == "<leader>/" then
        assert.is_true(entry.remap, string.format("<leader>/ (mode %s) must set remap", entry.mode or "n"))
      end
    end
  end)
end)

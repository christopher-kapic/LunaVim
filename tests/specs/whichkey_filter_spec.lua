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
--     prefix `<leader>d`.

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
  for _, entry in ipairs(captured or {}) do
    seen[entry[1]] = entry.group or entry[2] or true
  end
  return seen, captured or {}
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
    local _, captured = capture(vim.deepcopy(defaults))

    -- With lazygit stubbed absent, `<leader>gg` is the only default entry
    -- allowed to be missing.
    local dropped = {}
    local kept = {}
    for _, e in ipairs(captured) do
      kept[e[1]] = true
    end
    for _, e in ipairs(defaults) do
      if not kept[e[1]] then
        dropped[#dropped + 1] = e[1]
      end
    end
    for _, lhs in ipairs(dropped) do
      assert.is_true(lhs == "<leader>gg", string.format("unexpectedly dropped %q from the forwarded mapping list", lhs))
    end

    -- The loop above only bounds what MAY be dropped; on its own a filter that
    -- dropped nothing would satisfy it. Assert the gated binding actually was
    -- dropped, so the check fails if filtering stops working entirely.
    assert.is_nil(kept["<leader>gg"], "expected the lazygit binding to be filtered out")
    assert.is_true(#dropped > 0, "expected filtering to drop the gated binding")
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
end)

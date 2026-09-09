-- Coverage for `lvim.plugins.modules.whichkey`'s mapping filter.
--
-- The filter hides bindings whose backing plugin is absent (the `<leader>d`
-- debug family, which all `require('dap')`) and then hides any group label
-- whose bindings were all hidden, so the popup never shows a row that opens
-- onto nothing.
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
  before_each(function()
    require("lvim.config").load_defaults()
    -- dap/dapui must be absent for the filtering cases below.
    package.loaded["dap"] = nil
    package.loaded["dapui"] = nil
  end)

  after_each(function()
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
      { "<leader>d", group = "Debug" },
      { "<leader>dt", "<cmd>lua require'dap'.toggle_breakpoint()<cr>", desc = "Toggle Breakpoint" },
    })
    assert.is_nil(seen["<leader>d"])
    assert.is_nil(seen["<leader>dt"])
  end)

  it("drops a NESTED group whose every child was filtered out", function()
    local seen = capture({
      { "<leader>d", group = "Debug" },
      { "<leader>da", group = "Advanced" },
      { "<leader>dar", "<cmd>lua require'dap'.run()<cr>", desc = "Run" },
    })
    assert.is_nil(seen["<leader>da"])
    assert.is_nil(seen["<leader>d"])
  end)

  it("keeps a group when at least one child survives", function()
    local seen = capture({
      { "<leader>d", group = "Debug" },
      { "<leader>dt", "<cmd>lua require'dap'.toggle_breakpoint()<cr>", desc = "Toggle Breakpoint" },
      { "<leader>dh", "<cmd>echo 'hi'<cr>", desc = "Harmless" },
    })
    assert.equals("Debug", seen["<leader>d"])
    assert.is_nil(seen["<leader>dt"])
    assert.equals("<cmd>echo 'hi'<cr>", seen["<leader>dh"])
  end)

  it("recognises every Lua spelling of require when filtering dap bindings", function()
    local seen = capture({
      { "<leader>d1", "<cmd>lua require'dap'.continue()<cr>" },
      { "<leader>d2", '<cmd>lua require("dap").continue()<cr>' },
      { "<leader>d3", "<cmd>lua require('dap').continue()<cr>" },
      { "<leader>d4", '<cmd>lua require "dap".continue()<cr>' },
      { "<leader>d5", "<cmd>lua require([[dap]]).continue()<cr>" },
      { "<leader>d6", "<cmd>lua require([=[dap]=]).continue()<cr>" },
    })
    for _, lhs in ipairs({ "<leader>d1", "<leader>d2", "<leader>d3", "<leader>d4", "<leader>d5", "<leader>d6" }) do
      assert.is_nil(seen[lhs], lhs .. " should have been filtered with dap absent")
    end
  end)

  it("forwards every surviving default mapping, not a subset", function()
    require("lvim.config").load_defaults()
    local defaults = vim.deepcopy(_G.lvim.builtin.whichkey.mappings)
    local _, captured = capture(vim.deepcopy(defaults))

    -- Nothing in the defaults requires a module that is present in this
    -- harness except lazygit-gated `<leader>gg`, so the only entries allowed
    -- to be missing are the dap family and that one.
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
      assert.is_true(
        lhs:match("^<leader>d") ~= nil or lhs == "<leader>gg",
        string.format("unexpectedly dropped %q from the forwarded mapping list", lhs)
      )
    end

    -- The loop above only bounds what MAY be dropped; on its own a filter that
    -- dropped nothing would satisfy it. Assert the dap family actually was
    -- dropped, so the check fails if filtering stops working entirely.
    assert.is_nil(kept["<leader>dt"], "expected the dap bindings to be filtered out")
    assert.is_nil(kept["<leader>d"], "expected the emptied Debug group to be dropped")
    assert.is_true(#dropped > 0, "expected filtering to drop the dap family")
  end)

  it("keeps a non-dap binding that merely mentions another plugin name", function()
    local seen = capture({
      { "<leader>z", "<cmd>echo 'no plugin here'<cr>" },
      { "<leader>y", "<cmd>lua myrequire('dap').continue()<cr>" },
    })
    assert.is_not_nil(seen["<leader>z"])
    assert.is_not_nil(seen["<leader>y"], "myrequire('dap') is not a require of dap")
  end)
end)

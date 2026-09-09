-- The LunarVim `lvim.lsp.null-ls.*` compatibility surface must stay require-able.
--
-- config.lua is executed as a single chunk, so a `module not found` raised part
-- way through it aborts every later line as well. A user migrating from
-- LunarVim then gets a silently half-applied config, with the error naming a
-- module rather than the setting that quietly never took effect. That is the
-- regression this spec exists to prevent -- it is about load-bearing
-- compatibility, not about the modules doing anything useful.

describe("lvim.lsp.null-ls compat surface", function()
  local modules = {
    "lvim.lsp.null-ls",
    "lvim.lsp.null-ls.formatters",
    "lvim.lsp.null-ls.linters",
    "lvim.lsp.null-ls.code_actions",
  }

  before_each(function()
    require("lvim.config").load_defaults()
  end)

  it("every documented submodule is require-able", function()
    for _, name in ipairs(modules) do
      local ok, mod = pcall(require, name)
      assert.is_true(ok, string.format("require(%q) failed: %s", name, tostring(mod)))
      assert.is_table(mod)
    end
  end)

  it("every submodule exposes the LunarVim call surface", function()
    for _, name in ipairs(modules) do
      local mod = require(name)
      assert.is_function(mod.setup, name .. ".setup should be callable")
    end
    -- The three per-kind modules also answer introspection calls.
    for _, name in ipairs({
      "lvim.lsp.null-ls.formatters",
      "lvim.lsp.null-ls.linters",
      "lvim.lsp.null-ls.code_actions",
    }) do
      local mod = require(name)
      assert.is_function(mod.list_registered, name .. ".list_registered should be callable")
      assert.is_function(mod.list_supported, name .. ".list_supported should be callable")
    end
  end)

  it("code_actions accepts a legacy registration without raising", function()
    local code_actions = require("lvim.lsp.null-ls.code_actions")
    assert.has_no.errors(function()
      code_actions.setup({
        { name = "eslint_d", filetypes = { "typescript", "typescriptreact" } },
      })
    end)
    -- It has no backend, so it reports nothing as registered. Returning entries
    -- that never run would be a worse lie than returning none.
    assert.same({}, code_actions.list_registered("typescript"))
  end)

  it("the umbrella module's setup is a harmless no-op", function()
    assert.has_no.errors(function()
      require("lvim.lsp.null-ls").setup({ debug = false })
    end)
  end)
end)

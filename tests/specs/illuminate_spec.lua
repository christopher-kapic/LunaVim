-- Coverage for `lvim.plugins.modules.illuminate`.
--
-- The one thing worth pinning is the entry point: vim-illuminate configures via
-- `configure()`, NOT the `setup()` every other plugin here uses, and calling
-- `setup` on it fails silently -- the options would simply never apply.

describe("lvim.plugins.modules.illuminate", function()
  local captured

  before_each(function()
    require("lvim.config").load_defaults()
    captured = nil
    package.loaded["illuminate"] = {
      configure = function(opts)
        captured = opts
      end,
      setup = function()
        error("illuminate configures via configure(), not setup()")
      end,
    }
    package.loaded["lvim.plugins.modules.illuminate"] = nil
  end)

  after_each(function()
    package.loaded["illuminate"] = nil
    package.loaded["lvim.plugins.modules.illuminate"] = nil
  end)

  it("forwards lvim.builtin.illuminate.options to configure()", function()
    require("lvim.plugins.modules.illuminate").setup({})

    assert.is_table(captured)
    assert.same({ "lsp", "treesitter", "regex" }, captured.providers)
    assert.equals(200, captured.delay)
    assert.equals(2000, captured.large_file_cutoff)
  end)

  it("forwards a user override", function()
    _G.lvim.builtin.illuminate.options.delay = 500
    table.insert(_G.lvim.builtin.illuminate.options.filetypes_denylist, "markdown")

    require("lvim.plugins.modules.illuminate").setup({})

    assert.equals(500, captured.delay)
    assert.is_truthy(vim.tbl_contains(captured.filetypes_denylist, "markdown"))
  end)

  it("does not mutate the live builtin table", function()
    require("lvim.plugins.modules.illuminate").setup({})
    captured.delay = "MUTATED"

    assert.equals(200, _G.lvim.builtin.illuminate.options.delay)
  end)

  it("is a no-op when the plugin is absent", function()
    package.loaded["illuminate"] = nil
    package.loaded["lvim.plugins.modules.illuminate"] = nil

    assert.has_no.errors(function()
      require("lvim.plugins.modules.illuminate").setup({})
    end)
  end)
end)

describe("autopairs module", function()
  local original_lvim
  local original_blink_pairs
  local original_preload
  local setup_opts

  before_each(function()
    require("lvim.config").load_defaults()
    original_lvim = _G.lvim
    original_blink_pairs = package.loaded["blink.pairs"]
    original_preload = package.preload["blink.pairs"]
    setup_opts = nil

    package.loaded["lvim.plugins.modules.autopairs"] = nil
    package.loaded["blink.pairs"] = nil
    package.preload["blink.pairs"] = function()
      return {
        setup = function(opts)
          setup_opts = opts
        end,
      }
    end
  end)

  after_each(function()
    package.loaded["lvim.plugins.modules.autopairs"] = nil
    package.loaded["blink.pairs"] = original_blink_pairs
    package.preload["blink.pairs"] = original_preload
    _G.lvim = original_lvim
  end)

  it("forwards lvim.builtin.autopairs (minus active) to blink.pairs.setup", function()
    require("lvim.plugins.modules.autopairs").setup()

    assert.is_table(setup_opts)
    assert.is_nil(setup_opts.active)
    assert.is_true(setup_opts.mappings.enabled)
    assert.is_true(setup_opts.highlights.enabled)
    assert.is_truthy(vim.tbl_contains(setup_opts.mappings.disabled_filetypes, "TelescopePrompt"))
  end)

  it("forwards a user override", function()
    _G.lvim.builtin.autopairs.highlights.enabled = false

    require("lvim.plugins.modules.autopairs").setup()

    assert.is_false(setup_opts.highlights.enabled)
  end)

  it("does not mutate the live builtin table", function()
    require("lvim.plugins.modules.autopairs").setup()

    setup_opts.mappings.enabled = false
    setup_opts.highlights.enabled = false

    assert.is_true(_G.lvim.builtin.autopairs.mappings.enabled)
    assert.is_true(_G.lvim.builtin.autopairs.highlights.enabled)
  end)

  it("does not error when blink.pairs is absent", function()
    package.loaded["blink.pairs"] = nil
    package.preload["blink.pairs"] = nil

    assert.has_no.errors(function()
      require("lvim.plugins.modules.autopairs").setup()
    end)
    assert.is_nil(setup_opts)
  end)
end)

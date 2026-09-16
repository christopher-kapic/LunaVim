describe("autopairs module", function()
  local original_lvim
  local original_mini_pairs
  local original_preload
  local original_buf
  local setup_opts

  before_each(function()
    require("lvim.config").load_defaults()
    original_lvim = _G.lvim
    original_mini_pairs = package.loaded["mini.pairs"]
    original_preload = package.preload["mini.pairs"]
    original_buf = vim.api.nvim_get_current_buf()
    setup_opts = nil

    package.loaded["lvim.plugins.modules.autopairs"] = nil
    package.loaded["mini.pairs"] = nil
    package.preload["mini.pairs"] = function()
      return {
        setup = function(opts)
          setup_opts = opts
        end,
      }
    end
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "lvim_minipairs_disable")
    package.loaded["lvim.plugins.modules.autopairs"] = nil
    package.loaded["mini.pairs"] = original_mini_pairs
    package.preload["mini.pairs"] = original_preload
    _G.lvim = original_lvim

    if vim.api.nvim_buf_is_valid(original_buf) then
      vim.api.nvim_set_current_buf(original_buf)
    end
  end)

  it("forwards lvim.builtin.autopairs.options to mini.pairs.setup", function()
    require("lvim.plugins.modules.autopairs").setup()

    assert.is_table(setup_opts)
    assert.is_true(setup_opts.modes.insert)
    assert.is_true(setup_opts.modes.command)
    assert.is_false(setup_opts.modes.terminal)
    assert.is_nil(setup_opts.active)
    assert.is_nil(setup_opts.disabled_filetypes)
  end)

  it("forwards a user override", function()
    _G.lvim.builtin.autopairs.options.modes.command = false

    require("lvim.plugins.modules.autopairs").setup()

    assert.is_false(setup_opts.modes.command)
  end)

  it("does not mutate the live builtin table", function()
    require("lvim.plugins.modules.autopairs").setup()

    setup_opts.modes.command = false

    assert.is_true(_G.lvim.builtin.autopairs.options.modes.command)
  end)

  it("does not error when mini.pairs is absent", function()
    package.loaded["mini.pairs"] = nil
    package.preload["mini.pairs"] = nil

    assert.has_no.errors(function()
      require("lvim.plugins.modules.autopairs").setup()
    end)
    assert.is_nil(setup_opts)
  end)

  it("sets vim.b.minipairs_disable for configured filetypes", function()
    require("lvim.plugins.modules.autopairs").setup()

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "TelescopePrompt"
    vim.api.nvim_exec_autocmds("FileType", { buffer = bufnr })

    assert.is_true(vim.b[bufnr].minipairs_disable == true)
  end)

  it("accepts disabled_filetypes as a map", function()
    _G.lvim.builtin.autopairs.disabled_filetypes = { TelescopePrompt = true, markdown = false }

    require("lvim.plugins.modules.autopairs").setup()

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "TelescopePrompt"
    vim.api.nvim_exec_autocmds("FileType", { buffer = bufnr })

    assert.is_true(vim.b[bufnr].minipairs_disable == true)
  end)

  it("clears minipairs_disable when the filetype leaves the disabled set", function()
    require("lvim.plugins.modules.autopairs").setup()

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "TelescopePrompt"
    vim.api.nvim_exec_autocmds("FileType", { buffer = bufnr })
    assert.is_true(vim.b[bufnr].minipairs_disable == true)

    vim.bo[bufnr].filetype = "markdown"
    vim.api.nvim_exec_autocmds("FileType", { buffer = bufnr })
    assert.is_nil(vim.b[bufnr].minipairs_disable)
  end)

  it("clears prior disable rules when disabled_filetypes is empty", function()
    require("lvim.plugins.modules.autopairs").setup()

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "TelescopePrompt"
    vim.api.nvim_exec_autocmds("FileType", { buffer = bufnr })
    assert.is_true(vim.b[bufnr].minipairs_disable == true)

    _G.lvim.builtin.autopairs.disabled_filetypes = {}
    require("lvim.plugins.modules.autopairs").setup()
    assert.is_nil(vim.b[bufnr].minipairs_disable)

    vim.bo[bufnr].filetype = "TelescopePrompt"
    vim.api.nvim_exec_autocmds("FileType", { buffer = bufnr })
    assert.is_nil(vim.b[bufnr].minipairs_disable)
  end)
end)

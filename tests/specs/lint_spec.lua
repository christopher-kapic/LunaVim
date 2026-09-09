-- Behavioral coverage for the LunarVim `lvim.lsp.null-ls.linters` shim and its
-- nvim-lint backend (`lvim.plugins.modules.lint`).
--
-- This spec exists because two real bugs shipped through a green suite that had
-- no test for this path at all:
--   * registrations made from config.lua never reached nvim-lint, because the
--     plugin had no lazy trigger and so its `config` callback never ran;
--   * `extra_args` were re-appended on every re-application, because the
--     override was rebuilt from the previously-overridden definition instead of
--     from an immutable baseline.
-- Both are pinned below.

local function fresh_lint_stub()
  -- Minimal stand-in for nvim-lint: `linters` is a plain table of definitions
  -- and `linters_by_ft` is what the module assigns.
  return {
    linters_by_ft = {},
    linters = {
      shellcheck = { cmd = "shellcheck", args = { "--format", "json" } },
      flake8 = { cmd = "flake8", args = { "--stdin-display-name" } },
    },
    try_lint = function() end,
  }
end

local function reload_modules()
  package.loaded["lvim.plugins.modules.lint"] = nil
  package.loaded["lvim.lsp.null-ls.linters"] = nil
end

describe("null-ls linters shim -> nvim-lint", function()
  local stub

  before_each(function()
    require("lvim.config").load_defaults()
    _G.lvim._null_ls_registry = nil
    stub = fresh_lint_stub()
    package.loaded["lint"] = stub
    reload_modules()
    pcall(vim.api.nvim_del_augroup_by_name, "lvim_nvim_lint")
  end)

  after_each(function()
    package.loaded["lint"] = nil
    reload_modules()
  end)

  it("translates registrations into linters_by_ft", function()
    require("lvim.lsp.null-ls.linters").setup({
      { name = "shellcheck", filetypes = { "sh", "bash" } },
      { name = "flake8", filetypes = { "python" } },
    })

    assert.same({ "shellcheck" }, stub.linters_by_ft.sh)
    assert.same({ "shellcheck" }, stub.linters_by_ft.bash)
    assert.same({ "flake8" }, stub.linters_by_ft.python)
  end)

  it("applies extra_args exactly once, even across repeated setup calls", function()
    local linters = require("lvim.lsp.null-ls.linters")
    linters.setup({
      { name = "shellcheck", filetypes = { "sh" }, extra_args = { "--severity", "warning" } },
    })

    local after_first = vim.deepcopy(stub.linters.shellcheck.args)
    assert.same({ "--format", "json", "--severity", "warning" }, after_first)

    -- A second, unrelated registration re-enters the backend. The shellcheck
    -- override must be rebuilt from its baseline, not from the already
    -- augmented definition, or the extras accumulate.
    linters.setup({ { name = "flake8", filetypes = { "python" } } })
    assert.same(after_first, stub.linters.shellcheck.args)

    -- A third pass, this time re-registering shellcheck itself.
    linters.setup({
      { name = "shellcheck", filetypes = { "sh" }, extra_args = { "--severity", "warning" } },
    })
    assert.same(after_first, stub.linters.shellcheck.args)
  end)

  it("honors a command override without touching the baseline args", function()
    require("lvim.lsp.null-ls.linters").setup({
      { name = "flake8", filetypes = { "python" }, command = "/usr/local/bin/flake8" },
    })

    assert.equals("/usr/local/bin/flake8", stub.linters.flake8.cmd)
    assert.same({ "--stdin-display-name" }, stub.linters.flake8.args)
  end)

  it("installs the lint autocmd when at least one linter is registered", function()
    require("lvim.lsp.null-ls.linters").setup({
      { name = "shellcheck", filetypes = { "sh" } },
    })

    local autocmds = vim.api.nvim_get_autocmds({ group = "lvim_nvim_lint" })
    assert.is_true(#autocmds > 0)
  end)

  it("installs no autocmd when nothing is registered", function()
    require("lvim.plugins.modules.lint").setup({})

    local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = "lvim_nvim_lint" })
    assert.is_true(not ok or #autocmds == 0)
  end)

  it("skips registrations with no filetypes rather than linting everything", function()
    require("lvim.lsp.null-ls.linters").setup({
      { name = "shellcheck" },
      { name = "flake8", filetypes = {} },
    })

    assert.same({}, stub.linters_by_ft)
  end)

  it("does not re-append extra_args after the backend module is re-required", function()
    -- `:LvimReload` and `reload("lvim.plugins.modules.lint")` both re-require
    -- this module. A cache held in a module-local would be rebuilt from the
    -- already-augmented definition and start appending on top of it, so the
    -- baselines live on the `lint` module table instead. Note the stub is NOT
    -- recreated here: that is the whole point -- the backend state persists
    -- while our module is reloaded underneath it.
    local linters = require("lvim.lsp.null-ls.linters")
    linters.setup({
      { name = "shellcheck", filetypes = { "sh" }, extra_args = { "--severity", "warning" } },
    })
    local after_first = vim.deepcopy(stub.linters.shellcheck.args)

    package.loaded["lvim.plugins.modules.lint"] = nil
    require("lvim.plugins.modules.lint").setup({})

    assert.same(after_first, stub.linters.shellcheck.args)
  end)

  it("clears linters_by_ft and the autocmd when a reload empties the registry", function()
    require("lvim.lsp.null-ls.linters").setup({
      { name = "shellcheck", filetypes = { "sh" } },
    })
    assert.same({ "shellcheck" }, stub.linters_by_ft.sh)

    -- `:LvimReload` replaces `_G.lvim` (and with it the registry) and then
    -- re-enters the backend. With the registration gone from config.lua the
    -- registry is empty, and the previous session's state must not survive.
    require("lvim.config").load_defaults()
    require("lvim.plugins.modules.lint").setup({})

    assert.same({}, stub.linters_by_ft)
    local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = "lvim_nvim_lint" })
    assert.is_true(not ok or #autocmds == 0)
  end)

  it("reverts a definition to baseline when its override is removed", function()
    -- The user drops `extra_args` from an existing registration and reloads.
    -- Writing only the NEW overrides would leave the augmented definition in
    -- place, so shellcheck would keep running with arguments the config no
    -- longer asks for.
    local linters = require("lvim.lsp.null-ls.linters")
    linters.setup({
      { name = "shellcheck", filetypes = { "sh" }, extra_args = { "--severity", "warning" } },
    })
    assert.same({ "--format", "json", "--severity", "warning" }, stub.linters.shellcheck.args)

    -- Reload: fresh registry, registration kept but the override removed.
    require("lvim.config").load_defaults()
    linters.setup({ { name = "shellcheck", filetypes = { "sh" } } })

    assert.same({ "--format", "json" }, stub.linters.shellcheck.args)
  end)

  it("reverts a definition to baseline when the linter is removed entirely", function()
    local linters = require("lvim.lsp.null-ls.linters")
    linters.setup({
      { name = "shellcheck", filetypes = { "sh" }, extra_args = { "--severity", "warning" } },
    })

    require("lvim.config").load_defaults()
    require("lvim.plugins.modules.lint").setup({})

    assert.same({ "--format", "json" }, stub.linters.shellcheck.args)
  end)

  it("does not clobber a linters_by_ft that LunaVim never managed", function()
    -- Someone configured nvim-lint directly, and this config registers nothing
    -- through the shim. A reload must leave their setup alone.
    stub.linters_by_ft = { markdown = { "vale" } }
    require("lvim.plugins.modules.lint").setup({})
    assert.same({ markdown = { "vale" } }, stub.linters_by_ft)
  end)

  it("warns when one linter is registered twice and only one carries an override", function()
    local notifications = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level)
      notifications[#notifications + 1] = { msg = msg, level = level }
    end

    require("lvim.lsp.null-ls.linters").setup({
      { name = "shellcheck", filetypes = { "sh" } },
      { name = "shellcheck", filetypes = { "bash" }, extra_args = { "--severity", "error" } },
    })
    vim.wait(200, function()
      return #notifications > 0
    end)
    vim.notify = real_notify

    local warned = false
    for _, n in ipairs(notifications) do
      if
        type(n.msg) == "string"
        and n.msg:find("shellcheck", 1, true)
        and n.msg:find("last registration wins", 1, true)
      then
        warned = true
      end
    end
    assert.is_true(warned, "expected a conflict warning naming shellcheck")
  end)

  it("picks up a linter defined after the first pass", function()
    -- nvim-lint's `linters` table is populated lazily, and a custom linter can
    -- be defined by a plugin that loads later than our first pass. A cached
    -- "no such linter" would suppress its override for the rest of the session.
    local linters = require("lvim.lsp.null-ls.linters")
    linters.setup({
      { name = "custom_linter", filetypes = { "text" }, extra_args = { "--strict" } },
    })
    assert.is_nil(stub.linters.custom_linter)

    stub.linters.custom_linter = { cmd = "custom", args = { "--base" } }
    linters.setup({ { name = "custom_linter", filetypes = { "text" }, extra_args = { "--strict" } } })

    assert.same({ "--base", "--strict" }, stub.linters.custom_linter.args)
  end)

  it("records registrations even when nvim-lint is not loadable yet", function()
    -- This is the config.lua-time state: user config runs before lazy.nvim
    -- exists, so `require("lint")` fails. The registration must still be
    -- recorded so the plugin's own config callback can apply it later.
    package.loaded["lint"] = nil
    reload_modules()

    local linters = require("lvim.lsp.null-ls.linters")
    linters.setup({ { name = "shellcheck", filetypes = { "sh" } } })

    assert.same({ "shellcheck" }, linters.list_registered("sh"))

    -- Now the plugin loads and its config callback re-enters the backend.
    stub = fresh_lint_stub()
    package.loaded["lint"] = stub
    package.loaded["lvim.plugins.modules.lint"] = nil
    require("lvim.plugins.modules.lint").setup({})

    assert.same({ "shellcheck" }, stub.linters_by_ft.sh)
  end)
end)

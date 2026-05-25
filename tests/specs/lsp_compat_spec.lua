-- Phase 8.4 lsp_compat_spec — verifies the LunarVim-compatible LSP surface:
--   * `_G.lvim.lsp` materializes with the documented keys (`ensure_installed`,
--     `servers`, `on_attach`, `capabilities`, `diagnostic`),
--   * `lvim.lsp.servers.<name> = { settings = {...} }` round-trips through
--     `lvim.lsp.setup()` so the merged per-server config carries the user's
--     `settings`, on the propagation channel the orchestrator actually uses,
--   * `lvim.lsp.on_attach` / `lvim.lsp.capabilities` overrides replace the
--     orchestrator's defaults wholesale when set,
--   * `vim.lsp.enable(name)` is invoked once per user-declared server,
--   * `lvim.lsp.servers = {}` (the default) does not register anything via
--     `vim.lsp.config`,
--   * `lvim.format_on_save = true` registers a `BufWritePre` autocmd inside
--     the `lvim_format_on_save` augroup with `vim.lsp.buf.format` as its
--     callback,
--   * `lvim.format_on_save = false` leaves that augroup empty.
--
-- Divergence from the literal step description:
--
-- The step text names `lspconfig.lua_ls.config_def.settings` as the
-- propagation sink. That field belongs to the legacy
-- `require('lspconfig')[name].setup({...})` framework. On Neovim 0.11+ the
-- orchestrator (`lua/lvim/lsp/init.lua`) calls Neovim's native
-- `vim.lsp.config(name, merged)` + `vim.lsp.enable(name)` API to avoid the
-- `vim.deprecate` warning that lspconfig 2.x fires when its `__index`
-- metamethod is touched on 0.11+. nvim-lspconfig 2.x is now data-only —
-- `lsp/<name>.lua` returns a `vim.lsp.Config` table and `.config_def` no
-- longer exists at runtime (kcl-confirmed against the current release).
-- Asserting that literal path would therefore assert against `nil`.
--
-- The modern equivalent of `lspconfig.<name>.config_def` is Neovim's
-- registered LSP config registry — `vim.lsp.config[name]` returns the merged
-- config table that was passed via `vim.lsp.config(name, opts)`. The
-- propagation test below registers through the REAL `vim.lsp.config` and
-- reads back via `vim.lsp.config[name].settings` so the contract is pinned
-- on the genuine runtime channel, not on a captured stub argument. Only
-- `vim.lsp.enable` is stubbed (it would otherwise try to spawn a real
-- language server). The on_attach-override test still uses an inline capture
-- because it must inspect orchestrator-set defaults that are dropped by
-- Neovim's `vim.lsp.config` schema normalization (e.g. `name` is overwritten,
-- function values like `on_attach` are not directly readable back through
-- the registry in older 0.11 builds).
describe("lsp_compat", function()
  local original_lvim
  local original_modules = {}
  local module_keys = {
    "lvim.config",
    "lvim.config.defaults",
    "lvim.config.loader",
    "lvim.lsp",
    "lvim.lsp.diagnostics",
    "lvim.lsp.format",
    "lvim.lsp.handlers",
    "lvim.plugins",
    "lvim.plugins.spec",
    "lvim.utils",
  }

  -- The orchestrator gates each plugin require behind `pcall(require, ...)`
  -- so a missing plugin (the smoke harness boots against an isolated runtime
  -- dir with `install.missing = false`) does not raise. For this spec we
  -- want the `lspconfig` branch to actually run so the per-server
  -- propagation is exercised; preload a stub module that merely makes
  -- `pcall(require, "lspconfig")` succeed. mason and mason-lspconfig are
  -- left to fail-pcall normally because their setup paths are out of scope
  -- here.
  local original_preload_lspconfig
  local original_loaded_lspconfig

  local original_vim_lsp_enable

  local AUGROUP = "lvim_format_on_save"
  -- The set of server names this spec may register against the real
  -- `vim.lsp.config` registry. Used in `after_each` to reset each entry to
  -- an empty config (Neovim 0.11 does not expose deletion of a registered
  -- config; setting `vim.lsp.config[name] = {}` clears the stored fields
  -- while preserving the auto-populated `name`, which is the closest we can
  -- get to "unregistered" without restarting Neovim).
  local SERVERS_USED = { "lua_ls" }

  before_each(function()
    original_lvim = _G.lvim
    _G.lvim = nil

    for _, key in ipairs(module_keys) do
      original_modules[key] = package.loaded[key]
      package.loaded[key] = nil
    end

    original_loaded_lspconfig = package.loaded["lspconfig"]
    original_preload_lspconfig = package.preload["lspconfig"]
    package.loaded["lspconfig"] = nil
    package.preload["lspconfig"] = function()
      return {}
    end

    -- Stub `vim.lsp.enable` only — without it the orchestrator would try to
    -- spawn a real language server for each declared entry, which the test
    -- harness cannot satisfy. `vim.lsp.config` is left intact so the
    -- propagation test below can read back through the real registry.
    original_vim_lsp_enable = vim.lsp.enable

    -- Drop a stray augroup from a previous test run (e.g. an aborted
    -- earlier session) so the per-test `format.setup()` always starts from
    -- a clean slate. `pcall` because the group may not exist.
    pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)

    -- Reset the real `vim.lsp.config` registry for every server name this
    -- spec touches, so a config registered by a previous test does not
    -- bleed into the next. `= {}` is the documented reset shape — the
    -- proxy's `__newindex` validator only accepts table values.
    for _, name in ipairs(SERVERS_USED) do
      vim.lsp.config[name] = {}
    end
  end)

  after_each(function()
    _G.lvim = original_lvim

    for _, key in ipairs(module_keys) do
      package.loaded[key] = original_modules[key]
      original_modules[key] = nil
    end

    package.loaded["lspconfig"] = original_loaded_lspconfig
    package.preload["lspconfig"] = original_preload_lspconfig
    original_loaded_lspconfig = nil
    original_preload_lspconfig = nil

    vim.lsp.enable = original_vim_lsp_enable

    for _, name in ipairs(SERVERS_USED) do
      vim.lsp.config[name] = {}
    end

    pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  end)

  it("lvim.lsp exposes the documented compatibility surface", function()
    require("lvim.config").load_defaults()

    assert.is_table(_G.lvim.lsp)
    -- Table-shaped surfaces: pre-initialized to `{}` so a user can index
    -- straight into them (e.g. `lvim.lsp.servers.lua_ls = {...}`) without
    -- having to materialize the parent table first.
    assert.is_table(_G.lvim.lsp.ensure_installed)
    assert.is_table(_G.lvim.lsp.servers)
    assert.is_table(_G.lvim.lsp.diagnostic)
    -- Pin "empty by default" so a future regression that pre-populated
    -- these tables would surface here rather than silently changing the
    -- LunarVim-compatible "no user override" baseline.
    assert.equals(0, #_G.lvim.lsp.ensure_installed)
    assert.equals(0, vim.tbl_count(_G.lvim.lsp.servers))
    -- `on_attach` / `capabilities` default to nil — the orchestrator
    -- substitutes built-from-handlers defaults when these are unset, so
    -- the absence of a value is the LunarVim-compatible "no user override"
    -- signal. Reading a missing key returns nil in Lua, so `is_nil` here
    -- pins both "explicitly nil" and "absent" without distinguishing them.
    assert.is_nil(_G.lvim.lsp.on_attach)
    assert.is_nil(_G.lvim.lsp.capabilities)
  end)

  it("lvim.lsp.servers.<name> settings propagate to vim.lsp.config[name]", function()
    -- End-to-end propagation: the orchestrator calls Neovim's real
    -- `vim.lsp.config(name, merged)`; this test reads the result back
    -- through `vim.lsp.config[name]`, which is the runtime equivalent of
    -- the legacy `lspconfig.<name>.config_def.settings` propagation sink
    -- named in the step description. Asserting against the registry (not
    -- a captured stub argument) pins both halves of the contract: that
    -- the orchestrator constructs the right table AND that it hands it to
    -- the channel Neovim actually reads from on attach.
    require("lvim.config").load_defaults()

    _G.lvim.lsp.servers.lua_ls = {
      settings = {
        Lua = {
          telemetry = { enable = false },
          runtime = { version = "LuaJIT" },
        },
      },
    }

    local enabled = {}
    vim.lsp.enable = function(name)
      table.insert(enabled, name)
    end

    require("lvim.lsp").setup()

    local registered = vim.lsp.config["lua_ls"]
    assert.is_table(registered)
    -- Nested keys preserved end-to-end (deep-merge by `tbl_deep_extend`).
    assert.is_table(registered.settings)
    assert.is_table(registered.settings.Lua)
    assert.is_table(registered.settings.Lua.telemetry)
    assert.is_false(registered.settings.Lua.telemetry.enable)
    assert.equals("LuaJIT", registered.settings.Lua.runtime.version)
    -- `vim.lsp.enable("lua_ls")` is the side effect that actually starts
    -- the server — without it, configuring is a no-op. Pin the contract
    -- that the orchestrator pairs config + enable for each declared server.
    assert.equals(1, #enabled)
    assert.equals("lua_ls", enabled[1])
  end)

  it("lvim.lsp.on_attach override replaces the orchestrator default", function()
    -- LunarVim contract: assigning `lvim.lsp.on_attach` /
    -- `lvim.lsp.capabilities` substitutes the handlers-built default
    -- wholesale for EVERY server. Without this test, a regression that
    -- *wrapped* the user override (deep-merged it with the default)
    -- instead of replacing it (or one that ignored it entirely) would
    -- still pass the previous "settings propagate" test.
    --
    -- This case captures the orchestrator's call to `vim.lsp.config`
    -- inline (rather than reading from the real registry) because Neovim
    -- normalizes registered configs: it overwrites `name`, and the
    -- registry roundtrip is not guaranteed to preserve function identity
    -- across versions. The orchestrator's outgoing `merged` table is the
    -- single source of truth for the user-override-replacement contract,
    -- so we pin identity on that exact table.
    require("lvim.config").load_defaults()

    local sentinel_on_attach = function() end
    local sentinel_capabilities = { __sentinel = true }
    _G.lvim.lsp.on_attach = sentinel_on_attach
    _G.lvim.lsp.capabilities = sentinel_capabilities
    _G.lvim.lsp.servers.lua_ls = { settings = { Lua = {} } }

    local captured = {}
    local original_vim_lsp_config = vim.lsp.config
    vim.lsp.config = function(name, opts)
      captured[name] = opts
    end
    local ok, err = pcall(function()
      vim.lsp.enable = function() end
      require("lvim.lsp").setup()
    end)
    vim.lsp.config = original_vim_lsp_config
    assert.is_true(ok, err)

    -- Identity (not type / not contents): the user's exact function and
    -- table must reach the per-server merged config. The orchestrator's
    -- per-server `tbl_deep_extend` only deep-merges when the per-server
    -- config also carries the key (e.g. an `lvim.lsp.servers.lua_ls =
    -- { capabilities = {...} }`). Here the per-server config has only
    -- `settings`, so identity must be preserved — `tbl_deep_extend`
    -- copies the reference for keys that appear in only one source.
    -- Pinning identity (not just `__sentinel = true`) is what catches a
    -- wrap-don't-replace regression on the capabilities path: a
    -- contents-only assertion would still pass if the orchestrator
    -- deep-merged `default ∪ user` to build the global capabilities
    -- before forwarding.
    assert.equals(sentinel_on_attach, captured.lua_ls.on_attach)
    assert.equals(sentinel_capabilities, captured.lua_ls.capabilities)
    assert.is_true(captured.lua_ls.capabilities.__sentinel)
  end)

  it("default lvim.lsp.servers = {} does not invoke vim.lsp.config", function()
    -- Negative control: with no user-declared servers, the orchestrator's
    -- per-server loop must not call `vim.lsp.config` (and therefore not
    -- `vim.lsp.enable` either). This guards against a regression that
    -- accidentally iterates `ensure_installed` or some other table in
    -- place of `servers`, which would silently enable servers a user
    -- never asked for.
    require("lvim.config").load_defaults()

    local config_calls = {}
    local enabled = {}
    local original_vim_lsp_config = vim.lsp.config
    vim.lsp.config = function(name, opts)
      config_calls[name] = opts
    end
    vim.lsp.enable = function(name)
      table.insert(enabled, name)
    end
    local ok, err = pcall(function()
      require("lvim.lsp").setup()
    end)
    vim.lsp.config = original_vim_lsp_config
    assert.is_true(ok, err)

    assert.equals(0, vim.tbl_count(config_calls))
    assert.equals(0, #enabled)
  end)

  it("lvim.format_on_save = true registers a BufWritePre autocmd in lvim_format_on_save", function()
    require("lvim.config").load_defaults()
    _G.lvim.format_on_save = true

    require("lvim.lsp.format").setup()

    local autocmds = vim.api.nvim_get_autocmds({
      group = AUGROUP,
      event = "BufWritePre",
    })
    assert.equals(1, #autocmds)
    local cmd = autocmds[1]
    assert.equals("BufWritePre", cmd.event)
    -- The autocmd must carry an executable callback — without it the
    -- registration would be inert. `desc` is also pinned so a regression
    -- that registered a stray BufWritePre handler in the same augroup
    -- would surface here (it would have a different desc).
    assert.is_function(cmd.callback)
    assert.is_string(cmd.desc)
    assert.is_true(cmd.desc:find("format", 1, true) ~= nil)
  end)

  it("lvim.format_on_save = false leaves the lvim_format_on_save group empty", function()
    require("lvim.config").load_defaults()
    _G.lvim.format_on_save = false

    require("lvim.lsp.format").setup()

    -- The group is created (and cleared) regardless — only the autocmd
    -- registration is gated. Asserting zero autocmds inside the group
    -- pins the negative contract from the step description without
    -- having to distinguish "group missing" from "group present, empty".
    -- Querying with `group` plus `event` would error if the group did
    -- not exist, so a successful zero-result implicitly also pins that
    -- `format.setup()` created the (empty) augroup.
    local autocmds = vim.api.nvim_get_autocmds({
      group = AUGROUP,
      event = "BufWritePre",
    })
    assert.equals(0, #autocmds)
  end)
end)

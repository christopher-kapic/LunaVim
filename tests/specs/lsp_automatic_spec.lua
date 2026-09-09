-- Coverage for `lvim.lsp.automatic` -- automatic per-filetype server offers.
--
-- The module is deliberately split so this is possible: `plan()` answers "is
-- there anything to offer for this filetype" with no UI involved, and
-- `handle_filetype()` is that plus a prompt. The headless guard lives on the
-- autocmd rather than inside either, so both stay exercisable here (these tests
-- are themselves headless).
--
-- mason is stubbed throughout. The real registry would need a network fetch,
-- and the contract under test is our decision logic, not mason's.

local AUTOMATIC = "lvim.lsp.automatic"

describe("lvim.lsp.automatic", function()
  local cache_dir
  local prior_get_cache_dir
  local prior_select
  local selected

  ---Re-require the module so its cached state/in-flight locals start clean.
  local function fresh()
    package.loaded[AUTOMATIC] = nil
    return require(AUTOMATIC)
  end

  local installs
  local installed_by_test
  local deferred_install

  local prior_lsp_config
  local prior_get_clients

  ---Stand in for `vim.lsp.get_clients`, which reports live clients.
  local function stub_clients(clients)
    if prior_get_clients == nil then
      prior_get_clients = vim.lsp.get_clients
    end
    vim.lsp.get_clients = function(opts)
      if type(clients) == "function" then
        return clients(opts)
      end
      return clients
    end
  end

  local lsp_config_entries

  ---Stand in for `vim.lsp.config`, which resolves nvim-lspconfig blueprints.
  ---
  ---MERGES rather than replaces: `plan()` now offers only candidates whose
  ---blueprint resolves and serves the filetype, so a test that stubs one server
  ---must not silently drop the defaults the shipped preferences point at.
  local function stub_lsp_config(entries)
    if prior_lsp_config == nil then
      prior_lsp_config = vim.lsp.config
    end
    lsp_config_entries = vim.tbl_extend("force", lsp_config_entries or {}, entries)
    vim.lsp.config = setmetatable({}, {
      __index = function(_, name)
        return lsp_config_entries[name]
      end,
    })
  end

  ---Drop the merged blueprints, for a test that needs none to resolve.
  local function clear_lsp_config()
    lsp_config_entries = {}
    stub_lsp_config({})
  end

  ---Drop ONE blueprint, keeping the rest.
  ---
  ---`clear_lsp_config()` would also remove the candidates' blueprints, so
  ---`plan()` returns {} at its candidate filter no matter what the coverage
  ---logic does -- passing for the wrong reason.
  local function drop_lsp_config(name)
    lsp_config_entries = lsp_config_entries or {}
    lsp_config_entries[name] = nil
    stub_lsp_config({})
  end

  local default_packages = {
    basedpyright = "basedpyright",
    ruff = "ruff",
    rust_analyzer = "rust-analyzer",
  }

  local function stub_mason(opts)
    opts = opts or {}
    installs = {}
    installed_by_test = {}
    deferred_install = nil
    package.loaded["mason-registry"] = {
      get_package = function(name)
        if opts.no_package then
          error("package not found: " .. name)
        end
        return {
          is_installing = function()
            return opts.already_installing == true
          end,
          install = function(_, _, callback)
            installs[#installs + 1] = name
            if opts.install_raises then
              error("installer exploded")
            end
            -- Mirror mason: a package only appears in the installed list once
            -- its install actually SUCCEEDS.
            local function finish(success)
              if success then
                -- Real `get_installed_servers()` returns LSP names, not package
                -- names; those differ (`rust-analyzer` vs `rust_analyzer`).
                -- Recording the package name here would hide a mapped-name bug.
                local packages = (opts.packages or default_packages)
                local server = name
                for lsp_name, pkg_name in pairs(packages) do
                  if pkg_name == name then
                    server = lsp_name
                    break
                  end
                end
                installed_by_test[#installed_by_test + 1] = server
              end
              callback(success)
            end
            if opts.install_never_returns then
              return
            end
            if opts.defer_install then
              deferred_install = finish
              return
            end
            finish(opts.install_fails ~= true)
          end,
        }
      end,
    }
    package.loaded["mason-lspconfig"] = {
      get_available_servers = function(filter)
        local by_ft = opts.available or {}
        return vim.deepcopy(by_ft[filter and filter.filetype] or {})
      end,
      get_installed_servers = function()
        -- Real mason derives this from installed package names, so a
        -- successful install has to show up here. Without that, the
        -- no-blueprint test never reaches the combination that matters:
        -- installed, reported installed, and still not usable.
        local list = vim.deepcopy(opts.installed or {})
        vim.list_extend(list, installed_by_test)
        return list
      end,
      get_mappings = function()
        return {
          lspconfig_to_package = opts.packages or default_packages,
        }
      end,
    }
  end

  before_each(function()
    require("lvim.config").load_defaults()

    cache_dir = vim.fn.tempname()
    vim.fn.mkdir(cache_dir, "p")
    prior_get_cache_dir = _G.get_cache_dir
    _G.get_cache_dir = function()
      return cache_dir
    end

    selected = nil
    prior_select = vim.ui.select
    vim.ui.select = function(items, prompt_opts, on_choice)
      selected = { items = items, opts = prompt_opts, on_choice = on_choice }
    end

    stub_mason()
    lsp_config_entries = nil
    -- A resolvable blueprint for the servers these tests install. Without one
    -- the install path deliberately refuses to persist the answer, which is a
    -- different subject from the one most of these tests are about.
    stub_lsp_config({
      -- `sh` stands in for a real server binary: `usable()` requires cmd[1] to
      -- be executable, and the point of these tests is elsewhere.
      basedpyright = { cmd = { "sh" }, filetypes = { "python" } },
      ruff = { cmd = { "sh" }, filetypes = { "python" } },
      rust_analyzer = { cmd = { "sh" }, filetypes = { "rust" } },
    })
    -- nvim-lspconfig is not on the runtimepath in this harness, and `plan()`
    -- now (correctly) offers nothing without it -- installing a server whose
    -- blueprints never load produces no client. Stand it up so the tests below
    -- exercise their own subject rather than that gate.
    package.loaded["lspconfig"] = {}
  end)

  after_each(function()
    _G.get_cache_dir = prior_get_cache_dir
    vim.ui.select = prior_select
    if prior_lsp_config ~= nil then
      vim.lsp.config = prior_lsp_config
      prior_lsp_config = nil
    end
    if prior_get_clients ~= nil then
      vim.lsp.get_clients = prior_get_clients
      prior_get_clients = nil
    end
    package.loaded["mason-lspconfig"] = nil
    package.loaded["mason-registry"] = nil
    package.loaded["lspconfig"] = nil
    package.loaded[AUTOMATIC] = nil
    pcall(vim.fn.delete, cache_dir, "rf")
  end)

  describe("candidates", function()
    it("uses the shipped preference for a known filetype", function()
      assert.same({ "basedpyright", "ruff" }, fresh().candidates("python"))
      assert.same({ "rust_analyzer" }, fresh().candidates("rust"))
      assert.same({ "taplo" }, fresh().candidates("toml"))
      assert.same({ "yamlls" }, fresh().candidates("yaml"))
      assert.same({ "jsonls" }, fresh().candidates("json"))
      assert.same({ "vtsls" }, fresh().candidates("typescript"))
    end)

    -- The user asked for this explicitly: overriding one filetype from
    -- config.lua must not cost the other defaults.
    it("honours a per-filetype override from user config", function()
      lvim.lsp.automatic.preferred.python = { "pyright" }
      assert.same({ "pyright" }, fresh().candidates("python"))
      -- siblings survive
      assert.same({ "rust_analyzer" }, fresh().candidates("rust"))
    end)

    it("honours replacing the whole preferred table", function()
      lvim.lsp.automatic.preferred = { go = { "gopls" } }
      assert.same({ "gopls" }, fresh().candidates("go"))
      -- python now has no entry, so it falls through to mason
      stub_mason({ available = { python = { "pyright" } } })
      assert.same({ "pyright" }, fresh().candidates("python"))
    end)

    it("reads preferences at call time, so a later change is picked up", function()
      local automatic = fresh()
      assert.same({ "basedpyright", "ruff" }, automatic.candidates("python"))
      lvim.lsp.automatic.preferred.python = { "pylsp" }
      assert.same({ "pylsp" }, automatic.candidates("python"))
    end)

    it("falls through to mason for an unlisted filetype when set to ask", function()
      stub_mason({ available = { zig = { "zls", "ast_grep" } } })
      assert.same({ "zls", "ast_grep" }, fresh().candidates("zig"))
    end)

    it("offers nothing for an unlisted filetype when set to ignore", function()
      lvim.lsp.automatic.unknown_filetypes = "ignore"
      stub_mason({ available = { zig = { "zls" } } })
      assert.same({}, fresh().candidates("zig"))
      -- an explicitly preferred filetype still works
      assert.same({ "rust_analyzer" }, fresh().candidates("rust"))
    end)

    -- LunarVim compatibility: the upstream deny-list still filters.
    it("drops servers named in skipped_servers", function()
      lvim.lsp.automatic_configuration.skipped_servers = { "ruff" }
      assert.same({ "basedpyright" }, fresh().candidates("python"))
    end)

    it("drops filetypes named in skipped_filetypes", function()
      lvim.lsp.automatic_configuration.skipped_filetypes = { "python" }
      assert.same({}, fresh().candidates("python"))
    end)

    it("filters mason-derived candidates through skipped_servers too", function()
      lvim.lsp.automatic_configuration.skipped_servers = { "ast_grep" }
      stub_mason({ available = { zig = { "zls", "ast_grep" } } })
      assert.same({ "zls" }, fresh().candidates("zig"))
    end)
  end)

  describe("plan", function()
    it("offers nothing when the feature is disabled", function()
      lvim.lsp.automatic.enabled = false
      assert.same({}, fresh().plan("python"))
    end)

    it("offers nothing when a server for the filetype is already installed", function()
      stub_mason({ installed = { "basedpyright" } })
      assert.same({}, fresh().plan("python"))
    end)

    it("still offers when the installed servers serve other filetypes", function()
      stub_mason({ installed = { "gopls" } })
      assert.same({ "basedpyright", "ruff" }, fresh().plan("python"))
    end)

    it("offers nothing for an empty or non-string filetype", function()
      assert.same({}, fresh().plan(""))
      assert.same({}, fresh().plan(nil))
    end)

    -- Offering a server we cannot install is worse than staying quiet: the
    -- user says yes and the only result is "no mason package for
    -- basedpyright", because the name mapping lives in the plugin that would
    -- not load. `mason.active` being true does not mean mason is on disk --
    -- a fresh install, or the smoke harness's `install.missing = false`, is
    -- exactly that state.
    it("offers nothing when mason cannot be loaded, even for a preferred filetype", function()
      package.loaded["mason-lspconfig"] = nil
      package.preload["mason-lspconfig"] = function()
        error("mason-lspconfig is not installed")
      end

      assert.same({}, fresh().plan("python"))
      assert.same({}, fresh().plan("zig"))

      package.preload["mason-lspconfig"] = nil
    end)

    -- Installing a server whose lspconfig blueprint never joins the
    -- runtimepath leaves `vim.lsp.enable` unable to produce a client, after
    -- the yes has already been persisted.
    it("offers nothing when lspconfig is switched off", function()
      lvim.builtin.lspconfig = { active = false }
      assert.same({}, fresh().plan("python"))
    end)

    -- The toggle says "the user wants lspconfig", not "lspconfig is here".
    -- nvim-lspconfig 2.x is data-only: its `lsp/<name>.lua` blueprints join the
    -- runtimepath when it loads, and `vim.lsp.enable` has nothing to enable
    -- without them. A partial install leaves mason usable while lspconfig is
    -- absent, and we would install a package, persist the yes, and produce no
    -- client.
    it("offers nothing when lspconfig is enabled but cannot be loaded", function()
      package.loaded["lspconfig"] = nil
      package.preload["lspconfig"] = function()
        error("nvim-lspconfig is not installed")
      end

      assert.same({}, fresh().plan("python"))

      package.preload["lspconfig"] = nil
    end)

    it("offers nothing when mason is switched off", function()
      lvim.builtin.mason.active = false
      assert.same({}, fresh().plan("python"))
    end)

    -- The most likely way an existing user meets this feature: they already
    -- have a Python server, just not the one we would have picked.
    it("offers nothing when the user's configured server can actually run", function()
      stub_mason({ available = { python = { "pyright", "basedpyright" } } })
      lvim.lsp.servers = { pyright = {} }
      stub_lsp_config({ pyright = { cmd = { "sh" } } }) -- `sh` is executable
      assert.same({}, fresh().plan("python"))
    end)

    it("offers nothing when an ensure_installed server can actually run", function()
      stub_mason({ available = { python = { "pyright", "basedpyright" } } })
      lvim.lsp.ensure_installed = { "pyright" }
      stub_lsp_config({ pyright = { cmd = { "sh" } } })
      assert.same({}, fresh().plan("python"))
    end)

    -- A declaration is intent, not coverage. Treating `lvim.lsp.servers.pyright
    -- = {}` as "python is handled" when pyright is neither installed nor on
    -- PATH suppresses the offer forever for a user who has no server at all.
    it("still offers when the configured server is not installed or on PATH", function()
      stub_mason({ available = { python = { "pyright", "basedpyright" } } })
      lvim.lsp.servers = { pyright = {} }
      stub_lsp_config({ pyright = { cmd = { "definitely-not-a-real-binary-xyz" } } })
      assert.same({ "basedpyright", "ruff" }, fresh().plan("python"))
    end)

    it("still offers when ensure_installed names a server that never installed", function()
      stub_mason({ available = { python = { "pyright", "basedpyright" } } })
      lvim.lsp.ensure_installed = { "pyright" }
      stub_lsp_config({ pyright = { cmd = { "definitely-not-a-real-binary-xyz" } } })
      assert.same({ "basedpyright", "ruff" }, fresh().plan("python"))
    end)

    -- A client someone else started is coverage whatever its origin; mason has
    -- never heard of it, and offering to install a second server for a
    -- filetype that already has one is noise.
    it("offers nothing when a client for the filetype is already attached", function()
      stub_clients({ { name = "pyright", config = { filetypes = { "python" } } } })
      assert.same({}, fresh().plan("python"))
    end)

    -- Neovim treats a client with no `filetypes` as applying to every one.
    it("offers nothing when an attached client declares no filetypes", function()
      stub_clients({ { name = "custom", config = {} } })
      assert.same({}, fresh().plan("python"))
    end)

    -- mason has never heard of a hand-rolled server, but its own resolved
    -- blueprint says which filetypes it serves.
    it("offers nothing for a working server mason does not know", function()
      stub_mason({ available = { python = { "basedpyright" } } })
      lvim.lsp.servers = { my_python = {} }
      stub_lsp_config({ my_python = { cmd = { "sh" }, filetypes = { "python" } } })
      assert.same({}, fresh().plan("python"))
    end)

    it("still offers when that server declares a different filetype", function()
      stub_mason({ available = { python = { "basedpyright" } } })
      lvim.lsp.servers = { gopls = {} }
      stub_lsp_config({ gopls = { cmd = { "sh" }, filetypes = { "go" } } })
      assert.same({ "basedpyright", "ruff" }, fresh().plan("python"))
    end)

    -- A global lookup would let a gopls attached to one project suppress the
    -- offer for a Go file in another, where it cannot attach because the roots
    -- differ. The lookup is buffer-scoped whenever we know the buffer.
    it("scopes the attached-client lookup to the buffer", function()
      local other = vim.api.nvim_create_buf(false, true)
      stub_clients(function(opts)
        -- a client attached to some OTHER buffer only
        if opts and opts.bufnr then
          return {}
        end
        return { { name = "pyright", config = { filetypes = { "python" } } } }
      end)

      assert.same({ "basedpyright", "ruff" }, fresh().plan("python", other))
      pcall(vim.api.nvim_buf_delete, other, { force = true })
    end)

    it("still offers when the attached clients serve other filetypes", function()
      stub_clients({ { name = "gopls", config = { filetypes = { "go" } } } })
      assert.same({ "basedpyright", "ruff" }, fresh().plan("python"))
    end)

    -- Several real nvim-lspconfig blueprints build `cmd` at attach time. That
    -- tells us nothing about whether anything can run, and guessing "yes" is
    -- the worse error: it leaves a user with no server AND no prompt.
    it("still offers when a declared server has a cmd we cannot inspect", function()
      stub_mason({ available = { python = { "pyright", "basedpyright" } } })
      lvim.lsp.servers = { pyright = {} }
      stub_lsp_config({ pyright = { cmd = function() end } })
      assert.same({ "basedpyright", "ruff" }, fresh().plan("python"))
    end)

    it("still offers when a declared server resolves to no config at all", function()
      stub_mason({ available = { python = { "pyright", "basedpyright" } } })
      lvim.lsp.servers = { pyright = {} }
      drop_lsp_config("pyright") -- the candidates keep theirs
      assert.same({ "basedpyright", "ruff" }, fresh().plan("python"))
    end)

    -- mason reporting a package installed is not proof Neovim can run it: its
    -- bin may not be on Neovim's PATH, or the install may be damaged. Neovim
    -- checks `cmd[1]` before starting a client, so counting it as coverage
    -- would suppress every future offer for a server that never starts.
    it("still offers when an installed server's command is not executable", function()
      stub_mason({
        available = { python = { "pyright", "basedpyright" } },
        installed = { "pyright" },
      })
      stub_lsp_config({
        pyright = { cmd = { "definitely-not-a-real-binary-xyz" }, filetypes = { "python" } },
      })
      assert.same({ "basedpyright", "ruff" }, fresh().plan("python"))
    end)

    -- A wrong preference must not reach the prompt at all. Offering it would
    -- install a package that `vim.lsp.enable` then does nothing useful with,
    -- and the user paid a download to find out.
    it("does not offer a preferred server whose blueprint serves another filetype", function()
      lvim.lsp.automatic.preferred.python = { "gopls", "ruff" }
      stub_lsp_config({ gopls = { cmd = { "sh" }, filetypes = { "go" } } })
      assert.same({ "ruff" }, fresh().plan("python"))
    end)

    it("does not offer a candidate with no blueprint at all", function()
      lvim.lsp.automatic.preferred.python = { "not_a_real_server", "ruff" }
      assert.same({ "ruff" }, fresh().plan("python"))
    end)

    -- mason's generated filetype map can be stale, and a preference can simply
    -- be wrong. A server's own blueprint is the authority on what it serves.
    it("does not count a server whose blueprint declares another filetype", function()
      stub_mason({
        available = { python = { "gopls" } },
        installed = { "gopls" },
      })
      stub_lsp_config({ gopls = { cmd = { "sh" }, filetypes = { "go" } } })
      assert.same({ "basedpyright", "ruff" }, fresh().plan("python"))
    end)

    -- mason owning the binary is what lets an UNINSPECTABLE cmd count: for a
    -- server we merely declared, a function cmd proves nothing, but for one
    -- mason installed it is as far as we can check. Uses a function cmd on
    -- purpose -- an executable string would pass with or without that branch.
    it("counts a mason-installed server whose cmd cannot be inspected", function()
      stub_mason({
        available = { python = { "pyright", "basedpyright" } },
        installed = { "pyright" },
      })
      stub_lsp_config({ pyright = { cmd = function() end, filetypes = { "python" } } })
      assert.same({}, fresh().plan("python"))
    end)

    it("offers nothing when mason reports the server installed", function()
      stub_mason({
        available = { python = { "pyright", "basedpyright" } },
        installed = { "pyright" },
      })
      stub_lsp_config({ pyright = { cmd = { "sh" }, filetypes = { "python" } } })
      assert.same({}, fresh().plan("python"))
    end)

    -- Installed is not usable. With mason reporting a package present but
    -- nothing resolving for it, `vim.lsp.enable` starts no client -- and
    -- counting it as coverage would suppress every future offer forever.
    it("still offers when an installed server has no resolvable blueprint", function()
      stub_mason({
        available = { python = { "pyright", "basedpyright" } },
        installed = { "pyright" },
      })
      drop_lsp_config("pyright") -- the candidates keep theirs
      assert.same({ "basedpyright", "ruff" }, fresh().plan("python"))
    end)

    it("offers nothing when an installed server outside our preferences serves the filetype", function()
      stub_mason({
        available = { python = { "pyright", "basedpyright" } },
        installed = { "pyright" },
      })
      stub_lsp_config({ pyright = { cmd = { "sh" }, filetypes = { "python" } } })
      assert.same({}, fresh().plan("python"))
    end)

    it("still offers when the user's configured server is for another filetype", function()
      stub_mason({ available = { python = { "basedpyright" }, go = { "gopls" } } })
      lvim.lsp.servers = { gopls = {} }
      assert.same({ "basedpyright", "ruff" }, fresh().plan("python"))
    end)
  end)

  describe("prompting", function()
    it("offers each candidate plus an explicit refusal", function()
      fresh().handle_filetype("python")
      assert.is_not_nil(selected)
      assert.same({ "basedpyright", "ruff", "Never ask again for python" }, selected.items)
    end)

    it("does not prompt when there is nothing to offer", function()
      stub_mason({ installed = { "basedpyright" } })
      fresh().handle_filetype("python")
      assert.is_nil(selected)
    end)

    it("does not queue a second prompt while one is open", function()
      local automatic = fresh()
      automatic.handle_filetype("python")
      selected = nil
      automatic.handle_filetype("python")
      assert.is_nil(selected)
    end)

    it("records a refusal, and stops offering once refused", function()
      local automatic = fresh()
      automatic.handle_filetype("python")
      selected.on_choice("Never ask again for python")

      assert.is_false(automatic.decision("python"))
      assert.same({}, automatic.plan("python"))
    end)

    -- The point of persisting: the answer survives the session that gave it.
    it("persists a refusal across a reload", function()
      local automatic = fresh()
      automatic.handle_filetype("python")
      selected.on_choice("Never ask again for python")

      assert.is_false(fresh().decision("python"))
    end)

    it("treats a dismissed prompt as unanswered, not as a refusal", function()
      local automatic = fresh()
      automatic.handle_filetype("python")
      selected.on_choice(nil)

      assert.is_nil(automatic.decision("python"))
      selected = nil
      automatic.handle_filetype("python")
      assert.is_not_nil(selected)
    end)

    it("forgets a single filetype, restoring the offer", function()
      local automatic = fresh()
      automatic.handle_filetype("python")
      selected.on_choice("Never ask again for python")
      automatic.handle_filetype("rust")
      selected.on_choice("Never ask again for rust")

      automatic.forget("python")
      assert.is_nil(automatic.decision("python"))
      assert.is_false(automatic.decision("rust"))
    end)

    it("forgets every filetype when given no argument", function()
      local automatic = fresh()
      automatic.handle_filetype("python")
      selected.on_choice("Never ask again for python")
      automatic.handle_filetype("rust")
      selected.on_choice("Never ask again for rust")
      assert.is_false(automatic.decision("rust"))

      automatic.forget()
      -- both, not just the first: an implementation that cleared only one
      -- would have passed the single-filetype version of this test
      assert.is_nil(fresh().decision("python"))
      assert.is_nil(fresh().decision("rust"))
    end)
  end)

  describe("setup", function()
    local function automatic_autocmds()
      local ok, found = pcall(vim.api.nvim_get_autocmds, {
        group = "lvim_lsp_automatic",
        event = "FileType",
      })
      return ok and found or {}
    end

    it("registers a FileType autocmd by default", function()
      fresh().setup()
      assert.is_true(#automatic_autocmds() > 0)
    end)

    it("registers nothing when disabled", function()
      lvim.lsp.automatic.enabled = false
      fresh().setup()
      assert.equals(0, #automatic_autocmds())
    end)

    it("registers nothing when mason is switched off", function()
      lvim.builtin.mason.active = false
      fresh().setup()
      assert.equals(0, #automatic_autocmds())
    end)

    it("is idempotent -- a second setup does not double-register", function()
      local automatic = fresh()
      automatic.setup()
      local first = #automatic_autocmds()
      automatic.setup()
      assert.equals(first, #automatic_autocmds())
    end)
  end)
  describe("installing", function()
    -- Every one of these is about `in_flight`, which gates re-prompting. If it
    -- is left set, that filetype can never be offered again for the rest of the
    -- session -- a silent dead end with no way for the user to retry.
    it("clears in_flight when the installer raises before calling back", function()
      stub_mason({ install_raises = true })
      local automatic = fresh()
      automatic.handle_filetype("python")
      selected.on_choice("basedpyright")

      selected = nil
      automatic.handle_filetype("python")
      assert.is_not_nil(selected)
    end)

    it("clears in_flight when the install reports failure", function()
      stub_mason({ install_fails = true })
      local automatic = fresh()
      automatic.handle_filetype("python")
      selected.on_choice("basedpyright")
      -- the install callback lands via vim.schedule
      vim.wait(200, function()
        return automatic.decision("python") ~= nil
      end, 10)

      selected = nil
      automatic.handle_filetype("python")
      assert.is_not_nil(selected)
    end)

    it("does not start a second install of a package already installing", function()
      stub_mason({ already_installing = true })
      local automatic = fresh()
      automatic.handle_filetype("python")
      selected.on_choice("basedpyright")

      assert.same({}, installs)
      selected = nil
      automatic.handle_filetype("python")
      assert.is_not_nil(selected)
    end)

    -- An asynchronous picker returns immediately, so "closed without
    -- answering" is not detectable at the call site. The claim expires instead,
    -- which also covers an installer whose job stalls -- otherwise that
    -- filetype is dead for the rest of the session with no way to retry.
    --
    -- A NONZERO expiry is the case that matters. An earlier version took the
    -- claim once to test it and again to hold it: the first call renewed an
    -- expired claim and the second then saw a fresh one and bailed, so the
    -- prompt never came back -- it just renewed the wedge forever. Zero made
    -- `elapsed < 0` false on every path and sailed straight past that.
    it("re-offers after a nonzero claim expiry when the picker never answers", function()
      lvim.lsp.automatic.retry_after_seconds = 0.05
      vim.ui.select = function()
        -- open, unanswered
      end
      local automatic = fresh()
      automatic.handle_filetype("python")

      vim.ui.select = function(items, prompt_opts, on_choice)
        selected = { items = items, opts = prompt_opts, on_choice = on_choice }
      end
      -- still inside the window
      automatic.handle_filetype("python")
      assert.is_nil(selected)

      vim.wait(120)
      automatic.handle_filetype("python")
      assert.is_not_nil(selected)
    end)

    -- Once two prompts can overlap, a late answer from the first must not
    -- release the second's claim -- otherwise a third prompt opens on top.
    it("does not let a stale answer release a newer claim", function()
      lvim.lsp.automatic.retry_after_seconds = 0.05
      local first
      vim.ui.select = function(items, prompt_opts, on_choice)
        first = { items = items, opts = prompt_opts, on_choice = on_choice }
      end
      local automatic = fresh()
      automatic.handle_filetype("python")
      assert.is_not_nil(first)

      vim.wait(120)
      vim.ui.select = function(items, prompt_opts, on_choice)
        selected = { items = items, opts = prompt_opts, on_choice = on_choice }
      end
      automatic.handle_filetype("python")
      assert.is_not_nil(selected) -- the second prompt took a fresh claim

      -- the abandoned first prompt finally answers
      first.on_choice(nil)

      -- the second claim must still be held, so nothing new opens
      selected = nil
      automatic.handle_filetype("python")
      assert.is_nil(selected)
    end)

    -- The token has to gate ACTIONS, not just release. An abandoned prompt
    -- answering late would otherwise overwrite the newer prompt's decision.
    it("ignores a stale answer that would overwrite a newer decision", function()
      lvim.lsp.automatic.retry_after_seconds = 0.05
      local first
      vim.ui.select = function(items, prompt_opts, on_choice)
        first = { items = items, opts = prompt_opts, on_choice = on_choice }
      end
      local automatic = fresh()
      automatic.handle_filetype("python")

      vim.wait(120)
      vim.ui.select = function(items, prompt_opts, on_choice)
        selected = { items = items, opts = prompt_opts, on_choice = on_choice }
      end
      automatic.handle_filetype("python")
      selected.on_choice("basedpyright")
      vim.wait(200, function()
        return automatic.decision("python") ~= nil
      end, 10)
      assert.equals("basedpyright", automatic.decision("python"))

      -- the abandoned first prompt answers "never" long after the fact
      first.on_choice("Never ask again for python")
      assert.equals("basedpyright", automatic.decision("python"))
    end)

    it("ignores a stale answer that would start a second install", function()
      lvim.lsp.automatic.retry_after_seconds = 0.05
      local first
      vim.ui.select = function(items, prompt_opts, on_choice)
        first = { items = items, opts = prompt_opts, on_choice = on_choice }
      end
      local automatic = fresh()
      automatic.handle_filetype("python")

      vim.wait(120)
      vim.ui.select = function(items, prompt_opts, on_choice)
        selected = { items = items, opts = prompt_opts, on_choice = on_choice }
      end
      automatic.handle_filetype("python")
      selected.on_choice("basedpyright")
      vim.wait(200, function()
        return automatic.decision("python") ~= nil
      end, 10)

      first.on_choice("ruff")
      vim.wait(50)
      assert.same({ "basedpyright" }, installs)
    end)

    -- A download is not an abandoned prompt. If the install inherited the
    -- prompt's short window, a slow download would expire mid-flight and let a
    -- second prompt install a DIFFERENT server for the same filetype.
    it("does not expire a running install at the prompt window", function()
      lvim.lsp.automatic.retry_after_seconds = 0.05
      -- install_timeout_seconds left at its default
      stub_mason({ defer_install = true })
      local automatic = fresh()

      automatic.handle_filetype("python")
      selected.on_choice("basedpyright")
      assert.same({ "basedpyright" }, installs)

      vim.wait(120) -- well past the prompt window
      selected = nil
      automatic.handle_filetype("python")
      assert.is_nil(selected)
      assert.same({ "basedpyright" }, installs)
    end)

    -- A negative window would re-stamp the install claim as ALREADY expired,
    -- so reopening the file could start a second install while the first is
    -- still running. `retry_after_seconds` already rejects negatives.
    it("ignores a zero install window", function()
      lvim.lsp.automatic.retry_after_seconds = 0.05
      lvim.lsp.automatic.install_timeout_seconds = 0
      stub_mason({ defer_install = true })
      local automatic = fresh()

      automatic.handle_filetype("python")
      selected.on_choice("basedpyright")
      vim.wait(120)
      selected = nil
      automatic.handle_filetype("python")
      assert.is_nil(selected)
      assert.same({ "basedpyright" }, installs)
    end)

    it("ignores a negative install window", function()
      lvim.lsp.automatic.retry_after_seconds = 0.05
      lvim.lsp.automatic.install_timeout_seconds = -1
      stub_mason({ defer_install = true })
      local automatic = fresh()

      automatic.handle_filetype("python")
      selected.on_choice("basedpyright")
      assert.same({ "basedpyright" }, installs)

      vim.wait(120)
      selected = nil
      automatic.handle_filetype("python")
      assert.is_nil(selected)
      assert.same({ "basedpyright" }, installs)
    end)

    -- The prompt gate cannot cover this: the answer was legitimate when given.
    -- It is the INSTALL COMPLETING after a newer claim took over that must be
    -- ignored, or a long download finishing late overwrites a fresher decision
    -- and enables a server the user has since replaced.
    it("ignores an install that completes after a newer claim took over", function()
      lvim.lsp.automatic.retry_after_seconds = 0.05
      lvim.lsp.automatic.install_timeout_seconds = 0.05
      stub_mason({ defer_install = true })
      local automatic = fresh()

      automatic.handle_filetype("python")
      selected.on_choice("basedpyright")
      assert.same({ "basedpyright" }, installs)
      assert.is_not_nil(deferred_install)
      local slow = deferred_install

      vim.wait(120)
      selected = nil
      automatic.handle_filetype("python")
      assert.is_not_nil(selected) -- a newer claim is live

      slow(true) -- the abandoned install finally finishes
      vim.wait(50)
      assert.is_nil(automatic.decision("python"))
    end)

    it("re-offers after the claim expires when the picker never answers", function()
      lvim.lsp.automatic.retry_after_seconds = 0
      vim.ui.select = function()
        -- some pickers close without answering
      end
      local automatic = fresh()
      automatic.handle_filetype("python")

      vim.ui.select = function(items, prompt_opts, on_choice)
        selected = { items = items, opts = prompt_opts, on_choice = on_choice }
      end
      automatic.handle_filetype("python")
      assert.is_not_nil(selected)
    end)

    it("does not re-offer while the claim is still fresh", function()
      vim.ui.select = function()
        -- open, unanswered
      end
      local automatic = fresh()
      automatic.handle_filetype("python")

      vim.ui.select = function(items, prompt_opts, on_choice)
        selected = { items = items, opts = prompt_opts, on_choice = on_choice }
      end
      automatic.handle_filetype("python")
      assert.is_nil(selected)
    end)

    it("clears in_flight when the picker raises", function()
      vim.ui.select = function()
        error("picker exploded")
      end
      local automatic = fresh()
      automatic.handle_filetype("python")

      vim.ui.select = function(items, prompt_opts, on_choice)
        selected = { items = items, opts = prompt_opts, on_choice = on_choice }
      end
      automatic.handle_filetype("python")
      assert.is_not_nil(selected)
    end)

    it("records the accepted server on a successful install", function()
      stub_mason()
      local automatic = fresh()
      automatic.handle_filetype("python")
      selected.on_choice("basedpyright")
      vim.wait(200, function()
        return automatic.decision("python") ~= nil
      end, 10)

      assert.same({ "basedpyright" }, installs)
      assert.equals("basedpyright", automatic.decision("python"))
    end)

    -- `enable_and_attach` re-fires FileType for matching buffers so the newly
    -- installed server attaches to what is already open. That lands back in
    -- `handle_filetype`; releasing the claim before it would let the re-fire
    -- open a second prompt whenever mason does not yet report the install.
    -- `enable_and_attach` re-fires FileType for matching buffers so a newly
    -- installed server attaches to what is already open, and that re-entry
    -- lands back in `handle_filetype`. Releasing the claim before it would let
    -- the re-fire open a second prompt whenever mason does not yet report the
    -- install. Driven through the stubbed `vim.lsp.enable` rather than a real
    -- autocmd, because the autocmd's headless guard makes it unreachable here.
    -- `enable_and_attach` re-fires FileType for matching buffers so a newly
    -- installed server attaches to what is already open, and that re-entry
    -- lands back in `handle_filetype`. Releasing the claim before it would let
    -- the re-fire open a second prompt whenever mason does not yet report the
    -- install.
    --
    -- Driven through the REAL `nvim_exec_autocmds("FileType")` that
    -- `enable_and_attach` performs. The production autocmd cannot be used --
    -- its headless guard makes it inert here -- so this registers an equivalent
    -- one. An earlier version of this test re-entered from inside the stubbed
    -- `vim.lsp.enable`, which sits BEFORE the re-fire, so moving the release
    -- between the two would have broken production and still passed.
    it("holds the claim across the post-install re-attach", function()
      stub_mason() -- get_installed_servers stays empty: nothing else suppresses a re-prompt
      local automatic = fresh()

      local prompts = 0
      vim.ui.select = function(items, prompt_opts, on_choice)
        prompts = prompts + 1
        selected = { items = items, opts = prompt_opts, on_choice = on_choice }
      end

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value("filetype", "python", { buf = buf })

      local group = vim.api.nvim_create_augroup("lvim_lsp_automatic_spec", { clear = true })
      vim.api.nvim_create_autocmd("FileType", {
        group = group,
        callback = function(args)
          automatic.handle_filetype(vim.bo[args.buf].filetype)
        end,
      })

      local refires = 0
      vim.api.nvim_create_autocmd("FileType", {
        group = group,
        callback = function()
          refires = refires + 1
        end,
      })

      automatic.handle_filetype("python")
      assert.equals(1, prompts)
      selected.on_choice("basedpyright")
      vim.wait(200, function()
        return automatic.decision("python") ~= nil
      end, 10)

      -- The re-fire must actually have happened, or "only one prompt" proves
      -- nothing: removing the re-attach entirely would satisfy it too.
      assert.is_true(refires > 0)
      assert.equals(1, prompts)

      pcall(vim.api.nvim_del_augroup_by_id, group)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)

    -- `vim.lsp.enable(name)` does not error when nothing resolves: it enables
    -- the name and the next FileType pass quietly starts no client. Persisting
    -- the yes there would leave the user with an installed package, no client,
    -- and -- because mason now reports it installed -- no further offers.
    -- The blueprint resolves when the offer is made and is gone by the time the
    -- install finishes -- nvim-lspconfig updating underneath a long download,
    -- or a broken runtimepath. `vim.lsp.enable` would not error; it would
    -- simply start no client, and persisting the yes there strands the user
    -- with an installed package and no further offers.
    -- Not just "a blueprint exists": a slow install can span a config reload
    -- that moves the server to another filetype, and persisting it there would
    -- report a server enabled for Python that can never attach to Python.
    it("does not remember an install whose blueprint moves to another filetype", function()
      stub_mason()
      local automatic = fresh()
      automatic.handle_filetype("python")
      stub_lsp_config({ basedpyright = { cmd = { "sh" }, filetypes = { "go" } } })
      selected.on_choice("basedpyright")
      vim.wait(200)

      assert.same({ "basedpyright" }, installs)
      assert.is_nil(automatic.decision("python"))
    end)

    it("does not remember an install whose blueprint stops resolving", function()
      stub_mason()
      local automatic = fresh()
      automatic.handle_filetype("python")
      clear_lsp_config()
      selected.on_choice("basedpyright")
      vim.wait(200)

      assert.same({ "basedpyright" }, installs)
      assert.is_nil(automatic.decision("python"))

      -- mason now reports basedpyright installed. Because its blueprint still
      -- does not resolve it must NOT count as coverage -- otherwise the user is
      -- stuck with an installed package, no client, and no further offers. With
      -- another candidate available, they are offered that one instead.
      stub_lsp_config({ ruff = { cmd = { "sh" }, filetypes = { "python" } } })
      assert.same({ "ruff" }, automatic.plan("python"))
    end)

    it("clears in_flight when the server maps to no mason package", function()
      stub_mason({ packages = {} })
      local automatic = fresh()
      automatic.handle_filetype("python")
      selected.on_choice("basedpyright")

      selected = nil
      automatic.handle_filetype("python")
      assert.is_not_nil(selected)
    end)
  end)

  describe("state file", function()
    -- The single-JSON design this replaced had a lost-update race that neither
    -- an atomic rename nor a re-read-before-write closes: two instances both
    -- read the whole document, and whichever writes second erases the other's
    -- answer. A file per filetype makes the two writes independent, so the
    -- test that matters is the one the old design would fail.
    it("keeps answers from two instances that both read before either wrote", function()
      local a = fresh()
      local b = fresh()

      -- both observe an empty store first
      assert.is_nil(a.decision("python"))
      assert.is_nil(b.decision("rust"))

      a.handle_filetype("python")
      selected.on_choice("Never ask again for python")
      b.handle_filetype("rust")
      selected.on_choice("Never ask again for rust")

      local reread = fresh()
      assert.is_false(reread.decision("python"))
      assert.is_false(reread.decision("rust"))
    end)

    -- `io.open`, `write` and `os.rename` all report failure by RETURNING nil
    -- plus a message; a bare `pcall` reads that as success. Left unchecked, a
    -- failed write leaves the temp file behind and the caller believing the
    -- answer was saved. Forced here by making the target path a non-empty
    -- directory, which rename cannot replace.
    it("does not report success, or leak a temp file, when the write fails", function()
      local automatic = fresh()
      vim.fn.mkdir(automatic.state_dir() .. "/python/blocker", "p")

      automatic.handle_filetype("python")
      selected.on_choice("Never ask again for python")

      assert.is_nil(fresh().decision("python"))
      assert.same({}, vim.fn.glob(automatic.state_dir() .. "/.tmp/*", false, true))
    end)

    it("does not persist a decision when the cache directory is not writable", function()
      local automatic = fresh()
      vim.fn.mkdir(automatic.state_dir(), "p")
      vim.fn.setfperm(automatic.state_dir(), "r-xr-xr-x")

      automatic.handle_filetype("python")
      selected.on_choice("Never ask again for python")

      assert.is_nil(fresh().decision("python"))
      vim.fn.setfperm(automatic.state_dir(), "rwxr-xr-x")
    end)

    it("reports failure when a decision cannot be cleared", function()
      local automatic = fresh()
      automatic.handle_filetype("python")
      selected.on_choice("Never ask again for python")
      assert.is_false(automatic.decision("python"))

      vim.fn.setfperm(automatic.state_dir(), "r-xr-xr-x")
      assert.is_false(automatic.forget("python"))
      vim.fn.setfperm(automatic.state_dir(), "rwxr-xr-x")

      -- and true once it can
      assert.is_true(automatic.forget("python"))
      assert.is_nil(automatic.decision("python"))
    end)

    it("reports success when there was nothing to clear", function()
      assert.is_true(fresh().forget("python"))
    end)

    -- `.` and `..` would otherwise resolve to the store itself and its parent.
    it("stores a decision for a filetype named like a directory entry", function()
      lvim.lsp.automatic.preferred["."] = { "dotls" }
      stub_lsp_config({ dotls = { cmd = { "sh" }, filetypes = { "." } } })
      local automatic = fresh()
      automatic.handle_filetype(".")
      selected.on_choice("Never ask again for .")

      assert.is_false(fresh().decision("."))
      assert.equals(1, vim.fn.isdirectory(automatic.state_dir()))
    end)

    -- The structural property, not a timing one: the single-document design
    -- this replaced could not be made safe by re-reading before writing,
    -- because two writers still hold independent stale snapshots. One file per
    -- filetype means there is no shared document to lose an update in.
    it("keeps each filetype in its own file", function()
      local automatic = fresh()
      automatic.handle_filetype("python")
      selected.on_choice("Never ask again for python")
      automatic.handle_filetype("rust")
      selected.on_choice("Never ask again for rust")

      local entries = vim.tbl_filter(function(name)
        return name ~= ".tmp"
      end, vim.fn.readdir(automatic.state_dir()))
      table.sort(entries)
      assert.same({ "python", "rust" }, entries)
    end)

    -- Case-insensitive filesystems (default macOS, Windows) would otherwise
    -- give `Python` and `python` the same file, so one answer would silently
    -- overwrite the other. Encoding the uppercase byte keeps them distinct
    -- everywhere; asserted structurally, since this machine's filesystem is
    -- case-sensitive and could not observe the collision.
    it("encodes uppercase so the filename cannot collide case-insensitively", function()
      lvim.lsp.automatic.preferred["Python"] = { "pyls" }
      stub_lsp_config({ pyls = { cmd = { "sh" }, filetypes = { "Python" } } })
      local automatic = fresh()
      automatic.handle_filetype("Python")
      selected.on_choice("Never ask again for Python")

      local entries = vim.tbl_filter(function(name)
        return name ~= ".tmp"
      end, vim.fn.readdir(automatic.state_dir()))
      assert.same({ "%50ython" }, entries)
      assert.is_false(fresh().decision("Python"))
    end)

    -- `<ft>.tmp.<pid>` beside the decisions is itself a legal encoded filetype
    -- name, so writing python's decision would have opened, truncated and then
    -- renamed away the decision belonging to the filetype `python.tmp.<pid>`.
    it("does not destroy a decision whose filetype looks like a temp name", function()
      local pid = tostring((vim.uv or vim.loop).getpid())
      local victim = "python.tmp." .. pid
      lvim.lsp.automatic.preferred[victim] = { "victimls" }
      stub_lsp_config({ victimls = { cmd = { "sh" }, filetypes = { victim } } })

      local automatic = fresh()
      automatic.handle_filetype(victim)
      selected.on_choice("Never ask again for " .. victim)
      assert.is_false(automatic.decision(victim))

      automatic.handle_filetype("python")
      selected.on_choice("Never ask again for python")

      assert.is_false(fresh().decision("python"))
      assert.is_false(fresh().decision(victim))
    end)

    it("leaves no temp file behind", function()
      local automatic = fresh()
      automatic.handle_filetype("python")
      selected.on_choice("Never ask again for python")

      local leftovers = vim.fn.glob(automatic.state_dir() .. "/.tmp/*", false, true)
      assert.same({}, leftovers)
    end)

    it("survives a corrupt decision file without raising", function()
      local automatic = fresh()
      vim.fn.mkdir(automatic.state_dir(), "p")
      local fh = io.open(automatic.state_dir() .. "/python", "w")
      fh:write("{not json")
      fh:close()

      assert.is_nil(automatic.decision("python"))
      assert.same({ "basedpyright", "ruff" }, automatic.plan("python"))
    end)

    -- A corrupt file for one filetype must not cost the answers for others --
    -- the whole point of not keeping them in one document.
    it("loses only the corrupt filetype's answer", function()
      local automatic = fresh()
      automatic.handle_filetype("python")
      selected.on_choice("Never ask again for python")
      automatic.handle_filetype("rust")
      selected.on_choice("Never ask again for rust")

      local fh = io.open(automatic.state_dir() .. "/python", "w")
      fh:write("{not json")
      fh:close()

      assert.is_nil(fresh().decision("python"))
      assert.is_false(fresh().decision("rust"))
    end)

    it("encodes a filetype that is not filename-safe", function()
      lvim.lsp.automatic.preferred["c++"] = { "clangd" }
      stub_lsp_config({ clangd = { cmd = { "sh" }, filetypes = { "c++" } } })
      local automatic = fresh()
      automatic.handle_filetype("c++")
      selected.on_choice("Never ask again for c++")

      assert.is_false(fresh().decision("c++"))
      assert.same({}, vim.fn.glob(automatic.state_dir() .. "/c++", false, true))
    end)
  end)
end)
-- `:LvimReload` must be able to REMOVE the autocmd, not only add it.
-- `load_defaults()` replaces `_G.lvim`, so without an explicit re-arm a user
-- who sets `enabled = false` and reloads keeps the previous session's autocmd.
describe("lvim.lsp.automatic under :LvimReload", function()
  local function automatic_autocmds()
    local ok, found = pcall(vim.api.nvim_get_autocmds, {
      group = "lvim_lsp_automatic",
      event = "FileType",
    })
    return ok and found or {}
  end

  local reload_cache
  local prior_cache_fn

  before_each(function()
    require("lvim.config").load_defaults()
    package.loaded[AUTOMATIC] = nil
    -- `:LvimReload` runs `lvim.core.options.setup()`, which needs the
    -- `get_cache_dir` global that `lvim.bootstrap.init()` normally installs.
    -- The plenary harness does not run `lvim.start()`, so provide it here and
    -- point it somewhere disposable.
    reload_cache = vim.fn.tempname()
    vim.fn.mkdir(reload_cache, "p")
    prior_cache_fn = _G.get_cache_dir
    _G.get_cache_dir = function()
      return reload_cache
    end
  end)

  after_each(function()
    _G.get_cache_dir = prior_cache_fn
    pcall(vim.fn.delete, reload_cache, "rf")
    package.loaded[AUTOMATIC] = nil
  end)

  it("drops the autocmd when the feature is turned off and re-armed", function()
    require(AUTOMATIC).setup()
    assert.is_true(#automatic_autocmds() > 0)

    lvim.lsp.automatic.enabled = false
    require(AUTOMATIC).setup()
    assert.equals(0, #automatic_autocmds())
  end)

  -- Behavioural, not a grep for the call. An earlier version of this test
  -- searched commands.lua for the literal `require("lvim.lsp.automatic").setup()`,
  -- which would have passed with that call sitting in a comment or in an
  -- unreachable branch. Run the real command instead.
  it("removes the autocmd when a reloaded config disables the feature", function()
    require("lvim.core.commands").setup()
    require(AUTOMATIC).setup()
    assert.is_true(#automatic_autocmds() > 0)

    local cfg = vim.fn.tempname()
    vim.fn.mkdir(cfg, "p")
    vim.fn.writefile({ "lvim.lsp.automatic.enabled = false" }, cfg .. "/config.lua")
    local prior_cfg = vim.env.LUNAVIM_CONFIG_DIR
    vim.env.LUNAVIM_CONFIG_DIR = cfg

    vim.cmd("LvimReload")
    assert.equals(0, #automatic_autocmds())

    vim.fn.writefile({ "-- automatic left enabled" }, cfg .. "/config.lua")
    vim.cmd("LvimReload")
    assert.is_true(#automatic_autocmds() > 0)

    vim.env.LUNAVIM_CONFIG_DIR = prior_cfg
    pcall(vim.fn.delete, cfg, "rf")
  end)

  -- The user asked specifically that their `preferred` survive a reload.
  it("picks up a preferred override from a reloaded config.lua", function()
    require("lvim.core.commands").setup()

    local cfg = vim.fn.tempname()
    vim.fn.mkdir(cfg, "p")
    vim.fn.writefile({ 'lvim.lsp.automatic.preferred.python = { "pylsp" }' }, cfg .. "/config.lua")
    local prior_cfg = vim.env.LUNAVIM_CONFIG_DIR
    vim.env.LUNAVIM_CONFIG_DIR = cfg

    vim.cmd("LvimReload")
    package.loaded[AUTOMATIC] = nil
    assert.same({ "pylsp" }, require(AUTOMATIC).candidates("python"))
    -- the siblings we did not override are still there
    assert.same({ "rust_analyzer" }, require(AUTOMATIC).candidates("rust"))

    vim.env.LUNAVIM_CONFIG_DIR = prior_cfg
    pcall(vim.fn.delete, cfg, "rf")
  end)
end)

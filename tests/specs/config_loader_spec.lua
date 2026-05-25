-- Phase 8.2 config_loader_spec covers:
--   * `load_defaults()` initializing `_G.lvim` with the expected shape;
--   * `load_user_config()` returning true on success / false on missing file
--     and applying both scalar and nested mutations from the user config;
--   * `lvim.builtin.<name>.active = false` propagating through
--     `lvim.plugins.final_spec()`;
--   * `lvim.plugins` entries being appended after the core spec.
describe("config_loader", function()
  local original_env = {}
  local env_names = {
    "LUNAVIM_CONFIG_DIR",
    "LUNARVIM_CONFIG_DIR",
  }
  local original_lvim
  local original_notify
  -- Modules reset before each test so a stale require from a previous
  -- spec cannot leak resolved_dirs / cached state into this one.
  local module_keys = {
    "lvim.bootstrap",
    "lvim.config",
    "lvim.config.defaults",
    "lvim.config.loader",
    "lvim.utils",
    "lvim.plugins",
    "lvim.plugins.spec",
  }
  local original_modules = {}
  local tmpdirs = {}

  local function setenv(name, value)
    if value == nil or value == vim.NIL then
      vim.fn.setenv(name, vim.NIL)
      vim.env[name] = nil
      return
    end

    vim.fn.setenv(name, value)
    vim.env[name] = value
  end

  local function make_tempdir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    table.insert(tmpdirs, dir)
    return dir
  end

  local function write_file(path, contents)
    local f = assert(io.open(path, "w"))
    f:write(contents)
    f:close()
  end

  before_each(function()
    for _, name in ipairs(env_names) do
      original_env[name] = vim.env[name]
      setenv(name, nil)
    end

    original_lvim = _G.lvim
    _G.lvim = nil

    original_notify = vim.notify

    for _, key in ipairs(module_keys) do
      original_modules[key] = package.loaded[key]
      package.loaded[key] = nil
    end
  end)

  after_each(function()
    for _, name in ipairs(env_names) do
      setenv(name, original_env[name])
      original_env[name] = nil
    end

    _G.lvim = original_lvim
    vim.notify = original_notify

    for _, key in ipairs(module_keys) do
      package.loaded[key] = original_modules[key]
      original_modules[key] = nil
    end

    for _, dir in ipairs(tmpdirs) do
      pcall(vim.fn.delete, dir, "rf")
    end
    tmpdirs = {}
  end)

  it("load_defaults() initializes _G.lvim with expected top-level keys", function()
    local config = require("lvim.config")
    config.load_defaults()

    assert.is_table(_G.lvim)
    assert.equals(" ", _G.lvim.leader)
    assert.is_table(_G.lvim.builtin)
    assert.is_table(_G.lvim.plugins)
    assert.is_table(_G.lvim.opt)
    assert.is_table(_G.lvim.lsp)
    assert.is_table(_G.lvim.lazy)
    assert.is_table(_G.lvim.lang)
    assert.is_table(_G.lvim.log)
    assert.is_table(_G.lvim.keys)
    assert.is_table(_G.lvim.utils)
  end)

  it("load_user_config() applies a fixture config materialized via tempname", function()
    local config_dir = make_tempdir()
    write_file(
      config_dir .. "/config.lua",
      table.concat({
        'lvim.leader = "X"',
        'lvim.colorscheme = "test-colors"',
        "lvim.builtin.telescope.active = false",
        'lvim.builtin.lualine.options.theme = "user-theme"',
        "",
      }, "\n")
    )
    setenv("LUNAVIM_CONFIG_DIR", config_dir)

    local config = require("lvim.config")
    config.load_defaults()
    assert.is_true(config.load_user_config())

    assert.equals("X", _G.lvim.leader)
    assert.equals("test-colors", _G.lvim.colorscheme)
    -- Nested mutations from the user config are visible on `_G.lvim`
    -- (the loader runs the chunk against the global env, so `lvim.*`
    -- assignments hit the deep-copied defaults already on `_G.lvim`).
    assert.is_false(_G.lvim.builtin.telescope.active)
    assert.equals("user-theme", _G.lvim.builtin.lualine.options.theme)
    -- Sibling defaults under the same nested table survive the override
    -- (proves the user assignment lands on the deep-copied defaults tree
    -- rather than replacing the whole `options` subtree). If this ever
    -- regresses, a user setting one lualine option would silently wipe
    -- every other LunarVim default in the same subtable.
    assert.equals("", _G.lvim.builtin.lualine.options.section_separators)
    assert.equals("", _G.lvim.builtin.lualine.options.component_separators)
    -- The unrelated `nvimtree` builtin keeps its defaults — the user
    -- override does not bleed across siblings of `builtin`.
    assert.is_true(_G.lvim.builtin.nvimtree.active)
  end)

  it("load_user_config() returns false and does not error when no config file exists", function()
    local config_dir = make_tempdir()
    setenv("LUNAVIM_CONFIG_DIR", config_dir)

    -- `original_notify` was captured by `before_each` and is restored by
    -- `after_each`, so an assertion failure below cannot leak the mocked
    -- `vim.notify` into the next spec.
    local notified = {}
    vim.notify = function(message, level)
      table.insert(notified, { message = message, level = level })
    end

    local config = require("lvim.config")
    config.load_defaults()
    local result = config.load_user_config()

    assert.is_false(result)
    assert.equals(vim.log.levels.INFO, notified[1] and notified[1].level)
    assert.matches("No user config at", notified[1] and notified[1].message or "")
  end)

  it("load_user_config() accepts LUNARVIM_CONFIG_DIR as an alias for LUNAVIM_CONFIG_DIR", function()
    local config_dir = make_tempdir()
    write_file(
      config_dir .. "/config.lua",
      'lvim.leader = "Y"\n'
    )
    setenv("LUNARVIM_CONFIG_DIR", config_dir)

    local config = require("lvim.config")
    config.load_defaults()
    assert.is_true(config.load_user_config())
    assert.equals("Y", _G.lvim.leader)
  end)

  it("load_user_config() prefers LUNAVIM_CONFIG_DIR over LUNARVIM_CONFIG_DIR when both are set", function()
    -- Plan convention: `LUNAVIM_*` env vars take precedence; `LUNARVIM_*` are
    -- accepted aliases. The neighbouring test covers the alias-only case; this
    -- one locks down the precedence contract by pointing each env var at a
    -- distinct config dir and asserting the LUNAVIM dir's leader wins.
    local lunavim_dir = make_tempdir()
    local lunarvim_dir = make_tempdir()
    write_file(lunavim_dir .. "/config.lua", 'lvim.leader = "L"\n')
    write_file(lunarvim_dir .. "/config.lua", 'lvim.leader = "R"\n')
    setenv("LUNAVIM_CONFIG_DIR", lunavim_dir)
    setenv("LUNARVIM_CONFIG_DIR", lunarvim_dir)

    local config = require("lvim.config")
    config.load_defaults()
    assert.is_true(config.load_user_config())
    assert.equals("L", _G.lvim.leader)
  end)

  it("lvim.builtin.<name>.active = false propagates through lvim.plugins.final_spec()", function()
    local config = require("lvim.config")
    config.load_defaults()

    local plugins = require("lvim.plugins")

    local had_telescope = false
    for _, spec in ipairs(plugins.final_spec()) do
      if spec.name == "telescope" then
        had_telescope = true
        break
      end
    end
    assert.is_true(had_telescope)

    _G.lvim.builtin.telescope.active = false

    local still_present = false
    for _, spec in ipairs(plugins.final_spec()) do
      if spec.name == "telescope" then
        still_present = true
        break
      end
    end
    assert.is_false(still_present)
  end)

  it("lvim.plugins entries are appended after the core spec in final_spec()", function()
    local config = require("lvim.config")
    config.load_defaults()

    _G.lvim.plugins = {
      { "foo/bar", name = "foo-bar-user-plugin" },
    }

    local plugins = require("lvim.plugins")
    local spec = plugins.final_spec()

    local last = spec[#spec]
    assert.equals("foo/bar", last[1])
    assert.equals("foo-bar-user-plugin", last.name)

    local user_count = 0
    local user_index, telescope_index
    for i, entry in ipairs(spec) do
      if entry.name == "foo-bar-user-plugin" then
        user_count = user_count + 1
        user_index = i
      elseif entry.name == "telescope" then
        telescope_index = i
      end
    end
    assert.equals(1, user_count)
    -- The user plugin must come strictly after every active core plugin
    -- (telescope is a stable representative). Without this assertion the
    -- spec only proves "last element is the user plugin" — which would
    -- still hold if append-after-core regressed to a single-core-plugin
    -- prefix. Pinning a specific core index keeps the ordering contract
    -- testable as the core spec grows.
    assert.is_not_nil(telescope_index)
    assert.is_true(user_index > telescope_index)
  end)
end)

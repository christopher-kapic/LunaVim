describe("bootstrap", function()
  local bootstrap
  local original_version
  local original_notify
  local original_globals
  local original_bootstrap_module
  local original_isolated_xdg
  local original_env = {}
  local env_names = {
    "LUNAVIM_RUNTIME_DIR",
    "LUNARVIM_RUNTIME_DIR",
    "LUNAVIM_CONFIG_DIR",
    "LUNARVIM_CONFIG_DIR",
    "LUNAVIM_CACHE_DIR",
    "LUNARVIM_CACHE_DIR",
    "LUNAVIM_BASE_DIR",
    "LUNARVIM_BASE_DIR",
    "XDG_DATA_HOME",
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
  }

  local function setenv(name, value)
    if value == nil or value == vim.NIL then
      vim.fn.setenv(name, vim.NIL)
      vim.env[name] = nil
      return
    end

    vim.fn.setenv(name, value)
    vim.env[name] = value
  end

  local function repo_root()
    return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
  end

  before_each(function()
    for _, name in ipairs(env_names) do
      original_env[name] = vim.env[name]
      setenv(name, nil)
    end

    original_bootstrap_module = package.loaded["lvim.bootstrap"]
    package.loaded["lvim.bootstrap"] = nil
    bootstrap = require("lvim.bootstrap")

    original_version = vim.version
    original_notify = vim.notify
    original_isolated_xdg = vim.g.lunavim_isolated_xdg
    original_globals = {
      get_runtime_dir = _G.get_runtime_dir,
      get_config_dir = _G.get_config_dir,
      get_cache_dir = _G.get_cache_dir,
      get_lvim_base_dir = _G.get_lvim_base_dir,
    }

  end)

  after_each(function()
    vim.version = original_version
    vim.notify = original_notify
    vim.g.lunavim_isolated_xdg = original_isolated_xdg
    package.loaded["lvim.bootstrap"] = original_bootstrap_module
    _G.get_runtime_dir = original_globals.get_runtime_dir
    _G.get_config_dir = original_globals.get_config_dir
    _G.get_cache_dir = original_globals.get_cache_dir
    _G.get_lvim_base_dir = original_globals.get_lvim_base_dir

    for _, name in ipairs(env_names) do
      setenv(name, original_env[name])
      original_env[name] = nil
    end
  end)

  it("notifies when Neovim is below the minimum version", function()
    local notified

    vim.version = function()
      return {
        major = 0,
        minor = 10,
        patch = 4,
      }
    end

    vim.notify = function(message, level)
      notified = {
        message = message,
        level = level,
      }
    end

    assert.is_false(bootstrap.check_min_nvim_version())
    assert.equals(vim.log.levels.ERROR, notified.level)
    assert.matches("LunaVim requires Neovim >= 0%.11%.0", notified.message)
    assert.matches("current version is 0%.10%.4", notified.message)
  end)

  it("uses LUNAVIM_RUNTIME_DIR for runtime path resolution", function()
    setenv("LUNAVIM_RUNTIME_DIR", "/tmp/lunavim-runtime")

    assert.equals("/tmp/lunavim-runtime", bootstrap.get_runtime_dir())
  end)

  it("accepts LUNARVIM_RUNTIME_DIR as a runtime path alias", function()
    setenv("LUNARVIM_RUNTIME_DIR", "/tmp/lunarvim-runtime")

    assert.equals("/tmp/lunarvim-runtime", bootstrap.get_runtime_dir())
  end)

  it("prefers LUNAVIM_RUNTIME_DIR over LUNARVIM_RUNTIME_DIR", function()
    setenv("LUNAVIM_RUNTIME_DIR", "/tmp/lunavim-runtime")
    setenv("LUNARVIM_RUNTIME_DIR", "/tmp/lunarvim-runtime")

    assert.equals("/tmp/lunavim-runtime", bootstrap.get_runtime_dir())
  end)

  it("resolves deterministic default runtime, config, cache, and base dirs", function()
    assert.equals(vim.fn.expand("~") .. "/.local/share/lunavim", bootstrap.get_runtime_dir())
    assert.equals(vim.fn.expand("~") .. "/.config/lvim", bootstrap.get_config_dir())
    assert.equals(vim.fn.expand("~") .. "/.cache/lvim", bootstrap.get_cache_dir())
    assert.equals(repo_root(), bootstrap.get_lvim_base_dir())
  end)

  it("resolves config, cache, and base dirs with LUNAVIM precedence over LUNARVIM aliases", function()
    setenv("LUNAVIM_CONFIG_DIR", "/tmp/lunavim-config")
    setenv("LUNARVIM_CONFIG_DIR", "/tmp/lunarvim-config")
    setenv("LUNAVIM_CACHE_DIR", "/tmp/lunavim-cache")
    setenv("LUNARVIM_CACHE_DIR", "/tmp/lunarvim-cache")
    setenv("LUNAVIM_BASE_DIR", "/tmp/lunavim-base")
    setenv("LUNARVIM_BASE_DIR", "/tmp/lunarvim-base")

    assert.equals("/tmp/lunavim-config", bootstrap.get_config_dir())
    assert.equals("/tmp/lunavim-cache", bootstrap.get_cache_dir())
    assert.equals("/tmp/lunavim-base", bootstrap.get_lvim_base_dir())
  end)

  it("accepts LUNARVIM aliases for config, cache, and base dirs", function()
    setenv("LUNARVIM_CONFIG_DIR", "/tmp/lunarvim-config")
    setenv("LUNARVIM_CACHE_DIR", "/tmp/lunarvim-cache")
    setenv("LUNARVIM_BASE_DIR", "/tmp/lunarvim-base")

    assert.equals("/tmp/lunarvim-config", bootstrap.get_config_dir())
    assert.equals("/tmp/lunarvim-cache", bootstrap.get_cache_dir())
    assert.equals("/tmp/lunarvim-base", bootstrap.get_lvim_base_dir())
  end)

  it("installs compatibility globals for resolved directories", function()
    setenv("LUNAVIM_RUNTIME_DIR", "/tmp/lunavim-runtime")
    setenv("LUNAVIM_CONFIG_DIR", "/tmp/lunavim-config")
    setenv("LUNAVIM_CACHE_DIR", "/tmp/lunavim-cache")
    setenv("LUNAVIM_BASE_DIR", "/tmp/lunavim-base")

    bootstrap.setup_globals()

    assert.equals("/tmp/lunavim-runtime", get_runtime_dir())
    assert.equals("/tmp/lunavim-config", get_config_dir())
    assert.equals("/tmp/lunavim-cache", get_cache_dir())
    assert.equals("/tmp/lunavim-base", get_lvim_base_dir())
  end)

  it("keeps resolved directories stable during bootstrap init", function()
    setenv("XDG_DATA_HOME", "/tmp/data-home")
    setenv("XDG_CONFIG_HOME", "/tmp/config-home")
    setenv("XDG_CACHE_HOME", "/tmp/cache-home")
    vim.g.lunavim_isolated_xdg = true

    bootstrap.init()

    assert.equals("/tmp/data-home/lunavim", get_runtime_dir())
    assert.equals("/tmp/config-home/lvim", get_config_dir())
    assert.equals("/tmp/cache-home/lvim", get_cache_dir())
    assert.equals("/tmp/data-home/lunavim", vim.env.XDG_DATA_HOME)
    assert.equals("/tmp/config-home/lvim", vim.env.XDG_CONFIG_HOME)
    assert.equals("/tmp/cache-home/lvim", vim.env.XDG_CACHE_HOME)
  end)

  it("freezes env override resolution after bootstrap init", function()
    setenv("LUNAVIM_RUNTIME_DIR", "/tmp/initial-runtime")
    setenv("LUNAVIM_CONFIG_DIR", "/tmp/initial-config")
    setenv("LUNAVIM_CACHE_DIR", "/tmp/initial-cache")
    setenv("LUNAVIM_BASE_DIR", "/tmp/initial-base")

    bootstrap.init()

    setenv("LUNAVIM_RUNTIME_DIR", "/tmp/changed-runtime")
    setenv("LUNAVIM_CONFIG_DIR", "/tmp/changed-config")
    setenv("LUNAVIM_CACHE_DIR", "/tmp/changed-cache")
    setenv("LUNAVIM_BASE_DIR", "/tmp/changed-base")

    assert.equals("/tmp/initial-runtime", get_runtime_dir())
    assert.equals("/tmp/initial-config", get_config_dir())
    assert.equals("/tmp/initial-cache", get_cache_dir())
    assert.equals("/tmp/initial-base", get_lvim_base_dir())
  end)

  it("leaves XDG env vars unchanged unless isolated XDG is opted in", function()
    setenv("XDG_DATA_HOME", "/tmp/data-home")
    setenv("XDG_CONFIG_HOME", "/tmp/config-home")
    setenv("XDG_CACHE_HOME", "/tmp/cache-home")

    bootstrap.init()

    assert.equals("/tmp/data-home", vim.env.XDG_DATA_HOME)
    assert.equals("/tmp/config-home", vim.env.XDG_CONFIG_HOME)
    assert.equals("/tmp/cache-home", vim.env.XDG_CACHE_HOME)
  end)

end)

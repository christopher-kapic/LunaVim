local M = {}
local resolved_dirs = nil

local MIN_NVIM_VERSION = {
  major = 0,
  minor = 11,
  patch = 0,
}

local function version_string(version)
  return string.format("%d.%d.%d", version.major or 0, version.minor or 0, version.patch or 0)
end

local function env_value(primary, alias)
  local value = vim.env[primary]
  if value ~= nil and value ~= "" then
    return value
  end

  value = vim.env[alias]
  if value ~= nil and value ~= "" then
    return value
  end

  return nil
end

local function join_path(...)
  return table.concat({ ... }, "/")
end

local function home_dir()
  return vim.fn.expand("~")
end

local function xdg_home(name, fallback)
  local value = vim.env[name]
  if value ~= nil and value ~= "" then
    return value
  end

  return join_path(home_dir(), fallback)
end

local function bootstrap_source()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    return source:sub(2)
  end

  return source
end

local function resolve_dirs()
  return {
    base = env_value("LUNAVIM_BASE_DIR", "LUNARVIM_BASE_DIR")
      or vim.fn.fnamemodify(bootstrap_source(), ":p:h:h:h"),
    runtime = env_value("LUNAVIM_RUNTIME_DIR", "LUNARVIM_RUNTIME_DIR")
      or join_path(xdg_home("XDG_DATA_HOME", ".local/share"), "lunavim"),
    config = env_value("LUNAVIM_CONFIG_DIR", "LUNARVIM_CONFIG_DIR")
      or join_path(xdg_home("XDG_CONFIG_HOME", ".config"), "lvim"),
    cache = env_value("LUNAVIM_CACHE_DIR", "LUNARVIM_CACHE_DIR")
      or join_path(xdg_home("XDG_CACHE_HOME", ".cache"), "lvim"),
  }
end

function M.get_lvim_base_dir()
  return (resolved_dirs and resolved_dirs.base)
    or env_value("LUNAVIM_BASE_DIR", "LUNARVIM_BASE_DIR")
    or resolve_dirs().base
end

function M.get_runtime_dir()
  return (resolved_dirs and resolved_dirs.runtime)
    or env_value("LUNAVIM_RUNTIME_DIR", "LUNARVIM_RUNTIME_DIR")
    or resolve_dirs().runtime
end

function M.get_config_dir()
  return (resolved_dirs and resolved_dirs.config)
    or env_value("LUNAVIM_CONFIG_DIR", "LUNARVIM_CONFIG_DIR")
    or resolve_dirs().config
end

function M.get_cache_dir()
  return (resolved_dirs and resolved_dirs.cache)
    or env_value("LUNAVIM_CACHE_DIR", "LUNARVIM_CACHE_DIR")
    or resolve_dirs().cache
end

function M.check_min_nvim_version()
  local current = vim.version()
  local major = current.major or 0
  local minor = current.minor or 0
  local patch = current.patch or 0
  local ok = major > MIN_NVIM_VERSION.major
    or (major == MIN_NVIM_VERSION.major and minor > MIN_NVIM_VERSION.minor)
    or (
      major == MIN_NVIM_VERSION.major
      and minor == MIN_NVIM_VERSION.minor
      and patch >= MIN_NVIM_VERSION.patch
    )

  if not ok then
    local message = string.format(
      "LunaVim requires Neovim >= %s; current version is %s",
      version_string(MIN_NVIM_VERSION),
      version_string(current)
    )
    vim.notify(message, vim.log.levels.ERROR)
  end

  return ok
end

function M.setup_globals()
  _G.get_runtime_dir = M.get_runtime_dir
  _G.get_config_dir = M.get_config_dir
  _G.get_cache_dir = M.get_cache_dir
  _G.get_lvim_base_dir = M.get_lvim_base_dir
end

local function setup_isolated_xdg()
  if not vim.g.lunavim_isolated_xdg then
    return
  end

  vim.env.XDG_DATA_HOME = resolved_dirs.runtime
  vim.env.XDG_CONFIG_HOME = resolved_dirs.config
  vim.env.XDG_CACHE_HOME = resolved_dirs.cache
end

function M.init()
  if not M.check_min_nvim_version() then
    vim.cmd("cquit")
    return
  end

  resolved_dirs = resolve_dirs()
  M.setup_globals()
  setup_isolated_xdg()

  return M
end

return M

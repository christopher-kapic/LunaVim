-- `:checkhealth lvim` entry point. Neovim discovers this module by path
-- convention (`lua/<name>/health.lua`) and invokes `check()` against a
-- scratch checkhealth buffer. Interactively the buffer is shown in a new
-- window; the headless `bin/lvim doctor` driver reads the same buffer and
-- streams it to stdout (see `scripts/doctor.lua`).

local M = {}

local MIN_NVIM = { major = 0, minor = 11, patch = 0 }

local function check_nvim_version()
  local current = vim.version()
  local major = current.major or 0
  local minor = current.minor or 0
  local patch = current.patch or 0
  local label = string.format("Neovim %d.%d.%d", major, minor, patch)
  local ok = major > MIN_NVIM.major
    or (major == MIN_NVIM.major and minor > MIN_NVIM.minor)
    or (major == MIN_NVIM.major and minor == MIN_NVIM.minor and patch >= MIN_NVIM.patch)

  if ok then
    vim.health.ok(string.format("%s (>= %d.%d.%d required)", label, MIN_NVIM.major, MIN_NVIM.minor, MIN_NVIM.patch))
  else
    vim.health.error(
      string.format("%s is older than the required %d.%d.%d", label, MIN_NVIM.major, MIN_NVIM.minor, MIN_NVIM.patch),
      { "Upgrade Neovim to at least 0.11" }
    )
  end
end

local function check_executable(name, hints)
  if vim.fn.executable(name) == 1 then
    vim.health.ok(string.format("`%s` found on PATH", name))
    return true
  end
  vim.health.warn(string.format("`%s` not found on PATH", name), hints)
  return false
end

local function check_compiler()
  for _, name in ipairs({ "cc", "gcc", "clang" }) do
    if vim.fn.executable(name) == 1 then
      vim.health.ok(string.format("C compiler `%s` found on PATH", name))
      return
    end
  end
  vim.health.warn("no C compiler (cc, gcc, or clang) found on PATH", {
    "Treesitter parser builds and several Lua C deps need a C compiler",
    "Debian/Ubuntu: `sudo apt install build-essential`",
    "macOS: `xcode-select --install`",
  })
end

local function check_finder()
  for _, name in ipairs({ "fd", "fdfind" }) do
    if vim.fn.executable(name) == 1 then
      vim.health.ok(string.format("`%s` found on PATH", name))
      return
    end
  end
  vim.health.warn("`fd` (or `fdfind`) not found on PATH", {
    "Telescope uses fd for fast file finding",
    "Debian/Ubuntu: `sudo apt install fd-find`",
    "macOS: `brew install fd`",
  })
end

local function check_provider(exe, label)
  if vim.fn.executable(exe) == 1 then
    vim.health.ok(string.format("provider `%s` available (`%s` on PATH)", label, exe))
  else
    vim.health.warn(string.format("provider `%s` unavailable (`%s` not on PATH)", label, exe), {
      string.format("Silence by setting `vim.g.loaded_%s_provider = 0` in your config", label),
    })
  end
end

local function check_writable(label, dir)
  if not dir or dir == "" then
    vim.health.error(string.format("%s directory is unset", label))
    return
  end

  if vim.fn.isdirectory(dir) == 0 then
    local ok = pcall(vim.fn.mkdir, dir, "p")
    if not ok or vim.fn.isdirectory(dir) == 0 then
      vim.health.error(string.format("%s directory does not exist and could not be created: %s", label, dir), {
        "Check parent directory permissions",
      })
      return
    end
  end

  local probe = string.format("%s/.lvim-health-%d-%d", dir, vim.fn.getpid(), os.time())
  local fd, err = io.open(probe, "w")
  if not fd then
    vim.health.error(string.format("%s directory is not writable: %s", label, dir), {
      err or "open() failed",
      "Check filesystem permissions and disk space",
    })
    return
  end
  fd:close()
  os.remove(probe)
  vim.health.ok(string.format("%s directory writable: %s", label, dir))
end

function M.check()
  local bootstrap = require("lvim.bootstrap")

  vim.health.start("LunaVim — runtime")
  check_nvim_version()

  vim.health.start("LunaVim — external tools")
  check_executable("git", { "git is required for plugin install/update" })
  check_compiler()
  check_executable("tree-sitter", {
    "nvim-treesitter parser install/update needs the `tree-sitter` CLI",
    "Install it from your system package manager; do not use the deprecated npm package",
  })
  check_executable("rg", {
    "Telescope live_grep uses ripgrep",
    "Debian/Ubuntu: `sudo apt install ripgrep`; macOS: `brew install ripgrep`",
  })
  check_finder()

  vim.health.start("LunaVim — providers")
  check_provider("node", "node")
  check_provider("python3", "python3")

  vim.health.start("LunaVim — directories")
  check_writable("base", bootstrap.get_lvim_base_dir())
  check_writable("runtime", bootstrap.get_runtime_dir())
  check_writable("config", bootstrap.get_config_dir())
  check_writable("cache", bootstrap.get_cache_dir())
end

return M

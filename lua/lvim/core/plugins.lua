-- Phase 2.1: bootstrap lazy.nvim and hand it the assembled plugin spec.
--
-- Layout (per the LunaVim runtime/config contract):
--   * lazy.nvim's own source lives under `<runtime>/lazy/lazy.nvim` so it
--     stays inside the LunaVim-managed runtime tree (cleaned up via
--     :LvimCacheReset alongside the rest of the plugin install root).
--   * Managed plugin installs live under `<runtime>/lazy` (lazy.nvim's
--     `root`); the bootstrap clone sits alongside them by convention.
--   * The lockfile lives in the USER's config dir (`<config>/lazy-lock.json`)
--     so it's part of the user's versioned config, not the disposable
--     runtime tree.
--
-- The `--branch=stable` flag is the form lazy.nvim itself recommends in its
-- README/docs and uses in its internal bootstrap fallback — see
-- `kcl ask lazy-nvim "is lazy.nvim's stable branch still recommended or main"`
-- (answer pinned 2026-05). `--filter=blob:none` matches lazy.nvim's
-- documented snippet to keep the clone small.

local M = {}

local LAZY_REPO = "https://github.com/folke/lazy.nvim.git"
local LAZY_BRANCH = "stable"

local function lazy_install_path()
  return _G.get_runtime_dir() .. "/lazy/lazy.nvim"
end

-- Clone lazy.nvim on first launch; on every subsequent launch the clone
-- already exists so we just prepend it to runtimepath. Idempotency is what
-- makes a passing smoke run hold across re-launches without re-clone.
--
-- On clone failure we raise a Lua error with the captured `git` output so
-- the underlying network/git error surfaces directly. Using `error()` (not
-- `os.exit`) keeps this library-friendly: callers and tests can `pcall` it,
-- and the failure propagates through normal Lua semantics rather than
-- terminating the Neovim process from a deeply nested module.
function M.bootstrap()
  local path = lazy_install_path()
  local uv = vim.uv or vim.loop

  if not uv.fs_stat(path) then
    local out = vim.fn.system({
      "git",
      "clone",
      "--filter=blob:none",
      "--branch=" .. LAZY_BRANCH,
      LAZY_REPO,
      path,
    })
    if vim.v.shell_error ~= 0 then
      error(string.format("lvim: failed to clone lazy.nvim into %s: %s", path, out or ""))
    end
  end

  vim.opt.rtp:prepend(path)
end

-- Hand the assembled spec (core + user, with disabled builtins filtered)
-- to lazy.nvim. `root`/`lockfile` defaults align lazy.nvim's storage with
-- the LunaVim path contract; `lvim.lazy.opts` lets users override any of
-- lazy's options (e.g. ui, dev, install) without us listing them upfront.
--
-- `install.missing = false` is the LunarVim contract: a fresh launch must
-- not block on synchronously cloning the entire core spec — installation
-- happens explicitly via `:LvimSyncCorePlugins` (Phase 2.4). Without this
-- default lazy.setup() would synchronously `git clone` every missing entry
-- on first launch (kcl-confirmed: `Async:wait` blocks the main thread
-- inside `lazy.manage.install`), making the smoke test wedge on a 15-plugin
-- network round-trip on every invocation. User config can still flip it
-- back via `lvim.lazy.opts = { install = { missing = true } }`.
-- Advisory for the state `install.missing = false` makes reachable: spec
-- entries with no on-disk install. This is what a user lands in after
-- updating the checkout without re-syncing plugins (e.g. a bare `git pull`
-- in the install dir, or `:LvimUpdate` before it chained a sync): lazy.nvim
-- only reports the gap per lazy-load trigger, one cryptic
-- "Plugin <name> is not installed" error at a time, with no hint at the
-- remedy. One scheduled WARN naming the full missing set replaces that
-- confusion with the fix.
--
-- Gated on an attached UI: the smoke harness boots headless with
-- `install.missing = false` and deliberately runs without core plugins on
-- disk, and this advisory must not leak into its stderr assertions (lazy's
-- own per-plugin errors are what it tolerates there). The wording avoids
-- the phrase "is not installed" for the same reason — both smoke scripts
-- pattern-match that exact shape as lazy.nvim noise. The gate also
-- suppresses the advisory for `--embed` front ends (neovide,
-- VSCode-neovim) that attach their UI after init — acceptable: they are
-- outside LunaVim's terminal-launcher contract.
local function warn_missing_plugins()
  if #vim.api.nvim_list_uis() == 0 then
    return
  end
  local ok, config = pcall(require, "lazy.core.config")
  if not ok or type(config.plugins) ~= "table" then
    return
  end

  local missing = {}
  for _, plugin in pairs(config.plugins) do
    if plugin._.installed ~= true then
      missing[#missing + 1] = plugin.name
    end
  end
  if #missing == 0 then
    return
  end

  table.sort(missing)
  vim.schedule(function()
    vim.notify(
      string.format(
        "lvim: %d plugin%s missing from the runtime dir (%s). Run :LvimSyncCorePlugins to install them.",
        #missing,
        #missing == 1 and "" or "s",
        table.concat(missing, ", ")
      ),
      vim.log.levels.WARN
    )
  end)
end

function M.load()
  local lvim = _G.lvim or {}
  local user_opts = (lvim.lazy and lvim.lazy.opts) or {}

  local opts = vim.tbl_deep_extend("force", {
    root = _G.get_runtime_dir() .. "/lazy",
    lockfile = _G.get_config_dir() .. "/lazy-lock.json",
    install = { missing = false },
  }, user_opts)

  -- lazy.nvim's `performance.rtp.reset = true` (default) rebuilds rtp from
  -- the configured plugin set and would drop the LunaVim base dir the root
  -- init.lua prepended. `performance.rtp.paths` is lazy's documented hook
  -- for "always include these in rtp"; lazy iterates it via
  -- `vim.opt.rtp:append` after the reset, so rtp-based discovery
  -- (`:checkhealth lvim`, ftdetect/, queries/, etc.) keeps finding our base
  -- dir without us re-prepending after `setup()`.
  --
  -- Force-include the base dir AFTER the deep-extend rather than seeding it
  -- in the defaults table: `vim.tbl_deep_extend` replaces array-style tables
  -- wholesale (it does not concatenate), so a user-supplied
  -- `lvim.lazy.opts.performance.rtp.paths` would otherwise drop our entry
  -- and silently break health/ftdetect/queries discovery. Build a NEW
  -- `paths` array rather than `table.insert`ing into the existing one —
  -- `vim.tbl_deep_extend` shares array-table references, so mutating
  -- `opts.performance.rtp.paths` would also mutate the user's
  -- `lvim.lazy.opts.performance.rtp.paths` table (observable, e.g. across
  -- `:LvimReload` calls).
  opts.performance = opts.performance or {}
  opts.performance.rtp = opts.performance.rtp or {}
  local lvim_base = _G.get_lvim_base_dir()
  local new_paths = {}
  local has_base = false
  for _, p in ipairs(opts.performance.rtp.paths or {}) do
    table.insert(new_paths, p)
    if p == lvim_base then
      has_base = true
    end
  end
  if not has_base then
    table.insert(new_paths, lvim_base)
  end
  opts.performance.rtp.paths = new_paths

  local spec = require("lvim.plugins").final_spec()
  local lazy = require("lazy").setup(spec, opts)
  warn_missing_plugins()
  return lazy
end

return M

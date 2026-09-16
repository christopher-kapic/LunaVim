-- Phase 2.3: register the user-facing commands from the Compatibility
-- Contract (plan.md). Each command is a thin wrapper that delegates to the
-- helpers already in place (paths from bootstrap, reload from utils.reload,
-- plugin manager from lazy.nvim). Future phases extend these — notably
-- :LvimSyncCorePlugins which Phase 2.4 will switch to a snapshot-driven
-- restore, and :LvimReload which Phase 3.4 will extend to re-apply options
-- and keymaps once those modules exist.

local M = {}

local function neovim_version_string()
  local v = vim.version()
  return string.format("%d.%d.%d", v.major or 0, v.minor or 0, v.patch or 0)
end

local function call_or(fn, fallback)
  if type(fn) == "function" then
    local ok, value = pcall(fn)
    if ok and type(value) == "string" and value ~= "" then
      return value
    end
  end
  return fallback
end

local function plugin_count()
  local ok, lazy = pcall(require, "lazy")
  if not ok or type(lazy.stats) ~= "function" then
    return "unknown"
  end
  local stats = lazy.stats()
  return tostring(stats.count or 0)
end

local function builtins_summary()
  if type(_G.lvim) ~= "table" or type(_G.lvim.builtin) ~= "table" then
    return "<unset>"
  end
  local entries = {}
  for name, value in pairs(_G.lvim.builtin) do
    local active = type(value) == "table" and value.active and true or false
    table.insert(entries, string.format("%s=%s", name, tostring(active)))
  end
  table.sort(entries)
  return table.concat(entries, ", ")
end

-- Build the textual report. Each entry is rendered as a `key: value` line so
-- the buffer is greppable from headless invocations. The first line begins
-- with `Neovim` because the step's acceptance grep matches against it.
local function build_info_lines()
  local config_dir = call_or(_G.get_config_dir, "")
  local user_config_path = config_dir ~= "" and (config_dir .. "/config.lua") or "<unknown>"

  return {
    "Neovim version: " .. neovim_version_string(),
    "lvim base dir: " .. call_or(_G.get_lvim_base_dir, "<unset>"),
    "runtime dir: " .. call_or(_G.get_runtime_dir, "<unset>"),
    "config dir: " .. call_or(_G.get_config_dir, "<unset>"),
    "cache dir: " .. call_or(_G.get_cache_dir, "<unset>"),
    "user config path: " .. user_config_path,
    "plugin count: " .. plugin_count(),
    "lvim.leader: " .. tostring((_G.lvim or {}).leader or "<unset>"),
    "builtins: " .. builtins_summary(),
  }
end

local function lvim_info()
  vim.cmd("enew")
  vim.cmd("setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, build_info_lines())
end

-- Snapshot-driven plugin sync, shared by :LvimSyncCorePlugins and the
-- post-pull pass of :LvimUpdate above. Forward-declared here so
-- lvim_update's on_exit callback can reference it; the definition below
-- assigns to this local (a `local function` there would shadow the
-- placeholder instead, leaving lvim_update calling nil).
local sync_core_plugins
local refresh_lazy_spec

-- :LvimUpdate runs `git pull --rebase --autostash` inside the LunaVim base
-- directory and streams every captured line through vim.notify. Using
-- vim.fn.jobstart keeps the UI responsive (the LunarVim original ran git
-- synchronously and froze the editor for the duration of the pull).
--
-- When the pull actually moved HEAD, it chains a core-plugin sync. Without
-- that, a spec change shipped in the pull leaves the runtime dir without
-- the new plugins, and since `install.missing = false` keeps lazy.nvim
-- from installing anything at launch, every lazy-load trigger for a new
-- entry errors with "Plugin <name> is not installed" until the user
-- manually runs :LvimSyncCorePlugins. Upstream LunarVim's update flow
-- chains its plugin sync for the same reason.
--
-- The chained sync only runs when the pull moved HEAD, detected by
-- comparing `git rev-parse HEAD` before and after (git localizes its
-- "up to date" prose — "Bereits aktuell.", "Déjà à jour." — so its
-- output cannot be matched reliably): a no-op update should not pay a
-- network round-trip per managed plugin.
local function git_head(base)
  local out = vim.fn.system({ "git", "-C", base, "rev-parse", "HEAD" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return vim.trim(out)
end

local function lvim_update()
  local base = call_or(_G.get_lvim_base_dir, "")
  if base == "" then
    vim.notify("LvimUpdate: cannot resolve lvim base dir", vim.log.levels.ERROR)
    return
  end

  vim.notify(string.format("LvimUpdate: git pull --rebase --autostash in %s", base), vim.log.levels.INFO)
  local head_before = git_head(base)

  local function stream(level)
    return function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line ~= "" then
          vim.notify(line, level)
        end
      end
    end
  end

  vim.fn.jobstart({ "git", "-C", base, "pull", "--rebase", "--autostash" }, {
    on_stdout = stream(vim.log.levels.INFO),
    on_stderr = stream(vim.log.levels.WARN),
    on_exit = function(_, code)
      if code ~= 0 then
        vim.notify(string.format("LvimUpdate failed (exit %d)", code), vim.log.levels.ERROR)
        return
      end
      vim.notify("LvimUpdate OK", vim.log.levels.INFO)

      -- Commit SHAs are stable across locales, and no path through
      -- `pull --rebase --autostash` updates the working tree without
      -- moving HEAD (a rebase replay produces new SHAs too). When either
      -- rev-parse fails, assume the checkout changed: the safe failure
      -- direction is a spurious sync (a wasted round trip), not skipping
      -- a needed one (which strands new spec entries uninstalled).
      local head_after = git_head(base)
      if head_before and head_after and head_before == head_after then
        vim.notify("LvimUpdate: checkout unchanged; skipping plugin sync", vim.log.levels.INFO)
        return
      end

      -- lazy.nvim will not re-run setup() in this session. Reload the
      -- core spec into Config.plugins so same-name URL swaps (mini.nvim →
      -- mini.comment, blink.pairs → mini.pairs) are visible to eviction
      -- and rebase before we sync. If that fails, skip the in-session
      -- sync rather than keep-pinning against the pre-pull spec.
      if not refresh_lazy_spec() then
        vim.notify(
          "LvimUpdate: could not reload the plugin spec in this session; restart Neovim and run :LvimSyncCorePlugins",
          vim.log.levels.WARN
        )
        return
      end
      vim.notify("LvimUpdate: syncing core plugins after update", vim.log.levels.INFO)
      sync_core_plugins(false)
    end,
  })
end

-- Phase 2.4: snapshot-driven restore. If `snapshots/default.json` (under
-- the LunaVim base dir) is a non-empty plugin map, copy it onto the
-- user's `<config>/lazy-lock.json` and call `require('lazy').restore()`
-- so every plugin checks out the pinned commit. If the snapshot is empty
-- (the initial `{}` shipped with the repo) or absent, fall back to
-- `require('lazy').sync()` — the previous Phase 2.3 contract.
--
-- The `bang` form (`:LvimSyncCorePlugins!`) skips the overwrite
-- confirmation; the unbanged form prompts because writing the lockfile
-- is destructive of the user's currently-pinned commit set. Declining
-- keeps the user's pins but still installs missing entries at them,
-- restores drifted checkouts, and cleans removed plugins — see the
-- confirm block in `sync_core_plugins` below for why "No" must not be a
-- no-op. Both branches run `lazy.clean()` so a spec-removed plugin
-- (e.g. `blink.lib` after autopairs moved to mini.pairs) does not stay
-- on disk. Keep-pins also rewrites lockfile entries whose on-disk git
-- origin no longer matches the spec URL, swapping in the snapshot pin.
-- Those checkouts are then deleted so install re-clones the new URL at
-- that pin; the lockfile is re-applied after install because lazy.nvim
-- Lock.update()s from on-disk SHAs when install finishes.
local function snapshot_path()
  local base = call_or(_G.get_lvim_base_dir, "")
  if base == "" then
    return nil
  end
  return base .. "/snapshots/default.json"
end

local function read_file(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local contents = fd:read("*a")
  fd:close()
  return contents
end

-- Returns (decoded_table, raw_contents, err). Reads the snapshot file exactly
-- once and hands back both the decoded value (so the caller can branch on
-- empty/non-empty) AND the raw bytes (so the caller can write them onto the
-- lockfile without re-reading). Reading once closes the TOCTTOU window where
-- a concurrent edit between validation and copy could leave the lockfile
-- holding bytes the validator never saw — and avoids redundant I/O.
local function load_snapshot()
  local path = snapshot_path()
  if not path then
    return nil, nil, "cannot resolve snapshot path"
  end
  local contents = read_file(path)
  if not contents then
    return nil, nil, "snapshot not found at " .. path
  end
  -- `vim.json.decode` rejects an empty string; tolerate it by treating it
  -- as an empty object so a maintainer accidentally truncating the file
  -- doesn't break the command.
  if contents:match("^%s*$") then
    return {}, contents, nil
  end
  local ok, decoded = pcall(vim.json.decode, contents)
  if not ok or type(decoded) ~= "table" then
    return nil, nil, "snapshot at " .. path .. " is not valid JSON"
  end
  return decoded, contents, nil
end

local function write_file(path, contents)
  local fd, err = io.open(path, "w")
  if not fd then
    return false, err or "open failed"
  end
  fd:write(contents)
  fd:close()
  return true, nil
end

-- Phase 5.3: after a successful sync/restore, refresh treesitter parsers
-- by running `:TSUpdate`. Deferred through `vim.schedule_wrap` so the
-- command itself returns immediately — parser fetch/compile streams on
-- the next loop tick.
--
-- Gate on `package.loaded["nvim-treesitter"]` (mirroring LunarVim's
-- upstream reference's `lua/lvim/utils/hooks.lua:67`, vendored under
-- `references/`): the plugin is event-lazy
-- via `BufReadPost`/`BufNewFile` (see `lua/lvim/plugins/spec.lua`), so
-- on a fresh sync — before any buffer is opened — it has not loaded
-- and `:TSUpdate` is not yet registered. In that state lazy.nvim's
-- own `build = ":TSUpdate"` hook (also in the spec) has already
-- refreshed parsers as part of `lazy.sync()`/`lazy.restore()`, so
-- there is nothing left to do; skip silently rather than emit a noisy
-- WARN on every fresh-launch sync.
--
-- The pcall guards the documented runtime failure mode (`:help
-- nvim-treesitter-troubleshooting` cites a missing C compiler as the
-- usual cause) so a parser-compile error does NOT abort the
-- surrounding sync; the error is surfaced verbatim via `vim.notify`
-- at WARN level so the user sees what actually went wrong.
local schedule_tsupdate = vim.schedule_wrap(function()
  if not package.loaded["nvim-treesitter"] then
    return
  end
  if vim.fn.executable("tree-sitter") ~= 1 then
    return
  end
  local ok, err = pcall(vim.cmd, "TSUpdate")
  if not ok then
    vim.notify("LvimSyncCorePlugins: TSUpdate failed (skipping parser refresh): " .. tostring(err), vim.log.levels.WARN)
  end
end)

local function maybe_schedule_tsupdate()
  local builtin = (_G.lvim or {}).builtin or {}
  local ts = builtin.treesitter
  if type(ts) == "table" and ts.active then
    schedule_tsupdate()
  end
end

local function collect_error_tasks()
  local seen = {}
  local ok_c, Config = pcall(require, "lazy.core.config")
  if not ok_c or type(Config) ~= "table" or type(Config.plugins) ~= "table" then
    return seen
  end
  for _, plugin in pairs(Config.plugins) do
    if type(plugin) == "table" and type(plugin.name) == "string" then
      for _, task in ipairs((plugin._ or {}).tasks or {}) do
        local ok, has = pcall(function()
          return task:has_errors()
        end)
        if ok and has then
          seen[task] = plugin.name
        end
      end
    end
  end
  return seen
end

-- lazy.install/restore/clean each return a runner with :wait(cb). Smoke
-- stubs often return nothing; treat that as already finished so tests that
-- only record the call still see restore+clean. `cb` receives a list of
-- plugin names that reported *new* task errors since this wait started, or
-- nil on success. Pre-existing error tasks (lazy keeps them for the UI)
-- are ignored so a successful snapshot-pin retry is not treated as failure.
local function wait_runner(runner, cb)
  local before = collect_error_tasks()
  local function finish()
    local failed = require("lvim.core.plugin_lock").new_error_names(before, collect_error_tasks())
    cb(#failed > 0 and failed or nil)
  end
  if type(runner) == "table" and type(runner.wait) == "function" then
    runner:wait(finish)
    return
  end
  finish()
end

-- lazy.manage.lock.load() caches the decoded lockfile in Lock._loaded.
-- After we write pins, that cache must be dropped or install/restore
-- keep using the pre-write table. lazy.install also Lock.update()s from
-- on-disk SHAs when it finishes, which would clobber snapshot/rebased
-- pins for still-installed plugins; the caller re-writes `intended_bytes`
-- after install and invalidates again before restore.
local function invalidate_lock_cache()
  local ok, Lock = pcall(require, "lazy.manage.lock")
  if ok and type(Lock) == "table" then
    Lock._loaded = false
  end
end

local function mark_uninstalled(names)
  local ok_cfg, Config = pcall(require, "lazy.core.config")
  if not ok_cfg or type(Config) ~= "table" or type(Config.plugins) ~= "table" then
    return
  end
  local want = {}
  for _, name in ipairs(names) do
    want[name] = true
  end
  for _, plugin in pairs(Config.plugins) do
    if type(plugin) == "table" and want[plugin.name] then
      plugin._ = plugin._ or {}
      plugin._.installed = false
    end
  end
end

local function evict_mismatched_checkouts()
  local ok_cfg, Config = pcall(require, "lazy.core.config")
  if not ok_cfg or type(Config) ~= "table" or type(Config.plugins) ~= "table" then
    return {}
  end
  local plugin_lock = require("lvim.core.plugin_lock")
  local root = Config.options and Config.options.root
  local victims = plugin_lock.list_mismatched(Config.plugins, root)
  local evicted = {}
  for _, item in ipairs(victims) do
    if vim.fn.delete(item.dir, "rf") == 0 then
      evicted[#evicted + 1] = item.name
    else
      vim.notify("LvimSyncCorePlugins: failed to remove stale checkout " .. item.dir, vim.log.levels.WARN)
    end
  end
  if #evicted > 0 then
    local ok_state = pcall(function()
      require("lazy.core.plugin").update_state()
    end)
    if not ok_state then
      mark_uninstalled(evicted)
    end
  end
  return evicted
end

local function drop_error_tasks(names)
  local ok_cfg, Config = pcall(require, "lazy.core.config")
  if not ok_cfg or type(Config) ~= "table" or type(Config.plugins) ~= "table" or type(names) ~= "table" then
    return
  end
  local want = {}
  for _, name in ipairs(names) do
    want[name] = true
  end
  for _, plugin in pairs(Config.plugins) do
    if type(plugin) == "table" and want[plugin.name] then
      plugin._ = plugin._ or {}
      local kept = {}
      for _, task in ipairs(plugin._.tasks or {}) do
        local ok, running = pcall(function()
          return task:running()
        end)
        if ok and running then
          kept[#kept + 1] = task
        end
      end
      plugin._.tasks = kept
    end
  end
end

local function evict_named_checkouts(names)
  local ok_cfg, Config = pcall(require, "lazy.core.config")
  if not ok_cfg or type(Config) ~= "table" or type(Config.plugins) ~= "table" or type(names) ~= "table" then
    return
  end
  local plugin_lock = require("lvim.core.plugin_lock")
  local root = Config.options and Config.options.root
  local want = {}
  for _, name in ipairs(names) do
    want[name] = true
  end
  local evicted = {}
  for _, plugin in pairs(Config.plugins) do
    if type(plugin) == "table" and want[plugin.name] and plugin_lock.is_under_root(plugin.dir, root) then
      if vim.fn.delete(plugin.dir, "rf") ~= 0 then
        vim.notify("LvimSyncCorePlugins: failed to remove stale checkout " .. plugin.dir, vim.log.levels.WARN)
      end
      evicted[#evicted + 1] = plugin.name
    end
  end
  if #evicted > 0 then
    pcall(function()
      require("lazy.core.plugin").update_state()
    end)
    mark_uninstalled(evicted)
  end
end

local function install_restore_clean(lazy, lockfile, intended_bytes, snapshot)
  local retried = false

  local function assert_pins()
    if type(intended_bytes) ~= "string" then
      return true
    end
    local wrote, write_err = write_file(lockfile, intended_bytes)
    if not wrote then
      vim.notify(
        string.format("LvimSyncCorePlugins: failed to write %s: %s", lockfile, write_err),
        vim.log.levels.ERROR
      )
      return false
    end
    invalidate_lock_cache()
    return true
  end

  local function finish_with_clean()
    wait_runner(lazy.clean(), function()
      maybe_schedule_tsupdate()
    end)
  end

  local function try_snapshot_pins(failed)
    if retried or type(snapshot) ~= "table" or type(failed) ~= "table" then
      return false
    end
    local raw = read_file(lockfile) or intended_bytes
    local ok_lock, lock = pcall(vim.json.decode, raw or "")
    if not ok_lock or type(lock) ~= "table" then
      lock = {}
    end
    local plugin_lock = require("lvim.core.plugin_lock")
    local next_lock, applied = plugin_lock.pins_for_failed_checkouts(lock, snapshot, failed)
    if #applied == 0 then
      return false
    end
    retried = true
    intended_bytes = plugin_lock.encode(next_lock)
    vim.notify(
      string.format("LvimSyncCorePlugins: checkout failed; retrying %s at snapshot pins", table.concat(applied, ", ")),
      vim.log.levels.WARN
    )
    evict_named_checkouts(applied)
    drop_error_tasks(applied)
    return assert_pins()
  end

  if not assert_pins() then
    return
  end
  wait_runner(lazy.install({ lockfile = true }), function(failed)
    -- install's completion Lock.update() rewrote the file from whatever
    -- was still on disk. Put the intended pins back so restore checkouts
    -- the snapshot / rebased SHAs, not the pre-eviction blink.pairs
    -- / mini.nvim commits.
    if failed then
      if try_snapshot_pins(failed) then
        wait_runner(lazy.install({ lockfile = true }), function(retry_failed)
          if retry_failed then
            vim.notify(
              "LvimSyncCorePlugins: install failed after snapshot-pin retry ("
                .. table.concat(retry_failed, ", ")
                .. ")",
              vim.log.levels.ERROR
            )
            finish_with_clean()
            return
          end
          if not assert_pins() then
            finish_with_clean()
            return
          end
          wait_runner(lazy.restore(), function(restore_failed)
            if restore_failed then
              vim.notify(
                "LvimSyncCorePlugins: restore failed (" .. table.concat(restore_failed, ", ") .. ")",
                vim.log.levels.ERROR
              )
            elseif not assert_pins() then
              finish_with_clean()
              return
            end
            finish_with_clean()
          end)
        end)
        return
      end
      vim.notify("LvimSyncCorePlugins: install failed (" .. table.concat(failed, ", ") .. ")", vim.log.levels.ERROR)
      finish_with_clean()
      return
    end
    if not assert_pins() then
      finish_with_clean()
      return
    end
    wait_runner(lazy.restore(), function(restore_failed)
      if restore_failed then
        if try_snapshot_pins(restore_failed) then
          wait_runner(lazy.restore(), function(retry_failed)
            if retry_failed then
              vim.notify(
                "LvimSyncCorePlugins: restore failed after snapshot-pin retry ("
                  .. table.concat(retry_failed, ", ")
                  .. ")",
                vim.log.levels.ERROR
              )
            elseif not assert_pins() then
              finish_with_clean()
              return
            end
            finish_with_clean()
          end)
          return
        end
        vim.notify(
          "LvimSyncCorePlugins: restore failed (" .. table.concat(restore_failed, ", ") .. ")",
          vim.log.levels.ERROR
        )
        finish_with_clean()
        return
      end
      -- Re-assert after restore; clean's Lock.update then drops
      -- spec-removed names (e.g. blink.lib) from the lockfile.
      if not assert_pins() then
        finish_with_clean()
        return
      end
      finish_with_clean()
    end)
  end)
end

-- After `:LvimUpdate` moves HEAD, package.loaded still has the pre-pull
-- spec. Re-parse `final_spec()` into lazy's Config so URL-changed names
-- and new entries exist before install/restore/clean.
refresh_lazy_spec = function()
  package.loaded["lvim.plugins.spec"] = nil
  package.loaded["lvim.plugins"] = nil
  local ok_spec, spec = pcall(function()
    return require("lvim.plugins").final_spec()
  end)
  if not ok_spec or type(spec) ~= "table" then
    return false
  end
  local ok_cfg, Config = pcall(require, "lazy.core.config")
  if not ok_cfg or type(Config) ~= "table" or type(Config.options) ~= "table" then
    return false
  end
  Config.options.spec = spec
  local ok_load = pcall(function()
    local Plugin = require("lazy.core.plugin")
    Plugin.load()
    Plugin.update_state()
  end)
  return ok_load == true
end

local function collect_installed_origins()
  local ok, Config = pcall(require, "lazy.core.config")
  if not ok or type(Config) ~= "table" or type(Config.plugins) ~= "table" then
    return {}
  end
  local plugin_lock = require("lvim.core.plugin_lock")
  local installed = {}
  for _, plugin in pairs(Config.plugins) do
    if type(plugin) == "table" and type(plugin.name) == "string" then
      installed[plugin.name] = {
        spec_url = plugin.url,
        origin = plugin_lock.read_origin(plugin.dir),
      }
    end
  end
  return installed
end

local function rebase_lockfile_for_origin_changes(lockfile, snapshot)
  local contents = read_file(lockfile)
  if not contents or contents:match("^%s*$") then
    return {}
  end
  local ok, lock = pcall(vim.json.decode, contents)
  if not ok or type(lock) ~= "table" then
    return {}
  end

  local plugin_lock = require("lvim.core.plugin_lock")
  local next_lock, rewritten = plugin_lock.rebase_stale_pins(lock, snapshot, collect_installed_origins())
  if #rewritten == 0 then
    return rewritten
  end

  local wrote, write_err = write_file(lockfile, plugin_lock.encode(next_lock))
  if not wrote then
    vim.notify(
      string.format("LvimSyncCorePlugins: failed to rewrite stale lockfile pins at %s: %s", lockfile, write_err),
      vim.log.levels.ERROR
    )
    return {}
  end
  return rewritten
end

sync_core_plugins = function(bang)
  local ok, lazy = pcall(require, "lazy")
  if not ok then
    vim.notify("LvimSyncCorePlugins: lazy.nvim not available", vim.log.levels.ERROR)
    return
  end

  local snapshot, contents, err = load_snapshot()
  if not snapshot then
    vim.notify("LvimSyncCorePlugins: " .. err .. "; running lazy.sync() instead", vim.log.levels.WARN)
    lazy.sync()
    maybe_schedule_tsupdate()
    return
  end

  if next(snapshot) == nil then
    -- Empty/initial snapshot: nothing pinned yet, so sync against branch
    -- HEADs the same way the Phase 2.3 implementation did.
    lazy.sync()
    maybe_schedule_tsupdate()
    return
  end

  local config_dir = call_or(_G.get_config_dir, "")
  if config_dir == "" then
    vim.notify("LvimSyncCorePlugins: cannot resolve config dir", vim.log.levels.ERROR)
    return
  end

  local snap_path = snapshot_path()
  local lockfile = config_dir .. "/lazy-lock.json"

  if not bang then
    local choice = vim.fn.confirm(string.format("Overwrite %s with snapshot %s?", lockfile, snap_path), "&Yes\n&No", 2)
    if choice ~= 1 then
      -- "No" means "keep my pins", not "do nothing". lazy.restore() alone
      -- cannot honor even that: its runner filters to ALREADY-INSTALLED
      -- plugins (lazy/manage/init.lua: `plugin.url and plugin._.installed`),
      -- so it re-checks-out pins but never puts spec entries missing from
      -- disk there. Chain lazy.install({ lockfile = true }) — the same
      -- call lazy.nvim's own startup path makes when install.missing is on
      -- — which clones missing entries AT their lockfile pins, then restore
      -- (re-pin drifted checkouts) and clean (drop spec-removed dirs).
      -- lazy.sync() would be wrong here: its update stage moves every
      -- installed plugin to branch HEAD and rewrites the lockfile,
      -- discarding exactly the pins the user just declined to give up.
      -- This branch also covers headless runs, where confirm() cannot
      -- prompt and answers with the default choice.
      local rewritten = rebase_lockfile_for_origin_changes(lockfile, snapshot)
      if #rewritten > 0 then
        vim.notify(
          string.format(
            "LvimSyncCorePlugins: snapshot pins applied for plugins whose repo URL changed (%s)",
            table.concat(rewritten, ", ")
          ),
          vim.log.levels.INFO
        )
      end
      local evicted = evict_mismatched_checkouts()
      if #evicted > 0 then
        vim.notify(
          string.format(
            "LvimSyncCorePlugins: removed stale checkouts so they re-clone (%s)",
            table.concat(evicted, ", ")
          ),
          vim.log.levels.INFO
        )
      end
      vim.notify(
        "LvimSyncCorePlugins: keeping your lazy-lock.json pins; installing missing plugins and cleaning removed ones",
        vim.log.levels.INFO
      )
      install_restore_clean(lazy, lockfile, read_file(lockfile), snapshot)
      return
    end
  end

  if vim.fn.isdirectory(config_dir) == 0 then
    vim.fn.mkdir(config_dir, "p")
  end

  local wrote, write_err = write_file(lockfile, contents)
  if not wrote then
    vim.notify(string.format("LvimSyncCorePlugins: failed to write %s: %s", lockfile, write_err), vim.log.levels.ERROR)
    return
  end

  -- Install BEFORE restore: restore's runner only processes plugins that
  -- are already on disk (it re-checks-out their pins against the lockfile
  -- we just wrote), so a fresh runtime — or a spec entry shipped after the
  -- user's last sync — only lands on disk via install, which clones it AT
  -- the lockfile commit. Without this, :LvimSyncCorePlugins! on a machine
  -- missing core plugins re-pinned the installed set and silently left the
  -- missing ones absent (lazy.restore() alone never installs).
  --
  -- Origin-mismatched dirs (same lazy name, new git URL) are evicted first
  -- so install does not skip them as "already installed". The lockfile
  -- bytes are re-applied after install because lazy.install Lock.update()s
  -- from on-disk SHAs and would otherwise restore the old repo's commit.
  local evicted = evict_mismatched_checkouts()
  if #evicted > 0 then
    vim.notify(
      string.format("LvimSyncCorePlugins: removed stale checkouts so they re-clone (%s)", table.concat(evicted, ", ")),
      vim.log.levels.INFO
    )
  end
  install_restore_clean(lazy, lockfile, contents, snapshot)
end

-- :LvimSyncCorePlugins entry point: a thin adapter from the user-command
-- opts table onto the shared sync above. :LvimUpdate's post-pull pass
-- calls sync_core_plugins directly.
local function lvim_sync_core_plugins(opts)
  sync_core_plugins(opts and opts.bang or false)
end

-- Phase 3.4: a one-shot re-apply of the user-visible runtime state. The
-- sequence is:
--   (a) reload('lvim.config')         -- evict the cached module so the next
--                                        require re-evaluates it from disk;
--   (b) load_defaults()               -- reset `_G.lvim` to the deepcopied
--                                        defaults table (wipes runtime
--                                        mutations like `lvim.builtin.X.active`
--                                        a user may have flipped from the
--                                        command line);
--   (c) load_user_config()            -- re-source `~/.config/lvim/config.lua`
--                                        so any edits the user just saved
--                                        land on the freshly-reset table;
--   (d) options.setup()               -- re-apply curated `vim.opt.*` defaults
--                                        plus user `lvim.opt` overrides;
--   (e) keymaps.setup()               -- re-pin `vim.g.mapleader` and re-emit
--                                        every mapping. `vim.keymap.set`
--                                        replaces an existing mapping at the
--                                        same lhs in-place, so a second
--                                        setup() does NOT duplicate mappings;
--   (f) autocmds.setup()              -- re-arm the `lvim_core` /
--                                        `lvim_file_opened` / `lvim_dir_opened`
--                                        augroups. Each `setup()` call passes
--                                        `clear = true` to `nvim_create_augroup`,
--                                        so re-armed groups overwrite any
--                                        prior registration (no listener
--                                        leak).
-- Plugin spec re-evaluation (lazy.setup with the fresh `final_spec`) is NOT
-- in scope for Phase 3.4 — lazy.nvim caches setup state by module identity
-- and `lazy.setup({...})` is not idempotent in a way that survives a hot
-- re-run. A spec change still requires a Neovim restart, as documented in
-- the LunarVim Compatibility Contract.
local function lvim_reload()
  if type(_G.reload) == "function" then
    _G.reload("lvim.config")
  else
    package.loaded["lvim.config"] = nil
  end
  require("lvim.config").load_defaults()
  require("lvim.config.loader").load_user_config()
  require("lvim.core.options").setup()
  require("lvim.core.keymaps").setup()
  require("lvim.core.autocmds").setup()
  -- Phase 4.3: re-arm the lvim_format_on_save augroup so toggling
  -- `lvim.format_on_save` in user config and then running `:LvimReload`
  -- picks up the new setting without restarting. The format module
  -- always recreates the group with `clear = true`, so this call replaces
  -- (rather than stacks) any prior autocmd.
  require("lvim.lsp.format").setup()

  -- Reconcile nvim-lint against the freshly-loaded config.
  --
  -- ADDING a linter already worked without this: `load_user_config()` re-runs
  -- config.lua, whose `linters.setup{}` call hands the registry straight to the
  -- backend. REMOVING one did not. `load_defaults()` replaces `_G.lvim` (and
  -- with it the `_null_ls_registry`), so after a reload that deleted the
  -- registration nothing re-enters the backend at all, and the previous
  -- session's `linters_by_ft` and `lvim_nvim_lint` autocmd keep linting against
  -- a config that no longer asks for it. This call closes that gap; the module
  -- clears its own state when the registry is empty and nvim-lint is loaded,
  -- and stays out of the way entirely when it was never loaded.
  require("lvim.plugins.modules.lint").setup({})

  -- Reconcile nvim-dap the same way, but only if it is already loaded. The
  -- module reconciles its dapui listeners on each pass, so a user who turns
  -- `lvim.builtin.dap.auto_open` off and reloads actually stops the UI opening
  -- itself. Gated on `package.loaded` so a reload never drags the debugger in
  -- for a session that has not used it.
  if package.loaded["dap"] then
    require("lvim.plugins.modules.dap").setup({})
  end

  -- Re-arm the automatic language-server offer against the fresh config, for
  -- the same reason as format above: `load_defaults()` replaces `_G.lvim`, so
  -- flipping `lvim.lsp.automatic.enabled` (or the mason toggle) and reloading
  -- has to be able to remove the autocmd, not just add it. `setup()` recreates
  -- the group with `clear = true` and returns early when disabled, so this
  -- replaces rather than stacks.
  require("lvim.lsp.automatic").setup()

  vim.notify("LvimReload OK", vim.log.levels.INFO)
end

local function lvim_cache_reset()
  local cache = call_or(_G.get_cache_dir, "")
  if cache == "" then
    vim.notify("LvimCacheReset: cannot resolve cache dir", vim.log.levels.ERROR)
    return
  end
  vim.fn.delete(cache, "rf")
  vim.notify("Cache reset")
end

local function buffer_kill()
  local bufnr = vim.api.nvim_get_current_buf()
  local listed = vim.fn.getbufinfo({ buflisted = 1 })

  if #listed <= 1 then
    vim.cmd("enew")
  else
    vim.cmd("bnext")
    if vim.api.nvim_get_current_buf() == bufnr then
      vim.cmd("bprevious")
    end
  end

  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.cmd("bdelete " .. bufnr)
  end
end

local function lvim_treesitter_info()
  for _, cmd in ipairs({ "TSStatus", "TSConfigInfo", "TSInstallInfo" }) do
    if vim.fn.exists(":" .. cmd) == 2 then
      vim.cmd(cmd)
      return
    end
  end
  vim.notify("LvimTreesitterInfo: nvim-treesitter info command is unavailable", vim.log.levels.WARN)
end

-- `force = true` mirrors LunarVim's `M.load` (see the upstream
-- reference under `references/`, `lua/lvim/core/commands.lua:92`) so
-- a re-invocation of
-- `setup()` (e.g. from a future :LvimReload extension or a user calling
-- it from their own config) overwrites the existing command rather than
-- erroring on duplicate registration.
-- `:LvimExplorer` is the smart-toggle that `<leader>e` routes through.
-- A plain `:NvimTreeToggle` would close the hijack-opened full-screen
-- tree (the only window on `./bin/lvim some/dir` launches), leaving the
-- user staring at a bare `[No Name]` and confused about where the
-- explorer went. Three-state smart toggle instead:
--
--   1. Full-screen tree (the tree IS the only window) → carve off an
--      empty editor window on the OPPOSITE side from the configured
--      tree position, leaving the tree itself as a sidebar at its
--      configured width and focusing the new empty editor. Only ONE
--      window ever shows the NvimTree buffer. (Earlier iterations used
--      `rightbelow vsplit` to CLONE the tree buffer into a second
--      window, but that left two windows pointing at the same
--      NvimTree_1 buffer — and nvim-tree only tracks one of them as
--      "the tree". Cursor-reading APIs like `get_node_under_cursor`
--      use `view.get_winnr()` to look up the cursor row, so keypresses
--      in the duplicate window operated on the cursor position of the
--      ORIGINAL tracked tree window — a confusing mismatch the user
--      saw as "my interactions go to the main window." Splitting an
--      empty buffer off instead keeps nvim-tree's internal state in
--      sync with what's actually on screen.)
--   2. Multiple tree windows (legacy state, or if a user manually
--      `:vsplit`s from the tree) → close the non-focused tree
--      windows. We can't call `:NvimTreeToggle` here: nvim-tree's
--      internal "is-open" tracking gets out of sync with the actual
--      window count, and the next toggle hits `E95: Buffer with this
--      name already exists` because it tries to recreate `NvimTree_1`
--      while a sibling window still references it. Closing windows
--      directly with `nvim_win_close` sidesteps that path entirely.
--   3. One tree window + other editor windows, or no tree at all →
--      `:NvimTreeToggle`. nvim-tree's internal state is consistent
--      here, so the close/open path works without buffer conflicts.
local function lvim_explorer()
  local cur_win = vim.api.nvim_get_current_win()
  local tree_wins = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].filetype == "NvimTree" then
      table.insert(tree_wins, w)
    end
  end
  local total_wins = #vim.api.nvim_list_wins()

  if #tree_wins == 1 and total_wins == 1 then
    local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.nvimtree) or {}
    local view_opts = (builtin.setup or {}).view or {}
    local sidebar_width = view_opts.width or 30
    local tree_side = view_opts.side or "left"

    -- Open a fresh empty buffer in a new window pinned to the side
    -- opposite the tree. `:topleft vnew` / `:botright vnew` ignore
    -- `splitright`/`splitbelow` (they're positional modifiers, not
    -- relative ones) so the resulting layout is unambiguous regardless
    -- of the user's split-direction options.
    if tree_side == "right" then
      vim.cmd("topleft vnew")
    else
      vim.cmd("botright vnew")
    end

    -- Mark the staging buffer unlisted + wipe-on-hidden so it does not
    -- pollute the bufferline tabs and disappears the moment the user
    -- opens a real file from the tree (which replaces it in this
    -- window). Without `bufhidden = wipe`, the unnamed buffer lingers
    -- in the buffer list until `:bd` is run.
    local staging = vim.api.nvim_get_current_buf()
    vim.bo[staging].buflisted = false
    vim.bo[staging].bufhidden = "wipe"

    -- Pin the tree back to its configured sidebar width. The new
    -- editor window above took the remainder, but on a wide terminal
    -- the tree window's residual width is whatever Neovim defaulted
    -- the split to — explicitly resizing keeps the sidebar consistent
    -- with the dedicated `:NvimTreeToggle` path.
    --
    -- We also return focus to the tree window: the user just summoned
    -- the explorer and expects to navigate it, not to type into the
    -- empty `[No Name]` buffer that vnew created. The empty buffer is
    -- staged so a later file-open from the tree has a real editor
    -- window to land in — once nvim-tree's window picker writes the
    -- file into that window, focus follows the file naturally.
    local tree_win = tree_wins[1]
    if vim.api.nvim_win_is_valid(tree_win) then
      vim.api.nvim_win_call(tree_win, function()
        vim.cmd("vertical resize " .. tostring(sidebar_width))
      end)
      vim.api.nvim_set_current_win(tree_win)
    end
    return
  end

  if #tree_wins > 1 then
    for _, w in ipairs(tree_wins) do
      if w ~= cur_win then
        pcall(vim.api.nvim_win_close, w, false)
      end
    end
    return
  end

  vim.cmd("NvimTreeToggle")
end

function M.setup()
  vim.api.nvim_create_user_command("LvimInfo", lvim_info, { force = true })
  vim.api.nvim_create_user_command("LvimUpdate", lvim_update, { force = true })
  vim.api.nvim_create_user_command("LvimSyncCorePlugins", function(cmd_opts)
    lvim_sync_core_plugins(cmd_opts)
  end, { force = true, bang = true })
  vim.api.nvim_create_user_command("LvimReload", lvim_reload, { force = true })
  vim.api.nvim_create_user_command("LvimCacheReset", lvim_cache_reset, { force = true })
  vim.api.nvim_create_user_command("LvimExplorer", lvim_explorer, { force = true })
  vim.api.nvim_create_user_command("BufferKill", buffer_kill, { force = true })
  vim.api.nvim_create_user_command("LvimTreesitterInfo", lvim_treesitter_info, { force = true })
  vim.api.nvim_create_user_command("LvimProjectRoot", function()
    require("lvim.core.project").change_to_root()
  end, { force = true, desc = "Change directory to the current file's project root" })

  -- Clear remembered answers to the "install a language server?" prompt.
  -- With no argument it forgets every filetype; with one it forgets that
  -- filetype, which is how a user undoes a "never ask again" they regret.
  vim.api.nvim_create_user_command("LvimLspForget", function(cmd_opts)
    local ft = cmd_opts.args ~= "" and cmd_opts.args or nil
    local cleared = require("lvim.lsp.automatic").forget(ft)
    local what = ft and ("the decision for " .. ft) or "all decisions"
    if cleared then
      vim.notify("LvimLspForget: cleared " .. what, vim.log.levels.INFO)
    else
      -- An unwritable cache dir is the usual cause. Saying "cleared" when the
      -- refusal is still on disk sends the user looking in the wrong place.
      vim.notify("LvimLspForget: could not clear " .. what, vim.log.levels.ERROR)
    end
  end, {
    force = true,
    nargs = "?",
    desc = "Forget remembered language-server install decisions",
  })
end

return M

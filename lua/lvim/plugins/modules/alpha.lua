-- Phase 6: alpha-nvim (dashboard) configuration.
--
-- Per `kcl ask alpha-nvim`, alpha's canonical entry point is
-- `require('alpha').setup(config)`, where `config = { layout = {...}, opts = {...} }`.
-- The `dashboard` theme module exports a ready-made `config` plus a
-- `button(sc, txt, keybind)` helper, and a mutable `section.buttons.val`
-- array. This module reads the user-overridable
-- `lvim.builtin.alpha.config.buttons.entries` list, runs each entry through
-- `theme.button(...)`, and replaces `theme.section.buttons.val` before
-- handing `theme.config` to `alpha.setup`. Splitting button specs (plain
-- data) from the assembled output (alpha-internal element tables) lets
-- users override a single entry without restating alpha's element shape.
--
-- `mode` selects which `alpha.themes.<mode>` preset to drive. Only
-- "dashboard" is wired in Phase 6; "startify" / custom themes can be
-- enabled by users via `lvim.builtin.alpha.mode = "..."` provided their
-- chosen theme exposes the same `button` helper and `section.buttons`
-- shape.
--
-- Each button entry's action may be a function so callers can defer string
-- construction until setup-time (e.g. interpolating `_G.get_config_dir()`).
-- The function is invoked with no args and must return the string keybind
-- alpha forwards to `nvim_feedkeys`.
--
-- Auto-open on startup: alpha's canonical use case is to show the
-- dashboard on `VimEnter` when no file args are given. The lazy spec
-- uses `cmd = "Alpha"` (see `lua/lvim/plugins/spec.lua` for the
-- rationale — none of `event = "VimEnter"`, eager-load, or `cond` work
-- under our `install.missing = false` contract). To preserve the
-- startup behavior, `M.attach_autoopen()` (invoked from `lvim.start()`
-- after `plugins.load()`) registers our own `VimEnter` autocmd that
-- runs `:Alpha` when `argc() == 0`, the buffer is empty, the builtin
-- is active, and the alpha plugin is actually on disk. The install
-- check prevents the lazy "not installed" notification on a fresh
-- pre-`:LvimSyncCorePlugins` launch; the buffer-emptiness check
-- mirrors alpha's own `should_skip_alpha` logic so piped input or
-- pre-loaded buffers don't get clobbered. Per `kcl ask alpha-nvim`,
-- `:Alpha` (which calls `alpha.start(false, config)`) bypasses
-- `should_skip_alpha` and reliably renders the dashboard after
-- VimEnter has already fired.
--
-- A `pcall` guards each require in `M.setup` so the smoke harness
-- (`install.missing = false`, alpha not on disk) does not raise if
-- some other code path triggers the lazy `config = setup("alpha")`
-- callback.
local M = {}

local function build_buttons(theme, entries)
  local vals = {}
  for _, entry in ipairs(entries) do
    local sc, txt, action = entry[1], entry[2], entry[3]
    if type(action) == "function" then
      action = action()
    end
    table.insert(vals, theme.button(sc, txt, action))
  end
  return vals
end

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.alpha) or {}
  local mode = builtin.mode or "dashboard"
  local user_config = builtin.config or {}

  local ok_alpha, alpha = pcall(require, "alpha")
  if not ok_alpha then
    return
  end
  local ok_theme, theme = pcall(require, "alpha.themes." .. mode)
  if not ok_theme then
    return
  end

  local entries = (user_config.buttons and user_config.buttons.entries) or {}
  if #entries > 0 then
    theme.section.buttons.val = build_buttons(theme, entries)
  end

  alpha.setup(theme.config)
end

local function alpha_is_installed()
  local rt = _G.get_runtime_dir and _G.get_runtime_dir() or vim.fn.stdpath("data")
  local uv = vim.uv or vim.loop
  return uv.fs_stat(rt .. "/lazy/alpha") ~= nil
end

local function buffer_is_empty()
  local lines = vim.api.nvim_buf_get_lines(0, 0, 2, false)
  if #lines > 1 then
    return false
  end
  if #lines == 1 and #lines[1] > 0 then
    return false
  end
  return true
end

function M.attach_autoopen()
  vim.api.nvim_create_autocmd("VimEnter", {
    group = vim.api.nvim_create_augroup("lvim_alpha_autoopen", { clear = true }),
    pattern = "*",
    nested = true,
    callback = function()
      local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.alpha) or {}
      if builtin.active == false then
        return
      end
      if vim.fn.argc() > 0 then
        return
      end
      if not buffer_is_empty() then
        return
      end
      if not alpha_is_installed() then
        return
      end
      pcall(vim.cmd, "Alpha")
    end,
  })
end

return M

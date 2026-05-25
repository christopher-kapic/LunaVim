-- Phase 3.3: core autocmds.
--
-- `setup()` registers three augroups so that:
--   1. `lvim_core` holds the always-on niceties (highlight-on-yank,
--      split-resizing on terminal resize, opt-in trailing-whitespace strip
--      on save).
--   2. `lvim_file_opened` fires `User FileOpened` exactly once per session
--      the first time a real file is loaded — across `BufRead` /
--      `BufWinEnter` / `BufNewFile` so creating a brand-new file or
--      switching to a buffer for the first time both trigger the event,
--      not just reading an existing file. This matches the LunarVim
--      contract surface plugins depend on (see the upstream LunarVim
--      reference under `references/`,
--      `lua/lvim/core/autocmds.lua:142-155`) and lets every lazy-loaded
--      consumer keyed on `event = "User FileOpened"` drop its own
--      detection autocmd.
--   3. `lvim_dir_opened` fires `User DirOpened` the first time a buffer
--      backed by a directory is entered. Hooking `BufEnter` (rather than
--      only `VimEnter`) catches both `nvim some/dir/` startup and a later
--      `:edit some/dir/`, matching the upstream LunarVim reference's
--      `lua/lvim/core/autocmds.lua:127-140` (see `references/`).
--
-- The file/dir augroups are one-shot: their callback deletes the group on
-- the first successful fire, so the User event lands exactly once per
-- session — exactly what plugins lazy-loading on it expect. `setup()`
-- itself re-creates them on every call, so `:LvimReload` arms a fresh
-- pair for the next file/dir open. `nested = true` lets the fired User
-- event cascade into other listeners (this is how lazy.nvim's
-- `event = "User FileOpened"` triggers).
--
-- The trailing-whitespace strip is opt-in (`lvim.builtin.trailing_whitespace_strip == true`)
-- because silently rewriting buffers a user did not author surprises
-- people; the LunarVim contract surface keeps `lvim.builtin.<name>` as
-- the canonical place to flip behaviour.

local M = {}

local function highlight_yank()
  -- `vim.hl.on_yank` is the 0.11+ path; `vim.highlight.on_yank` is the
  -- pre-0.11 alias kept around as a deprecation shim. Resolve at call
  -- time so a future Neovim release that drops the legacy alias does not
  -- break setup().
  local hl = vim.hl or vim.highlight
  hl.on_yank({ higroup = "Search", timeout = 100 })
end

local function strip_trailing_whitespace_on_save()
  if not (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.trailing_whitespace_strip == true) then
    return
  end
  -- Save and restore the view so the strip does not yank the cursor or
  -- collapse a fold the user had open.
  local view = vim.fn.winsaveview()
  vim.cmd([[silent! keepjumps keeppatterns %s/\s\+$//e]])
  vim.fn.winrestview(view)
end

local function auto_resize_splits()
  -- Equalize windows on every tab, then return to the tab the user was
  -- on. `tabdo` switches tabs as a side effect; without restoring the
  -- original tabpage the user would be teleported every time they
  -- resized the terminal.
  local current_tab = vim.fn.tabpagenr()
  vim.cmd("tabdo wincmd =")
  vim.cmd("tabnext " .. current_tab)
end

local function fire_file_opened_if_real(args)
  local bufname = vim.api.nvim_buf_get_name(args.buf)
  if bufname == "" then
    return
  end
  local buftype = vim.api.nvim_get_option_value("buftype", { buf = args.buf })
  if buftype == "nofile" then
    return
  end
  if vim.fn.isdirectory(bufname) == 1 then
    return
  end
  -- Mark the originating buffer so the smoke harness can observe "yes,
  -- the listener ran for this buffer." The augroup deletion below is the
  -- load-bearing once-per-session proof for downstream plugins, but the
  -- vim.b flag is the breadcrumb a per-buffer probe can read.
  vim.b[args.buf].lvim_file_opened_fired = true
  -- One-shot: drop the augroup so this callback never runs again in this
  -- session. Plugins lazy-loaded on `User FileOpened` only need a single
  -- trigger; further file opens fall through to whatever those plugins
  -- install themselves. Delete BEFORE firing the User event so a
  -- listener that itself triggers another BufRead (e.g. a plugin that
  -- opens a sibling buffer in its setup) cannot re-enter this callback.
  pcall(vim.api.nvim_del_augroup_by_name, "lvim_file_opened")
  require("lvim.core.events").fire_file_opened()
end

local function fire_dir_opened_if_dir(args)
  local bufname = vim.api.nvim_buf_get_name(args.buf)
  if bufname == "" or vim.fn.isdirectory(bufname) ~= 1 then
    return
  end
  pcall(vim.api.nvim_del_augroup_by_name, "lvim_dir_opened")
  require("lvim.core.events").fire_dir_opened()
  -- Re-fire the originating event for the directory buffer so plugins
  -- that lazy-load on `User DirOpened` and then install their own
  -- listener for that event (nvim-tree's hijack-netrw path,
  -- project-detection helpers) get the event they would have missed by
  -- virtue of having been off the listener list at the natural firing.
  -- Mirrors the upstream LunarVim reference's
  -- `lua/lvim/core/autocmds.lua:136` re-emit verbatim (see
  -- `references/`): passing `args.event` rather than hardcoding "BufEnter"
  -- means the re-emit always routes to the same event the autocmd was
  -- registered against, even if that registration is later widened to
  -- include additional events (e.g. WinEnter for a future hijack path).
  vim.api.nvim_exec_autocmds(args.event, { buffer = args.buf, data = args.data })
end

-- Register user-supplied autocmds from `lvim.autocommands`. Each entry is a
-- 2-tuple `{ events, opts }` where `events` is a string or list-of-strings
-- and `opts` is forwarded verbatim to `nvim_create_autocmd` (so it carries
-- `desc`, `pattern`, `callback`/`command`, etc.). Mirrors the shape used by
-- the upstream LunarVim reference's `lua/lvim/core/autocmds.lua:267-279`
-- (see `references/`).
--
-- All user autocmds land in a dedicated `lvim_user_autocmds` augroup so a
-- re-run (via `:LvimReload`) can clear-and-redefine without leaking
-- duplicate listeners. Per-entry `opts.group` overrides are still honored,
-- but the default-augroup path matches what users coming from CKLunarVim
-- expect (their listeners survive a reload because the group is cleared
-- before re-armament).
function M.define_autocmds(definitions)
  if type(definitions) ~= "table" then
    return
  end
  local default_group = vim.api.nvim_create_augroup("lvim_user_autocmds", { clear = true })
  for _, entry in ipairs(definitions) do
    local event = entry[1]
    local opts = entry[2]
    if type(opts) == "table" then
      -- Respect a per-entry group override (creating it if it does not
      -- exist yet, matching the upstream reference's behavior). Otherwise
      -- fall through to the shared `lvim_user_autocmds` group above.
      if type(opts.group) == "string" and opts.group ~= "" then
        local exists = pcall(vim.api.nvim_get_autocmds, { group = opts.group })
        if not exists then
          vim.api.nvim_create_augroup(opts.group, {})
        end
      else
        opts = vim.tbl_extend("keep", { group = default_group }, opts)
      end
      vim.api.nvim_create_autocmd(event, opts)
    end
  end
end

function M.setup()
  local core = vim.api.nvim_create_augroup("lvim_core", { clear = true })

  vim.api.nvim_create_autocmd("TextYankPost", {
    group = core,
    desc = "Highlight text on yank",
    callback = highlight_yank,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = core,
    desc = "Auto-resize splits when the terminal is resized",
    callback = auto_resize_splits,
  })

  vim.api.nvim_create_autocmd("BufWritePre", {
    group = core,
    desc = "Strip trailing whitespace if lvim.builtin.trailing_whitespace_strip == true",
    callback = strip_trailing_whitespace_on_save,
  })

  local file_group = vim.api.nvim_create_augroup("lvim_file_opened", { clear = true })
  vim.api.nvim_create_autocmd({ "BufRead", "BufWinEnter", "BufNewFile" }, {
    group = file_group,
    nested = true,
    desc = "Fire `User FileOpened` once per session on first real-file load",
    callback = fire_file_opened_if_real,
  })

  local dir_group = vim.api.nvim_create_augroup("lvim_dir_opened", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = dir_group,
    nested = true,
    desc = "Fire `User DirOpened` once per session on first directory buffer enter",
    callback = fire_dir_opened_if_dir,
  })

  -- User-supplied autocmds from `lvim.autocommands`. Reads from `_G.lvim`
  -- at setup time so values mutated by `config.lua` (which runs before this
  -- in the boot sequence) are picked up. Lives inside `setup()` (rather
  -- than at a separate boot-sequence call site) so `:LvimReload`'s
  -- `autocmds.setup()` re-arm also re-defines the user augroup with
  -- `clear = true` — no duplicate listeners across reloads.
  if _G.lvim and _G.lvim.autocommands then
    M.define_autocmds(_G.lvim.autocommands)
  end
end

return M

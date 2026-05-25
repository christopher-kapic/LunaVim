-- Phase 3.3: stable event layer for plugins to lazy-load on.
--
-- LunarVim's contract surfaces two pseudo-events for plugins to hook into:
--   * `User FileOpened`  — a real file (not a directory, not an empty
--                          scratch buffer) just finished loading.
--   * `User DirOpened`   — nvim was launched with a directory argument.
-- Plugins (e.g. nvim-tree, gitsigns) can use these as `event` triggers in
-- their lazy specs instead of every plugin re-implementing the detection
-- logic in its own autocmd. Centralising the firing here lets us change
-- the detection rule once and have every consumer pick it up.
--
-- These helpers exist as a separate module so callers can fire the event
-- programmatically without having to know about `lvim.core.autocmds`.

local M = {}

function M.fire_file_opened()
  vim.api.nvim_exec_autocmds("User", { pattern = "FileOpened" })
end

function M.fire_dir_opened()
  vim.api.nvim_exec_autocmds("User", { pattern = "DirOpened" })
end

return M

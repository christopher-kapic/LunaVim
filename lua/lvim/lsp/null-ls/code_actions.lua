-- Deprecation stub for LunarVim's `lvim.lsp.null-ls.code_actions`.
--
-- There is no backend behind this module and there will not be one. null-ls's
-- code-action sources were largely a workaround for language servers that did
-- not implement `textDocument/codeAction`; the servers LunaVim installs through
-- mason (eslint, ts_ls, gopls, ...) implement it natively, so those actions
-- already reach the user through `vim.lsp.buf.code_action()` on `<leader>la`.
--
-- The module exists purely so a migrated LunarVim config keeps loading. Deleting
-- it outright is tempting -- it does nothing -- but `config.lua` is executed as
-- a single chunk, so a `module not found` error on this line aborts every line
-- AFTER it too. The user does not get a clean failure; they get a silently
-- half-applied config, with the error naming a module rather than the setting
-- that quietly never took effect.
--
-- So: accept the call, do nothing with it, and say so once. Registrations are
-- deliberately NOT recorded. A registry nothing consumes would imply a backend
-- that is coming, and `list_registered` returning entries that never run is a
-- worse lie than returning nothing.

local M = {}

local warned = false

local function warn_once()
  if warned then
    return
  end
  warned = true
  vim.schedule(function()
    vim.notify(
      "lvim.lsp.null-ls.code_actions is a no-op in LunaVim. Modern language servers provide "
        .. "code actions directly -- use `<leader>la` (vim.lsp.buf.code_action). You can delete "
        .. "the code_actions.setup{} call from your config.",
      vim.log.levels.WARN
    )
  end)
end

function M.setup(_)
  warn_once()
end

function M.list_registered(_)
  return {}
end

function M.list_supported(_)
  return {}
end

return M

-- Drop-in compatibility shim for LunarVim's `lvim.lsp.null-ls.*` module tree.
--
-- null-ls.nvim is archived. The modern Neovim formatting/linting/code-action
-- stack is split across multiple plugins:
--   * formatting   → stevearc/conform.nvim   (wired by `formatters.lua`)
--   * linting      → mfussenegger/nvim-lint  (wired by `linters.lua`)
--   * code actions → per-LSP-server (eslint LSP, typescript LSP, ...)
--
-- The submodules under this directory translate the LunarVim API surface
-- (`setup(list)`, `list_registered(ft)`, `list_supported(ft)`) into calls
-- against those modern backends.
--
-- `code_actions` is a deprecation stub with no backend. null-ls's code-action
-- sources were largely a workaround for servers that did not implement
-- `textDocument/codeAction`; the servers LunaVim ships through mason
-- (eslint, ts_ls, gopls, ...) implement it natively, so those actions already
-- reach the user via `vim.lsp.buf.code_action()` on `<leader>la`. The module is
-- kept only so a migrated config keeps loading -- config.lua runs as one chunk,
-- so a module-not-found error there silently skips every later line as well.
--
-- This module's own `setup` is intentionally a no-op so a user who does
-- `require("lvim.lsp.null-ls").setup{}` (the old umbrella entry point)
-- does not crash; the per-kind setup happens via the submodules.

local M = {}

function M.setup(_)
  -- Intentionally empty. LunarVim's original `null-ls.init.setup` called
  -- `null_ls.setup(...)` with merged options; conform doesn't have a
  -- corresponding umbrella entry point and the user's registrations flow
  -- through the per-kind submodules' `setup(list)` calls instead.
end

return M

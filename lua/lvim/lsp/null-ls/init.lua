-- Drop-in compatibility shim for LunarVim's `lvim.lsp.null-ls.*` module tree.
--
-- null-ls.nvim is archived. The modern Neovim formatting/linting/code-action
-- stack is split across multiple plugins:
--   * formatting   → stevearc/conform.nvim  (wired by `formatters.lua`)
--   * linting      → mfussenegger/nvim-lint  (stubbed by `linters.lua`)
--   * code actions → per-LSP-server (eslint LSP, typescript LSP, ...)
--                    or dedicated plugins (stubbed by `code_actions.lua`)
--
-- The submodules under this directory translate the LunarVim API surface
-- (`setup(list)`, `list_registered(ft)`, `list_supported(ft)`) into calls
-- against those modern backends. Only the `formatters` shim is fully wired
-- — the user's CKLunarVim config doesn't register linters or code actions,
-- and conform is the only formatter backend LunaVim needs to ship to close
-- the immediate compat gap. The other two submodules emit a one-shot
-- vim.notify and return empty lists so a config that calls them at least
-- does not crash.
--
-- This module's own `setup` is intentionally a no-op so a user who does
-- `require("lvim.lsp.null-ls").setup{}` (the old umbrella entry point)
-- does not crash; the per-kind setup happens via the three submodules.

local M = {}

function M.setup(_)
  -- Intentionally empty. LunarVim's original `null-ls.init.setup` called
  -- `null_ls.setup(...)` with merged options; conform doesn't have a
  -- corresponding umbrella entry point and the user's registrations flow
  -- through the per-kind submodules' `setup(list)` calls instead.
end

return M

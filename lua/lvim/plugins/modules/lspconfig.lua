-- Phase 4.1 hook: when lazy.nvim loads nvim-lspconfig (because something
-- `require`'d it), bootstrap the full LSP stack via `lvim.lsp.setup()`. The
-- orchestrator is idempotent (a `did_setup` flag at module scope), so a
-- caller that already ran `lvim.lsp.setup()` from `lvim.start()` does not
-- re-run mason/mason-lspconfig setup here.
local M = {}

function M.setup(_)
  require("lvim.lsp").setup()
end

return M

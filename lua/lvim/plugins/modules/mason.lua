-- Phase 4.1: mason's setup runs inside `lvim.lsp.setup()` so the
-- mason → mason-lspconfig → lspconfig order is enforced from a single
-- orchestrator. This module stays a no-op so lazy.nvim's `config(_, opts)`
-- callback for mason still has a target to dispatch to.
local M = {}

function M.setup(_) end

return M

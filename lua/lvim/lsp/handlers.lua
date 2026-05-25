-- Phase 4.2: LSP capabilities + on_attach builders shared by the orchestrator.
--
-- `make_capabilities()` returns the protocol baseline extended with blink.cmp's
-- `get_lsp_capabilities()` when that module is loadable, falling back to the
-- plain `vim.lsp.protocol.make_client_capabilities()` table otherwise. blink's
-- helper layers in completionItem snippet/resolve support and the dynamic-
-- registration flags it needs (kcl-confirmed against blink.cmp's source);
-- composing them through `vim.tbl_deep_extend` rather than blindly assigning
-- preserves any flags the protocol baseline added in newer Neovim releases.
--
-- `make_on_attach()` returns a callback that registers buffer-local
-- LSP keymaps per the step contract: `gd`, `gr`, `K`, `<leader>la`, `<leader>lr`.
-- Each map is scoped to `bufnr` (the buffer the client attached to) so a buffer
-- without an LSP attached keeps its default mappings — and so detaching the
-- client cleans the maps up via buffer unload.
--
-- After the keymaps, the on_attach also attaches nvim-navic to the client
-- when both (a) the LSP server reports `documentSymbolProvider` (navic is
-- LSP-symbol-driven; without provider support `get_location()` would return
-- an empty string forever) and (b) `lvim.builtin.breadcrumbs.active` is not
-- explicitly false. The `require('nvim-navic')` call here is what triggers
-- lazy.nvim to load the spec (which is `lazy = true`), so a server attach is
-- the canonical entry point — no `event = "LspAttach"` needed in the spec.
-- A `pcall` guards the require so the smoke harness (install.missing = false,
-- navic not on disk) does not raise.

local M = {}

function M.make_capabilities()
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  local ok, blink = pcall(require, "blink.cmp")
  if ok and type(blink.get_lsp_capabilities) == "function" then
    capabilities = vim.tbl_deep_extend("force", capabilities, blink.get_lsp_capabilities() or {})
  end
  return capabilities
end

function M.make_on_attach()
  return function(client, bufnr)
    local function map(mode, lhs, rhs, desc)
      vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, noremap = true, silent = true, desc = desc })
    end
    map("n", "gd", vim.lsp.buf.definition, "Goto definition")
    map("n", "gr", vim.lsp.buf.references, "Goto references")
    map("n", "K", vim.lsp.buf.hover, "Hover")
    map("n", "<leader>la", vim.lsp.buf.code_action, "Code action")
    map("n", "<leader>lr", vim.lsp.buf.rename, "Rename")

    local breadcrumbs = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.breadcrumbs) or {}
    if
      breadcrumbs.active ~= false
      and client
      and client.server_capabilities
      and client.server_capabilities.documentSymbolProvider
    then
      local ok_navic, navic = pcall(require, "nvim-navic")
      if ok_navic then
        navic.attach(client, bufnr)
      end
    end
  end
end

return M

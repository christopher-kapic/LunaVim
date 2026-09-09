-- RRethy/vim-illuminate: highlight other occurrences of the symbol under the
-- cursor.
--
-- `lvim.builtin.illuminate.options` is forwarded to `illuminate.configure`.
-- Note the entry point is `configure`, not `setup` -- illuminate is one of the
-- few plugins that does not follow the `setup()` convention, and calling
-- `setup` on it silently does nothing.
--
-- Providers are ordered `lsp` -> `treesitter` -> `regex`: illuminate tries each
-- in turn and uses the first that yields references. LSP is most accurate
-- (it knows scope and shadowing), treesitter is a good structural fallback, and
-- regex is the last resort that works in any buffer with no language support at
-- all.

local M = {}

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.illuminate) or {}
  local opts = vim.deepcopy(builtin.options or {})

  local ok, illuminate = pcall(require, "illuminate")
  if not ok then
    return
  end

  illuminate.configure(opts)
end

return M

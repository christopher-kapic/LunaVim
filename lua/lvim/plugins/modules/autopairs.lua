-- blink.pairs wiring.
--
-- The whole `lvim.builtin.autopairs` subtree (minus `active`) is forwarded to
-- `require("blink.pairs").setup(opts)`. blink.pairs handles insert-mode
-- auto-closing of quotes, brackets, and parentheses; completion-time brackets
-- (`foo` → `foo()`) are owned by blink.cmp's
-- `completion.accept.auto_brackets` (see `lvim.builtin.cmp`).
--
-- LunarVim exposed this surface as `lvim.builtin.autopairs`; LunaVim keeps that
-- name for compatibility even though the implementation is blink.pairs rather
-- than windwp/nvim-autopairs.
local M = {}

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.autopairs) or {}
  local opts = vim.deepcopy(builtin)
  opts.active = nil

  local ok, blink_pairs = pcall(require, "blink.pairs")
  if not ok then
    return
  end

  blink_pairs.setup(opts)
end

return M

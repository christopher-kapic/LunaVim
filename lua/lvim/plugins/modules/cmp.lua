-- blink.cmp wiring.
--
-- The whole `lvim.builtin.cmp` subtree (minus `active`) is forwarded to
-- `require("blink.cmp").setup(opts)`. blink's option table is already close to
-- the shape LunarVim users expect -- `keymap`, `sources`, `completion`,
-- `signature` -- so we pass it through rather than inventing a translation
-- layer, and let `lvim/config/defaults.lua` carry the documented defaults.
--
-- Note on capabilities: blink advertises extra client capabilities (snippet
-- support, resolve support, insert-replace edits) that a server must be told
-- about at attach time. That hand-off lives in `lvim/lsp/handlers.lua`
-- `make_capabilities()`, which folds `blink.get_lsp_capabilities()` into the
-- table passed to every `vim.lsp.config(name, ...)` call. It is deliberately
-- not done here: `lvim.lsp.setup()` runs from `lvim.start()` before the user
-- has entered insert mode, so this module's `config` callback has usually not
-- fired yet at that point. `make_capabilities()` pcall-requires blink
-- directly, which trips lazy.nvim's require-interceptor and loads it on
-- demand, so the capabilities are correct regardless of load order.

local M = {}

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.cmp) or {}
  local opts = vim.deepcopy(builtin)
  opts.active = nil

  local ok, blink = pcall(require, "blink.cmp")
  if not ok then
    return
  end

  blink.setup(opts)
end

return M

-- Phase 6: toggleterm.nvim configuration.
--
-- Reads the live `lvim.builtin.terminal` subtree (so user overrides applied
-- in config.lua before plugin load flow through), strips the `active` toggle
-- (it's the spec gate's input, not a toggleterm option), and forwards the
-- rest to `require('toggleterm').setup(opts)`. The setup shape used in
-- defaults.lua follows the kcl-confirmed canonical surface: top-level
-- `size`, `open_mapping`, `direction`, `shading_factor`, etc.
--
-- `toggle_lazygit()` exposes a cached lazygit float (the canonical
-- toggleterm recipe). The Terminal instance is allocated on first call and
-- reused thereafter so repeated toggles share the same buffer/process.
-- `<leader>gg` (registered in `lvim/core/keymaps.lua`, only when lazygit is
-- on $PATH) routes here; lazy.nvim's require-interceptor loads toggleterm
-- on the first `require('toggleterm.terminal')` so we don't need an
-- explicit lazy trigger for the lazygit path.
--
-- A `pcall` guards each require so the smoke harness (`install.missing = false`,
-- toggleterm not on disk) does not raise when the lazy `config = setup("terminal")`
-- callback fires from the `cmd = "ToggleTerm"` trigger, or when
-- `toggle_lazygit()` is invoked before toggleterm is available.
local M = {}

local lazygit_term

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.terminal) or {}

  local opts = vim.deepcopy(builtin)
  opts.active = nil

  local ok, toggleterm = pcall(require, "toggleterm")
  if not ok then
    return
  end
  toggleterm.setup(opts)
end

function M.toggle_lazygit()
  local ok, terminal_mod = pcall(require, "toggleterm.terminal")
  if not ok then
    return
  end
  if not lazygit_term then
    lazygit_term = terminal_mod.Terminal:new({
      cmd = "lazygit",
      dir = "git_dir",
      direction = "float",
      hidden = true,
      float_opts = { border = "double" },
      on_open = function(term)
        vim.cmd("startinsert!")
        vim.api.nvim_buf_set_keymap(
          term.bufnr,
          "n",
          "q",
          "<cmd>close<CR>",
          { noremap = true, silent = true }
        )
      end,
    })
  end
  lazygit_term:toggle()
end

return M

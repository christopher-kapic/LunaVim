-- Phase 3.2: core keymaps.
--
-- `setup()` pins `vim.g.mapleader` / `vim.g.maplocalleader` from
-- `lvim.leader` *before* defining any mapping, then applies LunarVim's
-- canonical mapping set, then walks `lvim.keys.<mode>` and applies user
-- overrides on top. The leader must be set first because Neovim resolves
-- `<leader>` at the moment a mapping is created — if we set the global
-- after defining `<leader>w`, the map would resolve to whatever the global
-- happened to be before our assignment (typically `\`).
--
-- The literal token `"space"` is treated as the space character to match
-- the LunarVim contract — `scripts/install.sh` writes
-- `lvim.leader = "space"` into the starter config, and the upstream
-- LunarVim reference under `references/` (its `config/init.lua:76`
-- and `core/which-key.lua:210-211`) applies the same
-- translation. Without it, `<leader>` would resolve to the literal five
-- characters `s`, `p`, `a`, `c`, `e`, silently breaking every leader map.
--
-- User overrides are processed AFTER defaults so a user value with the same
-- LHS wins. Each entry in `lvim.keys.<mode>` may be:
--   * a string  → treated as the rhs (default opts: noremap + silent)
--   * a table   → `{ rhs, opts }` (opts merged on top of the defaults)
--   * `false`   → delete the default mapping at that LHS
-- This mirrors the LunarVim contract documented in the upstream
-- reference's `lua/lvim/keymappings.lua` (see `references/`).

local M = {}

local mode_adapters = {
  insert_mode = "i",
  normal_mode = "n",
  term_mode = "t",
  visual_mode = "v",
  visual_block_mode = "x",
  command_mode = "c",
  operator_pending_mode = "o",
}

local generic_opts = { noremap = true, silent = true }

local function map(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", generic_opts, { desc = desc }))
end

local function resolve_leader(value)
  if value == "space" then
    return " "
  end
  return value
end

function M.setup()
  local leader = resolve_leader(_G.lvim.leader)
  vim.g.mapleader = leader
  vim.g.maplocalleader = leader

  -- Window navigation
  map("n", "<C-h>", "<C-w>h", "Window left")
  map("n", "<C-j>", "<C-w>j", "Window down")
  map("n", "<C-k>", "<C-w>k", "Window up")
  map("n", "<C-l>", "<C-w>l", "Window right")

  -- Buffer cycling
  map("n", "<S-l>", "<cmd>bnext<CR>", "Next buffer")
  map("n", "<S-h>", "<cmd>bprevious<CR>", "Previous buffer")

  -- Leader essentials
  map("n", "<leader>w", "<cmd>w<CR>", "Save")
  map("n", "<leader>q", "<cmd>confirm q<CR>", "Quit")
  map("n", "<leader>h", "<cmd>nohlsearch<CR>", "No highlight")

  -- Visual-mode indent that keeps the selection
  map("v", "<", "<gv", "Indent left")
  map("v", ">", ">gv", "Indent right")

  -- Move selected lines up/down
  map("x", "J", ":m '>+1<CR>gv=gv", "Move selection down")
  map("x", "K", ":m '<-2<CR>gv=gv", "Move selection up")

  -- Telescope `<leader>f` group. Uses the `<cmd>Telescope ...<CR>` form so the
  -- mappings exist before telescope's plugin code loads — pressing the key
  -- triggers lazy.nvim's `cmd = "Telescope"` stub which loads the plugin and
  -- forwards the picker invocation.
  map("n", "<leader>ff", "<cmd>Telescope find_files<CR>", "Find files")
  map("n", "<leader>fg", "<cmd>Telescope live_grep<CR>", "Live grep")
  map("n", "<leader>fb", "<cmd>Telescope buffers<CR>", "Buffers")
  map("n", "<leader>fh", "<cmd>Telescope help_tags<CR>", "Help tags")

  -- nvim-tree toggle. Routes through `:LvimExplorer` rather than
  -- `:NvimTreeToggle` directly so the hijack-opened full-screen tree
  -- (the only window on `./bin/lvim some/dir`) does the right thing on
  -- first press — see `lvim/core/commands.lua` `lvim_explorer` for the
  -- two-state smart-toggle. `:LvimExplorer` still calls
  -- `:NvimTreeToggle` for the "open / close the side panel" case, so
  -- lazy.nvim's `cmd = "NvimTreeToggle"` trigger still loads nvim-tree
  -- on first press.
  map("n", "<leader>e", "<cmd>LvimExplorer<CR>", "Toggle file explorer")

  -- Gitsigns `<leader>g` group. Uses the `<cmd>Gitsigns <subcmd><CR>` form so
  -- the mappings exist before gitsigns' plugin code loads — pressing one
  -- triggers the `event = "BufReadPre"` rule (the first BufRead loads
  -- gitsigns and registers the `:Gitsigns` user command), then forwards the
  -- subcommand. `nav_hunk next`/`nav_hunk prev` is the non-deprecated form
  -- (`next_hunk`/`prev_hunk` still work but are marked deprecated upstream).
  map("n", "<leader>gj", "<cmd>Gitsigns nav_hunk next<CR>", "Next hunk")
  map("n", "<leader>gk", "<cmd>Gitsigns nav_hunk prev<CR>", "Previous hunk")
  map("n", "<leader>gp", "<cmd>Gitsigns preview_hunk<CR>", "Preview hunk")
  map("n", "<leader>gb", "<cmd>Gitsigns blame_line<CR>", "Blame line")

  -- Lazygit float on `<leader>gg`, only registered when lazygit is on $PATH so
  -- users without it do not see a phantom mapping. The rhs requires the
  -- terminal module, whose `toggle_lazygit` requires `toggleterm.terminal`;
  -- lazy.nvim's require-interceptor loads toggleterm on that first require so
  -- no explicit `cmd`/`keys` trigger is needed for this path.
  if vim.fn.executable("lazygit") == 1 then
    map("n", "<leader>gg", "<cmd>lua require('lvim.plugins.modules.terminal').toggle_lazygit()<CR>", "Lazygit")
  end

  local user_keys = (_G.lvim and _G.lvim.keys) or {}
  for mode_name, mappings in pairs(user_keys) do
    local mode = mode_adapters[mode_name] or mode_name
    for lhs, rhs in pairs(mappings) do
      if rhs == false then
        pcall(vim.api.nvim_del_keymap, mode, lhs)
      elseif type(rhs) == "table" then
        local opts = vim.tbl_extend("force", generic_opts, rhs[2] or {})
        vim.keymap.set(mode, lhs, rhs[1], opts)
      else
        vim.keymap.set(mode, lhs, rhs, generic_opts)
      end
    end
  end
end

return M

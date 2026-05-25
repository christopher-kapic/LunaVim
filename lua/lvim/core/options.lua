-- Phase 3.1: editor options preserving LunarVim's feel.
--
-- `setup()` applies a curated set of `vim.opt.*` defaults, then walks
-- `_G.lvim.opt` (set either from `defaults.lua` or by the user's config) and
-- applies overrides on top. This two-step shape lets users override any
-- default without having to redefine the entire table:
--
--   lvim.opt = { wrap = true, scrolloff = 0 }
--
-- The undodir is created on demand and `undodir` is assigned *before*
-- `undofile` so the persistent-undo flag picks up the right directory the
-- first time it matters; relying on `pairs()` order across a Lua table is
-- not specified by the language.

local M = {}

local function ensure_dir(path)
  local uv = vim.uv or vim.loop
  if not uv.fs_stat(path) then
    vim.fn.mkdir(path, "p")
  end
end

function M.setup()
  local undodir = _G.get_cache_dir() .. "/undo"
  ensure_dir(undodir)

  -- Pin undodir/undofile order: undodir first, then undofile, so the very
  -- first persistent-undo write lands under <cache>/undo rather than
  -- whatever Neovim's pre-startup default was.
  vim.opt.undodir = undodir
  vim.opt.undofile = true

  local defaults = {
    -- buffers / files
    backup = false,
    writebackup = false,
    swapfile = false,
    hidden = true,
    fileencoding = "utf-8",
    -- UI
    number = true,
    relativenumber = true,
    numberwidth = 4,
    signcolumn = "yes",
    cursorline = true,
    termguicolors = true,
    showmode = false,
    cmdheight = 1,
    pumheight = 10,
    laststatus = 3,
    title = true,
    conceallevel = 0,
    -- input
    mouse = "a",
    clipboard = "unnamedplus",
    -- splits
    splitright = true,
    splitbelow = true,
    -- scrolling
    scrolloff = 8,
    sidescrolloff = 8,
    -- indentation
    expandtab = true,
    tabstop = 2,
    shiftwidth = 2,
    softtabstop = 2,
    smartindent = true,
    -- search
    ignorecase = true,
    smartcase = true,
    hlsearch = true,
    -- completion / responsiveness
    completeopt = { "menu", "menuone", "noselect" },
    updatetime = 300,
    -- `timeoutlen` is the window (ms) Neovim waits for the next key in a
    -- mapping sequence. 300ms is aggressive: a user typing `<leader>e`
    -- (space + e) at a normal pace can exceed it, after which Neovim
    -- drops the leader and fires `e` standalone on whatever buffer is
    -- focused — alpha's button, nvim-tree's `e`, etc. The upstream
    -- reference (`references/CKLunarVim/lua/lvim/config/settings.lua:33`)
    -- uses 1000ms, which is Neovim's own default; matching it keeps the
    -- `<leader>X` family reliably reachable without speed-typing.
    timeoutlen = 1000,
    -- wrap
    wrap = false,
  }

  for k, v in pairs(defaults) do
    vim.opt[k] = v
  end

  local user_opt = (_G.lvim and _G.lvim.opt) or {}
  for k, v in pairs(user_opt) do
    vim.opt[k] = v
  end
end

return M

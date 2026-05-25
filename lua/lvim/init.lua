local M = {}

function M.start()
  require("lvim.bootstrap").init()
  local config = require("lvim.config")
  config.load_defaults()

  -- Seed `lvim.builtin.theme` from the theme module's own defaults BEFORE
  -- user config runs, so a user can override individual per-theme options
  -- (e.g. `lvim.builtin.theme.tokyonight.options.style = "storm"`) in their
  -- `config.lua` and have those overrides land on top of LunaVim's
  -- defaults. The actual `:colorscheme` call happens post-lazy in `M.setup()`
  -- because the theme plugin must be on rtp first.
  require("lvim.core.theme").config()

  -- Wire the reload helpers as globals after defaults have populated `_G.lvim`
  -- so user config (next, via `load_user_config()`) and any subsequently-
  -- loaded module can call them without an explicit `require`.
  local reload = require("lvim.utils.reload")
  _G.require_safe = reload.require_safe
  _G.require_clean = reload.require_clean
  _G.reload = reload.reload

  config.load_user_config()

  -- Apply editor options BEFORE plugin load: many plugins read `vim.opt.*`
  -- during their `setup()` (lualine/laststatus, bufferline/showtabline,
  -- indent-blankline/tabstop+shiftwidth, colorscheme/termguicolors). Eager
  -- plugins run their setup inside `lazy.setup({...})`, so options must be
  -- in place by then. User overrides via `lvim.opt` are picked up here
  -- because `load_user_config()` has already populated `_G.lvim.opt`.
  require("lvim.core.options").setup()

  -- Keymaps must be installed BEFORE plugin load so `vim.g.mapleader` is
  -- pinned by the time lazy.nvim (and any other plugin that captures the
  -- leader at setup time) reads it. Neovim resolves `<leader>` when a
  -- mapping is created, so the global also has to be in place before our
  -- own leader-prefixed defaults register.
  require("lvim.core.keymaps").setup()

  -- Autocmds register the `User FileOpened`/`User DirOpened` event layer
  -- BEFORE plugin load so any plugin spec can use those events as
  -- lazy-load triggers (`event = "User FileOpened"`) and have the
  -- listener queue land in lazy.nvim's spec table. They also bring in
  -- the highlight-on-yank / auto-resize niceties and the opt-in
  -- trailing-whitespace strip.
  require("lvim.core.autocmds").setup()

  -- Plugin bootstrap runs AFTER user config so users can mutate
  -- `lvim.plugins` and `lvim.builtin.<name>.active` (the inputs that
  -- `lvim.plugins.final_spec()` reads) before lazy sees the spec, and so
  -- `lvim.lazy.opts` is honored at lazy.setup time.
  local plugins = require("lvim.core.plugins")
  plugins.bootstrap()
  plugins.load()

  -- Apply the colorscheme AFTER lazy.setup so the matching theme plugin
  -- (tokyonight.nvim / lunar.nvim) is on rtp — the spec entries for those
  -- two are gated with `lazy = ...` such that the configured colorscheme's
  -- plugin loads eagerly while the other stays deferred. We also need to
  -- land this BEFORE lualine/bufferline's `event = "VeryLazy"` callbacks
  -- fire so their `theme = "auto"` resolution sees the active colorscheme's
  -- highlight groups rather than Neovim's default theme.
  require("lvim.core.theme").setup()

  -- Phase 6 (alpha): register the VimEnter autocmd that triggers `:Alpha`
  -- on a no-arg launch. Must register before VimEnter fires (i.e. before
  -- `lvim.start()` returns), so it lives here rather than inside alpha's
  -- lazy `config` callback — that callback only runs when `:Alpha` is
  -- invoked, by which point VimEnter would have already passed. The
  -- autocmd is gated on `lvim.builtin.alpha.active` and on alpha actually
  -- being on disk, so disabling the builtin or a fresh launch before
  -- `:LvimSyncCorePlugins` are both silent.
  require("lvim.plugins.modules.alpha").attach_autoopen()

  -- Phase 4.1: orchestrate the LSP stack (mason → mason-lspconfig →
  -- lspconfig). Runs AFTER plugin load so lazy.nvim has the spec registered
  -- and `require('mason')` inside `lvim.lsp.setup()` resolves through lazy's
  -- loader (with `pcall` guards covering the smoke harness case where the
  -- plugin sources are not on disk). Idempotent — the lspconfig plugin's
  -- `config` callback also calls `lvim.lsp.setup()` and is short-circuited
  -- by an internal `did_setup` flag.
  require("lvim.lsp").setup()

  -- Phase 4.3: register the BufWritePre format-on-save autocmd from
  -- `lvim.format_on_save`. Kept outside `lvim.lsp.setup()` because that
  -- entry point is guarded by an internal `did_setup` flag (so the
  -- mason/lspconfig orchestration runs exactly once per session); the
  -- format setup must re-run on `:LvimReload` to pick up user-config edits,
  -- so it lives as its own idempotent (clear-on-each-call) call.
  require("lvim.lsp.format").setup()

  -- Register :LvimInfo/:LvimUpdate/:LvimSyncCorePlugins/:LvimReload/
  -- :LvimCacheReset AFTER plugin load so :LvimInfo reads an accurate plugin
  -- count from `lazy.stats()` and :LvimSyncCorePlugins can resolve `lazy`
  -- on first invocation.
  require("lvim.core.commands").setup()

  vim.g.lunavim_loaded = true
  if #vim.api.nvim_list_uis() > 0 then
    vim.notify("lvim loaded", vim.log.levels.INFO)
  end
end

return M

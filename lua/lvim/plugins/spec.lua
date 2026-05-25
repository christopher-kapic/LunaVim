-- Core LunaVim plugin spec for lazy.nvim.
--
-- Each gated entry exposes `enabled = function() return lvim.builtin.<key>.active end`
-- so a user can flip a builtin off in their config and have lazy drop the spec
-- entirely (it never enters Config.plugins and never installs). The legacy
-- `final_spec()` filter in `lua/lvim/plugins/init.lua` matches on `spec.name`,
-- which we set to the same builtin key for all entries except mason-lspconfig
-- (see below). For those identically-keyed entries both filters agree on the
-- same toggle, so the spec is dropped consistently whether it reaches lazy
-- directly or through `final_spec()`.
--
-- The one intentional exception is `mason-lspconfig`: its `spec.name` is
-- `"mason-lspconfig"` (so users can still flip it independently via
-- `lvim.builtin["mason-lspconfig"].active = false`) but its `enabled` gate
-- reads `lvim.builtin.mason.active` so that disabling mason also drops the
-- bridge plugin (which would otherwise error at runtime against an
-- uninitialised mason). Smoke check `check_phase_22_plugin_count` pins both
-- directions of this contract.
--
-- `gate()` is intentionally defensive: a missing `lvim.builtin.<key>` table is
-- treated as "enabled". That keeps the spec usable before defaults run (e.g.
-- under harness re-requires) and tolerates future builtins added here but not
-- yet listed in defaults.lua.
--
-- Each gated entry pairs `opts = {}` with a `config` one-liner that hands the
-- plugin off to `lua/lvim/plugins/modules/<name>.lua`. Those modules ship as
-- no-op stubs in this step; later phases fill in their `setup(opts)` bodies
-- per the plan's per-phase split (Phase 4 fills lspconfig/mason/
-- mason-lspconfig/lazydev, Phase 5 fills treesitter and seeds mini.comment,
-- Phase 6 finalises the UI modules including the comment toggle). We keep the
-- `opts = {}` placeholder so user-side `lvim.lazy.opts`-merging and per-module
-- defaults set in later phases can flow through `config(_, opts)` unchanged.

local function gate(key)
  return function()
    local builtin = (_G.lvim and _G.lvim.builtin) or {}
    local toggle = builtin[key]
    if type(toggle) == "table" and toggle.active == false then
      return false
    end
    return true
  end
end

local function setup(mod)
  return function(_, opts)
    require("lvim.plugins.modules." .. mod).setup(opts)
  end
end

return {
  -- The plugin manager. Listed for visibility in `:Lazy` and so it sits under
  -- the LunaVim-managed runtime dir alongside everything else. Not gated.
  { "folke/lazy.nvim" },

  -- Bundled colorschemes. Both ship in the core spec so the user's
  -- `lvim.colorscheme` resolves out of the box for either default ("lunar")
  -- or the LunarVim-traditional "tokyonight". Lazy-loading is keyed off the
  -- live `lvim.colorscheme`: only the matching plugin loads eagerly, the
  -- other stays on disk-but-deferred so it can be enabled later via a
  -- `:colorscheme` invocation without paying its startup cost upfront.
  --
  -- `priority = 1000` is lazy.nvim's documented convention for "load this
  -- before other start plugins": lualine/bufferline read highlight groups
  -- in their `event = "VeryLazy"` callbacks, and they need the colorscheme's
  -- highlights to be live by then. Without the priority bump, lazy can
  -- interleave loads such that lualine resolves `theme = "auto"` against
  -- the default Neovim theme.
  --
  -- No `enabled = gate(...)` and no `config = setup(...)`: there is no
  -- `lvim.builtin.tokyonight.active` toggle (the `lazy = ...` condition
  -- already gates the load), and the colorscheme orchestration lives in
  -- `lvim/core/theme.lua` which runs from `lvim.start()` after lazy is up
  -- rather than via lazy's per-plugin `config` hook. Putting the
  -- `plugin.setup(opts)` call in a lazy `config` callback would race the
  -- post-lazy `:colorscheme` invocation in `theme.setup()` and break the
  -- "transparent option is honored" contract.
  -- Default colorscheme is `tokyonight` (see `lua/lvim/config/defaults.lua`).
  -- Not bundling `lunarvim/lunar.nvim`: the upstream repo isn't reliably
  -- installable from lazy.nvim's fetch path, and users who really want a
  -- different scheme can add it via `lvim.plugins` and set `lvim.colorscheme`.
  {
    "folke/tokyonight.nvim",
    lazy = not vim.startswith((_G.lvim and _G.lvim.colorscheme) or "", "tokyonight"),
    priority = 1000,
  },

  -- Lua-utility library; consumed by telescope and other plugins via
  -- `dependencies`. Not gated — it has no user-facing surface to toggle.
  { "nvim-lua/plenary.nvim", lazy = true },

  -- File-type icons. Consumed transitively by nvim-tree, telescope,
  -- bufferline, and lualine via `require('nvim-web-devicons')` — each of
  -- those plugins falls back to ASCII glyphs (or a different provider) if
  -- this isn't on rtp, which is what made users coming from the upstream
  -- reference see one icon set and LunaVim users see another. Bundling it
  -- as a non-gated infrastructure dependency matches what the upstream
  -- reference's plugin list ships (`references/.../plugins.lua` around
  -- line 223) and lines the two distributions up on iconography out of
  -- the box.
  --
  -- `lazy = true` (and no `name`, no `enabled`) keeps it deferred: the
  -- consuming plugins `require` it from their own setup paths, which
  -- triggers lazy.nvim's loader on demand. No standalone toggle since
  -- there is no user-facing reason to flip icons off independently of the
  -- plugins that render them. Not naming it also keeps it out of the
  -- gated-entry filter (`final_spec()`), matching the plenary entry above.
  --
  -- Not bundling `nvim-mini/mini.icons` alongside this: web-devicons alone
  -- matches LunarVim's traditional shipping set, and pulling in mini.icons
  -- would also need either a registration shim or a wrapper to avoid
  -- having two providers fight over the same `get_icon` call surface.
  { "nvim-tree/nvim-web-devicons", lazy = true },

  -- Neovim/Lua-API completion and signature help inside Lua buffers.
  {
    "folke/lazydev.nvim",
    name = "lazydev",
    enabled = gate("lazydev"),
    ft = "lua",
    opts = {},
    config = setup("lazydev"),
  },

  -- LSP client framework. Phase 4 wires the actual server presets via
  -- vim.lsp.config / vim.lsp.enable; this step only registers the plugin.
  -- `lazy = true` keeps it deferred until Phase 4 sets up an explicit trigger
  -- (`BufReadPre`/`BufNewFile` is the conventional LunarVim hook). Without
  -- this, lazy infers `lazy = false` from the absence of event/ft/cmd keys
  -- and would attempt to eager-load on startup, which errors under
  -- `install.missing = false`.
  {
    "neovim/nvim-lspconfig",
    name = "lspconfig",
    enabled = gate("lspconfig"),
    lazy = true,
    opts = {},
    config = setup("lspconfig"),
  },

  -- External tool installer.
  {
    "williamboman/mason.nvim",
    name = "mason",
    enabled = gate("mason"),
    cmd = { "Mason", "MasonInstall", "MasonUpdate", "MasonUninstall", "MasonLog" },
    opts = {},
    config = setup("mason"),
  },

  -- Bridge between mason and lspconfig. Shares the `mason` toggle per the
  -- plan: disabling mason should also drop this. `dependencies` keeps load
  -- order deterministic (mason must initialize first; the readme is explicit
  -- about this). Deferred via `lazy = true` for the same reason as
  -- nvim-lspconfig above — Phase 4 owns the trigger.
  {
    "williamboman/mason-lspconfig.nvim",
    name = "mason-lspconfig",
    enabled = gate("mason"),
    lazy = true,
    dependencies = { "williamboman/mason.nvim" },
    opts = {},
    config = setup("mason-lspconfig"),
  },

  -- Fuzzy finder UI.
  {
    "nvim-telescope/telescope.nvim",
    name = "telescope",
    enabled = gate("telescope"),
    cmd = "Telescope",
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = {},
    config = setup("telescope"),
  },

  -- File explorer.
  --
  -- `event = "User DirOpened"` is what makes `lvim some/dir` open the tree
  -- via nvim-tree's own hijack-netrw flow (rather than the old explicit
  -- `:NvimTreeOpen` VimEnter autocmd, which placed the tree as a side
  -- panel that collided with mini.map on the same side). LunaVim's
  -- `lvim/core/autocmds.lua` fires `User DirOpened` from the first
  -- directory-buffer `BufEnter` and then re-emits that BufEnter so
  -- nvim-tree's own `BufEnter`/`BufNewFile` handler — registered by
  -- `nvim-tree.setup()` when `disable_netrw`/`hijack_netrw` are true (see
  -- `lvim/config/defaults.lua`) — sees the directory and calls
  -- `open_on_directory`, replacing the would-be netrw view with the tree
  -- in the initial window. The `cmd` triggers cover the
  -- `<leader>e`-launched explicit-open path (`NvimTreeToggle`,
  -- `NvimTreeFindFile`); `NvimTreeOpen` is intentionally absent because
  -- nothing in LunaVim invokes it now that the dir-arg hijack is in
  -- nvim-tree's own hands.
  {
    "nvim-tree/nvim-tree.lua",
    name = "nvimtree",
    enabled = gate("nvimtree"),
    cmd = { "NvimTreeToggle", "NvimTreeFindFile" },
    event = "User DirOpened",
    opts = {},
    config = setup("nvimtree"),
  },

  -- Statusline.
  {
    "nvim-lualine/lualine.nvim",
    name = "lualine",
    enabled = gate("lualine"),
    event = "VeryLazy",
    opts = {},
    config = setup("lualine"),
  },

  -- Bufferline / tabs.
  {
    "akinsho/bufferline.nvim",
    name = "bufferline",
    enabled = gate("bufferline"),
    event = "VeryLazy",
    opts = {},
    config = setup("bufferline"),
  },

  -- Git decorations in the sign column.
  {
    "lewis6991/gitsigns.nvim",
    name = "gitsigns",
    enabled = gate("gitsigns"),
    event = "BufReadPre",
    opts = {},
    config = setup("gitsigns"),
  },

  -- Leader-key popup. v3 is the current line, deprecating the old `register()`
  -- API — Phase 6's whichkey module must use `add()` / `opts.spec`.
  {
    "folke/which-key.nvim",
    name = "whichkey",
    enabled = gate("whichkey"),
    event = "VeryLazy",
    opts = {},
    config = setup("whichkey"),
  },

  -- Floating/split terminal.
  --
  -- `keys = { [[<C-\>]] }` makes `<C-\>` cold-pressable: without it, the
  -- only lazy trigger is `cmd = "ToggleTerm"`, so toggleterm doesn't load
  -- until the user runs `:ToggleTerm` — and the `open_mapping` keymap
  -- (registered by toggleterm's own `setup()`) never gets a chance to
  -- exist on first press. The bare-key form (no `rhs`) tells lazy's keys
  -- handler (`lua/lazy/core/handler/keys.lua`) to load the plugin on
  -- press and then replay the keypress via `nvim_feedkeys("<Ignore>" ..
  -- lhs)`, after toggleterm's `setup()` has registered the real `<c-\>`
  -- mapping. Lua long-bracket form `[[<C-\>]]` matches the notation
  -- already used in `lvim/config/defaults.lua` for `open_mapping`.
  {
    "akinsho/toggleterm.nvim",
    name = "terminal",
    enabled = gate("terminal"),
    cmd = "ToggleTerm",
    keys = { [[<C-\>]] },
    opts = {},
    config = setup("terminal"),
  },

  -- Treesitter parsers + highlighting. Pinned to `branch = "master"`: the
  -- `main` branch is an incompatible rewrite requiring Neovim 0.12 (nightly),
  -- but LunaVim's minimum is 0.11 (see `lua/lvim/bootstrap.lua`). The master
  -- branch remains maintained as the 0.11-compatible line and still supports
  -- the BufReadPost/BufNewFile lazy-load hook used here.
  -- Branch is picked by Neovim version: `master` is the legacy
  -- 0.11-compatible line, `main` is the Neovim-0.12+ rewrite with a
  -- different setup API. On 0.12 the `master` branch's parser-runtime
  -- glue mismatches Neovim core's treesitter — opening a `.md` file
  -- raises `attempt to call method 'range' (a nil value)` from
  -- `vim/treesitter.lua:get_range` because the parse callback returns
  -- a nil node `main` no longer produces. `main` ships with a totally
  -- different config surface; the module under
  -- `lvim/plugins/modules/treesitter.lua` feature-probes both and
  -- dispatches accordingly. `build` is wrapped in `pcall` so the
  -- `:TSUpdate` command (master only) doesn't error the install on
  -- the `main` branch where parsers are managed differently.
  {
    "nvim-treesitter/nvim-treesitter",
    name = "treesitter",
    enabled = gate("treesitter"),
    branch = vim.fn.has("nvim-0.12") == 1 and "main" or "master",
    build = function()
      pcall(vim.cmd, "TSUpdate")
    end,
    event = { "BufReadPost", "BufNewFile" },
    opts = {},
    config = setup("treesitter"),
  },

  -- Dashboard / start screen. `cmd = "Alpha"` defers loading until
  -- `:Alpha` is invoked (either by the user or by the manual VimEnter
  -- autocmd registered in `lvim.start()` via
  -- `require('lvim.plugins.modules.alpha').attach_autoopen()`).
  --
  -- Alternatives considered and rejected:
  --   * `event = "VimEnter"` — lazy loads alpha on the VimEnter event,
  --     which means `alpha.setup()` (and the internal VimEnter autocmd
  --     it registers in `alpha_start`) runs AFTER the event has already
  --     fired, so the dashboard never opens.
  --   * No lazy trigger (eager load) — under `install.missing = false`
  --     (Phase 2.1) a fresh pre-`:LvimSyncCorePlugins` launch finds
  --     alpha not on disk and lazy emits a `Plugin alpha is not
  --     installed` error notification (`lua/lazy/core/loader.lua:315`),
  --     breaking the smoke harness's stderr-must-be-empty assertion.
  --   * `cond = function() return alpha_on_disk end` — lazy's
  --     `fix_cond` (`lua/lazy/core/meta.lua:265`) sets
  --     `plugin.enabled = false` when the condition is false, and the
  --     subsequent `fix_disabled` calls `self:disable(plugin)` which
  --     removes the plugin from `Config.plugins`. Once removed, the
  --     `:LvimSyncCorePlugins` install pipeline (which iterates
  --     `Config.plugins` via `Runner.new`) skips alpha entirely and it
  --     never gets installed — defeating the purpose of the gate.
  --
  -- `cmd = "Alpha"` is the only option that (a) keeps alpha in
  -- `Config.plugins` so `:LvimSyncCorePlugins` installs it, (b) prevents
  -- eager-load errors when alpha is missing, and (c) lets the manual
  -- autocmd in `lvim.start()` fire `:Alpha` once alpha is installed.
  {
    "goolord/alpha-nvim",
    name = "alpha",
    enabled = gate("alpha"),
    cmd = "Alpha",
    opts = {},
    config = setup("alpha"),
  },

  -- mini.nvim ships many independent modules; we only consume mini.comment
  -- for now (Phase 6 calls `require('mini.comment').setup()` from the
  -- comment module — the umbrella `require('mini')` is explicitly disallowed
  -- by the library).
  {
    "echasnovski/mini.nvim",
    name = "comment",
    enabled = gate("comment"),
    event = { "BufReadPost", "BufNewFile" },
    opts = {},
    config = setup("comment"),
  },

  -- Indent guides. v3 (the `ibl` module) is the current line; v2's
  -- `indent_blankline` module is deprecated and errors on require. The
  -- module file under `lvim/plugins/modules/indentlines.lua` forwards
  -- `lvim.builtin.indentlines.options` to `require('ibl').setup`.
  -- `event = { "BufReadPost", "BufNewFile" }` matches sibling per-buffer
  -- decorators (treesitter, mini.comment) so the guides arm as soon as
  -- the user has a real buffer on screen.
  {
    "lukas-reineke/indent-blankline.nvim",
    name = "indentlines",
    enabled = gate("indentlines"),
    event = { "BufReadPost", "BufNewFile" },
    opts = {},
    config = setup("indentlines"),
  },

  -- Formatter dispatcher. Backs the LunarVim `lvim.lsp.null-ls.formatters`
  -- compatibility shim (`lua/lvim/lsp/null-ls/formatters.lua`): when the user
  -- calls `formatters.setup{{ name = "prettier", filetypes = {...} }}` in
  -- their config.lua, the shim records the registration and `require`s
  -- this module so lazy.nvim loads conform and the registrations are pushed
  -- into `conform.setup({ formatters_by_ft = ... })`.
  --
  -- Lazy triggers cover the two entry points the user actually hits:
  --   * `event = "BufWritePre"` — format-on-save autocmd in
  --     `lua/lvim/lsp/format.lua` calls `require("conform")` from that event,
  --     so conform must be on rtp by the time the event fires.
  --   * `cmd = "ConformInfo"` — the canonical "what formatter ran on this
  --     buffer?" debug command. Without it the user has no way to load
  --     conform without writing a buffer first.
  -- The module's own `setup()` (see `lua/lvim/plugins/modules/conform.lua`)
  -- is also called directly from the null-ls shim's `formatters.setup`, so
  -- a fresh registration after conform has already been loaded re-applies
  -- the formatter list rather than waiting for the next BufWritePre.
  --
  -- No `name` and no `enabled = gate(...)` because there is no
  -- `lvim.builtin.conform.active` toggle: conform's behavior is entirely
  -- driven by what the user registered via `formatters.setup{}` (an empty
  -- `formatters_by_ft` table makes the BufWritePre callback a no-op).
  -- Omitting `name` also keeps the gated-entry count stable: every existing
  -- gated entry uses `enabled = gate(entry.name)`, and the plugin spec test
  -- pins that count exactly. Users who want to disable the formatting
  -- pipeline either omit the `formatters.setup` call or set
  -- `lvim.format_on_save.enabled = false` (which short-circuits the
  -- autocmd before it reaches conform).
  {
    "stevearc/conform.nvim",
    event = { "BufWritePre" },
    cmd = { "ConformInfo" },
    opts = {},
    config = setup("conform"),
  },

  -- Winbar breadcrumbs via SmiteshP/nvim-navic. Loaded lazily: the LSP
  -- on_attach callback in `lua/lvim/lsp/handlers.lua` calls
  -- `require('nvim-navic')` only after a server attaches AND
  -- `client.server_capabilities.documentSymbolProvider` is true, which
  -- triggers lazy's loader on demand. `lazy = true` (rather than
  -- `event = "LspAttach"`) keeps the trigger surface narrow: the spec
  -- only loads when a documentSymbol-providing client actually attaches,
  -- not on every LspAttach (which fires for clients without symbol
  -- support too — they'd load navic for nothing).
  {
    "SmiteshP/nvim-navic",
    name = "breadcrumbs",
    enabled = gate("breadcrumbs"),
    lazy = true,
    opts = {},
    config = setup("breadcrumbs"),
  },
}

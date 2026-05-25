return {
  leader = " ",
  colorscheme = "tokyonight",
  transparent_window = false,
  format_on_save = {
    enabled = false,
    timeout_ms = 1000,
  },
  keys = {
    normal_mode = {},
    insert_mode = {},
    visual_mode = {},
    term_mode = {},
    command_mode = {},
  },
  builtin = {
    -- Fuzzy finder. The whole subtree (minus `active`) is forwarded to
    -- `require('telescope').setup(opts)` by `lvim/plugins/modules/telescope.lua`.
    -- `defaults.mappings` use string-form actions so the table stays pure data
    -- (no `require('telescope.actions')` at config-load time, before telescope
    -- is on rtp).
    telescope = {
      active = true,
      defaults = {
        prompt_prefix = "> ",
        selection_caret = "> ",
        entry_prefix = "  ",
        initial_mode = "insert",
        layout_strategy = "horizontal",
        sorting_strategy = "ascending",
        file_ignore_patterns = { "node_modules", "%.git/", "%.cache" },
        path_display = { "smart" },
        mappings = {
          i = {
            ["<C-n>"] = "move_selection_next",
            ["<C-p>"] = "move_selection_previous",
            ["<C-c>"] = "close",
            ["<CR>"] = "select_default",
          },
          n = {
            ["<C-n>"] = "move_selection_next",
            ["<C-p>"] = "move_selection_previous",
          },
        },
      },
      pickers = {},
      extensions = {},
    },
    -- File explorer. The whole subtree (minus `active`) is the user-facing
    -- surface; `lvim.builtin.nvimtree.setup` is what the module forwards to
    -- `require('nvim-tree').setup(opts)`. Netrw is disabled by the module's
    -- `setup()` (the plugin readme is explicit that netrw must be disabled
    -- before `nvim-tree.setup` runs, or hijack-netrw is fighting against
    -- netrw's own load).
    nvimtree = {
      active = true,
      setup = {
        -- Both flags are required for the dir-arg hijack flow: nvim-tree
        -- only registers its `BufEnter`/`BufNewFile` "open on directory"
        -- handler when `hijack_directories.enable` (default true) AND
        -- (`disable_netrw` OR `hijack_netrw`) are true (kcl-confirmed
        -- against `lua/nvim-tree/autocmd.lua` `:52`). `disable_netrw`
        -- additionally disarms Neovim's bundled netrw plugin so it never
        -- competes for the directory buffer; `hijack_netrw` covers the
        -- post-startup `:edit some-dir/` path where netrw is otherwise
        -- still on rtp. Together they reproduce the upstream-reference
        -- behavior: `lvim some/dir` opens the tree in the initial window rather
        -- than placing it as a side panel (which under the previous
        -- VimEnter→`:NvimTreeOpen` shim collided with right-side panels
        -- like `mini.map`).
        disable_netrw = true,
        hijack_netrw = true,
        view = { width = 30 },
        renderer = {
          add_trailing = false,
          group_empty = false,
          highlight_git = true,
          indent_markers = { enable = true },
          -- Scaffold `renderer.icons.show` so a user writing
          -- `lvim.builtin.nvimtree.setup.renderer.icons.show.git = true` in
          -- config.lua does not crash on `attempt to index field 'icons'
          -- (a nil value)`. Defaults mirror nvim-tree's own
          -- `renderer.icons.show` defaults (git off, file/folder/folder_arrow
          -- on) so opting in to `git = true` is the only behavior change vs.
          -- a bare `nvim-tree.setup()` — everything else stays at upstream
          -- defaults until the user touches it.
          icons = {
            show = {
              git = false,
              file = true,
              folder = true,
              folder_arrow = true,
            },
          },
        },
        filters = { dotfiles = false },
      },
    },
    -- Statusline. The whole subtree (minus `active`) is forwarded to
    -- `require('lualine').setup(opts)` by `lvim/plugins/modules/lualine.lua`.
    -- `theme = 'auto'` lets lualine pick a theme matching the active
    -- colorscheme; `section_separators`/`component_separators` as empty
    -- strings render with no separator glyphs (kcl-confirmed shortcut: a
    -- string is accepted in place of `{ left, right }`). `sections` follow
    -- the LunarVim layout — branch in `lualine_b`, diagnostics in
    -- `lualine_c`, and `lsp_status` (the current LSP-client-name component)
    -- on the right — so users see git branch and active LSP servers at a
    -- glance without further configuration.
    lualine = {
      active = true,
      options = {
        theme = "auto",
        section_separators = "",
        component_separators = "",
      },
      sections = {
        lualine_a = { "mode" },
        lualine_b = { "branch" },
        lualine_c = { "diagnostics" },
        lualine_x = { "lsp_status", "encoding", "fileformat", "filetype" },
        lualine_y = { "progress" },
        lualine_z = { "location" },
      },
    },
    -- Bufferline / tabs. The whole subtree (minus `active`) is forwarded to
    -- `require('bufferline').setup(opts)` by `lvim/plugins/modules/bufferline.lua`.
    -- `diagnostics = "nvim_lsp"` surfaces LSP diagnostic counts on buffer tabs
    -- (kcl-confirmed: bufferline supports `"nvim_lsp"`, `"coc"`, or `false`).
    -- The `offsets` entry reserves a column on the left for nvim-tree so the
    -- bufferline does not draw over the file explorer when both are open;
    -- `filetype = "NvimTree"` matches the buffer set by `nvim-tree.lua`.
    bufferline = {
      active = true,
      options = {
        diagnostics = "nvim_lsp",
        offsets = {
          {
            filetype = "NvimTree",
            text = "File Explorer",
            highlight = "Directory",
            text_align = "left",
          },
        },
      },
    },
    -- Git decorations. The whole subtree (minus `active`) is forwarded to
    -- `require('gitsigns').setup(opts)` by `lvim/plugins/modules/gitsigns.lua`.
    -- The `signs` and `signs_staged` subtables follow the kcl-confirmed shape
    -- (per-status `{ text = "..." }` entries) so users can override a single
    -- glyph without restating the whole table — the table is deep-merged from
    -- the live `_G.lvim.builtin.gitsigns` at the moment the module's `config`
    -- callback fires. `signcolumn = true` keeps the gutter visible so the
    -- decorations have a column to render in. `attach_to_untracked = true`
    -- and `current_line_blame = false` (the latter toggled via
    -- `:Gitsigns toggle_current_line_blame`) match LunarVim's contract.
    gitsigns = {
      active = true,
      signs = {
        add = { text = "┃" },
        change = { text = "┃" },
        delete = { text = "_" },
        topdelete = { text = "‾" },
        changedelete = { text = "~" },
        untracked = { text = "┆" },
      },
      signs_staged = {
        add = { text = "┃" },
        change = { text = "┃" },
        delete = { text = "_" },
        topdelete = { text = "‾" },
        changedelete = { text = "~" },
        untracked = { text = "┆" },
      },
      signcolumn = true,
      numhl = false,
      linehl = false,
      word_diff = false,
      watch_gitdir = { follow_files = true },
      attach_to_untracked = true,
      current_line_blame = false,
      current_line_blame_opts = {
        virt_text = true,
        virt_text_pos = "eol",
        delay = 1000,
        ignore_whitespace = false,
      },
      sign_priority = 6,
      update_debounce = 200,
      max_file_length = 40000,
      preview_config = {
        border = "rounded",
        style = "minimal",
        relative = "cursor",
        row = 0,
        col = 1,
      },
    },
    -- which-key.nvim. v3 of the plugin deprecated the dictionary `register()`
    -- API in favor of a flat spec array fed via `add()` (or `opts.spec`); the
    -- module under `lvim/plugins/modules/whichkey.lua` follows kcl's
    -- recommendation and calls `require('which-key').setup(setup)` then
    -- `require('which-key').add(mappings)`. We keep the two concerns split
    -- into distinct subkeys so the module can filter cleanly without having
    -- to know every which-key.setup option name:
    --   * `setup`    — forwarded verbatim to `require('which-key').setup`.
    --                  Empty by default; v3 ships sensible defaults so we do
    --                  not need to restate them.
    --   * `mappings` — forwarded verbatim to `require('which-key').add`. The
    --                  seeded entries register leader-group labels per the
    --                  plan's Phase 6 contract; concrete `<leader>X<x>`
    --                  bindings live in `lua/lvim/core/keymaps.lua` and pick
    --                  up these group labels by prefix match.
    whichkey = {
      active = true,
      setup = {},
      -- Full mapping spec — ported from the upstream LunarVim reference's
      -- `lua/lvim/core/which-key.lua:86-203` (`references/CKLunarVim/...`).
      -- Each entry is a which-key v3 row: `{ "<lhs>", "<rhs>", desc = "..." }`
      -- or `{ "<lhs>", group = "+label" }` for a group label. We materialise
      -- the absolute `<leader>X` LHS form here (rather than CKLunarVim's
      -- bare-key form that's threaded through a `prepend_leader` helper at
      -- registration) so a user appending `lvim.builtin.whichkey.mappings`
      -- entries in `config.lua` does not have to know about the prefix
      -- convention. `<leader>` is resolved by Neovim at map-creation time
      -- using `vim.g.mapleader`, which `lvim/core/keymaps.lua` pins before
      -- plugin load, so the LHS strings here are stable.
      --
      -- The whichkey module under `lvim/plugins/modules/whichkey.lua`
      -- forwards this whole list to `require('which-key').add(mappings)` at
      -- `event = "VeryLazy"`, which both registers the labels for the popup
      -- AND installs each `{ "<lhs>", "<rhs>" }` row as an actual keymap
      -- (kcl-confirmed: in which-key v3 `add()` calls `vim.keymap.set` for
      -- every entry that has both an LHS and an RHS). That single hop wires
      -- `<leader>bn` → `<cmd>BufferLineCycleNext<cr>` end-to-end without
      -- needing duplicate `vim.keymap.set` calls in `core/keymaps.lua`.
      --
      -- The seven core leader bindings already installed by
      -- `core/keymaps.lua` (`<leader>w`, `<leader>q`, `<leader>h`,
      -- `<leader>e`, `<leader>ff/fg/fb/fh`, `<leader>gj/gk/gp/gb/gg`) are
      -- redundantly listed below — last write wins, and `core/keymaps.lua`
      -- runs first, so the `wk.add()` call's late-bind overwrites the
      -- earlier `vim.keymap.set` with an identical RHS. That redundancy is
      -- deliberate: a user who flips `lvim.builtin.whichkey.active = false`
      -- still has the seven core bindings via `core/keymaps.lua`, and a
      -- user who flips it on gets a labelled popup describing both the
      -- core bindings and the extra ~80 from below.
      mappings = {
        -- Top-level (no group)
        { "<leader>;", "<cmd>Alpha<CR>", desc = "Dashboard" },
        { "<leader>w", "<cmd>w!<CR>", desc = "Save" },
        { "<leader>q", "<cmd>confirm q<CR>", desc = "Quit" },
        { "<leader>/", "<Plug>(comment_toggle_linewise_current)", desc = "Comment toggle current line" },
        { "<leader>c", "<cmd>BufferKill<CR>", desc = "Close Buffer" },
        { "<leader>f", "<cmd>Telescope find_files<CR>", desc = "Find File" },
        { "<leader>h", "<cmd>nohlsearch<CR>", desc = "No Highlight" },
        { "<leader>e", "<cmd>LvimExplorer<CR>", desc = "Explorer" },
        -- Buffers
        { "<leader>b", group = "Buffers" },
        { "<leader>bj", "<cmd>BufferLinePick<cr>", desc = "Jump" },
        { "<leader>bf", "<cmd>Telescope buffers previewer=false<cr>", desc = "Find" },
        { "<leader>bb", "<cmd>BufferLineCyclePrev<cr>", desc = "Previous" },
        { "<leader>bn", "<cmd>BufferLineCycleNext<cr>", desc = "Next" },
        { "<leader>bW", "<cmd>noautocmd w<cr>", desc = "Save without formatting (noautocmd)" },
        { "<leader>be", "<cmd>BufferLinePickClose<cr>", desc = "Pick which buffer to close" },
        { "<leader>bh", "<cmd>BufferLineCloseLeft<cr>", desc = "Close all to the left" },
        { "<leader>bl", "<cmd>BufferLineCloseRight<cr>", desc = "Close all to the right" },
        { "<leader>bD", "<cmd>BufferLineSortByDirectory<cr>", desc = "Sort by directory" },
        { "<leader>bL", "<cmd>BufferLineSortByExtension<cr>", desc = "Sort by language" },
        -- Debug (nvim-dap; commands resolve lazily at press time so an
        -- uninstalled dap surfaces as a missing-module error rather than
        -- the whichkey popup hiding the binding entirely).
        { "<leader>d", group = "Debug" },
        { "<leader>dt", "<cmd>lua require'dap'.toggle_breakpoint()<cr>", desc = "Toggle Breakpoint" },
        { "<leader>db", "<cmd>lua require'dap'.step_back()<cr>", desc = "Step Back" },
        { "<leader>dc", "<cmd>lua require'dap'.continue()<cr>", desc = "Continue" },
        { "<leader>dC", "<cmd>lua require'dap'.run_to_cursor()<cr>", desc = "Run To Cursor" },
        { "<leader>dd", "<cmd>lua require'dap'.disconnect()<cr>", desc = "Disconnect" },
        { "<leader>dg", "<cmd>lua require'dap'.session()<cr>", desc = "Get Session" },
        { "<leader>di", "<cmd>lua require'dap'.step_into()<cr>", desc = "Step Into" },
        { "<leader>do", "<cmd>lua require'dap'.step_over()<cr>", desc = "Step Over" },
        { "<leader>du", "<cmd>lua require'dap'.step_out()<cr>", desc = "Step Out" },
        { "<leader>dp", "<cmd>lua require'dap'.pause()<cr>", desc = "Pause" },
        { "<leader>dr", "<cmd>lua require'dap'.repl.toggle()<cr>", desc = "Toggle Repl" },
        { "<leader>ds", "<cmd>lua require'dap'.continue()<cr>", desc = "Start" },
        { "<leader>dq", "<cmd>lua require'dap'.close()<cr>", desc = "Quit" },
        { "<leader>dU", "<cmd>lua require'dapui'.toggle({reset = true})<cr>", desc = "Toggle UI" },
        -- Plugins (lazy.nvim subcommands)
        { "<leader>p", group = "Plugins" },
        { "<leader>pi", "<cmd>Lazy install<cr>", desc = "Install" },
        { "<leader>ps", "<cmd>Lazy sync<cr>", desc = "Sync" },
        { "<leader>pS", "<cmd>Lazy clear<cr>", desc = "Status" },
        { "<leader>pc", "<cmd>Lazy clean<cr>", desc = "Clean" },
        { "<leader>pu", "<cmd>Lazy update<cr>", desc = "Update" },
        { "<leader>pp", "<cmd>Lazy profile<cr>", desc = "Profile" },
        { "<leader>pl", "<cmd>Lazy log<cr>", desc = "Log" },
        { "<leader>pd", "<cmd>Lazy debug<cr>", desc = "Debug" },
        -- Git (gitsigns + telescope-git pickers + lazygit float)
        { "<leader>g", group = "Git" },
        { "<leader>gg", "<cmd>lua require('lvim.plugins.modules.terminal').toggle_lazygit()<cr>", desc = "Lazygit" },
        { "<leader>gj", "<cmd>lua require 'gitsigns'.nav_hunk('next', {navigation_message = false})<cr>", desc = "Next Hunk" },
        { "<leader>gk", "<cmd>lua require 'gitsigns'.nav_hunk('prev', {navigation_message = false})<cr>", desc = "Prev Hunk" },
        { "<leader>gl", "<cmd>lua require 'gitsigns'.blame_line()<cr>", desc = "Blame" },
        { "<leader>gL", "<cmd>lua require 'gitsigns'.blame_line({full=true})<cr>", desc = "Blame Line (full)" },
        { "<leader>gp", "<cmd>lua require 'gitsigns'.preview_hunk()<cr>", desc = "Preview Hunk" },
        { "<leader>gr", "<cmd>lua require 'gitsigns'.reset_hunk()<cr>", desc = "Reset Hunk" },
        { "<leader>gR", "<cmd>lua require 'gitsigns'.reset_buffer()<cr>", desc = "Reset Buffer" },
        { "<leader>gs", "<cmd>lua require 'gitsigns'.stage_hunk()<cr>", desc = "Stage Hunk" },
        { "<leader>gu", "<cmd>lua require 'gitsigns'.undo_stage_hunk()<cr>", desc = "Undo Stage Hunk" },
        { "<leader>go", "<cmd>Telescope git_status<cr>", desc = "Open changed file" },
        { "<leader>gb", "<cmd>Telescope git_branches<cr>", desc = "Checkout branch" },
        { "<leader>gc", "<cmd>Telescope git_commits<cr>", desc = "Checkout commit" },
        { "<leader>gC", "<cmd>Telescope git_bcommits<cr>", desc = "Checkout commit(for current file)" },
        { "<leader>gd", "<cmd>Gitsigns diffthis HEAD<cr>", desc = "Git Diff" },
        -- LSP
        { "<leader>l", group = "LSP" },
        { "<leader>la", "<cmd>lua vim.lsp.buf.code_action()<cr>", desc = "Code Action" },
        { "<leader>ld", "<cmd>Telescope diagnostics bufnr=0 theme=get_ivy<cr>", desc = "Buffer Diagnostics" },
        { "<leader>lw", "<cmd>Telescope diagnostics<cr>", desc = "Diagnostics" },
        { "<leader>lf", "<cmd>lua vim.lsp.buf.format({ async = false })<cr>", desc = "Format" },
        { "<leader>li", "<cmd>LspInfo<cr>", desc = "Info" },
        { "<leader>lI", "<cmd>Mason<cr>", desc = "Mason Info" },
        { "<leader>lj", "<cmd>lua vim.diagnostic.goto_next()<cr>", desc = "Next Diagnostic" },
        { "<leader>lk", "<cmd>lua vim.diagnostic.goto_prev()<cr>", desc = "Prev Diagnostic" },
        { "<leader>ll", "<cmd>lua vim.lsp.codelens.run()<cr>", desc = "CodeLens Action" },
        { "<leader>lq", "<cmd>lua vim.diagnostic.setloclist()<cr>", desc = "Quickfix" },
        { "<leader>lr", "<cmd>lua vim.lsp.buf.rename()<cr>", desc = "Rename" },
        { "<leader>ls", "<cmd>Telescope lsp_document_symbols<cr>", desc = "Document Symbols" },
        { "<leader>lS", "<cmd>Telescope lsp_dynamic_workspace_symbols<cr>", desc = "Workspace Symbols" },
        { "<leader>le", "<cmd>Telescope quickfix<cr>", desc = "Telescope Quickfix" },
        -- Search (telescope pickers)
        { "<leader>s", group = "Search" },
        { "<leader>sb", "<cmd>Telescope git_branches<cr>", desc = "Checkout branch" },
        { "<leader>sc", "<cmd>Telescope colorscheme<cr>", desc = "Colorscheme" },
        { "<leader>sf", "<cmd>Telescope find_files<cr>", desc = "Find File" },
        { "<leader>sh", "<cmd>Telescope help_tags<cr>", desc = "Find Help" },
        { "<leader>sH", "<cmd>Telescope highlights<cr>", desc = "Find highlight groups" },
        { "<leader>sM", "<cmd>Telescope man_pages<cr>", desc = "Man Pages" },
        { "<leader>sr", "<cmd>Telescope oldfiles<cr>", desc = "Open Recent File" },
        { "<leader>sR", "<cmd>Telescope registers<cr>", desc = "Registers" },
        { "<leader>st", "<cmd>Telescope live_grep<cr>", desc = "Text" },
        { "<leader>sk", "<cmd>Telescope keymaps<cr>", desc = "Keymaps" },
        { "<leader>sC", "<cmd>Telescope commands<cr>", desc = "Commands" },
        { "<leader>sl", "<cmd>Telescope resume<cr>", desc = "Resume last search" },
        { "<leader>sp", "<cmd>lua require('telescope.builtin').colorscheme({enable_preview = true})<cr>", desc = "Colorscheme with Preview" },
        -- Treesitter
        { "<leader>T", group = "Treesitter" },
        { "<leader>Ti", "<cmd>TSConfigInfo<cr>", desc = "Info" },
      },
    },
    -- Floating/split terminal. The whole subtree (minus `active`) is forwarded
    -- to `require('toggleterm').setup(opts)` by `lvim/plugins/modules/terminal.lua`.
    -- Defaults follow LunarVim's contract: `<c-\>` toggles a 20-row horizontal
    -- split; `shading_factor = 2` darkens the terminal buffer slightly so it
    -- visually separates from the surrounding code window.
    -- Floating terminal by default — matches CKLunarVim's reference
    -- (`references/CKLunarVim/lua/lvim/core/terminal.lua:19`). A user who
    -- prefers a horizontal split can set `lvim.builtin.terminal.direction =
    -- "horizontal"` in their config; `float_opts` is consumed only when
    -- `direction = "float"`, so leaving it populated is harmless.
    terminal = {
      active = true,
      size = 20,
      open_mapping = [[<c-\>]],
      direction = "float",
      shading_factor = 2,
      float_opts = {
        border = "curved",
        winblend = 0,
        highlights = {
          border = "Normal",
          background = "Normal",
        },
      },
    },
    -- Treesitter parsers + highlighting. We pin nvim-treesitter to its
    -- `master` branch in the plugin spec because its `main` branch is an
    -- incompatible rewrite requiring Neovim 0.12 (LunaVim's minimum is
    -- 0.11). On `master` the canonical configuration shape is the
    -- `nvim-treesitter.configs.setup(opts)` table used by LunarVim's
    -- upstream reference (under `references/`) and documented in
    -- `:help nvim-treesitter-quickstart`. The module under
    -- `lvim/plugins/modules/treesitter.lua` forwards this whole subtree
    -- (minus `active`) to that setup call.
    treesitter = {
      active = true,
      -- `comment` powers mini.comment's treesitter-aware commentstring
      -- resolution (so e.g. JSX inside a `.tsx` buffer gets `{/* */}`
      -- instead of `//`). `markdown` and `markdown_inline` MUST ship
      -- together: the `markdown` parser embeds injection queries that
      -- point into `markdown_inline` for inline-content highlighting,
      -- and Neovim's `vim/treesitter/languagetree.lua` raises
      -- `attempt to call method 'range' (a nil value)` on a `.md` file
      -- when one is present without the other (or when the two were
      -- compiled against mismatched parser ABIs). `auto_install = true`
      -- on its own only fetches filetype parsers, so it'd grab
      -- `markdown` without the injection-only `markdown_inline`;
      -- listing both here forces nvim-treesitter to install them in
      -- the same pass at matching ABIs.
      ensure_installed = {
        "lua",
        "vim",
        "vimdoc",
        "bash",
        "json",
        "comment",
        "markdown",
        "markdown_inline",
      },
      highlight = { enable = true },
      indent = { enable = true },
      auto_install = true,
    },
    -- mini.comment. `options` is passed straight through to
    -- `require('mini.comment').setup({ options = ... })`. The treesitter-aware
    -- `hooks.pre` callback (set in `lvim/plugins/modules/comment.lua`) is owned
    -- by the module and is not exposed for user override here; Phase 6 may
    -- extend the surface if needed.
    comment = { active = true, options = {} },
    dap = { active = true },
    -- Dashboard. The whole subtree (minus `active`) is consumed by
    -- `lvim/plugins/modules/alpha.lua`. `mode` selects an `alpha.themes.*`
    -- preset; only "dashboard" is wired by Phase 6 (the upstream theme module
    -- name must match — `require('alpha.themes.' .. mode)`). `config.buttons.entries`
    -- is a list of `{ shortcut, label, action }` triples; the module passes
    -- each to `require('alpha.themes.dashboard').button(sc, txt, action)` to
    -- build the actual button element (with `on_press`, in-buffer `keymap`,
    -- alignment, highlighting), and then replaces `theme.section.buttons.val`
    -- before calling `alpha.setup`. Storing entries as plain data (rather
    -- than pre-built button tables) lets users override a single entry
    -- without having to restate the alpha element shape.
    --
    -- The Settings button's action is wrapped in `<cmd>lua ...<CR>` so the
    -- user-config path is resolved at press time via `_G.get_config_dir()`,
    -- picking up `LUNAVIM_CONFIG_DIR` overrides even after the user moves
    -- their config directory.
    alpha = {
      active = true,
      mode = "dashboard",
      config = {
        buttons = {
          -- Button shortcut letters intentionally avoid the `<leader>e`
          -- explorer toggle: alpha registers each button as a buffer-local
          -- map with `nowait`, so a bare `e` shadows the leader-prefixed
          -- `<leader>e → :NvimTreeToggle` while the dashboard is focused
          -- (the upstream alpha-nvim contract — alpha owns its buffer's
          -- key resolution). The upstream CKLunarVim dashboard uses `n`
          -- for New File for the same reason; mirroring that here keeps
          -- `<leader>e` reachable from a fresh launch.
          entries = {
            { "n", "  New file", "<cmd>enew<CR>" },
            { "f", "  Find file", "<cmd>Telescope find_files<CR>" },
            { "r", "  Recent files", "<cmd>Telescope oldfiles<CR>" },
            { "s", "  Settings", "<cmd>lua vim.cmd('edit ' .. _G.get_config_dir() .. '/config.lua')<CR>" },
            { "q", "  Quit", "<cmd>qa<CR>" },
          },
        },
      },
    },
    -- Winbar breadcrumbs via SmiteshP/nvim-navic. `options` is forwarded
    -- verbatim to `require('nvim-navic').setup(opts)` by
    -- `lvim/plugins/modules/breadcrumbs.lua`. The `icons` subtable maps the
    -- 26 LSP symbol kinds (LSP spec: `File` … `TypeParameter`) to the
    -- LunarVim-heritage Nerd Font glyphs (sourced verbatim from the
    -- upstream reference's `lua/lvim/icons.lua` `icons.kind` (see
    -- `references/`), filtered to the kinds
    -- navic recognises per `lua/nvim-navic/lib.lua`'s `lsp_str_to_num`
    -- table). Shipping the full 26-key map (rather than the empty `{}` that
    -- earlier iterations of this file used) honours the plan-prescribed
    -- defaults shape `{ active, options = { icons = {...}, highlight } }`
    -- and means a user who installs LunaVim sees the LunarVim glyphs in
    -- the winbar even before they edit `config.lua`. Each glyph trails a
    -- single space so the symbol name does not abut the icon when navic
    -- composes the location string.
    --
    -- nvim-navic's `setup(opts)` translates string-keyed icons to its
    -- internal integer-keyed `config.icons` via `adapt_lsp_str_to_num`
    -- (kcl-confirmed), so the user-facing kind names above are the right
    -- vocabulary — passing this table verbatim overwrites navic's bundled
    -- Nerd Font fallbacks one kind at a time with LunarVim's chosen glyphs.
    -- `highlight = true` opts in to the per-kind `NavicIcons*` highlight
    -- groups so the icons pick up the colorscheme's semantic highlights
    -- instead of rendering flat.
    --
    -- The actual winbar wiring (`vim.opt.winbar = "%{%v:lua.require('nvim-navic').get_location()%}"`)
    -- and the per-client `navic.attach(client, bufnr)` call live in
    -- `lvim/plugins/modules/breadcrumbs.lua` (winbar) and
    -- `lvim/lsp/handlers.lua` `make_on_attach` (attach), gated by
    -- `lvim.builtin.breadcrumbs.active` so a user can flip the whole
    -- feature off without unsetting the winbar by hand.
    breadcrumbs = {
      active = true,
      options = {
        icons = {
          Array = " ",
          Boolean = " ",
          Class = " ",
          Constant = " ",
          Constructor = " ",
          Enum = " ",
          EnumMember = " ",
          Event = " ",
          Field = " ",
          File = " ",
          Function = " ",
          Interface = " ",
          Key = " ",
          Method = " ",
          Module = " ",
          Namespace = " ",
          Null = "󰟢 ",
          Number = " ",
          Object = " ",
          Operator = " ",
          Package = " ",
          Property = " ",
          String = " ",
          Struct = " ",
          TypeParameter = " ",
          Variable = " ",
        },
        highlight = true,
      },
    },
    illuminate = { active = true },
    -- Indent guides via lukas-reineke/indent-blankline.nvim. v3 of the plugin
    -- renamed the Lua module from `indent_blankline` to `ibl` and replaced
    -- v2's flat options/global vars with a deeply nested config table. The
    -- whole `options` subtree (kcl-confirmed shape: `indent.{char,tab_char,...}`,
    -- `scope.{enabled,char,...}`, `whitespace.{...}`, `exclude.{filetypes,buftypes}`)
    -- is forwarded verbatim to `require('ibl').setup(opts)` by
    -- `lvim/plugins/modules/indentlines.lua`. The defaults seed `indent.char`
    -- with the thin vertical bar used by LunarVim's contract and turn on
    -- `scope.enabled` so the active block is highlighted out of the box.
    indentlines = {
      active = true,
      options = {
        indent = { char = "│" },
        scope = { enabled = true },
      },
    },
    lir = { active = true },
    project = { active = true },
    -- mason.nvim. The whole subtree (minus `active`) is forwarded to
    -- `require('mason').setup(opts)` by `lvim/lsp/init.lua`. Scaffolding
    -- `ui.{border,icons}` here means a user writing
    -- `lvim.builtin.mason.ui.border = "rounded"` does not crash on
    -- `attempt to index field 'ui' (a nil value)`. Default `border = "none"`
    -- and the three install-state icons mirror mason's own defaults so the
    -- scaffold is behavior-neutral until a user overrides a field.
    mason = {
      active = true,
      ui = {
        border = "none",
        icons = {
          package_installed = "✓",
          package_pending = "➜",
          package_uninstalled = "✗",
        },
      },
    },
    lspconfig = { active = true },
    -- folke/lazydev.nvim. The whole subtree (minus `active`) is forwarded to
    -- `require('lazydev').setup(opts)` by `lvim/plugins/modules/lazydev.lua`.
    -- The module always prepends `vim.env.VIMRUNTIME` and a `{ path = get_lvim_base_dir(),
    -- words = { "lvim" } }` entry to `opts.library` so completion for
    -- `vim.api.*` and for LunaVim's own modules works out of the box; user
    -- entries appended via `lvim.builtin.lazydev.library = { ... }` extend
    -- that list rather than replacing it. Scaffolding `library = {}` here
    -- means a user writing `lvim.builtin.lazydev.library = { "lazy.nvim" }`
    -- in `config.lua` does not crash on `attempt to index field 'lazydev'
    -- (a nil value)` — and a plain `table.insert(lvim.builtin.lazydev.library, ...)`
    -- works without a defensive `lvim.builtin.lazydev.library = lvim.builtin.lazydev.library or {}`
    -- preamble.
    lazydev = {
      active = true,
      library = {},
    },
  },
  plugins = {},
  -- User-supplied autocmd definitions. Each entry is a 2-tuple
  -- `{ events, opts }` consumed by `lvim.core.autocmds.define_autocmds()`:
  -- `events` is a string or list-of-strings; `opts` is forwarded verbatim
  -- to `nvim_create_autocmd` (so it carries `desc`, `pattern`, `callback`
  -- / `command`, etc.). Empty by default; users add entries from
  -- `config.lua` and they land in the `lvim_user_autocmds` augroup at
  -- setup() time.
  autocommands = {},
  -- User overrides for `vim.opt.*`. Keys map 1:1 to Neovim option names,
  -- e.g. `lvim.opt = { wrap = true, scrolloff = 0 }`. Defaults set by
  -- `lvim.core.options.setup()` are applied first, then these overrides on top.
  opt = {},
  -- LunarVim-compatible LSP surface. `servers` is a name-keyed table whose
  -- values are merged on top of the orchestrator's default
  -- `{ on_attach, capabilities }` and forwarded to
  -- `require('lspconfig')[name].setup(...)`. `on_attach`/`capabilities`, if
  -- set, replace the orchestrator's defaults for every server.
  -- `ensure_installed` is consumed by mason-lspconfig in `lvim.lsp.setup()`.
  lsp = {
    ensure_installed = {},
    servers = {},
    on_attach = nil,
    capabilities = nil,
    automatic_servers_installation = false,
    diagnostic = {},
  },
  lazy = {
    opts = {},
  },
  lang = {},
  log = {
    level = "warn",
  },
}

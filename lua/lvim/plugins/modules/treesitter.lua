-- nvim-treesitter ships two incompatible branches; the spec entry in
-- `lvim/plugins/spec.lua` picks one based on Neovim version:
--
--   * `master` — Neovim 0.11-compatible legacy line. Configured via
--     `require('nvim-treesitter.configs').setup(opts)` with a flat
--     `{ ensure_installed, highlight, indent, auto_install, ... }`
--     table. The plugin registers its own FileType autocmd that calls
--     into Neovim core treesitter to start highlighting per buffer.
--
--   * `main` — Neovim 0.12+ rewrite. The `configs` entry point is gone.
--     Parsers are installed via `require('nvim-treesitter').install(...)`
--     and highlighting must be turned on per buffer with
--     `vim.treesitter.start()` (no global FileType autocmd is registered
--     by the plugin itself). Indent is opt-in via setting `indentexpr`
--     on the buffer.
--
-- We feature-probe by trying to require the legacy `configs` module
-- (master only) and fall through to the `main` API when it's absent.
-- Both dispatchers consume the same user-facing
-- `lvim.builtin.treesitter` shape — `ensure_installed`, `highlight.enable`,
-- `indent.enable` — so a user's `config.lua` doesn't need to know
-- which branch is actually on disk.
local M = {}

local function setup_master(opts)
  local ok, configs = pcall(require, "nvim-treesitter.configs")
  if not ok then
    return
  end
  configs.setup(opts)
end

local function setup_main(opts)
  local ok, nt = pcall(require, "nvim-treesitter")
  if not ok then
    return
  end

  -- Install requested parsers. `install` on `main` is async and
  -- returns immediately; first-time highlighting on a not-yet-installed
  -- parser will silently no-op until the build finishes. Subsequent
  -- opens of the same filetype get full highlighting.
  if type(opts.ensure_installed) == "table" and #opts.ensure_installed > 0 then
    pcall(nt.install, opts.ensure_installed)
  end

  -- Per-buffer highlight start. `main` no longer registers a global
  -- FileType autocmd of its own, so distros are expected to wire one
  -- per their own conventions. `pcall` swallows the "no parser
  -- installed for <ft>" error that fires before the async install
  -- catches up on a fresh launch.
  if not opts.highlight or opts.highlight.enable ~= false then
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("lvim_treesitter_start", { clear = true }),
      callback = function(args)
        pcall(vim.treesitter.start, args.buf)
      end,
    })
  end

  -- Per-buffer indent. `main` ships an `indentexpr()` helper on the
  -- top-level module; setting `indentexpr` to call it lets `=` /
  -- auto-indent use the treesitter-derived indent for languages whose
  -- queries support it.
  if opts.indent and opts.indent.enable then
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("lvim_treesitter_indent", { clear = true }),
      callback = function(args)
        vim.api.nvim_set_option_value(
          "indentexpr",
          "v:lua.require'nvim-treesitter'.indentexpr()",
          { buf = args.buf }
        )
      end,
    })
  end
end

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.treesitter) or {}
  local opts = vim.deepcopy(builtin)
  opts.active = nil

  if pcall(require, "nvim-treesitter.configs") then
    setup_master(opts)
  else
    setup_main(opts)
  end
end

return M

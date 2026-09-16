-- nvim-treesitter `main` branch wiring (Neovim 0.12+).
--
-- The `main` rewrite dropped `nvim-treesitter.configs`. Parsers install via
-- `require('nvim-treesitter').install(...)`, highlighting is enabled per buffer
-- with `vim.treesitter.start()`, and indent uses the plugin's `indentexpr()`
-- helper. `lvim.builtin.treesitter` keeps the LunarVim-shaped surface
-- (`ensure_installed`, `highlight.enable`, `indent.enable`, `auto_install`) and
-- the module translates it into the `main` API.
local M = {}
local warned_missing_cli = false

local function has_tree_sitter_cli()
  return vim.fn.executable("tree-sitter") == 1
end

local function warn_missing_tree_sitter_cli()
  if warned_missing_cli then
    return
  end
  warned_missing_cli = true
  vim.schedule(function()
    vim.notify("nvim-treesitter parser installation skipped: `tree-sitter` CLI not found on PATH", vim.log.levels.WARN)
  end)
end

local function parser_requests_install(opts)
  if type(opts.ensure_installed) == "table" then
    return #opts.ensure_installed > 0
  end
  if type(opts.ensure_installed) == "string" then
    return opts.ensure_installed ~= ""
  end
  return opts.auto_install == true
end

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.treesitter) or {}
  local opts = vim.deepcopy(builtin)
  opts.active = nil

  local ok, nt = pcall(require, "nvim-treesitter")
  if not ok then
    return
  end

  if parser_requests_install(opts) then
    if has_tree_sitter_cli() then
      pcall(nt.install, opts.ensure_installed)
    else
      warn_missing_tree_sitter_cli()
    end
  end

  if not opts.highlight or opts.highlight.enable ~= false then
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("lvim_treesitter_start", { clear = true }),
      callback = function(args)
        pcall(vim.treesitter.start, args.buf)
      end,
    })
  end

  if opts.indent and opts.indent.enable then
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("lvim_treesitter_indent", { clear = true }),
      callback = function(args)
        vim.api.nvim_set_option_value("indentexpr", "v:lua.require'nvim-treesitter'.indentexpr()", { buf = args.buf })
      end,
    })
  end
end

return M

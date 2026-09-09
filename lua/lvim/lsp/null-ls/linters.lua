-- LunarVim `lvim.lsp.null-ls.linters` compat shim.
--
-- `linters.setup{}` accepts the null-ls registration shape LunarVim users
-- already write in their config.lua:
--
--   require("lvim.lsp.null-ls.linters").setup {
--     { name = "eslint_d", filetypes = { "typescript", "typescriptreact" } },
--     { name = "shellcheck", filetypes = { "sh" }, extra_args = { "--severity", "warning" } },
--   }
--
-- Registrations are recorded into the shared `_G.lvim._null_ls_registry` and
-- handed to `lvim/plugins/modules/lint.lua`, which translates them into
-- nvim-lint's `linters_by_ft` and arms the autocmd that runs them. See that
-- module for the full null-ls -> nvim-lint translation contract, including
-- the one field (`condition`) that has no nvim-lint equivalent.
--
-- `list_registered`/`list_supported` report what this shim has been given, so
-- a config that introspects its own linter set keeps working.

local M = {}

local function ensure_registry()
  _G.lvim = _G.lvim or {}
  _G.lvim._null_ls_registry = _G.lvim._null_ls_registry
    or {
      formatters = {},
      linters = {},
      code_actions = {},
    }
  return _G.lvim._null_ls_registry
end

function M.list_registered(filetype)
  local out = {}
  for _, entry in ipairs(ensure_registry().linters) do
    if entry.name and type(entry.filetypes) == "table" then
      for _, ft in ipairs(entry.filetypes) do
        if ft == filetype then
          table.insert(out, entry.name)
          break
        end
      end
    end
  end
  return out
end

function M.list_supported(filetype)
  -- Same partial semantics as `formatters.list_supported`: returns
  -- user-registered names rather than the full nvim-lint catalog.
  return M.list_registered(filetype)
end

function M.setup(linter_configs)
  if type(linter_configs) ~= "table" or vim.tbl_isempty(linter_configs) then
    return
  end

  local registry = ensure_registry().linters
  for _, entry in ipairs(linter_configs) do
    if type(entry) == "table" and entry.name then
      table.insert(registry, vim.deepcopy(entry))
    end
  end

  -- Hand the updated registry to the nvim-lint backend. Requiring the module
  -- also trips lazy.nvim's require-interceptor, which loads nvim-lint on
  -- demand the first time a user registers a linter -- the same hand-off the
  -- formatters shim makes to conform.nvim.
  local ok, lint_mod = pcall(require, "lvim.plugins.modules.lint")
  if ok then
    lint_mod.setup({})
  end
end

return M

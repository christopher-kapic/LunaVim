-- LunarVim `lvim.lsp.null-ls.code_actions` compat shim.
--
-- STUBBED: conform.nvim does not handle code actions (it's a formatter-only
-- plugin). null-ls's original code-action sources have been superseded by
-- per-language-server LSP code actions: the eslint LSP exposes
-- `source.fixAll.eslint`, the typescript LSP exposes its own import-organize
-- and quick-fix actions, etc. There is no single drop-in replacement plugin
-- equivalent to null-ls's code_actions catalog.
--
-- The user's CKLunarVim config does not register any code actions, so this
-- shim's only job is to not crash a config that *would* register them.
-- Registrations are recorded into the shared registry (so a future backend
-- could pick them up) and a one-shot vim.notify warns that the registration
-- is inert. `list_registered` returns the recorded names so user code that
-- introspects the registry sees what it asked for.

local M = {}

local notified_stub = false

local function ensure_registry()
  _G.lvim = _G.lvim or {}
  _G.lvim._null_ls_registry = _G.lvim._null_ls_registry or {
    formatters = {},
    linters = {},
    code_actions = {},
  }
  return _G.lvim._null_ls_registry
end

function M.list_registered(filetype)
  local out = {}
  for _, entry in ipairs(ensure_registry().code_actions) do
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

-- No equivalent of `list_supported` is exposed by LunarVim's
-- `code_actions.lua` (only `list_registered` and `setup`), but the umbrella
-- comment in this directory promises the trio for consistency. Same
-- partial semantics as the sibling shims: returns user-registered names.
function M.list_supported(filetype)
  return M.list_registered(filetype)
end

function M.setup(actions_configs)
  if type(actions_configs) ~= "table" or vim.tbl_isempty(actions_configs) then
    return
  end

  local registry = ensure_registry().code_actions
  for _, entry in ipairs(actions_configs) do
    if type(entry) == "table" and entry.name then
      table.insert(registry, vim.deepcopy(entry))
    end
  end

  if not notified_stub then
    notified_stub = true
    vim.notify(
      "lvim.lsp.null-ls.code_actions: code-action registrations recorded but no backend is wired. "
        .. "Modern code actions come from LSP servers (eslint, typescript) directly; "
        .. "this shim is provided for null-ls API compatibility only.",
      vim.log.levels.WARN
    )
  end
end

return M

-- LunarVim `lvim.lsp.null-ls.linters` compat shim.
--
-- STUBBED: nvim-lint (the modern linting replacement for null-ls's diagnostic
-- sources) is not wired through LunaVim yet. The user's CKLunarVim config
-- does not register linters, and adding nvim-lint as a transitive dependency
-- would double the surface area of the null-ls compat task. Calling
-- `linters.setup{}` records the registrations to the shared registry (so a
-- future linter backend can pick them up) and emits a one-shot vim.notify
-- so a user who DOES try to register a linter learns it's a no-op rather
-- than silently losing their config.
--
-- To fully wire this:
--   1. Add `mfussenegger/nvim-lint` to `lua/lvim/plugins/spec.lua` (lazy
--      on `BufReadPre`/`BufWritePost`).
--   2. Create `lua/lvim/plugins/modules/nvim_lint.lua` that reads
--      `_G.lvim._null_ls_registry.linters` and assigns to
--      `require("lint").linters_by_ft`.
--   3. Register a `BufWritePost`/`BufReadPost` autocmd that calls
--      `require("lint").try_lint()`.

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

  if not notified_stub then
    notified_stub = true
    vim.notify(
      "lvim.lsp.null-ls.linters: linter registrations recorded but no backend is wired. "
        .. "Install and configure nvim-lint manually for now; see "
        .. "lua/lvim/lsp/null-ls/linters.lua for wiring notes.",
      vim.log.levels.WARN
    )
  end
end

return M

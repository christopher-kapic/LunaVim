-- LunarVim `lvim.lsp.null-ls.formatters` compat shim.
--
-- The user's CKLunarVim config.lua does:
--   local formatters = require "lvim.lsp.null-ls.formatters"
--   formatters.setup {
--     { name = "prettier",
--       filetypes = { "typescript", "typescriptreact", "javascript", "javascriptreact" } },
--   }
--
-- That call must (a) not crash, (b) actually wire prettier to run on save
-- for the listed filetypes via conform.nvim.
--
-- We translate each entry into a registry row that
-- `lua/lvim/plugins/modules/conform.lua` reads at conform's load time. The
-- shim itself is intentionally pure-data-shuffling: no conform-specific
-- knowledge lives here, so a future swap from conform to a different
-- formatting backend only needs to change the conform module.

local M = {}

-- Shared registry: kept on `_G.lvim` so both this shim and the conform
-- module see the same table even across module-reload boundaries
-- (`:LvimReload` re-requires both modules; storing the registry at module
-- scope would split it into two disjoint tables and lose registrations).
local function ensure_registry()
  _G.lvim = _G.lvim or {}
  _G.lvim._null_ls_registry = _G.lvim._null_ls_registry or {
    formatters = {},
    linters = {},
    code_actions = {},
  }
  return _G.lvim._null_ls_registry
end

-- Returns the names of formatters this shim has been asked to register for
-- a given filetype. The LunarVim contract returns a list of strings
-- (provider names); we read straight from the registry rather than asking
-- conform what it has registered because (a) conform may not be loaded yet
-- and (b) conform's `formatters_by_ft` lookup includes its built-in
-- catalog defaults, which would conflate "user-registered" with "available."
function M.list_registered(filetype)
  local out = {}
  for _, entry in ipairs(ensure_registry().formatters) do
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

-- LunarVim's `list_supported(ft)` returned every null-ls source that
-- supported the filetype, sourced from null-ls's own catalog. conform has
-- a similar catalog under `conform.list_all_formatters()` / `conform.list_formatters_for_buffer()`
-- but the latter only works once a buffer of that filetype exists, and the
-- former returns ALL known formatters regardless of filetype. Rather than
-- emulate null-ls's filetype index (a moving target maintained by null-ls
-- upstream), we return the user-registered names for this filetype — the
-- common case for `list_supported` in user configs is "did my registration
-- succeed?" which is answered by the same data as `list_registered`.
--
-- Stub-with-fallback notice: this is a partial implementation. A user who
-- needs the literal "what could I register" semantics should call
-- `require("conform").list_all_formatters()` directly.
function M.list_supported(filetype)
  return M.list_registered(filetype)
end

-- Append the formatter entries verbatim to the shared registry. The
-- conform module reads from this registry when lazy.nvim triggers its load
-- (on BufWritePre or :ConformInfo); a late call here also asks the conform
-- module to re-apply its setup so re-registrations take effect immediately.
function M.setup(formatter_configs)
  if type(formatter_configs) ~= "table" or vim.tbl_isempty(formatter_configs) then
    return
  end

  local registry = ensure_registry().formatters
  for _, entry in ipairs(formatter_configs) do
    if type(entry) == "table" and entry.name then
      table.insert(registry, vim.deepcopy(entry))
    end
  end

  -- Touch the conform module so a registration made AFTER conform was
  -- already loaded (e.g. via :LvimReload, or from a second config file)
  -- re-applies the formatters_by_ft mapping. No-op when conform is not
  -- yet loaded — the lazy `config` callback will pick up the registry on
  -- first load.
  local ok, conform_mod = pcall(require, "lvim.plugins.modules.conform")
  if ok then
    conform_mod.reapply()
  end
end

return M

-- Null-ls compatibility backend: forwards the registry that the
-- `lvim.lsp.null-ls.formatters` shim accumulates into a single
-- `require("conform").setup(...)` call.
--
-- The shim (`lua/lvim/lsp/null-ls/formatters.lua`) does not know whether
-- conform is on rtp yet when the user's config.lua runs — lazy.nvim defers
-- loading until BufWritePre / ConformInfo fires. So the shim writes into
-- `_G.lvim._null_ls_registry.formatters` (a table-of-tables keyed by
-- formatter name) and this module reads that registry at conform's load
-- time. The shim also calls `M.setup({})` directly when conform is already
-- loaded so a late `formatters.setup{}` (e.g. from `:LvimReload`) is
-- re-applied without waiting for the next BufWritePre.
--
-- Translation contract (CKLunarVim → conform):
--   { name = "prettier", filetypes = { "typescript", "javascript" } }
--     →  formatters_by_ft = { typescript = { "prettier" }, javascript = { "prettier" } }
--
--   { name = "prettier", filetypes = {...}, extra_args = { "--single-quote" } }
--     →  formatters = { prettier = { prepend_args = { "--single-quote" } } }
--
--   `args` and `extra_args` are unified onto conform's `prepend_args` (conform
--   merges them BEFORE the formatter's built-in default args, matching null-ls's
--   `extra_args` semantics — null-ls also prepended). This matches the
--   compat docstring on the CKLunarVim `services.lua`: "treat `args` as
--   `extra_args` for backwards compatibility."
--
--   `command` and `condition` are forwarded directly. `condition` in null-ls
--   was an executable-check callback `(utils) -> bool`; conform's equivalent
--   is also `condition = function(self, ctx) -> bool`. The signature is
--   different, but most CKLunarVim users never set `condition` (it was
--   primarily a null-ls internal concern for source-availability), and a
--   user who DOES set one with the null-ls-utils signature will get a benign
--   "function called with unexpected arg" at format time rather than a load
--   error. We forward verbatim and document the mismatch here rather than
--   silently dropping the field.
--
-- Multiple formatters per filetype: if the user calls `formatters.setup{}`
-- twice for the same filetype with different formatter names, conform runs
-- them sequentially in registration order. The registry is an ordered list
-- per filetype so duplicate names are deduped but order is preserved.

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

-- Build conform's `formatters_by_ft` and per-formatter `formatters` tables
-- from the accumulated registry. Returns two tables; the caller hands them
-- to `conform.setup({ formatters_by_ft = ..., formatters = ... })`.
local function build_conform_opts()
  local registry = ensure_registry().formatters
  local formatters_by_ft = {}
  local formatters = {}

  for _, entry in ipairs(registry) do
    local name = entry.name
    if name and type(entry.filetypes) == "table" then
      for _, ft in ipairs(entry.filetypes) do
        formatters_by_ft[ft] = formatters_by_ft[ft] or {}
        -- Dedup-on-insert: same name registered twice for the same
        -- filetype should not run the formatter twice on the buffer.
        local already_present = false
        for _, existing in ipairs(formatters_by_ft[ft]) do
          if existing == name then
            already_present = true
            break
          end
        end
        if not already_present then
          table.insert(formatters_by_ft[ft], name)
        end
      end

      -- Per-formatter customization: unify `args`/`extra_args` onto
      -- `prepend_args`, forward `command`/`condition` as-is. Only emit a
      -- `formatters[name]` entry if at least one of these is set —
      -- conform ships built-in definitions for prettier/stylua/black/etc.
      -- and we want to leave those untouched when the user only provided
      -- a `name`/`filetypes` pair.
      local override = {}
      if entry.extra_args then
        override.prepend_args = entry.extra_args
      elseif entry.args then
        override.prepend_args = entry.args
      end
      if entry.command then
        override.command = entry.command
      end
      if entry.condition then
        override.condition = entry.condition
      end
      if next(override) ~= nil then
        -- A later registration for the same formatter overwrites the
        -- previous override — matches null-ls's last-wins behavior when
        -- the same source was registered twice with different `extra_args`.
        formatters[name] = override
      end
    end
  end

  return formatters_by_ft, formatters
end

function M.setup(_)
  local ok, conform = pcall(require, "conform")
  if not ok then
    return
  end

  local formatters_by_ft, formatters = build_conform_opts()

  conform.setup({
    formatters_by_ft = formatters_by_ft,
    formatters = formatters,
    -- `format_on_save` deliberately left UNSET here: LunaVim drives
    -- format-on-save from `lua/lvim/lsp/format.lua`'s BufWritePre autocmd
    -- (which calls `require("conform").format(...)` with the user's
    -- `lvim.format_on_save.timeout_ms`). Letting conform register its own
    -- format_on_save autocmd would race ours and double-format the buffer.
  })
end

-- Re-apply the conform setup from the current registry. Called by the
-- null-ls shim's `formatters.setup` after a late registration so the
-- update takes effect without waiting for the next BufWritePre. No-op when
-- conform is not yet loaded — the lazy `config` callback will pick up the
-- registry naturally on first load.
function M.reapply()
  if package.loaded["conform"] then
    M.setup({})
  end
end

return M

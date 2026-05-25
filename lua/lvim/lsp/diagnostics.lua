-- Phase 4.5: configure `vim.diagnostic.config` once at startup so signs,
-- virtual text, severity ordering, and float-window styling match the
-- LunarVim defaults. The orchestrator calls this from `lvim.lsp.setup()`
-- under its `did_setup` guard, so the config is applied exactly once per
-- session.
--
-- `lvim.lsp.diagnostic` (table-shaped, declared in `lua/lvim/config/
-- defaults.lua`) is deep-merged on top of the defaults via
-- `tbl_deep_extend("force", ...)` so a user override of one nested key
-- (e.g. `lvim.lsp.diagnostic.float = { border = "single" }`) does not have
-- to restate the rest. User-set scalar fields win; nested tables merge,
-- which is the contract Phase 1.3 established for every `lvim.*` surface.
--
-- Signs API note: Neovim 0.11+'s sign handler renders the four severity
-- glyphs from `opts.signs.text[severity]` (see
-- `runtime/lua/vim/diagnostic.lua` `handlers.signs.show`). The legacy
-- `vim.fn.sign_define("DiagnosticSign*", { text = ... })` channel is no
-- longer consulted by `vim.diagnostic.handlers.signs.show` — when
-- `signs = true` (boolean) it falls back to the built-in `"E"/"W"/"I"/"H"`
-- single-letter text. So the LunaVim-prescribed `●` glyphs only actually
-- appear in the sign column if we pass them through the table-shaped
-- `signs.text` field keyed by `vim.diagnostic.severity`. `vim.fn.sign_define`
-- is *also* called below so third-party tooling that queries
-- `vim.fn.sign_getdefined("DiagnosticSign*")` (e.g. older statusline/
-- sign-list plugins, and any LunarVim-compat code path that inspected the
-- named signs directly) still sees the registered glyph/highlight pair.

local M = {}

-- Use the string severity names instead of the numeric enum values so the
-- `text`/`numhl` tables are NOT list-like (consecutive integer keys from 1).
-- That keeps the per-severity user-override contract intact: a user table like
-- `lvim.lsp.diagnostic.signs = { text = { ERROR = "X" } }` merges per-key
-- against the string-keyed defaults rather than landing as a list-shape that
-- clobbers the other three glyphs.
--
-- Render-time lookup differs between the three sub-tables, though:
--   * `signs.text` — the renderer (`runtime/lua/vim/diagnostic.lua`
--     `handlers.signs.show`) tries `text[diagnostic.severity]` (numeric) then
--     falls back to `text[M.severity[diagnostic.severity]]` (string), so a
--     string-keyed `text` works as-is.
--   * `signs.numhl` / `signs.linehl` — looked up ONLY as
--     `numhl[diagnostic.severity]` / `linehl[diagnostic.severity]`, no string
--     fallback. A string-keyed numhl/linehl is silently dropped — the
--     extmark's `number_hl_group`/`line_hl_group` ends up nil.
--
-- We therefore normalize the merged signs sub-tables in `M.setup()` so each
-- string severity entry is mirrored under its numeric key (and vice versa).
-- After normalization both lookup forms resolve, so the prescribed
-- `DiagnosticSign*` highlights actually paint the line-number column.
local SIGN_TEXT = {
  ERROR = "●",
  WARN = "●",
  INFO = "●",
  HINT = "●",
}

local SIGN_NUMHL = {
  ERROR = "DiagnosticSignError",
  WARN = "DiagnosticSignWarn",
  INFO = "DiagnosticSignInfo",
  HINT = "DiagnosticSignHint",
}

local SEVERITY_NAME_TO_INDEX = {
  ERROR = vim.diagnostic.severity.ERROR,
  WARN = vim.diagnostic.severity.WARN,
  INFO = vim.diagnostic.severity.INFO,
  HINT = vim.diagnostic.severity.HINT,
}

local function normalize_signs_subkey(tbl)
  if type(tbl) ~= "table" then
    return
  end
  for name, index in pairs(SEVERITY_NAME_TO_INDEX) do
    if tbl[name] ~= nil and tbl[index] == nil then
      tbl[index] = tbl[name]
    elseif tbl[index] ~= nil and tbl[name] == nil then
      tbl[name] = tbl[index]
    end
  end
end

local DEFAULTS = {
  virtual_text = { spacing = 4, prefix = "●" },
  signs = {
    text = SIGN_TEXT,
    numhl = SIGN_NUMHL,
  },
  underline = true,
  update_in_insert = false,
  severity_sort = true,
  float = { border = "rounded", source = "always" },
}

local LEGACY_SIGNS = {
  DiagnosticSignError = "●",
  DiagnosticSignWarn = "●",
  DiagnosticSignInfo = "●",
  DiagnosticSignHint = "●",
}

function M.setup()
  local lvim_cfg = _G.lvim or {}
  local lsp_cfg = lvim_cfg.lsp or {}
  local overrides = lsp_cfg.diagnostic
  if type(overrides) ~= "table" then
    overrides = {}
  end

  -- Deep-copy DEFAULTS before merging so the subsequent in-place key
  -- normalization (and any later user mutation of the resulting config) does
  -- NOT leak into the module-level `SIGN_TEXT`/`SIGN_NUMHL` constants —
  -- `tbl_deep_extend` shares table references for keys that exist in only
  -- one source.
  local config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), overrides)
  if type(config.signs) == "table" then
    normalize_signs_subkey(config.signs.text)
    normalize_signs_subkey(config.signs.numhl)
    normalize_signs_subkey(config.signs.linehl)
  end
  vim.diagnostic.config(config)

  for name, text in pairs(LEGACY_SIGNS) do
    vim.fn.sign_define(name, { text = text, texthl = name, numhl = name })
  end
end

return M

-- Phase 4.3 + null-ls compat: register a BufWritePre autocmd that formats
-- the buffer. Preserves LunarVim's
-- `lvim.format_on_save = true|false|{ enabled, timeout_ms, filter, ... }`
-- compatibility surface.
--
-- The callback prefers conform.nvim when it is available, falling back to
-- `vim.lsp.buf.format()` when conform is not loaded (e.g. user disabled the
-- null-ls compat shim and never triggered `require("lvim.lsp.null-ls.formatters").setup{}`,
-- so conform never landed on rtp). conform's `lsp_fallback = true` means it
-- will run any user-registered formatter first (prettier-for-TS, stylua-for-Lua,
-- etc. registered via the null-ls shim) and otherwise hand off to attached
-- LSP servers — that single autocmd therefore covers both
-- "prettier formats my .ts files" AND "lua_ls formats my .lua files" from the
-- user's pre-existing CKLunarVim config.
--
-- `filter` / `exclude_clients` only apply to the LSP fallback path because
-- conform does not consume an LSP-client filter — it just runs its registered
-- formatter binaries. That divergence is documented at the field level: the
-- LunarVim filter contract is "exclude these LSP clients from the format
-- request"; conform's formatters were chosen explicitly by the user when they
-- called `formatters.setup{}` so further filtering would be surprising. If
-- the user wants per-buffer suppression they should use conform's own
-- `format_after_save = false` or set `lvim.format_on_save.enabled = false`
-- in a per-filetype autocmd.

local M = {}

local AUGROUP = "lvim_format_on_save"

-- Coerce raw `lvim.format_on_save` into a config table or nil.
--   true   -> { enabled = true, timeout_ms = 1000 }  (step contract)
--   table  -> the table itself
--   other  -> nil
local function normalize(cfg)
  if cfg == true then
    return { enabled = true, timeout_ms = 1000 }
  end
  if type(cfg) ~= "table" then
    return nil
  end
  return cfg
end

-- A user-provided `filter` replaces the default wholesale (user takes over
-- selection); otherwise `exclude_clients` builds a filter that drops named
-- clients. Returns nil when no filtering is needed — vim.lsp.buf.format then
-- formats with every attached client.
local function build_filter(cfg)
  if type(cfg.filter) == "function" then
    return cfg.filter
  end
  local exclude = cfg.exclude_clients
  if type(exclude) ~= "table" or #exclude == 0 then
    return nil
  end
  local exclude_set = {}
  for _, name in ipairs(exclude) do
    exclude_set[name] = true
  end
  return function(client)
    return not exclude_set[client.name]
  end
end

function M.setup()
  -- Clear-on-each-call gives idempotency: a re-setup (e.g. via :LvimReload
  -- toggling format_on_save) replaces the prior autocmd rather than stacking.
  -- The disabled-config branch below returns early, so the cleared group is
  -- left empty — that "group exists but no autocmds" shape is the negative
  -- acceptance contract from the step description.
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  local cfg = normalize(_G.lvim and _G.lvim.format_on_save)
  -- Gate matches LunarVim verbatim (see upstream reference under
  -- `references/` — `lua/lvim/core/autocmds.lua:192-200`
  -- `configure_format_on_save`): the table form requires `enabled` to be
  -- truthy, so
  -- `lvim.format_on_save = { timeout_ms = 5000 }` (no `enabled`) does NOT
  -- enable format-on-save.
  if not cfg or not cfg.enabled then
    return
  end

  -- LunarVim's upstream contract (`references/CKLunarVim/lua/lvim/core/autocmds.lua:170`)
  -- read the timeout as `cfg.timeout`; LunaVim canonicalises to `cfg.timeout_ms`
  -- (matches `vim.lsp.buf.format`'s argument name and conform's `timeout_ms`).
  -- Accept both for drop-in compat so a CKLunarVim user's
  -- `lvim.format_on_save = { enabled = true, timeout = 5000 }` keeps working;
  -- prefer `timeout_ms` if both are set so the canonical key wins on collision.
  local timeout_ms = cfg.timeout_ms or cfg.timeout or 1000
  local format_opts = {
    timeout_ms = timeout_ms,
    filter = build_filter(cfg),
  }

  -- `cfg.pattern` scopes the BufWritePre autocmd to specific file globs,
  -- matching CKLunarVim's contract (`references/CKLunarVim/lua/lvim/core/autocmds.lua:179`).
  -- A nil pattern leaves `nvim_create_autocmd` at its default ("*") so a
  -- user who doesn't set it keeps the format-every-buffer behavior.
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    pattern = cfg.pattern,
    desc = "lvim: format buffer (conform.nvim if available, vim.lsp.buf.format fallback) on save",
    callback = function(args)
      -- `pcall` here (not at module scope) so a fresh launch that has not
      -- yet installed conform — or a user who disabled the null-ls compat
      -- shim — still triggers the LSP-fallback path. We re-resolve on every
      -- write rather than caching: lazy.nvim's loader populates rtp
      -- on-demand, so conform may become available between calls.
      local ok, conform = pcall(require, "conform")
      if ok then
        conform.format({
          bufnr = args.buf,
          async = false,
          timeout_ms = timeout_ms,
          -- `lsp_fallback = true` lets conform run a registered formatter
          -- (e.g. prettier for TS) and fall back to LSP-server formatting
          -- for filetypes the user did NOT register a formatter for
          -- (e.g. Lua via lua_ls). That single behavior unifies the
          -- prettier-for-JS-and-lua_ls-for-Lua expectation from the
          -- CKLunarVim config without an extra autocmd.
          lsp_fallback = true,
        })
        return
      end
      vim.lsp.buf.format(format_opts)
    end,
  })
end

return M

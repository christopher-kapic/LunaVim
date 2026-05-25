-- Phase 4.1: orchestrate the LSP stack — mason → mason-lspconfig → lspconfig
-- in that fixed order.
--
-- Order is load-bearing. mason-lspconfig validates mason.has_setup at runtime
-- and warns / no-ops if mason was not initialised first (kcl-confirmed against
-- the current release: `check_and_notify_bad_setup_order` in
-- `mason-lspconfig/init.lua`). lspconfig consumes server binaries managed by
-- mason via `mason-lspconfig.ensure_installed`, so the bridge must be set up
-- before any server's `lspconfig.<name>.setup()` is invoked.
--
-- This is the sole entry point for LSP setup. `lvim.start()` calls it
-- explicitly after `plugins.load()`. The lspconfig plugin's `config` callback
-- (see `lua/lvim/plugins/modules/lspconfig.lua`) also calls it, so a `require
-- ('lspconfig')` issued from any source bootstraps the same stack. The
-- `did_setup` guard makes the second call a no-op so orchestration runs
-- exactly once per session — without it the call chain
-- `lvim.start() → setup() → require('lspconfig') → lazy config callback →
-- modules/lspconfig.setup() → setup()` would recurse.
--
-- Each plugin `require` is wrapped in `pcall` because the smoke harness boots
-- with `install.missing = false` against an isolated runtime dir — the plugin
-- sources are not on disk and `require('mason')` would otherwise raise. In a
-- real user environment with plugins installed the pcall returns the module
-- and setup proceeds normally. The `builtin_active` gates mirror the spec's
-- `enabled = gate("...")` so a user who flipped a builtin off does not see
-- the corresponding plugin attempt to load.

local M = {}

local did_setup = false

-- `builtin` is passed in (not re-read from `_G.lvim.builtin`) so a single
-- M.setup() invocation evaluates every gate against the same snapshot taken
-- at the top of M.setup(). Re-reading per call would TOCTOU against any
-- mutation that happens during setup (e.g. a plugin's lazy `config` callback
-- flipping a sibling toggle), letting a later gate disagree with an earlier
-- one that used the snapshot directly (`builtin.mason and builtin.mason.config`).
local function builtin_active(builtin, name)
  local toggle = builtin[name]
  if type(toggle) == "table" and toggle.active == false then
    return false
  end
  return true
end

function M.setup()
  if did_setup then
    return
  end
  did_setup = true

  -- Phase 4.5: apply vim.diagnostic.config + named diagnostic signs before any
  -- server attaches. Sits at the top of the orchestrator so signs/virtual_text/
  -- severity_sort/float-border are in place by the time a `vim.lsp.enable`'d
  -- server publishes its first diagnostic.
  require("lvim.lsp.diagnostics").setup()

  local lvim_cfg = _G.lvim or {}
  local lsp_cfg = lvim_cfg.lsp or {}
  local builtin = lvim_cfg.builtin or {}

  -- (a) mason: install root for external tooling (LSP/DAP/linter binaries).
  -- Forward the whole `builtin.mason` subtree (minus `active`, which is the
  -- spec gate's input rather than a mason option) so user overrides under
  -- `lvim.builtin.mason.ui.*` (e.g. `border = "rounded"`) and any other
  -- top-level mason.setup option reach `mason.setup()` verbatim. Mirrors
  -- the strip-`active`-then-forward pattern used by
  -- `lua/lvim/plugins/modules/terminal.lua`. `vim.deepcopy` so mutating the
  -- local `mason_opts` (the `active = nil` clear) does not bleed back into
  -- the shared `_G.lvim.builtin.mason` table.
  if builtin_active(builtin, "mason") then
    local mason_opts = vim.deepcopy(builtin.mason or {})
    mason_opts.active = nil
    local ok, mason = pcall(require, "mason")
    if ok then
      mason.setup(mason_opts)
    end
  end

  -- (b) mason-lspconfig: bridge populating `ensure_installed` from
  -- `lvim.lsp.ensure_installed`. Gates on the mason toggle (not its own) so
  -- disabling mason also drops the bridge, matching the spec contract pinned
  -- by check_phase_22_plugin_count's mason-off branch. The
  -- `automatic_installation` arg flows from `lvim.lsp.automatic_servers_installation`
  -- (Phase 4.2 surface): exposing the field without consuming it would leave
  -- it as a dead default.
  if builtin_active(builtin, "mason") then
    local ok, mlc = pcall(require, "mason-lspconfig")
    if ok then
      mlc.setup({
        ensure_installed = lsp_cfg.ensure_installed or {},
        automatic_installation = lsp_cfg.automatic_servers_installation or false,
      })
    end
  end

  -- (c) per-server setup via Neovim's native LSP API. The orchestrator computes
  -- a default `on_attach`/`capabilities` pair via `lvim.lsp.handlers` and lets
  -- the user override either by setting `lvim.lsp.on_attach` /
  -- `lvim.lsp.capabilities` to their own value. Per-server `config` tables in
  -- `lvim.lsp.servers` are merged on top via
  -- `tbl_deep_extend("force", { on_attach, capabilities }, config)` so a
  -- server entry can replace either field locally and add its own
  -- `settings`/`cmd`/etc. without having to repeat the defaults.
  --
  -- Uses `vim.lsp.config(name, opts)` + `vim.lsp.enable(name)` instead of the
  -- legacy `require('lspconfig')[name].setup(opts)` framework: indexing
  -- `lspconfig[name]` on Neovim 0.11+ triggers nvim-lspconfig's
  -- `vim.deprecate` warning (kcl-confirmed against the current release —
  -- the `mt:__index` metamethod in `lua/lspconfig.lua` fires
  -- `vim.deprecate(...)` on every server access on Neovim 0.11+), which
  -- violates the Phase 4 acceptance criterion that "Deprecated LSP API
  -- warnings are absent on the supported Neovim version."
  --
  -- nvim-lspconfig 2.x is now a data-only repository: it ships
  -- `lsp/<name>.lua` blueprints that Neovim auto-discovers from `runtimepath`
  -- as soon as the plugin is loaded. `require('lspconfig')` is invoked here
  -- purely for that side-effect (it triggers lazy.nvim's loader so the
  -- plugin's `lsp/` directory joins `rtp`); the returned module value is
  -- intentionally unused — indexing it is what fires the deprecation warning.
  if builtin_active(builtin, "lspconfig") then
    local ok = pcall(require, "lspconfig")
    if ok then
      local handlers = require("lvim.lsp.handlers")
      local on_attach = lsp_cfg.on_attach or handlers.make_on_attach()
      local capabilities = lsp_cfg.capabilities or handlers.make_capabilities()
      for name, config in pairs(lsp_cfg.servers or {}) do
        local merged = vim.tbl_deep_extend(
          "force",
          { on_attach = on_attach, capabilities = capabilities },
          config or {}
        )
        vim.lsp.config(name, merged)
        vim.lsp.enable(name)
      end
    end
  end
end

return M

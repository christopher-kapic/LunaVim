-- Colorscheme orchestration.
--
-- Two responsibilities split across two entry points so the lifecycle lines
-- up with the rest of LunaVim's bootstrap (see `lua/lvim/init.lua`):
--
--   * `M.config()` runs during the config-defaults phase (alongside
--     `load_defaults()`) and seeds `lvim.builtin.theme` with the per-theme
--     option subtables a user might want to override in their `config.lua`.
--     It MUST run before `load_user_config()` so user-side
--     `lvim.builtin.theme.<name>.options.*` overrides land on top of these
--     defaults rather than getting clobbered when this module deep-merges
--     them later.
--
--   * `M.setup()` runs AFTER `lazy.setup({...})`, because:
--       - The matching theme plugin (tokyonight.nvim / lunar.nvim) must be
--         on runtimepath before `require('<theme>')` can resolve and before
--         `:colorscheme <name>` finds the `colors/<name>.lua` file.
--       - User overrides applied in their `config.lua` (specifically
--         `lvim.transparent_window`) must already be in place so the
--         tokyonight `transparent` option this module forwards reflects
--         what the user actually asked for.
--     Lualine and bufferline are gated on `event = "VeryLazy"`, which fires
--     after `setup()` returns, so this module's `vim.cmd("colorscheme ...")`
--     lands first and statusline/tabline pick up the right highlight groups.
--
-- Headless mode is skipped so the smoke harness (no UI, no termguicolors)
-- doesn't emit `colorscheme` errors when the theme plugin isn't on disk
-- yet — that path matches CKLunarVim's reference behavior verbatim.

local M = {}

function M.config()
  -- Deep-merge friendly: a user who set
  -- `lvim.builtin.theme = { name = "habamax" }` in their config before this
  -- runs would lose every default below if we did a flat assign. Defaults
  -- below sit underneath whatever the user already supplied.
  local user_theme = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.theme) or {}

  local defaults = {
    name = "lunar",
    lunar = {
      options = {},
    },
    tokyonight = {
      options = {
        -- Disable tokyonight's compiled-highlight cache. Tokyonight defaults
        -- `cache = true` and persists compiled highlights under
        -- `~/.cache/lvim/tokyonight/` keyed on an options-hash, so a boot
        -- with the wrong `transparent` value (e.g. before the
        -- `theme_cfg.name`/`lvim.colorscheme` mismatch in `M.setup()` was
        -- fixed) writes a stale cache that subsequent boots happily reload
        -- — silently re-introducing the bug even after the code fix. The
        -- compile step is ~10ms so losing the cache is not a real cost,
        -- and turning it off here sidesteps the stale-cache footgun for
        -- any user who ever booted with the wrong transparent value.
        cache = false,
        -- `lvim.transparent_window` is read here, at config-defaults time,
        -- before user config has run. `M.setup()` re-resolves this table at
        -- post-lazy time (via `_G.lvim.builtin.theme.tokyonight.options`),
        -- and the user-config overrides applied between the two phases flow
        -- through naturally because `lvim.builtin.theme.tokyonight.options
        -- .transparent = lvim.transparent_window` is what gets forwarded to
        -- the plugin. If a user sets `lvim.transparent_window = true` AFTER
        -- this default has been written with `false`, the user-config phase
        -- doesn't backfill it — so we resolve `transparent` lazily in
        -- `M.setup()` rather than locking the boolean in here.
        style = "night",
        terminal_colors = true,
        styles = {
          comments = { italic = true },
          keywords = { italic = true },
          functions = {},
          variables = {},
          sidebars = "dark",
          floats = "dark",
        },
        sidebars = {
          "qf",
          "vista_kind",
          "terminal",
          "packer",
          "spectre_panel",
          "NeogitStatus",
          "help",
        },
        day_brightness = 0.3,
        hide_inactive_statusline = false,
        dim_inactive = false,
        lualine_bold = false,
        use_background = true,
      },
    },
  }

  _G.lvim.builtin.theme = vim.tbl_deep_extend("keep", user_theme, defaults)
end

function M.setup()
  -- avoid running in headless mode since it's harder to detect failures
  -- and the smoke harness doesn't need a colorscheme applied. Matches
  -- CKLunarVim's reference behavior.
  if #vim.api.nvim_list_uis() == 0 then
    return
  end

  local lvim = _G.lvim or {}
  local theme_cfg = (lvim.builtin and lvim.builtin.theme) or {}
  local colorscheme = lvim.colorscheme or ""

  -- Resolve `transparent` against the live `lvim.transparent_window`. The
  -- config-defaults seed cannot do this — user config runs between
  -- `M.config()` and `M.setup()`, and the user is allowed to flip
  -- `lvim.transparent_window` in their `config.lua` without also restating
  -- the entire `lvim.builtin.theme.tokyonight.options` table.
  if theme_cfg.tokyonight and theme_cfg.tokyonight.options then
    theme_cfg.tokyonight.options.transparent = lvim.transparent_window and true or false
  end

  -- Derive the per-theme options-key from `lvim.colorscheme`, NOT from the
  -- stale `theme_cfg.name` field. Concretely: `lvim.colorscheme =
  -- "tokyonight-night"` should pick up `lvim.builtin.theme.tokyonight.options`,
  -- and `lvim.colorscheme = "lunar"` should pick up the `lunar` subtable.
  -- The previous shape — `selected_theme = theme_cfg.name or lvim.colorscheme`
  -- — left `selected_theme = "lunar"` (the default `name`) even when the user
  -- had set `lvim.colorscheme = "tokyonight"`, so `tokyonight.setup{}` was
  -- never called and `transparent_window` silently no-op'd.
  local selected_theme
  for key, _ in pairs(theme_cfg) do
    if key ~= "name" and type(key) == "string" and vim.startswith(colorscheme, key) then
      selected_theme = key
      break
    end
  end

  if selected_theme then
    local opts_table = theme_cfg[selected_theme].options or {}
    local ok, plugin = pcall(require, selected_theme)
    if ok and type(plugin) == "table" and type(plugin.setup) == "function" then
      pcall(plugin.setup, opts_table)
    end
  end

  -- Verify the colorscheme is actually on runtimepath before invoking
  -- `:colorscheme` — otherwise Neovim raises E185, which the smoke harness
  -- treats as a stderr failure. See neovim/neovim#18201 for the canonical
  -- "is this colorscheme available" recipe.
  local colors = vim.api.nvim_get_runtime_file(("colors/%s.*"):format(lvim.colorscheme or ""), false)
  if #colors == 0 then
    return
  end

  vim.g.colors_name = lvim.colorscheme
  pcall(vim.cmd, "colorscheme " .. lvim.colorscheme)
end

return M

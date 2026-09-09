local M = {}

local AUGROUP = "lvim_nvim_lint"

-- Immutable per-linter baselines, captured the first time each name is seen.
--
-- `setup()` is not once-per-session: it runs from the plugin's lazy `config`
-- callback AND from every `linters.setup{}` call the user makes. Rebuilding an
-- override from `lint.linters[name]` would read back the definition a previous
-- pass already wrote, so `extra_args` would be appended again on each pass --
-- `shellcheck --severity warning` becomes
-- `shellcheck --severity warning --severity warning`. Copying the stock table
-- is not enough on its own; the copy has to come from a value that never
-- changes, which is what this cache holds.
--
-- `false` records "nvim-lint has no linter by this name", so a typo'd
-- registration does not re-probe the (metatable-backed, filesystem-loading)
-- `lint.linters` table on every pass.
-- The cache is stashed on the nvim-lint module table, not in a local.
--
-- A local would be re-created whenever THIS module is re-required (which
-- `:LvimReload` and `reload("lvim.plugins.modules.lint")` both do). The rebuilt
-- cache would then capture `lint.linters[name]` as it stands at that moment --
-- i.e. the already-augmented definition a previous pass wrote -- and start
-- appending `extra_args` on top of it again. Hanging the cache off `lint`
-- itself ties its lifetime to the thing whose state it describes.
local function state_for(lint)
  lint.__lvim_state = lint.__lvim_state
    or {
      -- Immutable copies of each linter definition as nvim-lint shipped it.
      baselines = {},
      -- Names LunaVim has an override installed for right now.
      overridden = {},
      -- Whether LunaVim has ever assigned `linters_by_ft`.
      managed = false,
    }
  return lint.__lvim_state
end

local function baselines_for(lint)
  return state_for(lint).baselines
end

local function baseline_for(lint, name)
  local baselines = baselines_for(lint)
  local cached = baselines[name]
  if cached == nil then
    local stock = lint.linters[name]
    if type(stock) ~= "table" then
      -- Deliberately NOT memoised. nvim-lint's `linters` table is populated
      -- lazily and a custom linter can be defined after we first looked --
      -- typically by a plugin that loads later than our first pass. Caching the
      -- miss would suppress that linter's override for the rest of the session.
      return nil
    end
    cached = vim.deepcopy(stock)
    baselines[name] = cached
  end
  return vim.deepcopy(cached)
end

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

-- Build `linters_by_ft` plus a table of per-linter definition overrides.
local function build_lint_opts(lint)
  local registry = ensure_registry().linters
  local linters_by_ft = {}
  local overrides = {}
  local ignored_conditions = {}
  local conflicts = {}
  local seen_names = {}
  local conflict_candidates = {}

  for _, entry in ipairs(registry) do
    local name = entry.name
    if name and type(entry.filetypes) == "table" and #entry.filetypes > 0 then
      for _, ft in ipairs(entry.filetypes) do
        linters_by_ft[ft] = linters_by_ft[ft] or {}
        local already_present = false
        for _, existing in ipairs(linters_by_ft[ft]) do
          if existing == name then
            already_present = true
            break
          end
        end
        if not already_present then
          table.insert(linters_by_ft[ft], name)
        end
      end

      if entry.condition ~= nil then
        ignored_conditions[#ignored_conditions + 1] = name
      end

      -- Count every registration of this name, whether or not it carries an
      -- override. A plain registration alongside an overridden one is still a
      -- conflict: nvim-lint stores one definition per name, so the override
      -- applies to the filetype that asked for stock settings too.
      seen_names[name] = (seen_names[name] or 0) + 1
      if seen_names[name] == 2 then
        conflict_candidates[#conflict_candidates + 1] = name
      end

      local extra = entry.extra_args or entry.args
      if (extra and #extra > 0) or entry.command then
        local def = baseline_for(lint, name)
        if def then
          if extra and #extra > 0 then
            def.args = vim.list_extend(vim.deepcopy(def.args or {}), extra)
          end
          if entry.command then
            def.cmd = entry.command
          end
          -- nvim-lint keys a linter's definition by NAME, not by filetype, so
          -- one linter has exactly one set of args across every filetype it
          -- runs on. null-ls allowed per-source options, so a config can
          -- legitimately register the same linter twice with different args
          -- (shellcheck for `sh` with one flag, for `bash` with another).
          -- That cannot be represented here: the last registration wins for
          -- every filetype. Warn rather than silently applying the wrong
          -- flags -- this is the one translation gap that changes behavior
          -- without any visible symptom.
          overrides[name] = def
        end
      end
    end
  end

  -- A name registered more than once conflicts only if at least one of those
  -- registrations installs an override; two plain registrations are harmless.
  for _, name in ipairs(conflict_candidates) do
    if overrides[name] then
      conflicts[#conflicts + 1] = name
    end
  end

  return linters_by_ft, overrides, ignored_conditions, conflicts
end

local warned_conditions = false
local warned_conflicts = false

function M.setup(_)
  -- Bail out BEFORE requiring nvim-lint when nothing is registered AND the
  -- plugin was never loaded. The require is what pulls the plugin off disk via
  -- lazy.nvim's loader, so checking first is the difference between "costs
  -- nothing unless used" and "every user loads a linting plugin they never
  -- configured".
  --
  -- The `package.loaded` half of the condition is what makes removal work. If
  -- nvim-lint IS already live and the registry has since gone empty -- the user
  -- deleted their `linters.setup{}` call and ran `:LvimReload` -- we must still
  -- fall through, so `linters_by_ft` is reset and the autocmd group is cleared.
  -- Returning early there would leave the previous session's linters running
  -- against a config that no longer asks for them.
  if #ensure_registry().linters == 0 and not package.loaded["lint"] then
    return
  end

  -- nvim-lint's Lua module is `lint`; `nvim-lint` is only the repo directory.
  local ok, lint = pcall(require, "lint")
  if not ok then
    -- Not an error: the shim calls this from the user's config.lua, which runs
    -- before lazy.nvim exists. The plugin's own `config = setup("lint")`
    -- callback re-enters here once its event fires, with the registry already
    -- populated, so the registration is applied then.
    return
  end

  local linters_by_ft, overrides, ignored_conditions, conflicts = build_lint_opts(lint)
  local state = state_for(lint)

  -- Restore every definition we previously overrode back to its baseline
  -- BEFORE applying the current set.
  --
  -- Writing only the new overrides is not enough. A user who drops `extra_args`
  -- from a registration and reloads would otherwise keep running with the old
  -- arguments forever: the linter no longer produces an override, so nothing
  -- overwrites the augmented definition we installed on the previous pass. The
  -- same stale definition also survives removing a linter and adding it back
  -- plainly. Reverting first makes each pass a full reconciliation rather than
  -- an append.
  for name in pairs(state.overridden) do
    local base = state.baselines[name]
    if type(base) == "table" then
      lint.linters[name] = vim.deepcopy(base)
    end
  end
  state.overridden = {}

  for name, def in pairs(overrides) do
    lint.linters[name] = def
    state.overridden[name] = true
  end

  -- Only touch `linters_by_ft` when LunaVim actually has something to say about
  -- it, or has managed it before. Unconditionally assigning would let a
  -- `:LvimReload` with no LunaVim registrations wipe a `linters_by_ft` that the
  -- user (or another plugin) configured against nvim-lint directly.
  if next(linters_by_ft) ~= nil then
    lint.linters_by_ft = linters_by_ft
    state.managed = true
  elseif state.managed then
    lint.linters_by_ft = {}
    state.managed = false
  end

  if #conflicts > 0 and not warned_conflicts then
    warned_conflicts = true
    vim.schedule(function()
      vim.notify(
        string.format(
          "lvim: %s registered more than once with different args/command. nvim-lint stores one "
            .. "definition per linter name, so the last registration wins for every filetype.",
          table.concat(conflicts, ", ")
        ),
        vim.log.levels.WARN
      )
    end)
  end

  if #ignored_conditions > 0 and not warned_conditions then
    warned_conditions = true
    vim.schedule(function()
      vim.notify(
        string.format(
          "lvim: nvim-lint has no equivalent for null-ls `condition`; it is ignored for: %s. "
            .. "Restrict these linters by filetype, or gate them from your own autocmd.",
          table.concat(ignored_conditions, ", ")
        ),
        vim.log.levels.WARN
      )
    end)
  end

  -- Recreating the group with `clear = true` drops any autocmd from a previous
  -- pass, so a reload that removed linters leaves nothing behind.
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  if next(linters_by_ft) == nil then
    return
  end

  vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost", "InsertLeave" }, {
    group = group,
    desc = "lvim: run nvim-lint for the current buffer's registered linters",
    callback = function()
      pcall(lint.try_lint)
    end,
  })
end

function M.reapply()
  if package.loaded["lint"] then
    M.setup({})
  end
end

return M

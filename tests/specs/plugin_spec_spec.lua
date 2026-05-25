-- Phase 8.3 plugin_spec_spec covers:
--   * the core spec ships the expected set of plugin entries (owner/repo
--     strings) and matches the snapshot under `tests/golden/core_plugins.txt`,
--   * the two infrastructure entries (lazy.nvim, plenary.nvim) are not
--     gated, so a user cannot accidentally disable the plugin manager,
--   * with defaults loaded, every gated entry's `enabled()` returns true,
--     and flipping `lvim.builtin.<key>.active = false` for the SPECIFIC
--     key each gate reads from (entry.name for most, "mason" for the
--     mason-lspconfig exception) drops only that one gate to false while
--     every sibling gate remains true — proving each entry's wiring is
--     independent and pointed at the right builtin key,
--   * exactly 16 of the 19 core entries are gated (pinned count guards
--     against a stray gate-removal regression that a loose `> N` floor
--     would mask),
--   * `gate()` defensively defaults to "enabled" when `_G.lvim` is nil,
--     when `_G.lvim` has no `builtin` field, when `lvim.builtin.<key>` is
--     absent, and when the toggle entry exists but is not a table
--     (preserves the first-launch install path where defaults have not
--     yet run, and tolerates partially-populated user configs),
--   * mason-lspconfig follows the documented exception — its `name` is
--     its own key (so users can flip it independently) but its `enabled`
--     reads `lvim.builtin.mason.active`,
--   * toggling `active = false` on a gated builtin reduces the
--     `final_spec()` count by exactly one (per-toggle), proving the
--     gating contract is wired both at the lazy `enabled` boundary and
--     at the `final_spec()` filter that feeds `:LvimSyncCorePlugins`,
--   * the same per-toggle final_spec contract holds exhaustively across
--     every name-keyed gated entry (not just the spot checks): for each,
--     `final_spec()` drops the matching `name` while every other name
--     remains, pinning the filter to spec.name rather than gate key,
--   * `final_spec()` filters strictly on `spec.name`, so toggling
--     `mason.active = false` drops mason itself but leaves mason-lspconfig
--     in the list (the divergence between `enabled` and `final_spec()`
--     is the documented two-layer gating design),
--   * disabling every name-keyed gated entry leaves only the two
--     non-gated infrastructure plugins behind (proves no name-keyed
--     entry sneaks past the toggle).
--
-- The golden file pins the canonical owner/repo strings in the order they
-- appear in `lua/lvim/plugins/spec.lua`. If you intentionally add/remove
-- a core plugin, regenerate the golden by listing the new repos one per
-- line and re-running `make test`. The diff assertion prints the first
-- mismatching line so a stale golden surfaces immediately.
describe("plugin_spec", function()
  local original_lvim
  -- The spec module is reloaded between tests so a previously-mutated
  -- `_G.lvim.builtin.<name>.active` cannot bleed into the next case via
  -- closures captured at require-time. (Today's `gate()` reads `_G.lvim`
  -- at call-time so this is belt-and-braces, but a future refactor that
  -- caches the table would otherwise silently break these tests.)
  local module_keys = {
    "lvim.config",
    "lvim.config.defaults",
    "lvim.plugins",
    "lvim.plugins.spec",
  }
  local original_modules = {}

  local function repo_root()
    return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
  end

  local function read_golden()
    local path = repo_root() .. "/tests/golden/core_plugins.txt"
    local f = assert(io.open(path, "r"))
    local lines = {}
    for line in f:lines() do
      if line ~= "" then
        table.insert(lines, line)
      end
    end
    f:close()
    return lines
  end

  before_each(function()
    original_lvim = _G.lvim
    _G.lvim = nil

    for _, key in ipairs(module_keys) do
      original_modules[key] = package.loaded[key]
      package.loaded[key] = nil
    end
  end)

  after_each(function()
    _G.lvim = original_lvim

    for _, key in ipairs(module_keys) do
      package.loaded[key] = original_modules[key]
      original_modules[key] = nil
    end
  end)

  it("core spec matches the golden owner/repo snapshot", function()
    local spec = require("lvim.plugins.spec")
    local actual = {}
    for _, entry in ipairs(spec) do
      table.insert(actual, entry[1])
    end

    local expected = read_golden()
    -- Diff-style assertion: report the first mismatching line so a
    -- regression surfaces the offending repo string, not just "tables
    -- are not equal".
    local max = math.max(#actual, #expected)
    for i = 1, max do
      if actual[i] ~= expected[i] then
        error(
          string.format(
            "core spec mismatch at index %d: expected %q, got %q",
            i,
            tostring(expected[i]),
            tostring(actual[i])
          )
        )
      end
    end
    -- Length parity is implied by the per-index loop above (a length
    -- mismatch surfaces at the trailing index where one side is nil),
    -- but pinning it explicitly catches the degenerate case of a
    -- zero-length golden silently agreeing with an empty spec.
    assert.equals(#expected, #actual)
  end)

  it("non-gated entries (lazy.nvim, plenary.nvim) have no enabled field", function()
    -- The two infrastructure entries (lazy.nvim itself and plenary, used as
    -- a `dependencies` value by telescope/etc.) must always load regardless
    -- of user toggles. A regression that gives them a gate would let a
    -- user accidentally disable the plugin manager. Pin the contract by
    -- asserting both entries exist by repo string and that neither carries
    -- an `enabled` key (nil, not a function and not `false`).
    local spec = require("lvim.plugins.spec")
    local by_repo = {}
    for _, entry in ipairs(spec) do
      by_repo[entry[1]] = entry
    end

    local lazy = by_repo["folke/lazy.nvim"]
    assert.is_not_nil(lazy)
    assert.is_nil(lazy.enabled)

    local plenary = by_repo["nvim-lua/plenary.nvim"]
    assert.is_not_nil(plenary)
    assert.is_nil(plenary.enabled)
  end)

  it("core spec exposes the expected named plugins", function()
    local spec = require("lvim.plugins.spec")

    local names_present = {}
    for _, entry in ipairs(spec) do
      if entry.name then
        names_present[entry.name] = true
      end
    end

    -- Representative cross-section: one from each Phase-6 module group
    -- plus the LSP triplet. Not every gated name is enumerated here —
    -- the golden snapshot above already pins the full list, and this
    -- test guards against a name-key rename (e.g. `nvimtree` →
    -- `nvim-tree`) that would silently break the `lvim.builtin.<name>`
    -- toggle contract while keeping the repo string unchanged.
    local expected_names = {
      "lazydev",
      "lspconfig",
      "mason",
      "mason-lspconfig",
      "telescope",
      "nvimtree",
      "lualine",
      "bufferline",
      "gitsigns",
      "whichkey",
      "terminal",
      "treesitter",
      "alpha",
      "comment",
      "indentlines",
      "breadcrumbs",
    }
    for _, name in ipairs(expected_names) do
      assert.is_true(
        names_present[name] == true,
        string.format("expected core spec to include named entry %q", name)
      )
    end
  end)

  it("each gated entry's enabled() reflects lvim.builtin.<name>.active", function()
    require("lvim.config").load_defaults()

    local spec = require("lvim.plugins.spec")

    local gated_count = 0
    for _, entry in ipairs(spec) do
      if type(entry.enabled) == "function" then
        gated_count = gated_count + 1
        assert.is_true(
          entry.enabled(),
          string.format("expected enabled() to be true with defaults for %q", entry.name or entry[1])
        )
      end
    end
    -- Exact count: 16 gated entries out of 19 total. The three non-gated
    -- entries are folke/lazy.nvim, nvim-lua/plenary.nvim, and
    -- stevearc/conform.nvim (the two colorschemes use `lazy = ...` rather
    -- than `enabled = function()` so they don't count toward the gated
    -- tally either, bringing the breakdown to 19 = 16 gated + 5 non-gated
    -- infrastructure). Pinning the precise number means adding a new
    -- gated entry without updating this test forces a deliberate touch
    -- here, and conversely a stray gate-removal regression is caught
    -- immediately rather than masked by a loose `> 10` floor.
    assert.equals(16, gated_count)

    -- Flip telescope off — only telescope's `enabled()` should report
    -- false; sibling gates must still report true.
    _G.lvim.builtin.telescope.active = false
    for _, entry in ipairs(spec) do
      if type(entry.enabled) == "function" then
        if entry.name == "telescope" then
          assert.is_false(entry.enabled())
        else
          assert.is_true(
            entry.enabled(),
            string.format("sibling gate %q regressed when telescope was toggled", entry.name or entry[1])
          )
        end
      end
    end
  end)

  it("every gated entry's enabled() flips independently of its siblings", function()
    -- The header comment claims that flipping the SPECIFIC builtin key
    -- each gate reads from drops only that gate while every sibling gate
    -- remains true. The "each gated entry's enabled() reflects ..." test
    -- above only flips telescope as a canary; this test exhaustively
    -- iterates every gated entry so the per-key wiring is pinned for
    -- ALL 16 gates, not just one.
    --
    -- Most gated entries use `enabled = gate(entry.name)`. The documented
    -- exception is mason-lspconfig: its name is "mason-lspconfig" but its
    -- gate reads "mason" so that disabling mason cascades to the bridge.
    -- We encode the exception in `gate_key_for` and iterate every entry,
    -- restoring the toggle after each flip so the iteration does not
    -- accumulate cross-talk between iterations.
    require("lvim.config").load_defaults()
    local spec = require("lvim.plugins.spec")

    local gate_key_for = { ["mason-lspconfig"] = "mason" }

    local function gated_entries()
      local list = {}
      for _, entry in ipairs(spec) do
        if type(entry.enabled) == "function" and entry.name then
          table.insert(list, entry)
        end
      end
      return list
    end

    local entries = gated_entries()
    assert.equals(16, #entries)

    for _, target in ipairs(entries) do
      local target_key = gate_key_for[target.name] or target.name

      _G.lvim.builtin[target_key] = _G.lvim.builtin[target_key] or {}
      _G.lvim.builtin[target_key].active = false

      assert.is_false(
        target.enabled(),
        string.format(
          "expected enabled() of %q to be false when lvim.builtin[%q].active = false",
          target.name,
          target_key
        )
      )

      for _, sibling in ipairs(entries) do
        if sibling.name ~= target.name then
          local sibling_key = gate_key_for[sibling.name] or sibling.name
          -- Skip siblings that share the same builtin key as the target
          -- (the documented mason → mason-lspconfig cascade). They are
          -- expected to flip together; the dedicated mason-lspconfig
          -- test below pins that cascade explicitly.
          if sibling_key ~= target_key then
            assert.is_true(
              sibling.enabled(),
              string.format(
                "expected sibling gate %q to stay true when only lvim.builtin[%q].active was flipped",
                sibling.name,
                target_key
              )
            )
          end
        end
      end

      _G.lvim.builtin[target_key].active = true

      assert.is_true(
        target.enabled(),
        string.format(
          "expected enabled() of %q to return to true after restoring lvim.builtin[%q].active",
          target.name,
          target_key
        )
      )
    end
  end)

  it("gate() returns true defensively when lvim.builtin.<key> is missing", function()
    -- Documented invariant in lvim/plugins/spec.lua: a missing
    -- `lvim.builtin.<key>` table is treated as "enabled". That keeps the
    -- spec usable before `load_defaults()` runs (e.g. under harness
    -- re-requires during plugin install) and tolerates future builtins
    -- added here but not yet listed in defaults.lua. Without this test,
    -- a refactor that flipped the default to "disabled" when the key is
    -- absent would silently break first-launch installation.
    _G.lvim = nil
    local spec = require("lvim.plugins.spec")
    for _, entry in ipairs(spec) do
      if type(entry.enabled) == "function" then
        assert.is_true(
          entry.enabled(),
          string.format("expected enabled() to default to true when _G.lvim is nil for %q", entry.name or entry[1])
        )
      end
    end

    -- `_G.lvim` exists but lacks a `builtin` field entirely. The
    -- `(_G.lvim and _G.lvim.builtin) or {}` fallback inside `gate()`
    -- must paper over this — without the fallback, the next index would
    -- error with "attempt to index a nil value".
    _G.lvim = {}
    for _, entry in ipairs(spec) do
      if type(entry.enabled) == "function" then
        assert.is_true(
          entry.enabled(),
          string.format(
            "expected enabled() to default to true when lvim.builtin is missing for %q",
            entry.name or entry[1]
          )
        )
      end
    end

    -- Partial-table case: `_G.lvim` exists but `lvim.builtin` is a bare
    -- table without the specific keys. Same expectation — gate defaults
    -- to enabled.
    _G.lvim = { builtin = {} }
    for _, entry in ipairs(spec) do
      if type(entry.enabled) == "function" then
        assert.is_true(
          entry.enabled(),
          string.format(
            "expected enabled() to default to true with empty lvim.builtin for %q",
            entry.name or entry[1]
          )
        )
      end
    end

    -- Toggle entry exists but is not a table — `gate()` guards with
    -- `type(toggle) == "table"` before reading `.active`, so a string
    -- or boolean in place of the expected `{ active = ... }` table is
    -- treated as "enabled" rather than erroring. Belt-and-braces against
    -- a user config that mistakenly assigns a scalar to `lvim.builtin.X`.
    _G.lvim = { builtin = { telescope = "not a table", mason = true } }
    for _, entry in ipairs(spec) do
      if type(entry.enabled) == "function" then
        assert.is_true(
          entry.enabled(),
          string.format(
            "expected enabled() to default to true when lvim.builtin.<key> is non-table for %q",
            entry.name or entry[1]
          )
        )
      end
    end
  end)

  it("mason-lspconfig is gated by lvim.builtin.mason.active", function()
    -- Documented exception: mason-lspconfig's `name` is its own key
    -- (so users can flip it independently) but its `enabled` reads
    -- `lvim.builtin.mason.active` so disabling mason drops the bridge
    -- too. This test pins both directions of that contract.
    require("lvim.config").load_defaults()

    local spec = require("lvim.plugins.spec")
    local mason_lspconfig
    for _, entry in ipairs(spec) do
      if entry.name == "mason-lspconfig" then
        mason_lspconfig = entry
        break
      end
    end
    assert.is_not_nil(mason_lspconfig)
    assert.is_true(mason_lspconfig.enabled())

    _G.lvim.builtin.mason.active = false
    assert.is_false(mason_lspconfig.enabled())
  end)

  it("toggling active = false reduces final_spec() count by exactly one per toggle", function()
    require("lvim.config").load_defaults()
    local plugins = require("lvim.plugins")

    local baseline = #plugins.final_spec()

    _G.lvim.builtin.telescope.active = false
    assert.equals(baseline - 1, #plugins.final_spec())

    _G.lvim.builtin.nvimtree.active = false
    assert.equals(baseline - 2, #plugins.final_spec())

    -- A third toggle from a different module group (statusline, not file
    -- explorer / fuzzy finder) exercises the same per-toggle delta on an
    -- entry whose builtin key (`lualine`) differs from its repo basename
    -- (`lualine.nvim`). Proves the filter keys on `spec.name`, not on the
    -- owner/repo string.
    _G.lvim.builtin.lualine.active = false
    assert.equals(baseline - 3, #plugins.final_spec())

    -- Re-enabling restores every entry — the filter is pure (no
    -- cached/sticky state), so flipping back to true brings the count
    -- to baseline.
    _G.lvim.builtin.telescope.active = true
    _G.lvim.builtin.nvimtree.active = true
    _G.lvim.builtin.lualine.active = true
    assert.equals(baseline, #plugins.final_spec())
  end)

  it("flipping each name-keyed gated entry drops exactly that entry from final_spec()", function()
    -- Exhaustive per-entry pairing for the `final_spec()` filter, parallel
    -- to the `every gated entry's enabled() flips independently of its
    -- siblings` test above which only covered the lazy `enabled` boundary.
    --
    -- For every name-keyed gated entry we flip ONLY that entry's
    -- `lvim.builtin[name].active = false` and assert:
    --   (a) `final_spec()` count drops by exactly 1,
    --   (b) the dropped entry is the one whose `name` matches the flipped
    --       key (not some bystander that happened to share a builtin key),
    --   (c) every other name-keyed entry remains in the list.
    -- This pins both halves of the contract: filter wires through, and
    -- it targets the right entry by name (not by repo string, not by
    -- gate key shared with another entry).
    --
    -- mason-lspconfig is intentionally excluded from this iteration: it
    -- is absent from `defaults.lvim.builtin` (its toggle is only
    -- materialized if the user opts in), and its lazy-boundary gate
    -- cascade with mason is already pinned by the dedicated
    -- `mason-lspconfig is gated by lvim.builtin.mason.active` test plus
    -- the `final_spec() filter keys on spec.name` test. Pulling it in
    -- here would only re-test the cascade, not add new coverage.
    require("lvim.config").load_defaults()
    local spec = require("lvim.plugins.spec")
    local plugins = require("lvim.plugins")

    local function names_in(spec_list)
      local names = {}
      for _, entry in ipairs(spec_list) do
        if entry.name then
          names[entry.name] = true
        end
      end
      return names
    end

    local named_targets = {}
    for _, entry in ipairs(spec) do
      if entry.name and entry.name ~= "mason-lspconfig" then
        table.insert(named_targets, entry.name)
      end
    end
    -- 15 = 16 gated entries minus mason-lspconfig (handled by the
    -- dedicated cascade test). If this floor moves, update both this
    -- count and the rationale comment above so the exclusion stays
    -- documented.
    assert.equals(15, #named_targets)

    local baseline = #plugins.final_spec()
    local baseline_names = names_in(plugins.final_spec())

    for _, target_name in ipairs(named_targets) do
      _G.lvim.builtin[target_name].active = false

      local after = plugins.final_spec()
      assert.equals(
        baseline - 1,
        #after,
        string.format("expected final_spec() to drop by exactly 1 when %q was flipped", target_name)
      )

      local after_names = names_in(after)
      assert.is_nil(
        after_names[target_name],
        string.format("expected %q to be absent from final_spec() after flipping", target_name)
      )

      for sibling_name in pairs(baseline_names) do
        if sibling_name ~= target_name then
          assert.is_true(
            after_names[sibling_name] == true,
            string.format(
              "expected sibling %q to stay in final_spec() when only %q was flipped",
              sibling_name,
              target_name
            )
          )
        end
      end

      _G.lvim.builtin[target_name].active = true
      assert.equals(
        baseline,
        #plugins.final_spec(),
        string.format("expected final_spec() count to return to baseline after restoring %q", target_name)
      )
    end
  end)

  it("final_spec() filter keys on spec.name, so mason.active = false does not drop mason-lspconfig", function()
    -- The Phase 1 contract documented in `lua/lvim/plugins/init.lua` and
    -- `lua/lvim/plugins/spec.lua`: `final_spec()` matches on `spec.name`
    -- only. mason-lspconfig's `name` is `"mason-lspconfig"`, so disabling
    -- `lvim.builtin.mason.active` removes mason itself but keeps the
    -- bridge entry in `final_spec()`. (lazy.nvim then drops the bridge
    -- at install time via its `enabled = gate("mason")` callback — that
    -- divergence is the entire point of the two-layer gating split.)
    --
    -- Without this assertion a refactor that started honoring `enabled`
    -- inside `final_spec()` would pass every other test in this file
    -- while silently changing what `:LvimSyncCorePlugins` iterates over.
    require("lvim.config").load_defaults()
    local plugins = require("lvim.plugins")

    local function names_in(spec_list)
      local names = {}
      for _, entry in ipairs(spec_list) do
        if entry.name then
          names[entry.name] = true
        end
      end
      return names
    end

    local baseline_names = names_in(plugins.final_spec())
    assert.is_true(baseline_names["mason"] == true)
    assert.is_true(baseline_names["mason-lspconfig"] == true)

    _G.lvim.builtin.mason.active = false
    local after_names = names_in(plugins.final_spec())
    assert.is_nil(after_names["mason"])
    -- mason-lspconfig is keyed by its own name in final_spec, so it
    -- survives even though its `enabled()` callback would now return
    -- false at the lazy boundary.
    assert.is_true(after_names["mason-lspconfig"] == true)
  end)

  it("disabling every named core entry leaves only the non-gated infrastructure entries in final_spec()", function()
    -- With every name-keyed `lvim.builtin.<name>.active` flipped off,
    -- the filter should drop every name-keyed entry and leave behind
    -- only the non-gated infrastructure plugins (lazy.nvim + plenary.nvim
    -- + the two bundled colorschemes + conform.nvim). This proves the gate
    -- set covers every name-keyed entry and that no core plugin sneaks
    -- past the toggle by lacking a `name`.
    --
    -- We disable by iterating `spec.name` (not by walking `lvim.builtin`)
    -- because mason-lspconfig is intentionally absent from the defaults
    -- builtin table — its toggle key (`lvim.builtin["mason-lspconfig"]`)
    -- only materializes if the user opts to override it. Iterating
    -- `spec.name` is the only way to cover every name-keyed entry,
    -- including that exception.
    require("lvim.config").load_defaults()
    local spec = require("lvim.plugins.spec")
    local plugins = require("lvim.plugins")

    for _, entry in ipairs(spec) do
      if entry.name then
        _G.lvim.builtin[entry.name] = { active = false }
      end
    end

    local residual = plugins.final_spec()
    -- Five infrastructure entries remain: folke/lazy.nvim, the bundled
    -- tokyonight colorscheme, nvim-lua/plenary.nvim,
    -- nvim-tree/nvim-web-devicons, and stevearc/conform.nvim. They are
    -- passed through because they have no `name` field for the filter to
    -- match against — tokyonight intentionally has no
    -- `lvim.builtin.<x>.active` toggle since its own `lazy = ...`
    -- condition already controls eager-load; web-devicons is a transitive
    -- icon provider with no standalone user-facing surface; and
    -- conform.nvim is keyed entirely by what the null-ls compat shim
    -- registers (an empty registry makes its BufWritePre callback a
    -- no-op) so a builtin toggle would be redundant with the shim's own
    -- opt-in surface.
    assert.equals(5, #residual)
    local repos = {}
    for _, entry in ipairs(residual) do
      repos[entry[1]] = true
    end
    assert.is_true(repos["folke/lazy.nvim"] == true)
    assert.is_true(repos["nvim-lua/plenary.nvim"] == true)
    assert.is_true(repos["nvim-tree/nvim-web-devicons"] == true)
    assert.is_true(repos["folke/tokyonight.nvim"] == true)
    assert.is_true(repos["stevearc/conform.nvim"] == true)
  end)
end)

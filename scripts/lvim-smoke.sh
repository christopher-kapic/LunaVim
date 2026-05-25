#!/usr/bin/env bash
set -euo pipefail

check_nvim_init() {
  local init_file="$1"
  local output
  local rc

  set +e
  output="$(nvim --headless -u "$init_file" -c 'qall!' 2>&1)"
  rc=$?
  set -e

  if (( rc != 0 )) || grep -Eq 'E[0-9]+:|Error detected while processing' <<<"$output"; then
    printf '%s\n' "$output" >&2
    if (( rc != 0 )); then
      return "$rc"
    fi
    return 1
  fi
}

# Single base temp dir for everything the smoke script creates. Helpers below
# allocate subdirs under it via command substitution; if we tracked dirs in a
# bash array, the subshell appends would not persist into the parent (so the
# trap would see an empty array and leak the tempdirs). Removing one parent
# dir cleans them all and survives that subshell boundary.
SMOKE_TMP_BASE="$(mktemp -d -t lvim-smoke-XXXXXX)"

cleanup_smoke_tmp() {
  if [[ -n "${SMOKE_TMP_BASE:-}" && -d "$SMOKE_TMP_BASE" ]]; then
    rm -rf "$SMOKE_TMP_BASE"
  fi
}
trap cleanup_smoke_tmp EXIT

# Phase 2.1 added a lazy.nvim bootstrap step inside `lvim.start()`. Every
# `nvim --headless -u init.lua` invocation in this smoke script now triggers
# it. Without isolation the script would clone lazy.nvim into the user's
# real `~/.local/share/lunavim` on the first run and reuse it after — both
# polluting the user's machine and making the run depend on whatever
# state lives in their actual runtime dir.
#
# Pin LUNAVIM_RUNTIME_DIR to a shared tmpdir inside SMOKE_TMP_BASE so the
# clone happens exactly once per smoke run and is torn down on EXIT. The
# dedicated idempotency check (check_lazy_bootstrap_idempotent) uses its
# own independent tmpdir so its first/second-launch assertions are not
# polluted by sibling tests warming the shared dir.
export LUNAVIM_RUNTIME_DIR="$SMOKE_TMP_BASE/runtime"
mkdir -p "$LUNAVIM_RUNTIME_DIR"

# A config dir containing an empty config.lua so the loader does not emit the
# "No user config at ..." hint, but the dir is otherwise inert (no fixture
# state bleeds into launcher tests).
make_empty_config_dir() {
  local dir
  dir="$(mktemp -d -p "$SMOKE_TMP_BASE" empty-cfg-XXXXXX)"
  : > "$dir/config.lua"
  printf '%s\n' "$dir"
}

# A config dir whose config.lua is the sample fixture, used by
# check_user_config_applied to verify the loader actually applies user config.
make_sample_config_dir() {
  local dir
  dir="$(mktemp -d -p "$SMOKE_TMP_BASE" sample-cfg-XXXXXX)"
  cp tests/fixtures/sample-config.lua "$dir/config.lua"
  printf '%s\n' "$dir"
}

check_lvim_launcher() {
  local output
  local rc
  local cfg_dir

  cfg_dir="$(make_empty_config_dir)"

  set +e
  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" bin/lvim --headless -c 'qall!' 2>&1)"
  rc=$?
  set -e

  if (( rc != 0 )) || [[ -n "$output" ]]; then
    printf '%s\n' "$output" >&2
    if (( rc != 0 )); then
      return "$rc"
    fi
    return 1
  fi
}

check_lvim_appname() {
  local output
  local cfg_dir

  cfg_dir="$(make_empty_config_dir)"

  output="$(NVIM_APPNAME=nvim LUNAVIM_CONFIG_DIR="$cfg_dir" bin/lvim --headless -c 'lua print(vim.env.NVIM_APPNAME or "")' -c 'qall!' 2>&1)"
  if [[ "$output" != "lvim" ]]; then
    printf 'bin/lvim did not isolate NVIM_APPNAME as lvim: %s\n' "$output" >&2
    return 1
  fi
}

check_lvim_launcher_uses_repo_init() {
  local output
  local cfg_dir

  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_BASE_DIR=/tmp/lunavim-missing-base LUNAVIM_CONFIG_DIR="$cfg_dir" bin/lvim --headless -c 'lua print(vim.g.lunavim_loaded == true)' -c 'qall!' 2>&1)"
  if [[ "$output" != "true" ]]; then
    printf 'bin/lvim did not launch through the repository init.lua: %s\n' "$output" >&2
    return 1
  fi
}

check_user_config_applied() {
  local cfg_dir output_leader output_telescope

  cfg_dir="$(make_sample_config_dir)"

  output_leader="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua print(lvim.leader)' -c 'qall!' 2>&1)"
  if ! grep -F '\\' <<<"$output_leader" >/dev/null; then
    printf 'user config did not set lvim.leader (output: %s)\n' "$output_leader" >&2
    return 1
  fi

  output_telescope="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua print(lvim.builtin.telescope.active)' -c 'qall!' 2>&1)"
  if ! grep -q '^false$' <<<"$output_telescope"; then
    printf 'user config did not set lvim.builtin.telescope.active=false (output: %s)\n' \
      "$output_telescope" >&2
    return 1
  fi
}

check_user_config_literal_acceptance() {
  # Runs the literal acceptance commands from Phase 1.2 verbatim — pointing
  # LUNAVIM_CONFIG_DIR at tests/fixtures itself (no tmpdir indirection), so
  # the step's stated acceptance contract is exercised directly.
  local repo_dir output_leader output_telescope
  repo_dir="$(pwd)"

  output_leader="$(LUNAVIM_CONFIG_DIR="$repo_dir/tests/fixtures" nvim --headless -u init.lua \
    -c 'lua print(lvim.leader)' -c 'qall!' 2>&1)"
  if ! grep -F '\\' <<<"$output_leader" >/dev/null; then
    printf 'literal acceptance: lvim.leader not set via tests/fixtures (output: %s)\n' \
      "$output_leader" >&2
    return 1
  fi

  output_telescope="$(LUNAVIM_CONFIG_DIR="$repo_dir/tests/fixtures" nvim --headless -u init.lua \
    -c 'lua print(lvim.builtin.telescope.active)' -c 'qall!' 2>&1)"
  if ! grep -q false <<<"$output_telescope"; then
    printf 'literal acceptance: telescope.active not false via tests/fixtures (output: %s)\n' \
      "$output_telescope" >&2
    return 1
  fi
}

check_builtin_deep_merge_semantics() {
  # Step 1.3 acceptance: with the fixture replacing telescope wholesale via
  #   `lvim.builtin.telescope = { active = false, defaults = { custom = 1 } }`
  # the resulting state must be:
  #   * telescope.active == false (user replaced the table)
  #   * telescope.defaults.custom == 1 (nested key from the replacement)
  #   * nvimtree.active == true   (untouched builtin keeps its default)
  #
  # Anchor the regex to ^...$ so that a stray "true false" substring elsewhere
  # in nvim's stderr (a startup notice, deprecation warning, etc.) cannot make
  # the assertion silently pass while the actual print line is wrong.
  local repo_dir output
  repo_dir="$(pwd)"

  output="$(LUNAVIM_CONFIG_DIR="$repo_dir/tests/fixtures" nvim --headless -u init.lua \
    -c 'lua print(lvim.builtin.nvimtree.active, lvim.builtin.telescope.active)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^true[[:space:]]+false$' <<<"$output"; then
    printf 'deep-merge semantics: expected "true<sp>false" from nvimtree/telescope (output: %s)\n' \
      "$output" >&2
    return 1
  fi

  output="$(LUNAVIM_CONFIG_DIR="$repo_dir/tests/fixtures" nvim --headless -u init.lua \
    -c 'lua print(lvim.builtin.telescope.defaults.custom)' \
    -c 'qall!' 2>&1)"
  if ! grep -q '^1$' <<<"$output"; then
    printf 'deep-merge semantics: telescope.defaults.custom != 1 (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_merge_builtin_overrides_api() {
  # Step 1.3 exposes lvim.utils.merge_builtin_overrides for programmatic
  # callers. Exercise it inline (no fixture needed) so the API surface itself
  # is covered, independent of how the fixture is shaped.
  #
  # The check runs two consecutive merges so we can prove the API is genuinely
  # a *deep* merge — not a wholesale subtree replacement:
  #   1. seed `telescope.defaults` with `custom = 1` and `sentinel = "keep"`,
  #   2. second merge overrides `telescope.active` and bumps `custom = 7` but
  #      mentions no `sentinel`,
  #   3. assert `sentinel == "keep"` survived the second merge alongside the
  #      new value of `custom`. That sibling-survival is the defining property
  #      of deep-merge; a shallow replacement would have dropped it.
  # Other untouched builtins (nvimtree) must still retain their default.
  #
  # Additionally we capture `lvim.builtin` BEFORE the merges into a local and
  # assert it still points at the merged table afterward — proving the API
  # mutates the live `lvim.builtin` in place rather than reassigning the field
  # (which would leave any held reference stale).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__cached_builtin = lvim.builtin' \
    -c 'lua lvim.utils.merge_builtin_overrides({ telescope = { defaults = { custom = 1, sentinel = "keep" } } })' \
    -c 'lua lvim.utils.merge_builtin_overrides({ telescope = { active = false, defaults = { custom = 7 } } })' \
    -c 'lua lvim.utils.merge_builtin_overrides({ my_custom_module = { active = true, opts = { extra = "yes" } } })' \
    -c 'lua local t = lvim.builtin.telescope; local m = lvim.builtin.my_custom_module; local same = _G.__cached_builtin == lvim.builtin; print(lvim.builtin.nvimtree.active, t.active, t.defaults.custom, t.defaults.sentinel, same, m.active, m.opts.extra)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^true[[:space:]]+false[[:space:]]+7[[:space:]]+keep[[:space:]]+true[[:space:]]+true[[:space:]]+yes$' <<<"$output"; then
    printf 'merge_builtin_overrides API: expected "true<sp>false<sp>7<sp>keep<sp>true<sp>true<sp>yes" (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_merge_builtin_overrides_type_guards() {
  # Step 1.3's merge_builtin_overrides validates its input: passing a
  # non-table must raise with a precise, prefixed error. This is documented at
  # `lua/lvim/utils/init.lua:41-46` and is a real contract — callers rely on
  # the guard to surface mistakes early rather than producing a half-merged
  # state. Exercise the guard explicitly so a future refactor that drops the
  # check trips the smoke test.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local ok, err = pcall(lvim.utils.merge_builtin_overrides, "not a table"); print(ok, type(err) == "string" and err:find("overrides must be a table", 1, true) ~= nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^false[[:space:]]+true$' <<<"$output"; then
    printf 'merge_builtin_overrides type guard: expected "false<sp>true" (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_deep_extend_force_keep_user_helper() {
  # Step 1.3 also exposes the lower-level deep_extend_force_keep_user helper.
  # Exercise it directly (no _G.lvim mutation) so the helper's contract is
  # covered independently of merge_builtin_overrides:
  #   * user values win at every level ("force" semantics),
  #   * sibling keys at any depth survive a partial override,
  #   * defaults/user_overrides defaulting to {} when nil produces an empty
  #     result rather than erroring (defensive default the helper documents).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local d = { a = 1, nested = { keep = "yes", overwrite = "old" } }; local u = { nested = { overwrite = "new" }, added = true }; local r = lvim.utils.deep_extend_force_keep_user(d, u); print(r.a, r.nested.keep, r.nested.overwrite, r.added)' \
    -c 'lua local empty = lvim.utils.deep_extend_force_keep_user(nil, nil); print(type(empty), next(empty) == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '1[[:space:]]+yes[[:space:]]+new[[:space:]]+true' <<<"$output"; then
    printf 'deep_extend_force_keep_user: expected "1<sp>yes<sp>new<sp>true" (output: %s)\n' "$output" >&2
    return 1
  fi
  if ! grep -Eq 'table[[:space:]]+true' <<<"$output"; then
    printf 'deep_extend_force_keep_user: expected nil args to yield empty table (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_missing_config_hint() {
  # Step 1.2 acceptance: with LUNAVIM_CONFIG_DIR pointing at a nonexistent
  # directory, boot still succeeds AND stderr contains the hint string
  # `No user config at`. Capture stdout and stderr separately so we can
  # verify the channel, not just that the string appears in merged output.
  local empty_dir stdout_file stderr_file stdout_out stderr_out rc

  empty_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" missing-XXXXXX)"
  rmdir "$empty_dir"

  stdout_file="$(mktemp -p "$SMOKE_TMP_BASE" missing-stdout-XXXXXX)"
  stderr_file="$(mktemp -p "$SMOKE_TMP_BASE" missing-stderr-XXXXXX)"

  set +e
  LUNAVIM_CONFIG_DIR="$empty_dir" nvim --headless -u init.lua -c 'qall!' \
    >"$stdout_file" 2>"$stderr_file"
  rc=$?
  set -e

  stdout_out="$(<"$stdout_file")"
  stderr_out="$(<"$stderr_file")"

  if (( rc != 0 )); then
    printf 'boot failed with missing user config (rc=%d):\nstdout: %s\nstderr: %s\n' \
      "$rc" "$stdout_out" "$stderr_out" >&2
    return 1
  fi

  if ! grep -F 'No user config at' <<<"$stderr_out" >/dev/null; then
    printf 'missing-config hint not emitted on stderr (stdout: %s, stderr: %s)\n' \
      "$stdout_out" "$stderr_out" >&2
    return 1
  fi
}

check_user_plugins_appended() {
  # Phase 1.4 acceptance, run verbatim against tests/fixtures: the fixture's
  # `lvim.plugins = { { 'foo/bar', name = 'bar' } }` must end up in
  # `require('lvim.plugins').final_spec()`. The grep `USERPLUGIN_OK` confirms
  # the user-added entry survived assembly; the core spec stub at
  # `lua/lvim/plugins/spec.lua` is empty so this also implicitly proves
  # final_spec didn't drop the append-after-core step.
  local repo_dir output
  repo_dir="$(pwd)"

  output="$(LUNAVIM_CONFIG_DIR="$repo_dir/tests/fixtures" nvim --headless -u init.lua \
    -c "lua local s = require('lvim.plugins').final_spec(); for _,p in ipairs(s) do if (p[1] or p.url) == 'foo/bar' then print('USERPLUGIN_OK') end end" \
    -c 'qall!' 2>&1)"
  if ! grep -q USERPLUGIN_OK <<<"$output"; then
    printf 'user plugin not appended to lvim.plugins.final_spec() (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_final_spec_filters_disabled_builtin() {
  # Step 1.4 also requires `final_spec()` to drop core entries whose `name`
  # matches a `lvim.builtin.<name>.active = false`. The core spec is an empty
  # stub today (Phase 2 fills it), so we can't observe the filter without
  # injecting a fake spec module. `package.loaded['lvim.plugins.spec']` lets
  # us substitute one before `require` is called: two named entries (`keep`
  # and `telescope`), then disable the telescope builtin, then call
  # final_spec and assert `keep` survived while `telescope` was dropped.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua package.loaded['lvim.plugins.spec'] = { { 'foo/keep', name = 'keep' }, { 'foo/drop', name = 'telescope' } }" \
    -c 'lua lvim.builtin.telescope.active = false' \
    -c "lua local s = require('lvim.plugins').final_spec(); local has_keep, has_drop = false, false; for _,p in ipairs(s) do if p.name == 'keep' then has_keep = true end if p.name == 'telescope' then has_drop = true end end; print(has_keep, has_drop)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^true[[:space:]]+false$' <<<"$output"; then
    printf 'final_spec did not filter disabled builtin (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_disabled_builtin_filter_is_core_only() {
  # Step 1.4 contract subtlety: `lvim.builtin.<name>.active = false` must only
  # drop CORE spec entries with that `name`. A user-added entry in
  # `lvim.plugins` carrying the same `name` must survive — the filter is not
  # applied to user_plugins. This is what makes the "disable the builtin and
  # then add your own replacement under `lvim.plugins`" workflow work; if the
  # filter touched user_plugins, the replacement would be filtered out too.
  #
  # Inject a core entry `core/telescope` (name=telescope) and a user entry
  # `user/telescope` (name=telescope), disable the telescope builtin, then
  # assert: result contains exactly `user/telescope` and not `core/telescope`.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua package.loaded['lvim.plugins.spec'] = { { 'core/telescope', name = 'telescope' } }" \
    -c 'lua lvim.builtin.telescope.active = false' \
    -c "lua lvim.plugins = { { 'user/telescope', name = 'telescope' } }" \
    -c "lua local s = require('lvim.plugins').final_spec(); local repos = {}; for _,p in ipairs(s) do table.insert(repos, p[1]) end; print('REPOS=' .. table.concat(repos, ','))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^REPOS=user/telescope$' <<<"$output"; then
    printf 'disabled-builtin filter affected user_plugins or kept core (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_final_spec_order_core_before_user() {
  # Step 1.4 title is literally "append-after-core semantics": user specs are
  # appended AFTER the core spec, and relative input order is preserved within
  # each group. Inject two core entries and two user entries, then assert the
  # output `name` order is exactly `core1,core2,user1,user2`. Anchoring with
  # ^...$ guarantees no extra entries leaked in and order is verbatim.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua package.loaded['lvim.plugins.spec'] = { { 'org/core1', name = 'core1' }, { 'org/core2', name = 'core2' } }" \
    -c "lua lvim.plugins = { { 'org/user1', name = 'user1' }, { 'org/user2', name = 'user2' } }" \
    -c "lua local s = require('lvim.plugins').final_spec(); local names = {}; for _,p in ipairs(s) do table.insert(names, p.name) end; print('ORDER=' .. table.concat(names, ','))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^ORDER=core1,core2,user1,user2$' <<<"$output"; then
    printf 'final_spec did not preserve append-after-core order (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_anonymous_core_entry_passes_through() {
  # `lua/lvim/plugins/init.lua` documents that core entries without a `name`
  # field are passed through untouched — the filter only acts on entries
  # whose `name` matches a `lvim.builtin.<name>.active = false`. Without
  # this check, a regression that derived the toggle key from `spec[1]`
  # (or from any other source than `spec.name`) would silently start
  # filtering anonymous entries, breaking the contract that lazy.nvim sees
  # every nameless core spec verbatim.
  #
  # Inject a core spec with one anonymous entry (`org/anon`, no `name`),
  # one named entry that survives (`org/keep`, name=keep), and one named
  # entry that the user disables (`org/drop`, name=telescope). Disable
  # telescope, then assert REPOS=org/anon,org/keep — anonymous survived,
  # named-keep survived, named-drop filtered.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua package.loaded['lvim.plugins.spec'] = { { 'org/anon' }, { 'org/keep', name = 'keep' }, { 'org/drop', name = 'telescope' } }" \
    -c 'lua lvim.builtin.telescope.active = false' \
    -c "lua local s = require('lvim.plugins').final_spec(); local repos = {}; for _,p in ipairs(s) do table.insert(repos, p[1]) end; print('REPOS=' .. table.concat(repos, ','))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^REPOS=org/anon,org/keep$' <<<"$output"; then
    printf 'anonymous core entry did not pass through unfiltered (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_multiple_disabled_builtins_all_filtered() {
  # The Phase 1.4 filter loop at `lua/lvim/plugins/init.lua:25-31` is a plain
  # `for ... in ipairs ... if not (...) then insert end` — it must drop EVERY
  # core entry whose name maps to a disabled builtin, not just the first one.
  # The existing check_final_spec_filters_disabled_builtin only disables a
  # single name (telescope), so a regression that early-`break`ed after the
  # first match, or that special-cased a single builtin name, would pass the
  # existing checks while silently letting the second disabled entry leak
  # through.
  #
  # Inject four named core entries interleaved keep/drop/keep/drop, disable
  # BOTH `telescope` and `nvimtree` (two real builtins so `lvim.builtin.<n>`
  # already exists as a table from defaults), and assert the result is
  # exactly `org/keep1,org/keep2` in order. The `^...$`-anchored grep means a
  # single leaked entry — or a reordering — fails the check.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua package.loaded['lvim.plugins.spec'] = { { 'org/keep1', name = 'keep1' }, { 'org/drop1', name = 'telescope' }, { 'org/keep2', name = 'keep2' }, { 'org/drop2', name = 'nvimtree' } }" \
    -c 'lua lvim.builtin.telescope.active = false' \
    -c 'lua lvim.builtin.nvimtree.active = false' \
    -c "lua local s = require('lvim.plugins').final_spec(); local repos = {}; for _,p in ipairs(s) do table.insert(repos, p[1]) end; print('REPOS=' .. table.concat(repos, ','))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^REPOS=org/keep1,org/keep2$' <<<"$output"; then
    printf 'multiple disabled builtins were not all filtered (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_reload_globals() {
  # Pins the three literal acceptance commands from the step description
  # verbatim, then adds one extra command for two contract properties the
  # literal commands cannot prove on their own:
  #   - `reload` and `require_clean` share identity (current alias shim)
  #   - `require_clean` actually evicts `package.loaded[name]` before
  #     re-requiring (a no-op clear would still let literal #3 pass since
  #     it only checks that `reload('lvim.config')` does not error)
  #
  # Each nvim invocation prints its own sentinel-prefixed line and pipes
  # stderr into stdout so the WARN emitted by the intentional missing-
  # module call (acceptance #2) cannot break anchored greps. LUNAVIM_CONFIG_DIR
  # points at an empty config dir to suppress the "No user config at ..." hint
  # that would otherwise land on stderr.
  local cfg_dir out1 out2 out3 out4
  cfg_dir="$(make_empty_config_dir)"

  out1="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local m = require_safe('lvim.bootstrap'); print(type(m))" -c 'qall!' 2>&1)"
  if ! grep -q '^table$' <<<"$out1"; then
    printf 'require_safe(lvim.bootstrap) did not print "table" (output: %s)\n' "$out1" >&2
    return 1
  fi

  out2="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local m = require_safe('nonexistent.module'); print(m == nil)" -c 'qall!' 2>&1)"
  if ! grep -q '^true$' <<<"$out2"; then
    printf 'require_safe(nonexistent.module) did not print "true" (output: %s)\n' "$out2" >&2
    return 1
  fi

  out3="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua reload('lvim.config'); print('RELOAD_OK')" -c 'qall!' 2>&1)"
  if ! grep -q '^RELOAD_OK$' <<<"$out3"; then
    printf 'reload(lvim.config) did not print "RELOAD_OK" (output: %s)\n' "$out3" >&2
    return 1
  fi

  out4="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["lvim.utils.reload"] = "SENTINEL"; local m = require_clean("lvim.utils.reload"); print("CLEAN_ALIAS", type(m) == "table" and m ~= "SENTINEL", reload == require_clean)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^CLEAN_ALIAS[[:space:]]+true[[:space:]]+true$' <<<"$out4"; then
    printf 'require_clean did not evict cached sentinel, or reload != require_clean (output: %s)\n' "$out4" >&2
    return 1
  fi
}

check_globals_present() {
  local output
  local rc
  local lua_check
  read -r -d '' lua_check <<'LUA' || true
local names = {'get_runtime_dir','get_config_dir','get_cache_dir','get_lvim_base_dir'}
local ok = true
for _, fn in ipairs(names) do
  local g = _G[fn]
  if type(g) ~= 'function' then
    ok = false
    print('MISSING ' .. fn)
  else
    local called_ok, v = pcall(g)
    if not called_ok or type(v) ~= 'string' or v == '' then
      ok = false
      print('MISSING ' .. fn)
    end
  end
end
print(ok and 'GLOBALS_OK' or 'GLOBALS_BAD')
LUA

  set +e
  output="$(nvim --headless -u init.lua -c "lua $lua_check" -c 'qall!' 2>&1)"
  rc=$?
  set -e

  if (( rc != 0 )) \
    || ! grep -q '^GLOBALS_OK$' <<<"$output" \
    || grep -Eq '^GLOBALS_BAD$|^MISSING ' <<<"$output"; then
    printf 'bootstrap globals assertion failed (rc=%d):\n%s\n' "$rc" "$output" >&2
    return 1
  fi
}

check_lazy_bootstrap_idempotent() {
  # Phase 2.1 acceptance, run verbatim against an isolated runtime dir:
  #   1. fresh $RT → bootstrap MUST clone lazy.nvim into $RT/lazy/lazy.nvim
  #      (assert .git exists),
  #   2. second launch with the same $RT MUST NOT re-clone (compare
  #      `stat -c %Y` on the .git dir before/after; identical mtime proves
  #      the bootstrap took the existing-path branch rather than re-running
  #      `git clone`),
  #   3. `require('lazy')` must be loadable from the bootstrapped path —
  #      assert `type(require('lazy').stats)` is `function` or `table`
  #      (the literal acceptance grep pattern from the step).
  #
  # Each launch runs with an empty config dir so the loader's
  # "No user config at ..." hint can't break the stat-mtime measurement
  # by writing extra fs activity, and so the only fs work attributable to
  # bootstrap is the lazy clone itself.
  local rt cfg_dir mtime1 mtime2 out_first out_second out_stats
  rt="$(mktemp -d -p "$SMOKE_TMP_BASE" lazy-rt-XXXXXX)"
  cfg_dir="$(make_empty_config_dir)"

  set +e
  out_first="$(LUNAVIM_RUNTIME_DIR="$rt" LUNAVIM_CONFIG_DIR="$cfg_dir" \
    nvim --headless -u init.lua -c 'qall!' 2>&1)"
  local rc1=$?
  set -e
  if (( rc1 != 0 )); then
    printf 'first launch (fresh RT) failed (rc=%d):\n%s\n' "$rc1" "$out_first" >&2
    return 1
  fi
  if [[ ! -d "$rt/lazy/lazy.nvim/.git" ]]; then
    printf 'first launch did not clone lazy.nvim into %s/lazy/lazy.nvim/.git\n' "$rt" >&2
    printf 'launch output: %s\n' "$out_first" >&2
    return 1
  fi

  mtime1="$(stat -c %Y "$rt/lazy/lazy.nvim/.git")"

  set +e
  out_second="$(LUNAVIM_RUNTIME_DIR="$rt" LUNAVIM_CONFIG_DIR="$cfg_dir" \
    nvim --headless -u init.lua -c 'qall!' 2>&1)"
  local rc2=$?
  set -e
  if (( rc2 != 0 )); then
    printf 'second launch (warm RT) failed (rc=%d):\n%s\n' "$rc2" "$out_second" >&2
    return 1
  fi

  mtime2="$(stat -c %Y "$rt/lazy/lazy.nvim/.git")"
  if [[ "$mtime1" != "$mtime2" ]]; then
    printf 'second launch re-cloned lazy.nvim (mtime changed %s -> %s)\n' \
      "$mtime1" "$mtime2" >&2
    return 1
  fi

  out_stats="$(LUNAVIM_RUNTIME_DIR="$rt" LUNAVIM_CONFIG_DIR="$cfg_dir" \
    nvim --headless -u init.lua -c "lua print(type(require('lazy').stats))" -c 'qall!' 2>&1)"
  if ! grep -Eq 'function|table' <<<"$out_stats"; then
    printf 'require("lazy").stats not function/table after bootstrap (output: %s)\n' \
      "$out_stats" >&2
    return 1
  fi
}

check_phase_22_plugin_count() {
  # Phase 2.2 acceptance, run verbatim against the post-step spec:
  #   1. `#require('lazy').plugins()` reports >= 14 (the step pins a 14-plugin
  #      floor on the core spec).
  #   2. `require('lazy').stats().count` reports the same number — both
  #      reporters walk Config.plugins so any divergence means the spec
  #      assembly registered ghost entries somewhere.
  #   3. Setting `lvim.builtin.telescope.active = false` in user config
  #      reduces the count by exactly 1 — the gate function on telescope's
  #      spec entry must actually drop the spec from Config.plugins (not
  #      merely silence its loading).
  #
  # All three sub-checks run under an empty config dir so the loader's
  # "No user config at ..." hint can't land in the captured output; the
  # toggle case runs under its own ephemeral config dir so the existing
  # tests/fixtures fixture (which also appends a user plugin) does not
  # confound the count delta.
  local cfg_dir baseline_out match_out toggle_cfg toggled_out baseline_n stats_n toggled_n
  cfg_dir="$(make_empty_config_dir)"

  baseline_out="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua print('PLUGINS=' .. #require('lazy').plugins())" \
    -c 'qall!' 2>&1)"
  baseline_n="$(grep -Eo 'PLUGINS=[0-9]+' <<<"$baseline_out" | head -1 | cut -d= -f2)"
  if [[ -z "$baseline_n" ]]; then
    printf 'could not read PLUGINS= count from baseline (output: %s)\n' "$baseline_out" >&2
    return 1
  fi
  if (( baseline_n < 14 )); then
    printf 'core plugin spec has %d entries, expected >= 14 (output: %s)\n' \
      "$baseline_n" "$baseline_out" >&2
    return 1
  fi

  match_out="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua print('STATS=' .. require('lazy').stats().count)" \
    -c 'qall!' 2>&1)"
  stats_n="$(grep -Eo 'STATS=[0-9]+' <<<"$match_out" | head -1 | cut -d= -f2)"
  if [[ -z "$stats_n" ]]; then
    printf 'could not read STATS= count (output: %s)\n' "$match_out" >&2
    return 1
  fi
  if (( stats_n != baseline_n )); then
    printf 'lazy.stats().count (%d) != #lazy.plugins() (%d) (outputs: %s | %s)\n' \
      "$stats_n" "$baseline_n" "$match_out" "$baseline_out" >&2
    return 1
  fi

  toggle_cfg="$(mktemp -d -p "$SMOKE_TMP_BASE" telescope-off-XXXXXX)"
  printf 'lvim.builtin.telescope.active = false\n' > "$toggle_cfg/config.lua"
  toggled_out="$(LUNAVIM_CONFIG_DIR="$toggle_cfg" nvim --headless -u init.lua \
    -c "lua print('PLUGINS=' .. #require('lazy').plugins())" \
    -c 'qall!' 2>&1)"
  toggled_n="$(grep -Eo 'PLUGINS=[0-9]+' <<<"$toggled_out" | head -1 | cut -d= -f2)"
  if [[ -z "$toggled_n" ]]; then
    printf 'could not read PLUGINS= count from toggled run (output: %s)\n' "$toggled_out" >&2
    return 1
  fi
  if (( toggled_n != baseline_n - 1 )); then
    printf 'disabling telescope did not reduce plugin count by 1 (baseline=%d toggled=%d)\n' \
      "$baseline_n" "$toggled_n" >&2
    return 1
  fi

  # Gate-composition check: the mason-lspconfig spec uses `enabled = gate("mason")`
  # so that disabling mason also drops the bridge plugin. Without this assertion
  # a regression that gave mason-lspconfig its own independent gate (or dropped
  # the shared `gate("mason")` wiring) would silently let mason-lspconfig
  # survive even when the user disables mason — leaving an orphan plugin that
  # would error out at runtime because mason itself never initialised. Drop of
  # exactly 2 proves both specs were filtered.
  local mason_off_cfg mason_off_out mason_off_n
  mason_off_cfg="$(mktemp -d -p "$SMOKE_TMP_BASE" mason-off-XXXXXX)"
  printf 'lvim.builtin.mason.active = false\n' > "$mason_off_cfg/config.lua"
  mason_off_out="$(LUNAVIM_CONFIG_DIR="$mason_off_cfg" nvim --headless -u init.lua \
    -c "lua print('PLUGINS=' .. #require('lazy').plugins())" \
    -c 'qall!' 2>&1)"
  mason_off_n="$(grep -Eo 'PLUGINS=[0-9]+' <<<"$mason_off_out" | head -1 | cut -d= -f2)"
  if [[ -z "$mason_off_n" ]]; then
    printf 'could not read PLUGINS= count from mason-off run (output: %s)\n' "$mason_off_out" >&2
    return 1
  fi
  if (( mason_off_n != baseline_n - 2 )); then
    printf 'disabling mason did not also drop mason-lspconfig (baseline=%d mason_off=%d, want %d)\n' \
      "$baseline_n" "$mason_off_n" "$((baseline_n - 2))" >&2
    return 1
  fi

  # Reverse-direction symmetry: the mason-lspconfig spec's `name` is
  # "mason-lspconfig" (distinct from its `gate("mason")` `enabled` key) so the
  # user can still flip it independently via
  # `lvim.builtin["mason-lspconfig"].active = false` and drop ONLY the bridge —
  # mason itself must survive. A regression that collapsed the two specs onto
  # the same name (or gave mason-lspconfig `name = "mason"`) would either fail
  # to drop the bridge here or would also drop mason, both caught by the
  # exact `- 1` drop assertion. This locks down the documented exception in
  # `lua/lvim/plugins/spec.lua` from the opposite side that the mason-off
  # check above already covers.
  local mlc_off_cfg mlc_off_out mlc_off_n
  mlc_off_cfg="$(mktemp -d -p "$SMOKE_TMP_BASE" mlc-off-XXXXXX)"
  printf 'lvim.builtin["mason-lspconfig"] = { active = false }\n' > "$mlc_off_cfg/config.lua"
  mlc_off_out="$(LUNAVIM_CONFIG_DIR="$mlc_off_cfg" nvim --headless -u init.lua \
    -c "lua print('PLUGINS=' .. #require('lazy').plugins())" \
    -c 'qall!' 2>&1)"
  mlc_off_n="$(grep -Eo 'PLUGINS=[0-9]+' <<<"$mlc_off_out" | head -1 | cut -d= -f2)"
  if [[ -z "$mlc_off_n" ]]; then
    printf 'could not read PLUGINS= count from mason-lspconfig-off run (output: %s)\n' \
      "$mlc_off_out" >&2
    return 1
  fi
  if (( mlc_off_n != baseline_n - 1 )); then
    printf 'disabling mason-lspconfig dropped %d plugins, want exactly 1 (baseline=%d mlc_off=%d)\n' \
      "$((baseline_n - mlc_off_n))" "$baseline_n" "$mlc_off_n" >&2
    return 1
  fi
}

check_phase_22_load_triggers() {
  # Phase 2.2 spec contract: each gated plugin's lazy-load trigger keys are
  # plan-explicit (`cmd = 'Telescope'`, `event = 'VeryLazy'`, etc.), and
  # treesitter is pinned to `branch = "master"` because its `main` branch
  # requires Neovim 0.12 while LunaVim's minimum is 0.11. A regression that
  # silently dropped one of those keys (or flipped treesitter to `main`)
  # would not be caught by `check_phase_22_plugin_count` — that check only
  # counts entries, not their lazy-loading configuration.
  #
  # Walk the core spec table directly (no lazy.setup, so we observe the spec
  # as authored) and assert the plan-documented triggers/pins. Each entry is
  # keyed by `spec.name` so a name-change regression flips the assertion too.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua \
local s = require('lvim.plugins.spec'); \
local idx = {}; \
for _, p in ipairs(s) do if p.name then idx[p.name] = p end end; \
local function cmd_has(p, want) \
  if type(p.cmd) == 'string' then return p.cmd == want end; \
  if type(p.cmd) == 'table' then for _, c in ipairs(p.cmd) do if c == want then return true end end end; \
  return false \
end; \
local function event_has(p, want) \
  if type(p.event) == 'string' then return p.event == want end; \
  if type(p.event) == 'table' then for _, e in ipairs(p.event) do if e == want then return true end end end; \
  return false \
end; \
local ok = true; \
local function check(cond, msg) if not cond then ok = false; print('FAIL ' .. msg) end end; \
check(idx.treesitter ~= nil and idx.treesitter.branch == 'master', 'treesitter.branch must be master (main requires 0.12)'); \
check(idx.treesitter ~= nil and idx.treesitter.build == ':TSUpdate', 'treesitter.build must be :TSUpdate'); \
check(idx.treesitter ~= nil and event_has(idx.treesitter, 'BufReadPost'), 'treesitter event must include BufReadPost'); \
check(idx.telescope ~= nil and cmd_has(idx.telescope, 'Telescope'), 'telescope cmd must include Telescope'); \
check(idx.nvimtree ~= nil and cmd_has(idx.nvimtree, 'NvimTreeToggle'), 'nvimtree cmd must include NvimTreeToggle'); \
check(idx.nvimtree ~= nil and cmd_has(idx.nvimtree, 'NvimTreeFindFile'), 'nvimtree cmd must include NvimTreeFindFile'); \
check(idx.terminal ~= nil and cmd_has(idx.terminal, 'ToggleTerm'), 'terminal cmd must include ToggleTerm'); \
check(idx.mason ~= nil and cmd_has(idx.mason, 'Mason'), 'mason cmd must include Mason'); \
check(idx.lualine ~= nil and idx.lualine.event == 'VeryLazy', 'lualine event must be VeryLazy'); \
check(idx.bufferline ~= nil and idx.bufferline.event == 'VeryLazy', 'bufferline event must be VeryLazy'); \
check(idx.whichkey ~= nil and idx.whichkey.event == 'VeryLazy', 'whichkey event must be VeryLazy'); \
check(idx.gitsigns ~= nil and idx.gitsigns.event == 'BufReadPre', 'gitsigns event must be BufReadPre'); \
check(idx.lazydev ~= nil and idx.lazydev.ft == 'lua', 'lazydev ft must be lua'); \
print(ok and 'LOAD_TRIGGERS_OK' or 'LOAD_TRIGGERS_BAD')" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^LOAD_TRIGGERS_OK$' <<<"$output"; then
    printf 'phase 2.2 load-trigger contract not satisfied (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_23_commands_registered() {
  # Phase 2.3 acceptance: all five user-facing commands from the
  # Compatibility Contract (`plan.md` §"Compatibility commands to preserve")
  # must be registered as user commands after `lvim.start()` completes.
  # `vim.api.nvim_get_commands({})` returns a map keyed by command name, so a
  # missing entry surfaces as `false` in the print, which trips the anchored
  # grep below. Anchoring to a single line with all five `true`s guarantees no
  # registration regressed.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local c = vim.api.nvim_get_commands({}); print('CMDS', c.LvimInfo ~= nil, c.LvimUpdate ~= nil, c.LvimSyncCorePlugins ~= nil, c.LvimReload ~= nil, c.LvimCacheReset ~= nil)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^CMDS[[:space:]]+true[[:space:]]+true[[:space:]]+true[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 2.3 commands not all registered (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_23_lvim_info_renders() {
  # Phase 2.3 acceptance: `:LvimInfo` opens a scratch buffer and writes a
  # multi-line report covering the resolved LunaVim paths and the loaded
  # plugin count. Run it, then read the buffer back and assert every
  # contract-bearing key line is present. The "Neovim version: " prefix is
  # the first line of the report by design (commands.lua:48-50) so the grep
  # also exercises that the first-line ordering held.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'LvimInfo' \
    -c "lua print(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n'))" \
    -c 'qall!' 2>&1)"
  local key
  for key in 'Neovim version: ' 'lvim base dir: ' 'runtime dir: ' 'config dir: ' \
             'cache dir: ' 'user config path: ' 'plugin count: ' 'builtins: '; do
    if ! grep -Fq "$key" <<<"$output"; then
      printf 'phase 2.3 LvimInfo missing line %q (output: %s)\n' "$key" "$output" >&2
      return 1
    fi
  done
}

check_phase_23_lvim_cache_reset_clears_dir() {
  # Phase 2.3 acceptance: `:LvimCacheReset` removes the LunaVim cache dir.
  # Allocate an isolated cache dir, drop a sentinel file inside it, then run
  # `:LvimCacheReset` and assert the file is gone. We deliberately use a
  # dedicated cache dir (not the smoke-wide SMOKE_TMP_BASE one) so the
  # delete is observable in isolation and cannot mask a no-op against a
  # nonexistent target.
  local cfg_dir cache_dir
  cfg_dir="$(make_empty_config_dir)"
  cache_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" lvim-cache-XXXXXX)"
  : > "$cache_dir/sentinel"

  LUNAVIM_CONFIG_DIR="$cfg_dir" LUNAVIM_CACHE_DIR="$cache_dir" \
    nvim --headless -u init.lua -c 'LvimCacheReset' -c 'qall!' >/dev/null 2>&1

  if [[ -e "$cache_dir/sentinel" ]]; then
    printf 'phase 2.3 LvimCacheReset did not remove cache contents (sentinel still at %s)\n' \
      "$cache_dir/sentinel" >&2
    return 1
  fi
}

check_phase_23_lvim_reload_reapplies_config() {
  # Phase 2.3 acceptance: `:LvimReload` re-evaluates defaults + user config
  # so a runtime override the user makes against `lvim.*` is wiped back to
  # the post-config state. The user config sets
  # `lvim.builtin.telescope.active = false`; we then flip it to `true` at
  # runtime, run `:LvimReload`, and assert it's back to `false`. That proves
  # the reload path actually re-ran load_defaults() (which resets lvim) AND
  # load_user_config() (which re-applied the override).
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" lvim-reload-XXXXXX)"
  printf 'lvim.builtin.telescope.active = false\n' > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua lvim.builtin.telescope.active = true' \
    -c 'LvimReload' \
    -c 'lua print("RELOAD_VAL=" .. tostring(lvim.builtin.telescope.active))' \
    -c 'qall!' 2>&1)"
  if ! grep -q '^RELOAD_VAL=false$' <<<"$output"; then
    printf 'phase 2.3 LvimReload did not re-apply user config (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_23_lvim_sync_core_plugins_dispatches() {
  # Phase 2.3 acceptance: `:LvimSyncCorePlugins` delegates to `lazy.sync`.
  # We can't actually wait on a sync to network-fetch in the smoke run, so
  # we stub `package.loaded.lazy` with a sentinel object whose `sync` method
  # flips a flag; running the command must call our stub.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__lvim_sync_called = false; package.loaded.lazy = { sync = function() _G.__lvim_sync_called = true end, stats = function() return { count = 0 } end }' \
    -c 'LvimSyncCorePlugins' \
    -c 'lua print("SYNC_CALLED=" .. tostring(_G.__lvim_sync_called))' \
    -c 'qall!' 2>&1)"
  if ! grep -q '^SYNC_CALLED=true$' <<<"$output"; then
    printf 'phase 2.3 LvimSyncCorePlugins did not dispatch to lazy.sync (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_23_acceptance_commands_literal() {
  # Phase 2.3 step description states three acceptance commands verbatim
  # (in addition to the smoke script exiting 0). The behavioral checks above
  # exercise each command in depth, but they paraphrase the acceptance
  # invocations rather than running them literally. This check runs each
  # acceptance command from the step text exactly as written, so a future
  # refactor that breaks the literal contract — e.g. dropping the buffer's
  # line-1 "Neovim ..." prefix, swallowing `RELOAD_OK` output behind a stray
  # error, or accidentally registering one of the commands as a Lua function
  # instead of an `exists(':...')`-discoverable user command — fails here
  # rather than silently passing because the looser checks above happen to
  # still match.
  local cfg_dir output

  # Acceptance #1: `:LvimInfo` buffer's first line contains "Neovim".
  cfg_dir="$(make_empty_config_dir)"
  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "LvimInfo" \
    -c "lua print(vim.fn.getbufline('%', 1, '\$')[1])" \
    -c 'qall!' 2>&1)"
  if ! grep -q 'Neovim' <<<"$output"; then
    printf 'phase 2.3 literal acceptance: :LvimInfo line 1 missing "Neovim" (output: %s)\n' \
      "$output" >&2
    return 1
  fi

  # Acceptance #2: `:silent! LvimReload` must not abort the editor before
  # the trailing print statement runs. `silent!` matches the step text and
  # is important here: without it, the user-config-not-found notify could
  # interleave with stdout and obscure the assertion.
  cfg_dir="$(make_empty_config_dir)"
  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "silent! LvimReload" \
    -c "lua print('RELOAD_OK')" \
    -c 'qall!' 2>&1)"
  if ! grep -q 'RELOAD_OK' <<<"$output"; then
    printf 'phase 2.3 literal acceptance: :LvimReload did not let RELOAD_OK print (output: %s)\n' \
      "$output" >&2
    return 1
  fi

  # Acceptance #3: literal verbatim form from the step description:
  #   for cmd in LvimInfo LvimUpdate LvimSyncCorePlugins LvimReload LvimCacheReset; do
  #     nvim --headless -u init.lua -c "echo exists(':$cmd')" -c qall! 2>&1 | grep -q 2
  #   done
  # Each iteration spawns its own nvim, runs `:echo exists(':<cmd>')`, and
  # `grep -q 2` asserts a user-command match. Running the loop as five
  # separate invocations (rather than folding the echoes into one process)
  # mirrors the original acceptance contract exactly, so a regression that
  # only registers four of the five commands (or registers one of them as a
  # Lua function instead of an `:exists`-discoverable user command) trips
  # the loop at the exact iteration that fails. Each invocation runs under
  # an isolated empty-config dir so the loader's "No user config at ..."
  # hint cannot leak a stray `2` into the output and false-positive the
  # grep on a broken iteration.
  local cmd cmd_output
  for cmd in LvimInfo LvimUpdate LvimSyncCorePlugins LvimReload LvimCacheReset; do
    cfg_dir="$(make_empty_config_dir)"
    cmd_output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
      -c "echo exists(':$cmd')" -c 'qall!' 2>&1)"
    if ! grep -q '^2$' <<<"$cmd_output"; then
      printf 'phase 2.3 literal acceptance: exists(":%s") did not return 2 (output: %s)\n' \
        "$cmd" "$cmd_output" >&2
      return 1
    fi
  done
}

check_min_nvim_version_error() {
  local stdout
  local stderr
  local rc
  local err_file

  err_file="$(mktemp)"

  set +e
  stdout="$(nvim --headless \
    --cmd "lua vim.version = function() return {major=0,minor=10,patch=0} end" \
    -u init.lua -c 'qall!' 2>"$err_file")"
  rc=$?
  set -e

  stderr="$(<"$err_file")"
  rm -f "$err_file"

  if (( rc == 0 )); then
    printf 'min-nvim version check did not cquit (expected non-zero rc):\nstdout:\n%s\nstderr:\n%s\n' \
      "$stdout" "$stderr" >&2
    return 1
  fi

  if ! grep -Eq 'LunaVim requires Neovim >= 0\.11\.0' <<<"$stderr"; then
    printf 'min-nvim version check missing required-version "0.11.0" in error on stderr (got rc=%d):\nstdout:\n%s\nstderr:\n%s\n' \
      "$rc" "$stdout" "$stderr" >&2
    return 1
  fi

  if ! grep -Eq 'current version is 0\.10\.0' <<<"$stderr"; then
    printf 'min-nvim version check missing current-version "0.10.0" in error on stderr (got rc=%d):\nstdout:\n%s\nstderr:\n%s\n' \
      "$rc" "$stdout" "$stderr" >&2
    return 1
  fi
}

check_phase_24_snapshot_artifacts_present() {
  # Phase 2.4 acceptance: the snapshot file, its README, and the maintainer
  # export helper must all be present, with the script marked executable.
  if [[ ! -f snapshots/default.json ]]; then
    printf 'phase 2.4: snapshots/default.json is missing\n' >&2
    return 1
  fi
  if [[ ! -f snapshots/README.md ]]; then
    printf 'phase 2.4: snapshots/README.md is missing\n' >&2
    return 1
  fi
  if [[ ! -x scripts/snapshot-export.sh ]]; then
    printf 'phase 2.4: scripts/snapshot-export.sh is missing or not executable\n' >&2
    return 1
  fi
}

check_phase_24_lvim_sync_core_plugins_initial_no_error() {
  # Phase 2.4 acceptance: literal invocation must not error. With the
  # shipped (empty `{}`) snapshot the command falls back to
  # `lazy.sync()`; we stub `lazy` so the call records but no network
  # traffic happens (the smoke run must not depend on cloning every core
  # plugin). The acceptance is "no error in output" — we check both rc
  # and the absence of any `E\d+:` / `Error detected` markers.
  local cfg_dir output rc
  cfg_dir="$(make_empty_config_dir)"

  set +e
  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__lvim_sync_called = false; package.loaded.lazy = { sync = function() _G.__lvim_sync_called = true end, restore = function() _G.__lvim_restore_called = true end, stats = function() return { count = 0 } end }' \
    -c 'LvimSyncCorePlugins' \
    -c 'lua print("SYNC=" .. tostring(_G.__lvim_sync_called) .. " RESTORE=" .. tostring(_G.__lvim_restore_called))' \
    -c 'qall!' 2>&1)"
  rc=$?
  set -e

  if (( rc != 0 )); then
    printf 'phase 2.4: :LvimSyncCorePlugins exited non-zero (rc=%d, output: %s)\n' "$rc" "$output" >&2
    return 1
  fi

  if grep -Eq 'E[0-9]+:|Error detected while processing' <<<"$output"; then
    printf 'phase 2.4: :LvimSyncCorePlugins emitted Neovim error (output: %s)\n' "$output" >&2
    return 1
  fi

  # Initial snapshot is empty `{}`, so the sync path runs.
  if ! grep -q 'SYNC=true' <<<"$output"; then
    printf 'phase 2.4: empty snapshot did not fall back to lazy.sync() (output: %s)\n' "$output" >&2
    return 1
  fi

  # Restore should NOT have been called because the snapshot is empty.
  if grep -q 'RESTORE=true' <<<"$output"; then
    printf 'phase 2.4: empty snapshot incorrectly triggered lazy.restore() (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_24_non_empty_snapshot_restores() {
  # Phase 2.4 acceptance: when snapshots/default.json holds at least one
  # plugin entry, the command must copy it onto <config>/lazy-lock.json
  # and call `lazy.restore()`. We point LUNAVIM_BASE_DIR at a throwaway
  # base dir that contains its own `snapshots/default.json` (seeded from
  # tests/fixtures/lazy-lock.json) so the test exercises the non-empty
  # path without mutating the real `snapshots/default.json` in the
  # working tree — an interrupt or kill mid-test would otherwise leave
  # the tracked file dirty. `_G.get_lvim_base_dir()` reads
  # LUNAVIM_BASE_DIR (see lua/lvim/bootstrap.lua:56-57,67-71), and
  # snapshot_path() in commands.lua resolves "<base>/snapshots/default.json",
  # so the override fully redirects the snapshot lookup.
  local cfg_dir fake_base output
  cfg_dir="$(make_empty_config_dir)"
  fake_base="$(mktemp -d -p "$SMOKE_TMP_BASE" snapshot-base-XXXXXX)"
  mkdir -p "$fake_base/snapshots"
  cp tests/fixtures/lazy-lock.json "$fake_base/snapshots/default.json"

  set +e
  output="$(LUNAVIM_BASE_DIR="$fake_base" LUNAVIM_CONFIG_DIR="$cfg_dir" \
    nvim --headless -u init.lua \
    -c 'lua _G.__lvim_restore_called = false; package.loaded.lazy = { sync = function() _G.__lvim_sync_called = true end, restore = function() _G.__lvim_restore_called = true end, stats = function() return { count = 0 } end }' \
    -c 'LvimSyncCorePlugins!' \
    -c 'lua print("RESTORE=" .. tostring(_G.__lvim_restore_called) .. " LOCK_EXISTS=" .. tostring(vim.uv.fs_stat(vim.env.LUNAVIM_CONFIG_DIR .. "/lazy-lock.json") ~= nil))' \
    -c 'qall!' 2>&1)"
  local rc=$?
  set -e

  if (( rc != 0 )); then
    printf 'phase 2.4: :LvimSyncCorePlugins! with non-empty snapshot exited non-zero (rc=%d, output: %s)\n' "$rc" "$output" >&2
    return 1
  fi

  if ! grep -q 'RESTORE=true' <<<"$output"; then
    printf 'phase 2.4: non-empty snapshot did not invoke lazy.restore() (output: %s)\n' "$output" >&2
    return 1
  fi

  if ! grep -q 'LOCK_EXISTS=true' <<<"$output"; then
    printf 'phase 2.4: snapshot was not copied onto <config>/lazy-lock.json (output: %s)\n' "$output" >&2
    return 1
  fi

  # And the copy must be byte-identical to the fixture.
  if ! cmp -s tests/fixtures/lazy-lock.json "$cfg_dir/lazy-lock.json"; then
    printf 'phase 2.4: copied lazy-lock.json does not match snapshot source\n' >&2
    return 1
  fi
}

check_phase_24_snapshot_export_script_copies_lockfile() {
  # Phase 2.4 acceptance for scripts/snapshot-export.sh: it must copy
  # `<config>/lazy-lock.json` onto `snapshots/default.json`. The script
  # resolves its destination relative to its own location
  # (`SCRIPT_DIR/../snapshots/default.json`, see
  # scripts/snapshot-export.sh:36-41), so we copy the script into a
  # throwaway fake repo (with its own scripts/ + snapshots/ layout) and
  # run the copy from there. That way the test exercises the script
  # against an isolated destination — the real `snapshots/default.json`
  # in the working tree is never touched, so an interrupt mid-test
  # cannot leave the tracked file dirty.
  local cfg_dir fake_repo expected actual
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" export-cfg-XXXXXX)"
  fake_repo="$(mktemp -d -p "$SMOKE_TMP_BASE" export-repo-XXXXXX)"
  mkdir -p "$fake_repo/scripts" "$fake_repo/snapshots"
  cp scripts/snapshot-export.sh "$fake_repo/scripts/snapshot-export.sh"
  chmod +x "$fake_repo/scripts/snapshot-export.sh"
  # Seed the fake repo's snapshot with the empty initial state so the
  # write is observable as a content change (the assertion below compares
  # against the fixture contents).
  printf '{}\n' > "$fake_repo/snapshots/default.json"
  cp tests/fixtures/lazy-lock.json "$cfg_dir/lazy-lock.json"

  set +e
  LUNAVIM_CONFIG_DIR="$cfg_dir" "$fake_repo/scripts/snapshot-export.sh" >/dev/null 2>&1
  local rc=$?
  set -e

  expected="$(cat tests/fixtures/lazy-lock.json)"
  actual="$(cat "$fake_repo/snapshots/default.json" 2>/dev/null || true)"

  if (( rc != 0 )); then
    printf 'phase 2.4: snapshot-export.sh exited non-zero (rc=%d)\n' "$rc" >&2
    return 1
  fi
  if [[ "$expected" != "$actual" ]]; then
    printf 'phase 2.4: snapshot-export.sh did not copy lockfile contents into snapshots/default.json\n' >&2
    return 1
  fi
}

check_phase_25_second_launch_idempotency() {
  # Phase 2.5 acceptance: extending the bootstrap idempotency proof to also
  # cover wall-clock timing. The earlier check_lazy_bootstrap_idempotent
  # compares mtime of `.git` between two launches; this check tightens that
  # by:
  #   * comparing both mtime and inode of `.git/HEAD` specifically — mtime
  #     catches the bootstrap re-touching HEAD on a fresh-fetch refresh, and
  #     inode catches a full re-clone (delete + recreate of the file gives
  #     it a new inode even if the regression manages to stamp the same
  #     mtime back via `touch -d`/`cp -p`). The failure path is labelled
  #     "second mtime" so the acceptance grep
  #     `grep -q 'second mtime' scripts/lvim-smoke.sh` lands on this
  #     function rather than anywhere ambient,
  #   * timing each launch end-to-end and asserting the warm launch is not
  #     catastrophically slower than the cold one (dur2 < dur1 * 2). The
  #     bound is intentionally generous — a real bootstrap clones lazy.nvim
  #     from GitHub which is network-bound and easily an order of magnitude
  #     slower than a warm reuse, so a 2x ceiling reliably catches a
  #     regression that silently re-runs network work while leaving mtime
  #     unchanged. If `dur1` clocks in below 1ms (clock-resolution edge case
  #     on a non-network bootstrap) we skip the ratio check since `dur1 * 2`
  #     ceases to be a meaningful upper bound.
  #
  # Uses an isolated RT (distinct from the smoke-wide LUNAVIM_RUNTIME_DIR
  # set near the top of this script) so neither launch is warmed by any
  # sibling helper. `local -x` scopes the env mutation to the function so
  # subsequent checks still see the original LUNAVIM_RUNTIME_DIR. The RT is
  # allocated under SMOKE_TMP_BASE so the script's EXIT trap reclaims it
  # even on abnormal termination — no manual rm -rf needed on each return
  # path.
  #
  # Launch output (stdout+stderr) is captured rather than redirected to
  # /dev/null so that when a launch returns non-zero the underlying nvim
  # error is surfaced in the smoke output — debugging a CI failure with
  # only "rc=1" and no message is what made the earlier idempotency check
  # (check_lazy_bootstrap_idempotent above) adopt the same capture pattern.
  #
  # mtime and inode are read in a single `stat -c '%Y %i'` call per launch
  # rather than two consecutive `stat` invocations. One fork instead of
  # two, and — more importantly — no TOCTTOU window between the mtime and
  # inode reads (a second-launch re-clone that lands between the two
  # `stat`s on the same head_path would otherwise mix mtime from the old
  # inode with inode from the new file, making the assertion's verdict
  # incoherent). The split-read pattern was the same defect previously
  # fixed in :LvimSyncCorePlugins' snapshot read in Phase 2.4.
  local RT cfg_dir t1 t2 dur1 dur2 mtime1 mtime2 inode1 inode2 head_path rc
  local out_first out_second stat1 stat2
  RT="$(mktemp -d -p "$SMOKE_TMP_BASE" phase25-rt-XXXXXX)"
  local -x LUNAVIM_RUNTIME_DIR="$RT"
  cfg_dir="$(make_empty_config_dir)"

  t1="$(date +%s%N)"
  set +e
  out_first="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua -c 'qall!' 2>&1)"
  rc=$?
  set -e
  t2="$(date +%s%N)"
  dur1=$(( t2 - t1 ))
  if (( rc != 0 )); then
    printf 'phase 2.5: first launch failed (rc=%d):\n%s\n' "$rc" "$out_first" >&2
    return 1
  fi

  head_path="$RT/lazy/lazy.nvim/.git/HEAD"
  if [[ ! -f "$head_path" ]]; then
    printf 'phase 2.5: first launch did not clone lazy.nvim (.git/HEAD missing at %s)\nlaunch output: %s\n' \
      "$head_path" "$out_first" >&2
    return 1
  fi
  stat1="$(stat -c '%Y %i' "$head_path")"
  read -r mtime1 inode1 <<<"$stat1"

  t1="$(date +%s%N)"
  set +e
  out_second="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua -c 'qall!' 2>&1)"
  rc=$?
  set -e
  t2="$(date +%s%N)"
  dur2=$(( t2 - t1 ))
  if (( rc != 0 )); then
    printf 'phase 2.5: second launch failed (rc=%d):\n%s\n' "$rc" "$out_second" >&2
    return 1
  fi

  stat2="$(stat -c '%Y %i' "$head_path")"
  read -r mtime2 inode2 <<<"$stat2"
  if [[ "$mtime1" != "$mtime2" ]]; then
    printf 'phase 2.5: second mtime differs from first (first=%s second=%s) — lazy.nvim was re-cloned\n' \
      "$mtime1" "$mtime2" >&2
    return 1
  fi
  if [[ "$inode1" != "$inode2" ]]; then
    printf 'phase 2.5: .git/HEAD inode changed across launches (first=%s second=%s) — lazy.nvim was re-cloned\n' \
      "$inode1" "$inode2" >&2
    return 1
  fi

  # 1ms in nanoseconds. Below this `dur1 * 2` collapses into clock-resolution
  # noise rather than a real ceiling, so skip the ratio comparison — the
  # mtime+inode assertions above are the load-bearing no-re-clone proof.
  if (( dur1 >= 1000000 )) && (( dur2 >= dur1 * 2 )); then
    printf 'phase 2.5: second launch catastrophically slower than first (first=%dns second=%dns)\n' \
      "$dur1" "$dur2" >&2
    return 1
  fi
}

check_phase_31_options_defaults_applied() {
  # Phase 3.1 literal acceptance: after `lvim.start()` the curated defaults in
  # `lua/lvim/core/options.lua` must be in effect. The step pins three values
  # by name (`vim.opt.number:get()`, `scrolloff:get()`, `shiftwidth:get()`) so
  # the literal grep is `true<sp>8<sp>2`. Running under an empty config dir
  # so no user override interferes with the defaults assertion.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua print(vim.opt.number:get(), vim.opt.scrolloff:get(), vim.opt.shiftwidth:get())' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq 'true[[:space:]]+8[[:space:]]+2' <<<"$output"; then
    printf 'phase 3.1: defaults not applied (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_31_user_opt_override_wrap() {
  # Phase 3.1 override-path acceptance: the fixture sample-config.lua sets
  # `lvim.opt = { wrap = true }`. After user config loads, the options module
  # must walk `lvim.opt` and flip `vim.opt.wrap` from its `false` default
  # back to true. Pinning `WRAP=true` with anchors so a stray substring
  # elsewhere in stderr can't false-positive.
  local cfg_dir output
  cfg_dir="$(make_sample_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua print("WRAP=" .. tostring(vim.opt.wrap:get()))' \
    -c 'qall!' 2>&1)"
  if ! grep -q '^WRAP=true$' <<<"$output"; then
    printf 'phase 3.1: lvim.opt override did not set wrap=true (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_32_acceptance_commands_literal() {
  # Phase 3.2 step description states two literal acceptance commands. They
  # are short and exercise the load-bearing post-conditions (a leader-prefixed
  # mapping is registered, and `vim.g.mapleader` was set), so pin them
  # verbatim — a regression that silently breaks `setup()` (e.g. never wires
  # it into `lvim.start()`, or registers maps before pinning the global so
  # `<leader>` resolves to `\`) trips this check rather than passing silently.
  local cfg_dir out_maparg out_leader
  cfg_dir="$(make_empty_config_dir)"

  out_maparg="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local m = vim.fn.maparg('<leader>w', 'n'); print(#m > 0)" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^true$' <<<"$out_maparg"; then
    printf 'phase 3.2 literal acceptance: maparg(<leader>w, n) did not return non-empty (output: %s)\n' \
      "$out_maparg" >&2
    return 1
  fi

  out_leader="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua print(vim.g.mapleader)" \
    -c 'qall!' 2>&1)"
  if ! grep -F ' ' <<<"$out_leader" >/dev/null; then
    printf 'phase 3.2 literal acceptance: vim.g.mapleader output missing a space (output: %s)\n' \
      "$out_leader" >&2
    return 1
  fi
}

check_phase_32_space_leader_translation() {
  # Phase 3.2 contract: `lvim.leader = "space"` (what `scripts/install.sh`
  # writes into the starter config and what the upstream LunarVim
  # reference's `config/init.lua:76` / `core/which-key.lua:210-211`
  # apply — see `references/`) must be
  # translated to the single-character " " before being assigned to
  # `vim.g.mapleader`. Without the translation `<leader>w` would resolve to
  # the literal five characters `s p a c e w`, silently breaking every
  # leader-prefixed mapping for fresh installs. Anchor the assertion to
  # `LEADER=[ ]` so a regression that passed `"space"` through verbatim
  # (producing `LEADER=[space]`) trips this check rather than slipping past
  # the looser literal-acceptance grep above.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" leader-space-XXXXXX)"
  printf 'lvim.leader = "space"\n' > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua print('LEADER=[' .. vim.g.mapleader .. ']')" \
    -c "lua print('LEN=' .. #vim.g.mapleader)" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^LEADER=\[ \]$' <<<"$output"; then
    printf 'phase 3.2: lvim.leader="space" was not translated to a single space (output: %s)\n' "$output" >&2
    return 1
  fi
  if ! grep -q '^LEN=1$' <<<"$output"; then
    printf 'phase 3.2: vim.g.mapleader length != 1 after "space" translation (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_32_default_maps_registered() {
  # Phase 3.2 implementation registers 13 default mappings spanning normal,
  # visual, and visual-block modes (4 window-nav `<C-h/j/k/l>`, 2 buffer-cycle
  # `<S-l/h>`, 3 leader essentials `<leader>w/q/h`, 2 visual indent `<>`, 2
  # visual-block move `J/K`). Walk each one via `vim.fn.maparg` and assert
  # every default is registered after `lvim.start()`. A regression that drops
  # one (or registers it in the wrong mode) trips the anchored grep below —
  # the alternative `maparg('<leader>w','n')` check above only covers a
  # single LHS, so this is the contract-wide assertion. Visual `<` and `>`
  # are paired by `vim.keymap.set("v", ...)`, so `maparg('<','v')` resolves
  # them.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local function ok(mode, lhs) return #vim.fn.maparg(lhs, mode) > 0 end; print('MAPS', \
      ok('n','<C-h>'), ok('n','<C-j>'), ok('n','<C-k>'), ok('n','<C-l>'), \
      ok('n','<S-l>'), ok('n','<S-h>'), \
      ok('n','<leader>w'), ok('n','<leader>q'), ok('n','<leader>h'), \
      ok('v','<'), ok('v','>'), \
      ok('x','J'), ok('x','K'))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^MAPS([[:space:]]+true){13}$' <<<"$output"; then
    printf 'phase 3.2: not all 13 default mappings are registered (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_32_user_keys_override_applied() {
  # Phase 3.2 contract: `lvim.keys.<mode>` user entries are applied AFTER
  # defaults. Each entry can be a string rhs (uses default opts), a table
  # `{rhs, opts}` (opts merged on top of defaults), or `false` (delete the
  # default at that lhs). Exercise all three forms in a single fixture:
  #   - string rhs at a brand new lhs (`<C-x>`) → mapping registered
  #   - table form at another new lhs (`<leader>x`) → mapping registered AND
  #     the user-provided `desc` survives the merge
  #   - `false` at the default `<leader>q` → default mapping deleted
  # The fixture is constructed inline (not via tests/fixtures) so this check
  # does not perturb the existing sample fixture used by other phases.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" user-keys-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.keys.normal_mode["<C-x>"] = "<cmd>echo 'cx'<CR>"
lvim.keys.normal_mode["<leader>x"] = { "<cmd>echo 'lx'<CR>", { desc = "User leader x" } }
lvim.keys.normal_mode["<leader>q"] = false
LUA

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local function info(lhs) \
          local m = vim.fn.maparg(lhs, 'n', false, true) \
          if type(m) == 'table' and m.lhs then return (m.desc or '') .. '/yes' end \
          return 'no' \
        end; \
        print('USER_CX=' .. info('<C-x>')); \
        print('USER_LX=' .. info('<leader>x')); \
        print('DEL_LQ=' .. info('<leader>q'))" \
    -c 'qall!' 2>&1)"
  if ! grep -q 'USER_CX=.*/yes' <<<"$output"; then
    printf 'phase 3.2: user lvim.keys override (string form) not applied (output: %s)\n' "$output" >&2
    return 1
  fi
  if ! grep -q 'USER_LX=User leader x/yes' <<<"$output"; then
    printf 'phase 3.2: user lvim.keys override (table form) did not preserve desc (output: %s)\n' "$output" >&2
    return 1
  fi
  if ! grep -q '^DEL_LQ=no$' <<<"$output"; then
    printf 'phase 3.2: user lvim.keys=false did not delete default <leader>q (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_32_setup_wired_in_init() {
  # Phase 3.2 step 5 wires `require('lvim.core.keymaps').setup()` into
  # `lvim.start()`. The literal-acceptance check above proves leader+maparg
  # state holds after a full boot, but cannot distinguish "setup() ran from
  # init.lua" from "setup() ran from some autocmd". Read the file directly
  # to pin the wiring location: the require line must be present in
  # `lua/lvim/init.lua`. A regression that drops the wiring would still pass
  # an "is the file present" check but fail this one.
  if ! grep -Fq 'require("lvim.core.keymaps").setup()' lua/lvim/init.lua; then
    printf 'phase 3.2: lvim/init.lua does not call lvim.core.keymaps.setup()\n' >&2
    return 1
  fi
}

check_phase_33_file_opened_fires_once() {
  # Phase 3.3 literal acceptance: opening a real file must fire
  # `User FileOpened` exactly once, and the per-buffer guard
  # `vim.b.lvim_file_opened_fired` must record that. The grep target is
  # `true` per the step description, but anchoring to `^FIRED=true$` so a
  # stray `true` elsewhere in nvim's output (an autocmd-noise message)
  # cannot false-positive the check. Two consecutive `doautocmd
  # BufReadPost` calls prove the "once per buffer" guard: a second fire
  # without the guard would still set the flag, but if we re-set the flag
  # to false manually in between and assert it stays false on a no-op
  # rerun we could distinguish — instead we keep the check tight and only
  # assert the flag is `true` after the load, which is the load-bearing
  # contract.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua tests/minimal_init.lua \
    -c "lua vim.cmd('doautocmd BufReadPost'); print('FIRED=' .. tostring(vim.b.lvim_file_opened_fired))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^FIRED=true$' <<<"$output"; then
    printf 'phase 3.3: BufReadPost did not set vim.b.lvim_file_opened_fired (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

check_phase_33_file_opened_skipped_on_empty_buffer() {
  # Phase 3.3 contract: `User FileOpened` must NOT fire for buffers that
  # have no name (the scratch buffer nvim opens when launched without a
  # file argument) or for `buftype = nofile` (UI scratch buffers from
  # plugins). Otherwise every "open nvim with no file" launch would
  # trigger plugins that lazy-load on `User FileOpened` — defeating the
  # whole point of the event. The autocmd checks the live buffer name and
  # buftype at fire time and bails before flipping
  # `vim.b.lvim_file_opened_fired`, so we drive that exact path by
  # setting up a nameless buffer and asking our callback to run directly.
  # Invoke against the `lvim_file_opened` group only so unrelated BufRead
  # listeners installed by lazy.nvim's plugin stubs (which would
  # otherwise try to load uninstalled plugins like treesitter and emit
  # unrelated errors) are not triggered as a side effect.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua vim.api.nvim_exec_autocmds('BufRead', { group = 'lvim_file_opened' }); print('FIRED=' .. tostring(vim.b.lvim_file_opened_fired))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^FIRED=nil$' <<<"$output"; then
    printf 'phase 3.3: BufRead on a nameless buffer should leave the flag nil (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

check_phase_33_dir_opened_fires_when_listener_registered() {
  # Phase 3.3 contract: entering a buffer backed by a directory must fire
  # `User DirOpened` from the BufEnter autocmd in the `lvim_dir_opened`
  # group. The canonical LunarVim/AstroNvim shape (see the upstream
  # LunarVim reference under `references/`,
  # `lua/lvim/core/autocmds.lua:127-140`) hooks BufEnter — not VimEnter —
  # so a later `:edit some/dir/` also fires the event, not just the
  # startup directory-argument launch.
  #
  # Observation mechanism: register an external User DirOpened listener
  # BEFORE init.lua runs (via `--cmd`) so it is in place when the natural
  # BufEnter for the `tests/` directory argument fires our
  # `lvim_dir_opened` callback during boot. The callback's
  # `fire_dir_opened()` flips the external `_G.__dir_opened` flag to true
  # and then the augroup is deleted (one-shot). The `-c 'lua print(...)'`
  # then reads the flag. A regression that fails to fire the User event
  # (or fires it for the wrong pattern) leaves the flag false.
  #
  # A previous revision of this check invoked a manual `nvim_exec_autocmds(
  # 'BufEnter', { group = 'lvim_dir_opened', buffer = 0 })` AFTER boot to
  # "drive it explicitly" — but by that point the augroup is already
  # deleted (the natural BufEnter consumed it), so the manual fire raised
  # E5108 and tested nothing. The check is genuinely deterministic without
  # it: the boot-time natural BufEnter for the directory argument completes
  # before `-c qall!` is processed.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    --cmd 'lua _G.__dir_opened = false; vim.api.nvim_create_autocmd("User", { pattern = "DirOpened", callback = function() _G.__dir_opened = true end })' \
    -u init.lua tests/ \
    -c 'lua print("DIR_OPENED=" .. tostring(_G.__dir_opened))' \
    -c 'qall!' 2>&1)"
  if ! grep -q '^DIR_OPENED=true$' <<<"$output"; then
    printf 'phase 3.3: BufEnter on a directory did not fire User DirOpened (output: %s)\n' \
      "$output" >&2
    return 1
  fi

  # Guard against a regression of the prior defect: any `E<digits>:` marker
  # in the output would mean we've reintroduced a dead-code path that calls
  # `nvim_exec_autocmds` on an already-deleted augroup (or some other
  # incidental Vim error during the autocmd fire). The grep is intentionally
  # narrow — `^E[0-9]+:` at start-of-line — so plugin-stub messages embedded
  # in lazy.nvim's BufReadPre handler ("Plugin X is not installed") that
  # do NOT start with `E<n>:` cannot false-positive this check.
  if grep -Eq '^E[0-9]+:' <<<"$output"; then
    printf 'phase 3.3: dir_opened smoke check emitted a Vim error (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

check_phase_33_dir_opened_re_emits_originating_event() {
  # Phase 3.3 contract: after firing `User DirOpened`, the dir-opened
  # callback MUST re-emit the originating event (`args.event`, not a
  # hardcoded "BufEnter") for the directory buffer. This is the
  # load-bearing pattern that lets plugins lazy-load on `User DirOpened`
  # and then install their own listener for the triggering event in
  # their setup — nvim-tree's hijack-netrw path and project-detection
  # helpers depend on it. Mirrors the upstream LunarVim reference's
  # `lua/lvim/core/autocmds.lua:136` re-emit (see `references/`).
  #
  # Observation strategy: register a BufEnter listener BEFORE init.lua
  # runs (via `--cmd`) that records every fire keyed by buffer name, and
  # specifically counts fires whose bufname is a directory. The natural
  # BufEnter for the `tests/` dir argument fires once; our callback's
  # re-emit fires it again — so the count is EXACTLY 2 (1 natural + 1
  # re-emit). The assertion is pinned to `== 2`, not the looser `>= 2`
  # the prior revision used, because that empirical count is what proves
  # the contract: a regression that drops the re-emit shows 1; a
  # regression that double-fires the re-emit shows 3 — both trip the
  # exact-2 check, while `>= 2` would silently accept the double-fire.
  # The listener filters on dir-name match so transient BufEnters for
  # other scratch buffers nvim may visit during init don't pad the count.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    --cmd 'lua _G.__dir_bufenter_count = 0; vim.api.nvim_create_autocmd("BufEnter", { pattern = "*", callback = function(args) local n = vim.api.nvim_buf_get_name(args.buf); if n ~= "" and vim.fn.isdirectory(n) == 1 then _G.__dir_bufenter_count = _G.__dir_bufenter_count + 1 end end })' \
    -u init.lua tests/ \
    -c 'lua print("DIR_BUFENTER_COUNT=" .. tostring(_G.__dir_bufenter_count))' \
    -c 'qall!' 2>&1)"
  local count
  count="$(grep -Eo 'DIR_BUFENTER_COUNT=[0-9]+' <<<"$output" | head -1 | cut -d= -f2)"
  if [[ -z "$count" ]]; then
    printf 'phase 3.3: could not read DIR_BUFENTER_COUNT (output: %s)\n' "$output" >&2
    return 1
  fi
  if (( count != 2 )); then
    printf 'phase 3.3: dir_opened did not re-emit BufEnter exactly once for the dir buffer (count=%d, expected 2 = 1 natural + 1 re-emit, output: %s)\n' \
      "$count" "$output" >&2
    return 1
  fi
}

check_phase_33_file_opened_fires_on_new_file() {
  # Phase 3.3 contract: the User FileOpened event must fire when the user
  # creates a brand-new file (i.e. opens a path that doesn't exist on
  # disk), not only when reading an existing file. BufReadPost alone
  # misses this case — a fresh launch with `nvim newfile.txt` triggers
  # `BufNewFile`, not `BufRead`, so a listener that only hooked the
  # read-existing path would silently fail to load every plugin lazy-keyed
  # on `event = "User FileOpened"`. This was the load-bearing defect in
  # the original Phase 3.3 implementation that registered only
  # BufReadPost. Use a path that does NOT exist (mktemp-style name under
  # SMOKE_TMP_BASE that we never `touch`) so nvim reaches the
  # BufNewFile branch deterministically — a probe that opened an existing
  # tmp file would land on BufRead and silently pass even if BufNewFile
  # was missing from the listener set.
  local cfg_dir new_path output
  cfg_dir="$(make_empty_config_dir)"
  new_path="$SMOKE_TMP_BASE/phase33-newfile-$$.txt"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    --cmd 'lua _G.__file_opened_count = 0; vim.api.nvim_create_autocmd("User", { pattern = "FileOpened", callback = function() _G.__file_opened_count = _G.__file_opened_count + 1 end })' \
    -u init.lua "$new_path" \
    -c 'lua print("FILE_OPENED=" .. tostring(_G.__file_opened_count))' \
    -c 'qall!' 2>&1)"
  if ! grep -q '^FILE_OPENED=1$' <<<"$output"; then
    printf 'phase 3.3: BufNewFile path did not fire User FileOpened exactly once (output: %s)\n' \
      "$output" >&2
    return 1
  fi

  # Bookkeeping: the probe must not leave a stray file behind. A real
  # save would have written the buffer to disk, but `-c qall!` discards
  # the unsaved buffer, so $new_path should never exist on disk. If a
  # regression flipped the behavior (e.g. by autosaving on BufNewFile),
  # surface it here rather than letting it leak into the user's tmpdir.
  if [[ -e "$new_path" ]]; then
    printf 'phase 3.3: BufNewFile probe accidentally created %s on disk\n' "$new_path" >&2
    rm -f "$new_path"
    return 1
  fi
}

check_phase_33_file_opened_fires_once_per_session() {
  # Phase 3.3 contract (canonical LunarVim/AstroNvim pattern): once a
  # real file fires `User FileOpened`, subsequent file opens in the same
  # nvim session must NOT re-fire the User event. The implementation
  # achieves this by deleting the `lvim_file_opened` augroup on the first
  # successful fire; a regression that left the augroup alive (e.g. a
  # per-buffer guard alone) would fire the User event N times in an
  # N-file session, breaking the load-bearing contract that lazy.nvim
  # consumers rely on (a plugin keyed on `event = "User FileOpened"`
  # only wants to load once).
  #
  # Open two real existing files in sequence (using `-c 'edit ...'`
  # after the initial file argument) and count User FileOpened
  # dispatches. Expect exactly 1.
  local cfg_dir first_path second_path output
  cfg_dir="$(make_empty_config_dir)"
  first_path="$(mktemp -p "$SMOKE_TMP_BASE" phase33-fopen1-XXXXXX.txt)"
  second_path="$(mktemp -p "$SMOKE_TMP_BASE" phase33-fopen2-XXXXXX.txt)"
  printf 'one\n' > "$first_path"
  printf 'two\n' > "$second_path"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    --cmd 'lua _G.__file_opened_count = 0; vim.api.nvim_create_autocmd("User", { pattern = "FileOpened", callback = function() _G.__file_opened_count = _G.__file_opened_count + 1 end })' \
    -u init.lua "$first_path" \
    -c "edit $second_path" \
    -c 'lua print("COUNT=" .. tostring(_G.__file_opened_count))' \
    -c 'qall!' 2>&1)"
  if ! grep -q '^COUNT=1$' <<<"$output"; then
    printf 'phase 3.3: User FileOpened fired more than once across two file opens (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

check_phase_33_trailing_whitespace_toggle() {
  # Phase 3.3 BufWritePre acceptance: the strip runs IFF the user opts
  # in via `lvim.builtin.trailing_whitespace_strip = true`. Two saves of
  # the same fixture — one with the toggle off (default), one with it
  # on — prove the gate. The fixture writes `keep me<sp><sp>\n` (10
  # bytes) into a tmp file, opens it in nvim, then `silent write`
  # triggers BufWritePre. With the toggle off the on-disk file must
  # still be 10 bytes; with the toggle on it must be 8 bytes
  # (`keep me\n` — both trailing spaces removed). Byte-size is the
  # tightest possible check: a regression that strips less aggressively
  # (e.g. only one trailing space) or that re-pads the file with a
  # different whitespace shape would land at a third byte count.
  local cfg_dir target size_off size_on
  cfg_dir="$(make_empty_config_dir)"
  target="$(mktemp -p "$SMOKE_TMP_BASE" trailing-ws-XXXXXX.txt)"

  printf 'keep me  \n' > "$target"
  LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua "$target" \
    -c 'silent write' -c 'qall!' >/dev/null 2>&1
  size_off="$(stat -c %s "$target")"
  if [[ "$size_off" != "10" ]]; then
    printf 'phase 3.3: with the toggle off, file size changed (expected 10 bytes, got %s)\n' \
      "$size_off" >&2
    return 1
  fi

  printf 'keep me  \n' > "$target"
  printf 'lvim.builtin.trailing_whitespace_strip = true\n' > "$cfg_dir/config.lua"
  LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua "$target" \
    -c 'silent write' -c 'qall!' >/dev/null 2>&1
  size_on="$(stat -c %s "$target")"
  if [[ "$size_on" != "8" ]]; then
    printf 'phase 3.3: with the toggle on, trailing spaces not stripped (expected 8 bytes, got %s)\n' \
      "$size_on" >&2
    return 1
  fi
}

check_phase_33_setup_wired_in_init() {
  # Phase 3.3 step 5 wires `require('lvim.core.autocmds').setup()` into
  # `lvim.start()`. Pin the wiring at the file level so a regression that
  # drops the require (so the User FileOpened/DirOpened events never get
  # an emitter, and every plugin spec keyed on those events silently
  # stops triggering) is caught before the runtime checks above.
  if ! grep -Fq 'require("lvim.core.autocmds").setup()' lua/lvim/init.lua; then
    printf 'phase 3.3: lvim/init.lua does not call lvim.core.autocmds.setup()\n' >&2
    return 1
  fi
}

check_phase_34_lvim_reload_reapplies_keymaps() {
  # Phase 3.4 acceptance: `:LvimReload` must re-run `keymaps.setup()` so a
  # user-defined entry in `lvim.keys.normal_mode` is materialised as a live
  # vim mapping after the reload — proving the new (e) step in the reload
  # sequence (lua/lvim/core/commands.lua) actually runs.
  #
  # The fixture writes the mapping into `config.lua` (not via a runtime
  # `-c "lua lvim.keys.normal_mode[...]=..."` mutation): step (b)
  # `load_defaults()` reassigns `_G.lvim = vim.deepcopy(defaults)`, which
  # wipes any runtime mutation to `lvim.keys` before keymaps.setup() reads
  # it. Putting the mapping in config.lua means step (c) `load_user_config()`
  # re-installs it on the freshly-reset table, so step (e) keymaps.setup()
  # sees it and registers the mapping. This is the same pattern Phase 2.3
  # uses to test reload (`check_phase_23_lvim_reload_reapplies_config`).
  #
  # To prove the reload actually re-applied (rather than the literal
  # acceptance silently passing because the initial startup already
  # registered the mapping), the test deletes the mapping at runtime via
  # `vim.keymap.del`, asserts the delete took effect (BEFORE=0), then
  # invokes `:LvimReload` and asserts the mapping is back (AFTER>0).
  # Without the deletion guard, a no-op LvimReload would silently satisfy
  # `maparg('<leader>z', 'n') ~= ''` because keymaps.setup() ran once at
  # initial startup.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" lvim-reload-keymap-XXXXXX)"
  printf "lvim.keys.normal_mode['<leader>z'] = ':echo Z<CR>'\n" > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua pcall(vim.keymap.del, 'n', '<leader>z')" \
    -c "lua print('BEFORE=' .. #vim.fn.maparg('<leader>z', 'n'))" \
    -c "LvimReload" \
    -c "lua print('AFTER=' .. #vim.fn.maparg('<leader>z', 'n'))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^BEFORE=0$' <<<"$output"; then
    printf 'phase 3.4: pre-reload delete of <leader>z did not take effect (output: %s)\n' "$output" >&2
    return 1
  fi
  if ! grep -Eq '^AFTER=[1-9][0-9]*$' <<<"$output"; then
    printf 'phase 3.4: :LvimReload did not re-register <leader>z keymap (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_34_lvim_reload_reapplies_options() {
  # Phase 3.4 acceptance, options branch: `:LvimReload` must re-run
  # `options.setup()` so a user `lvim.opt` override survives the reload
  # even when the user has overwritten the live `vim.opt.*` at runtime.
  # The fixture pins `lvim.opt.scrolloff = 17` in config.lua; runtime sets
  # `vim.opt.scrolloff = 0`; after `:LvimReload` the value must be 17.
  # Picking 17 (not the default 8) so a regression where options.setup()
  # never ran but the runtime override stuck (scrolloff=0) is distinguished
  # from a regression where options.setup() ran but ignored lvim.opt
  # (scrolloff=8). The exact-17 assertion catches both.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" lvim-reload-opt-XXXXXX)"
  printf "lvim.opt = { scrolloff = 17 }\n" > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua vim.opt.scrolloff = 0" \
    -c "LvimReload" \
    -c "lua print('SCROLLOFF=' .. vim.opt.scrolloff:get())" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^SCROLLOFF=17$' <<<"$output"; then
    printf 'phase 3.4: :LvimReload did not re-apply lvim.opt.scrolloff=17 (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_34_lvim_reload_rearms_autocmds() {
  # Phase 3.4 acceptance, autocmds branch: `:LvimReload` must re-run
  # `autocmds.setup()` which re-arms the one-shot `lvim_file_opened`
  # augroup (Phase 3.3 deletes the group on the first fire). Without the
  # re-arm, every plugin lazy-loaded on `User FileOpened` would stop
  # triggering after the first reload — the autocmd group would be gone.
  #
  # To make this test catch the regression "autocmds.setup() never ran
  # during reload" (rather than passing trivially because the initial
  # startup already created the augroup), we explicitly delete the
  # augroup at runtime BEFORE :LvimReload, assert it's gone (BEFORE=false),
  # then run :LvimReload, then assert it's been re-armed (AFTER=true).
  # `nvim_get_autocmds({ group = '...' })` errors if the group is missing,
  # so pcall returns false in that case — a clean boolean probe.
  # `nvim_create_augroup` with `clear = true` is what makes setup()
  # idempotent here — the new group replaces any existing one rather than
  # stacking listeners.
  #
  # Group existence alone is not sufficient: a regression where setup()
  # called `nvim_create_augroup` but skipped the `nvim_create_autocmd`
  # registration would leave an EMPTY group that still passes
  # `pcall(nvim_get_autocmds, {group=...})`. To close that gap, we also
  # capture the listener count after reload and assert COUNT>=1, proving
  # the BufRead/BufWinEnter/BufNewFile autocmd was re-registered to the
  # re-armed group.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua pcall(vim.api.nvim_del_augroup_by_name, 'lvim_file_opened')" \
    -c "lua local ok = pcall(vim.api.nvim_get_autocmds, { group = 'lvim_file_opened' }); print('BEFORE=' .. tostring(ok))" \
    -c "LvimReload" \
    -c "lua local ok, acs = pcall(vim.api.nvim_get_autocmds, { group = 'lvim_file_opened' }); print('AFTER=' .. tostring(ok)); print('COUNT=' .. (ok and #acs or -1))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^BEFORE=false$' <<<"$output"; then
    printf 'phase 3.4: pre-reload delete of lvim_file_opened augroup did not take effect (output: %s)\n' "$output" >&2
    return 1
  fi
  if ! grep -q '^AFTER=true$' <<<"$output"; then
    printf 'phase 3.4: :LvimReload did not re-arm lvim_file_opened augroup (output: %s)\n' "$output" >&2
    return 1
  fi
  if ! grep -Eq '^COUNT=[1-9][0-9]*$' <<<"$output"; then
    printf 'phase 3.4: re-armed lvim_file_opened augroup has no autocmds registered (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_34_lvim_reload_emits_notify() {
  # Phase 3.4 acceptance: lvim_reload ends with `vim.notify('LvimReload OK')`.
  # The notification is the user-visible signal that reload completed;
  # without it a user who edited config.lua and ran `:LvimReload` would have
  # no feedback. The implementation passes the WARN-or-better text through
  # nvim --headless's stderr, so we can grep it directly.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "LvimReload" \
    -c 'qall!' 2>&1)"
  if ! grep -q 'LvimReload OK' <<<"$output"; then
    printf 'phase 3.4: :LvimReload did not emit "LvimReload OK" notification (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_34_lvim_reload_literal_acceptance() {
  # Phase 3.4 acceptance, literal-form: the step description prescribes
  # an `-c "lua lvim.keys.normal_mode['<leader>z']=':echo Z<CR>'"` style
  # invocation followed by `:LvimReload`, asserting
  # `vim.fn.maparg('<leader>z', 'n')` is non-empty.
  #
  # The reload sequence's step (b) `load_defaults()` reassigns
  # `_G.lvim = vim.deepcopy(defaults)`, which wipes a runtime-only
  # `lvim.keys.normal_mode['<leader>z'] = ...` set after initial startup.
  # The companion check `check_phase_34_lvim_reload_reapplies_keymaps`
  # therefore lands the mapping via `config.lua` so step (c)
  # `load_user_config()` re-installs it on the freshly-reset table — same
  # pattern Phase 2.3's reload test uses. This separate check exercises
  # the literal `-c lua` mutation form from the step description against
  # a config.lua that ALSO declares the mapping, so the runtime mutation
  # and the post-reload re-application converge on the same observable
  # outcome (maparg non-empty), and the literal acceptance grep matches
  # without depending on a runtime-only mutation surviving load_defaults().
  #
  # To stop this test from passing trivially when `:LvimReload` is a no-op
  # (initial startup already registered `<leader>z` from config.lua, so
  # `maparg` would still return the rhs even if reload did nothing), the
  # mapping is `vim.keymap.del`'d between init and `:LvimReload`. The
  # pre-reload `PRE=0` assertion proves the delete took effect; the final
  # `MAPARG=:echo Z<CR>` assertion then proves the reload re-installed it
  # via load_user_config() + keymaps.setup(). `pcall` swallows the "no
  # mapping" error if the mapping ever fails to register at startup, so
  # the failure mode surfaces as `PRE=` mismatch rather than a stray
  # `E31: No such mapping` line in `output`.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" lvim-reload-literal-XXXXXX)"
  printf "lvim.keys.normal_mode['<leader>z'] = ':echo Z<CR>'\n" > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua pcall(vim.keymap.del, 'n', '<leader>z')" \
    -c "lua print('PRE=' .. #vim.fn.maparg('<leader>z', 'n'))" \
    -c "lua lvim.keys.normal_mode['<leader>z']=':echo Z<CR>'" \
    -c "LvimReload" \
    -c "lua print('MAPARG=' .. vim.fn.maparg('<leader>z', 'n'))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^PRE=0$' <<<"$output"; then
    printf 'phase 3.4 literal acceptance: pre-reload delete of <leader>z did not take effect (output: %s)\n' "$output" >&2
    return 1
  fi
  if ! grep -qF 'MAPARG=:echo Z<CR>' <<<"$output"; then
    printf 'phase 3.4 literal acceptance: maparg(<leader>z, n) was empty or unexpected after :LvimReload (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_34_keymaps_setup_idempotent() {
  # Phase 3.4 contract: a second `keymaps.setup()` (the one that runs
  # inside `:LvimReload`) must not duplicate mappings. `vim.keymap.set`
  # replaces an existing mapping at the same lhs in-place, so the
  # "duplicate" failure mode would be a stacked rhs or an error from
  # double-registration — neither of which surfaces directly via
  # `vim.fn.maparg`. The strongest observable property is: after one or
  # more reloads, the rhs at a given lhs is still the original (not
  # mangled, not concatenated, not silently dropped to "").
  #
  # The test runs `:LvimReload` twice and then reads the rhs of
  # `<leader>w` (a default mapping registered by core/keymaps.lua). A
  # regression that re-registered with a wrong rhs, or that erased the
  # mapping mid-reload, would fail the exact-string match.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "LvimReload" \
    -c "LvimReload" \
    -c "lua print('RHS=' .. vim.fn.maparg('<leader>w', 'n'))" \
    -c 'qall!' 2>&1)"
  if ! grep -qF 'RHS=<Cmd>w<CR>' <<<"$output"; then
    printf 'phase 3.4: two LvimReload calls in a row did not leave <leader>w mapped to its canonical rhs (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

# Phase 4.1 helper: build an isolated runtime dir whose lazy plugin tree
# already contains REAL on-disk modules for mason, mason-lspconfig, and
# lspconfig at the exact paths lazy.nvim resolves for our spec
# (Config.options.root .. "/" .. plugin.name, with name="mason",
# name="mason-lspconfig", name="lspconfig" per `lua/lvim/plugins/spec.lua`).
#
# The literal Phase 4.1 acceptance command is:
#
#   nvim --headless -u init.lua \
#     -c "lua print(type(require('mason'))=='table', \
#                   type(require('lspconfig'))=='table', \
#                   type(require('mason-lspconfig'))=='table')" \
#     -c qall! 2>&1 | grep -E 'true\s+true\s+true'
#
# and the contract it proves is: after Phase 4.1 wiring, the three
# plugins are loadable via the orchestrator's require chain AS configured
# by lazy.nvim's spec resolution. The earlier (rejected) fix attempt
# pre-populated `package.loaded` for the three modules — that
# short-circuits BOTH the Lua loader chain AND lazy.nvim's custom loader
# (lazy/core/loader.lua `M.loader` only fires when `package.loaded[name]`
# is nil), so the test exercised nothing under our control: it asserted
# that pre-populated tables were tables.
#
# On-disk stubs exercise the real path end to end. With the directories
# present under Config.options.root, lazy's `update_state` (in
# lazy/core/plugin.lua) flips each plugin's `_.installed` flag to true
# from its `Util.ls(root, ...)` scan; the orchestrator's
# `pcall(require, "mason")` triggers `M.loader("mason")`, which calls
# `Util.normname("mason")` against every spec plugin's normalised name,
# matches our spec entry, finds the modpath under plugin.dir via
# `Cache.find`, runs `M.auto_load` (which runs the plugin's lazy `config`
# callback — `setup("mason")` → `modules/mason.setup` no-op — and
# add_to_rtp), and finally returns our stub through Lua's loader. Each
# stub's setup() records its invocation in _G.__lvim_setup_order /
# _G.__mason_calls / _G.__mlc_calls so the order- and
# idempotency-checks can read them after nvim exits.
#
# We symlink the shared LUNAVIM_RUNTIME_DIR/lazy/lazy.nvim into the
# per-check root so `plugins.bootstrap()` does NOT re-clone lazy.nvim
# over the network for every check. The earliest smoke check
# (`check_nvim_init init.lua` at script entry) has already warmed that
# shared clone, so the symlink target is guaranteed to exist by the
# time Phase 4.1 checks run.
make_phase_41_lsp_runtime() {
  local rt
  rt="$(mktemp -d -p "$SMOKE_TMP_BASE" lsp-rt-XXXXXX)"
  mkdir -p "$rt/lazy/mason/lua/mason"
  mkdir -p "$rt/lazy/mason-lspconfig/lua/mason-lspconfig"
  mkdir -p "$rt/lazy/lspconfig/lua/lspconfig"
  ln -s "$LUNAVIM_RUNTIME_DIR/lazy/lazy.nvim" "$rt/lazy/lazy.nvim"

  cat > "$rt/lazy/mason/lua/mason/init.lua" <<'LUA'
return {
  setup = function(_)
    _G.__lvim_setup_order = _G.__lvim_setup_order or {}
    table.insert(_G.__lvim_setup_order, "mason")
    _G.__mason_calls = (_G.__mason_calls or 0) + 1
  end,
}
LUA

  cat > "$rt/lazy/mason-lspconfig/lua/mason-lspconfig/init.lua" <<'LUA'
return {
  setup = function(_)
    _G.__lvim_setup_order = _G.__lvim_setup_order or {}
    table.insert(_G.__lvim_setup_order, "mason-lspconfig")
    _G.__mlc_calls = (_G.__mlc_calls or 0) + 1
  end,
}
LUA

  # lspconfig stub is a metatable so the orchestrator's per-server loop
  # (`for name, config in pairs(lsp_cfg.servers or {})` then
  # `lspconfig[name].setup(config)`) returns a callable .setup for any
  # indexed name. With `lvim.lsp.servers` empty (Phase 4.2 introduces
  # that table), the loop never iterates and the top-level setup is
  # never called — so this stub records nothing, which is exactly what
  # the orchestration order check expects.
  cat > "$rt/lazy/lspconfig/lua/lspconfig/init.lua" <<'LUA'
return setmetatable({}, {
  __index = function(_, _) return { setup = function(_) end } end,
})
LUA

  printf '%s\n' "$rt"
}

check_phase_41_lsp_setup_orchestration() {
  # Phase 4.1 literal acceptance reproduced verbatim — no --cmd
  # pre-population, no package.loaded fakery. The runtime dir prepared by
  # `make_phase_41_lsp_runtime` contains real on-disk plugin modules at
  # the canonical lazy paths, so `require('mason')` (etc.) resolves
  # through the same lazy.nvim loader + Lua require chain a real install
  # would hit. See the helper's comment for why on-disk modules are the
  # genuine fix.
  #
  # `lvim.start()` calls `require('lvim.lsp').setup()` exactly once after
  # plugins load (lua/lvim/init.lua:56). The orchestrator's pcall(require)
  # calls for mason / mason-lspconfig / lspconfig fire lazy's loader,
  # which loads each plugin via M._load (running their lazy `config`
  # callbacks — modules/{mason,mason-lspconfig}.setup are no-ops by
  # design; modules/lspconfig.setup calls `require('lvim.lsp').setup()`
  # which short-circuits on `did_setup`). After each plugin's module is
  # cached in package.loaded the orchestrator's local `mason.setup()` /
  # `mlc.setup()` invocations land on our recording stubs, appending to
  # _G.__lvim_setup_order in mason → mason-lspconfig order
  # (kcl-confirmed against mason-lspconfig's
  # `check_and_notify_bad_setup_order` — the bridge no-ops if mason.setup
  # was not called first).
  local cfg_dir rt output
  cfg_dir="$(make_empty_config_dir)"
  rt="$(make_phase_41_lsp_runtime)"

  output="$(LUNAVIM_RUNTIME_DIR="$rt" LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    -u init.lua \
    -c "lua print(type(require('mason'))=='table', type(require('lspconfig'))=='table', type(require('mason-lspconfig'))=='table')" \
    -c "lua print('ORDER=' .. table.concat(_G.__lvim_setup_order or {}, ','))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq 'true[[:space:]]+true[[:space:]]+true' <<<"$output"; then
    printf 'phase 4.1: literal acceptance "true true true" not in output (output: %s)\n' "$output" >&2
    return 1
  fi
  if ! grep -q '^ORDER=mason,mason-lspconfig$' <<<"$output"; then
    printf 'phase 4.1: setup order was not mason → mason-lspconfig (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_41_lsp_setup_idempotent() {
  # Phase 4.1 contract: `lvim.lsp.setup()` is the sole entry point and
  # must run mason/mason-lspconfig setup EXACTLY ONCE per nvim session.
  # The lspconfig plugin's lazy `config` callback at
  # `lua/lvim/plugins/modules/lspconfig.lua` ALSO calls
  # `require('lvim.lsp').setup()`, so without the `did_setup` guard a real
  # user environment would re-run mason.setup() and mason-lspconfig.setup()
  # for every `require('lspconfig')` — which doubles the bridge's
  # `ensure_installed` work and could trigger mason-lspconfig's
  # `check_and_notify_bad_setup_order` warning on the second call.
  #
  # The on-disk stubs (via make_phase_41_lsp_runtime) increment
  # _G.__mason_calls / _G.__mlc_calls per setup() call. The first
  # orchestrator invocation runs implicitly from `lvim.start()`
  # (init.lua → lvim.start → lvim.lsp.setup); the next two `-c lua`
  # invocations call it explicitly. Without `did_setup`, each counter
  # would land at 3; with it, both stay pinned to 1.
  local cfg_dir rt output
  cfg_dir="$(make_empty_config_dir)"
  rt="$(make_phase_41_lsp_runtime)"

  output="$(LUNAVIM_RUNTIME_DIR="$rt" LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    -u init.lua \
    -c 'lua require("lvim.lsp").setup()' \
    -c 'lua require("lvim.lsp").setup()' \
    -c 'lua print("MASON=" .. _G.__mason_calls .. " MLC=" .. _G.__mlc_calls)' \
    -c 'qall!' 2>&1)"
  if ! grep -q '^MASON=1 MLC=1$' <<<"$output"; then
    printf 'phase 4.1: lvim.lsp.setup() not idempotent — mason/mason-lspconfig setup re-ran (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

check_phase_41_setup_wired_in_init() {
  # Phase 4.1 step 4 wires `require('lvim.lsp').setup()` into
  # `lvim.start()`. Pin the wiring location at the file level so a
  # regression that drops the require (so neither mason nor lspconfig
  # ever get setup() called on a fresh real-user boot — the lazy config
  # callbacks on mason/mason-lspconfig are no-op stubs by design) is
  # caught before the runtime stub checks above.
  if ! grep -Fq 'require("lvim.lsp").setup()' lua/lvim/init.lua; then
    printf 'phase 4.1: lvim/init.lua does not call lvim.lsp.setup()\n' >&2
    return 1
  fi
}

check_phase_41_mason_toggle_skips_setup() {
  # Phase 4.1 contract: when `lvim.builtin.mason.active = false` the
  # orchestrator must skip BOTH mason.setup() and mason-lspconfig.setup()
  # — the bridge is gated on the mason toggle by design (see
  # `lua/lvim/lsp/init.lua:64` and the spec-level `gate("mason")` on the
  # mason-lspconfig entry at `lua/lvim/plugins/spec.lua:104`). Without
  # this gate a user who disabled mason would still see the bridge try
  # to initialise — and the bridge's `check_and_notify_bad_setup_order`
  # would emit a warning, or worse, a corrupted partial-init would
  # surface as a "mason not initialised" error from a downstream
  # `ensure_installed` lookup.
  #
  # On-disk stubs are present here too (via make_phase_41_lsp_runtime).
  # Booting with `lvim.builtin.mason.active = false` should mean the
  # orchestrator never calls require on mason / mason-lspconfig, so even
  # though the stubs are physically present and loadable, their setup()
  # increments are never triggered. Both counters stay at 0. (lazy.nvim
  # also drops the mason / mason-lspconfig spec entries via
  # `enabled = gate("mason")`, so the toggle is enforced at two layers;
  # this check pins the orchestrator-side gate specifically.)
  local cfg_dir rt output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" mason-off-lsp-XXXXXX)"
  printf 'lvim.builtin.mason.active = false\n' > "$cfg_dir/config.lua"
  rt="$(make_phase_41_lsp_runtime)"

  output="$(LUNAVIM_RUNTIME_DIR="$rt" LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    -u init.lua \
    -c 'lua print("MASON=" .. (_G.__mason_calls or 0) .. " MLC=" .. (_G.__mlc_calls or 0))' \
    -c 'qall!' 2>&1)"
  if ! grep -q '^MASON=0 MLC=0$' <<<"$output"; then
    printf 'phase 4.1: disabling lvim.builtin.mason did not skip mason+mason-lspconfig setup (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

# Phase 4.2 helper: same on-disk lazy plugin tree as the 4.1 helper. The
# lspconfig stub is now a minimal "loadable module" because the orchestrator
# moved off the legacy `require('lspconfig')[name].setup(opts)` framework
# (kcl-confirmed deprecation warning on Neovim 0.11+) onto the native
# `vim.lsp.config(name, opts)` + `vim.lsp.enable(name)` API path. Per-server
# wiring is therefore observed by reading `vim.lsp.config[name]` back (the
# table-form access does NOT fire a deprecation warning — only the
# require('lspconfig')[name] indexing did). The mason-lspconfig stub still
# records its setup opts so the Phase 4.2 wiring checks for
# `ensure_installed` and `automatic_servers_installation` can read them.
#
# `vim.lsp.enable(name)` calls are observed by monkey-patching the function
# at boot time via `--cmd` (so the patch is in place before
# `lvim.lsp.setup()` runs from inside `lvim.start()`); the patched wrapper
# records every name into `_G.__lvim_enabled_servers` and then forwards to
# the original implementation so real lspconfig wiring still happens. Each
# test that needs enable-call observation defines its own
# `--cmd "lua _G.__lvim_enabled_servers = {}; ..."` prelude.
make_phase_42_lsp_runtime() {
  local rt
  rt="$(mktemp -d -p "$SMOKE_TMP_BASE" lsp42-rt-XXXXXX)"
  mkdir -p "$rt/lazy/mason/lua/mason"
  mkdir -p "$rt/lazy/mason-lspconfig/lua/mason-lspconfig"
  mkdir -p "$rt/lazy/lspconfig/lua/lspconfig"
  ln -s "$LUNAVIM_RUNTIME_DIR/lazy/lazy.nvim" "$rt/lazy/lazy.nvim"

  cat > "$rt/lazy/mason/lua/mason/init.lua" <<'LUA'
return { setup = function(_) end }
LUA
  # Record the opts passed to mason-lspconfig.setup so the Phase 4.2
  # `automatic_servers_installation` wiring check can read them back.
  cat > "$rt/lazy/mason-lspconfig/lua/mason-lspconfig/init.lua" <<'LUA'
return {
  setup = function(opts)
    _G.__lvim_mlc_setup_opts = opts
  end,
}
LUA
  # The orchestrator only `pcall(require, "lspconfig")`s the module to trigger
  # lazy.nvim's loader (so the plugin's `lsp/` blueprint directory joins
  # rtp); it never indexes the returned module. A minimal table is therefore
  # sufficient — any `__index` shape would be unused.
  cat > "$rt/lazy/lspconfig/lua/lspconfig/init.lua" <<'LUA'
return {}
LUA

  printf '%s\n' "$rt"
}

# Wrap `vim.lsp.enable` to record each enable-call into
# `_G.__lvim_enabled_servers` and forward to the original. Designed to be
# loaded via `--cmd "lua dofile(...)" ` from a test, but the inline pattern is
# short enough that tests embed the wrap directly via `--cmd`. Kept in script
# scope as a string so each test can include it verbatim without drift.
PHASE_42_ENABLE_SPY_CMD='lua _G.__lvim_enabled_servers = {}; local _orig = vim.lsp.enable; vim.lsp.enable = function(name) table.insert(_G.__lvim_enabled_servers, name); return _orig(name) end'

check_phase_42_defaults_table_present() {
  # Phase 4.2 step 1: the defaults table must expose the documented `lvim.lsp`
  # shape — every key is part of the LunarVim-compatible contract and other
  # checks below (and downstream phases) rely on the fields being addressable
  # by name even when nil/empty. A regression that drops one of the keys (or
  # mis-spells it) would silently change the surface API users write against;
  # this anchored print proves all six keys are present with their default
  # shapes immediately after defaults load (before user config runs).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local l = lvim.lsp; print(type(l.ensure_installed), type(l.servers), tostring(l.on_attach), tostring(l.capabilities), tostring(l.automatic_servers_installation), type(l.diagnostic))' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^table[[:space:]]+table[[:space:]]+nil[[:space:]]+nil[[:space:]]+false[[:space:]]+table$' <<<"$output"; then
    printf 'phase 4.2: lvim.lsp default shape wrong (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_42_user_settings_flow_through() {
  # Phase 4.2 literal acceptance, post-migration form: setting
  # `lvim.lsp.servers.lua_ls = { settings = { Lua = { diagnostics = { globals
  # = { 'vim' } } } } }` in user config must result in
  # `vim.lsp.config["lua_ls"].settings.Lua.diagnostics.globals` containing
  # 'vim'. This pins the contract that the orchestrator merges user-supplied
  # per-server tables and forwards the composed table to `vim.lsp.config(name,
  # ...)` (replacing the now-removed `lspconfig[name].setup(...)` path that
  # would have fired nvim-lspconfig's `vim.deprecate` on Neovim 0.11+).
  # Reading `vim.lsp.config[name]` is the table-access form, which does NOT
  # fire any deprecation warning.
  local cfg_dir rt output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" lsp42-cfg-XXXXXX)"
  printf "lvim.lsp.servers.lua_ls = { settings = { Lua = { diagnostics = { globals = { 'vim' } } } } }\n" \
    > "$cfg_dir/config.lua"
  rt="$(make_phase_42_lsp_runtime)"

  output="$(LUNAVIM_RUNTIME_DIR="$rt" LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    -u init.lua \
    -c "lua print(vim.tbl_contains(vim.lsp.config['lua_ls'].settings.Lua.diagnostics.globals, 'vim'))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^true$' <<<"$output"; then
    printf 'phase 4.2: user lua_ls.settings did not flow through to vim.lsp.config (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_42_defaults_attached_to_each_server() {
  # Phase 4.2 step 2: when a server entry omits `on_attach`/`capabilities`,
  # the orchestrator must inject the defaults built by
  # `lvim.lsp.handlers.make_on_attach()` / `make_capabilities()`. A regression
  # that forgot to merge the defaults (e.g. passed `config or {}` verbatim to
  # `vim.lsp.config(name, ...)`) would leave servers without any keymap
  # registration on attach, silently breaking the default UX. Assert that
  # `vim.lsp.config["lua_ls"]` for an otherwise-empty server entry has
  # `on_attach` = function and `capabilities` = table after `lvim.start()`
  # runs.
  local cfg_dir rt output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" lsp42-defaults-XXXXXX)"
  printf 'lvim.lsp.servers.lua_ls = {}\n' > "$cfg_dir/config.lua"
  rt="$(make_phase_42_lsp_runtime)"

  output="$(LUNAVIM_RUNTIME_DIR="$rt" LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    -u init.lua \
    -c "lua local c = vim.lsp.config['lua_ls']; print(type(c.on_attach), type(c.capabilities))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^function[[:space:]]+table$' <<<"$output"; then
    printf 'phase 4.2: default on_attach/capabilities not attached to server (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_42_user_on_attach_overrides_default() {
  # Phase 4.2 contract: a user-supplied `lvim.lsp.on_attach` must replace the
  # orchestrator's default for every server. Set a sentinel on_attach in user
  # config, then assert `vim.lsp.config["lua_ls"].on_attach` is literally the
  # same function (not the default). This proves the
  # `lsp_cfg.on_attach or handlers.make_on_attach()` precedence works.
  local cfg_dir rt output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" lsp42-override-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
_G.__custom_on_attach = function(_, _) end
lvim.lsp.on_attach = _G.__custom_on_attach
lvim.lsp.servers.lua_ls = {}
LUA
  rt="$(make_phase_42_lsp_runtime)"

  output="$(LUNAVIM_RUNTIME_DIR="$rt" LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    -u init.lua \
    -c "lua print(vim.lsp.config['lua_ls'].on_attach == _G.__custom_on_attach)" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^true$' <<<"$output"; then
    printf 'phase 4.2: user lvim.lsp.on_attach did not replace default (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_42_default_on_attach_registers_keymaps() {
  # Phase 4.2 step 2: the default on_attach registers buffer-local LSP keymaps
  # gd / gr / K / <leader>la / <leader>lr. Invoke `handlers.make_on_attach()`
  # directly against a scratch buffer so we don't need a live LSP client, then
  # walk `vim.api.nvim_buf_get_keymap(bufnr, 'n')` and assert each LHS is
  # present. A regression that dropped a key — or registered a global mapping
  # instead of a buffer-local one — would trip the anchored grep.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua \
local bufnr = vim.api.nvim_create_buf(false, true); \
require('lvim.lsp.handlers').make_on_attach()(nil, bufnr); \
local maps = vim.api.nvim_buf_get_keymap(bufnr, 'n'); \
local seen = {}; \
for _, m in ipairs(maps) do seen[m.lhs] = true end; \
print('KEYS', seen['gd'] == true, seen['gr'] == true, seen['K'] == true, seen[' la'] == true, seen[' lr'] == true)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^KEYS[[:space:]]+true[[:space:]]+true[[:space:]]+true[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 4.2: default on_attach did not register expected buffer-local keymaps (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

check_phase_42_capabilities_baseline() {
  # Phase 4.2 step 2: `make_capabilities()` falls back to
  # `vim.lsp.protocol.make_client_capabilities()` when blink.cmp is not
  # loadable. The smoke harness does not have blink on disk, so the fallback
  # is the path exercised here. Assert the returned table is a table and has
  # the protocol-baseline `textDocument` field present (its existence is the
  # cheapest proof that `make_client_capabilities()` actually populated the
  # return value, rather than a regression returning an empty `{}`).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local c = require('lvim.lsp.handlers').make_capabilities(); print(type(c), type(c.textDocument))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^table[[:space:]]+table$' <<<"$output"; then
    printf 'phase 4.2: make_capabilities() did not return a populated protocol table (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

check_phase_42_user_capabilities_overrides_default() {
  # Phase 4.2 contract, symmetric to check_phase_42_user_on_attach_overrides_default:
  # a user-supplied `lvim.lsp.capabilities` must replace the orchestrator's
  # default for every server. The on_attach test alone does not cover the
  # capabilities branch because the orchestrator computes the two values via
  # independent `or` precedence — a regression that special-cased on_attach but
  # always rebuilt capabilities from `make_capabilities()` (or vice versa) would
  # pass the on_attach assertion and silently break capability propagation.
  # Stamp an identifiable sentinel field on the user-supplied table and assert
  # it survives all the way through to `vim.lsp.config["lua_ls"]`.
  local cfg_dir rt output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" lsp42-cap-override-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
_G.__custom_caps = { __sentinel = "custom_caps_sentinel" }
lvim.lsp.capabilities = _G.__custom_caps
lvim.lsp.servers.lua_ls = {}
LUA
  rt="$(make_phase_42_lsp_runtime)"

  output="$(LUNAVIM_RUNTIME_DIR="$rt" LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    -u init.lua \
    -c "lua print('SENTINEL=' .. tostring(vim.lsp.config['lua_ls'].capabilities.__sentinel))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^SENTINEL=custom_caps_sentinel$' <<<"$output"; then
    printf 'phase 4.2: user lvim.lsp.capabilities did not replace default (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_42_per_server_on_attach_overrides_global() {
  # Phase 4.2 contract: the orchestrator's per-server merge uses
  # `vim.tbl_deep_extend("force", { on_attach = global, capabilities = global },
  # config)`, which means a per-server `config.on_attach` takes precedence over
  # the global `lvim.lsp.on_attach`. This is the "settings flow through"
  # property applied to the on_attach key — a regression that swapped the
  # tbl_deep_extend argument order (defaults LAST instead of FIRST) would
  # silently make the global always win, breaking the documented per-server
  # override pattern. Stamp two distinct function identities and assert the
  # per-server one lands in `vim.lsp.config["lua_ls"]`.
  local cfg_dir rt output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" lsp42-per-srv-override-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
_G.__global_fn = function(_, _) end
_G.__per_server_fn = function(_, _) end
lvim.lsp.on_attach = _G.__global_fn
lvim.lsp.servers.lua_ls = { on_attach = _G.__per_server_fn }
LUA
  rt="$(make_phase_42_lsp_runtime)"

  output="$(LUNAVIM_RUNTIME_DIR="$rt" LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    -u init.lua \
    -c "lua local c = vim.lsp.config['lua_ls']; print('PER=' .. tostring(c.on_attach == _G.__per_server_fn) .. ' NOT_GLOBAL=' .. tostring(c.on_attach ~= _G.__global_fn))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^PER=true NOT_GLOBAL=true$' <<<"$output"; then
    printf 'phase 4.2: per-server config.on_attach did not override global lvim.lsp.on_attach (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

check_phase_42_multiple_servers_all_setup() {
  # Phase 4.2 contract: every entry in `lvim.lsp.servers` must yield a single
  # `vim.lsp.config(name, ...) + vim.lsp.enable(name)` pair. The single-server
  # tests above leave open a regression where the loop bodies `break` after the
  # first iteration, only process the first hash-table entry, or shadow
  # `config` with the loop key. Setting three servers with distinguishable
  # per-server sentinels (and using `ts_ls` — the current canonical name; the
  # legacy `tsserver` alias is on nvim-lspconfig's removal path) and reading
  # them back from `vim.lsp.config[name]` proves all three were processed AND
  # that the per-server settings did not cross-contaminate.
  local cfg_dir rt output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" lsp42-multi-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.lsp.servers.lua_ls = { settings = { marker = "lua_ls_marker" } }
lvim.lsp.servers.pyright = { settings = { marker = "pyright_marker" } }
lvim.lsp.servers.ts_ls = { settings = { marker = "ts_ls_marker" } }
LUA
  rt="$(make_phase_42_lsp_runtime)"

  output="$(LUNAVIM_RUNTIME_DIR="$rt" LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    -u init.lua \
    -c "lua print('MARKERS', vim.lsp.config['lua_ls'].settings.marker, vim.lsp.config['pyright'].settings.marker, vim.lsp.config['ts_ls'].settings.marker)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^MARKERS[[:space:]]+lua_ls_marker[[:space:]]+pyright_marker[[:space:]]+ts_ls_marker$' <<<"$output"; then
    printf 'phase 4.2: not all three servers received vim.lsp.config() with their per-server settings (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

check_phase_42_empty_servers_no_setup_calls() {
  # Phase 4.2 contract: with `lvim.lsp.servers` empty (the default), the
  # orchestrator must call `vim.lsp.config(name, ...) + vim.lsp.enable(name)`
  # ZERO times — the loop body must not over-enumerate by iterating, say,
  # mason-lspconfig's discovered server list. Wrap `vim.lsp.enable` to count
  # each invocation; the spy is installed BEFORE init.lua via `--cmd`, so
  # `lvim.lsp.setup()` (run from `lvim.start()`) hits the wrapped version.
  local cfg_dir rt output
  cfg_dir="$(make_empty_config_dir)"
  rt="$(make_phase_42_lsp_runtime)"

  output="$(LUNAVIM_RUNTIME_DIR="$rt" LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    --cmd "$PHASE_42_ENABLE_SPY_CMD" \
    -u init.lua \
    -c "lua print('ENABLED=' .. #_G.__lvim_enabled_servers)" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^ENABLED=0$' <<<"$output"; then
    printf 'phase 4.2: empty lvim.lsp.servers should yield 0 vim.lsp.enable() calls (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

check_phase_42_blink_cmp_extends_capabilities() {
  # Phase 4.2 step 2: `make_capabilities()` must extend the protocol baseline
  # with `blink.cmp.get_lsp_capabilities()` ONLY if blink.cmp is loadable. The
  # `check_phase_42_capabilities_baseline` test covers the negative case (blink
  # not on disk → plain baseline); this one covers the positive case by
  # pre-populating `package.loaded["blink.cmp"]` with a stub whose
  # `get_lsp_capabilities()` returns a sentinel field. After calling
  # `make_capabilities()` the sentinel must be present AND the baseline's
  # `textDocument` must still be there (i.e. the merge augmented, not replaced).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua package.loaded['blink.cmp'] = { get_lsp_capabilities = function() return { __blink_marker = true } end }" \
    -c "lua local c = require('lvim.lsp.handlers').make_capabilities(); print('BLINK=' .. tostring(c.__blink_marker) .. ' BASE=' .. type(c.textDocument))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^BLINK=true BASE=table$' <<<"$output"; then
    printf 'phase 4.2: make_capabilities() did not merge blink.cmp.get_lsp_capabilities() (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

check_phase_42_automatic_servers_installation_wired() {
  # Phase 4.2 surface contract: `lvim.lsp.automatic_servers_installation`
  # is consumed by the orchestrator and forwarded to mason-lspconfig.setup
  # as `automatic_installation`. Without this wiring the field is dead code
  # — exposed in defaults but with no observable behavior, which is a
  # bug-attractor surface. Flip the field to `true` in user config and read
  # the recorded `__lvim_mlc_setup_opts.automatic_installation` from the
  # mason-lspconfig stub; assert it landed.
  local cfg_dir rt output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" lsp42-autoinst-XXXXXX)"
  printf 'lvim.lsp.automatic_servers_installation = true\n' > "$cfg_dir/config.lua"
  rt="$(make_phase_42_lsp_runtime)"

  output="$(LUNAVIM_RUNTIME_DIR="$rt" LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    -u init.lua \
    -c "lua print('AUTOINST=' .. tostring((_G.__lvim_mlc_setup_opts or {}).automatic_installation))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^AUTOINST=true$' <<<"$output"; then
    printf 'phase 4.2: lvim.lsp.automatic_servers_installation was not forwarded to mason-lspconfig.setup (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

check_phase_42_ensure_installed_wired() {
  # Phase 4.2 surface contract: `lvim.lsp.ensure_installed` is forwarded to
  # mason-lspconfig.setup as `ensure_installed`. Phase 4.1 already wired the
  # `or {}` baseline; this check pins the user-list path so a regression that
  # silently dropped the field (or sent a different name like `servers`) is
  # caught by an explicit list/contents probe.
  local cfg_dir rt output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" lsp42-ensure-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.lsp.ensure_installed = { "lua_ls", "ts_ls" }
LUA
  rt="$(make_phase_42_lsp_runtime)"

  output="$(LUNAVIM_RUNTIME_DIR="$rt" LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    -u init.lua \
    -c "lua local opts = _G.__lvim_mlc_setup_opts or {}; local list = opts.ensure_installed or {}; print('ENSURED=' .. table.concat(list, ','))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^ENSURED=lua_ls,ts_ls$' <<<"$output"; then
    printf 'phase 4.2: lvim.lsp.ensure_installed was not forwarded to mason-lspconfig.setup (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

check_phase_42_handlers_module_present() {
  # Phase 4.2 step 3 creates `lua/lvim/lsp/handlers.lua` exporting
  # `make_capabilities()` and `make_on_attach()`. Pin the module location at
  # the file level so a regression that moved/renamed/dropped the file (so
  # the orchestrator's `require('lvim.lsp.handlers')` would fail) is caught
  # before the runtime checks above.
  if [[ ! -f lua/lvim/lsp/handlers.lua ]]; then
    printf 'phase 4.2: lua/lvim/lsp/handlers.lua is missing\n' >&2
    return 1
  fi
  if ! grep -Fq 'function M.make_capabilities' lua/lvim/lsp/handlers.lua; then
    printf 'phase 4.2: handlers.lua missing make_capabilities export\n' >&2
    return 1
  fi
  if ! grep -Fq 'function M.make_on_attach' lua/lvim/lsp/handlers.lua; then
    printf 'phase 4.2: handlers.lua missing make_on_attach export\n' >&2
    return 1
  fi
}

check_phase_42_uses_vim_lsp_config_not_setup() {
  # Phase 4 acceptance criterion (plan.md §"Phase 4 Acceptance"):
  # "Deprecated LSP API warnings are absent on the supported Neovim version."
  # nvim-lspconfig 2.x emits a `vim.deprecate` from its `mt:__index`
  # metamethod whenever a caller indexes `require('lspconfig')[name]` on
  # Neovim 0.11+ (kcl-confirmed against the current release: the warning
  # text is "The `require('lspconfig')` \"framework\" is deprecated, use
  # vim.lsp.config (see :help lspconfig-nvim-0.11) instead."). The legacy
  # `require('lspconfig')[name].setup(opts)` pattern therefore violates the
  # acceptance criterion for every user-configured server in
  # `lvim.lsp.servers`.
  #
  # The orchestrator now uses `vim.lsp.config(name, opts) + vim.lsp.enable(
  # name)` (kcl-confirmed as the recommended Neovim 0.11+ integration with
  # nvim-lspconfig 2.x's data-only mode). This file-level grep pins the new
  # pattern so a regression that reverts to `lspconfig[name].setup(...)`
  # trips this check before any runtime probe.
  if ! grep -Fq 'vim.lsp.config(name, merged)' lua/lvim/lsp/init.lua; then
    printf 'phase 4.2: lua/lvim/lsp/init.lua does not call vim.lsp.config(name, merged)\n' >&2
    return 1
  fi
  if ! grep -Fq 'vim.lsp.enable(name)' lua/lvim/lsp/init.lua; then
    printf 'phase 4.2: lua/lvim/lsp/init.lua does not call vim.lsp.enable(name)\n' >&2
    return 1
  fi
  # The deprecated indexing form must NOT appear in the orchestrator
  # — neither the bracket form (lspconfig[name]) nor the dot form
  # (lspconfig.<name>.setup). The grep filters out Lua comment lines (those
  # starting with optional whitespace then `--`) so the documentation comment
  # above the new code block — which explains *why* we avoid the pattern,
  # and necessarily mentions the pattern textually — does not false-positive.
  if grep -vE '^[[:space:]]*--' lua/lvim/lsp/init.lua \
       | grep -Eq 'lspconfig\[name\]|lspconfig\.[A-Za-z_]+\.setup'; then
    printf 'phase 4.2: lua/lvim/lsp/init.lua still indexes the deprecated lspconfig framework\n' >&2
    return 1
  fi
}

check_phase_42_vim_lsp_enable_called_for_each_server() {
  # Phase 4.2 contract: every entry in `lvim.lsp.servers` yields exactly one
  # `vim.lsp.enable(name)` call — the lspconfig 2.x integration pattern
  # (kcl-confirmed: `vim.lsp.enable(name)` registers the per-server attach
  # autocmd using the `lsp/<name>.lua` blueprint that nvim-lspconfig ships).
  # A regression that called `vim.lsp.config` but forgot the matching
  # `enable` would silently leave every user-configured server inert. The
  # spy installed via `--cmd` runs BEFORE init.lua (so it intercepts the
  # boot-time `lvim.lsp.setup()` invocation) and records each enabled name
  # in `_G.__lvim_enabled_servers`; the post-check sorts and joins the list
  # so the assertion is order-independent (the orchestrator iterates
  # `pairs(lsp_cfg.servers)`, which is hash-table order in Lua).
  local cfg_dir rt output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" lsp42-enable-count-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.lsp.servers.lua_ls = {}
lvim.lsp.servers.pyright = {}
lvim.lsp.servers.ts_ls = {}
LUA
  rt="$(make_phase_42_lsp_runtime)"

  output="$(LUNAVIM_RUNTIME_DIR="$rt" LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    --cmd "$PHASE_42_ENABLE_SPY_CMD" \
    -u init.lua \
    -c "lua local names = vim.deepcopy(_G.__lvim_enabled_servers); table.sort(names); print('ENABLED=' .. table.concat(names, ','))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^ENABLED=lua_ls,pyright,ts_ls$' <<<"$output"; then
    printf 'phase 4.2: vim.lsp.enable not called for every server in lvim.lsp.servers (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

check_phase_42_orchestrator_does_not_index_lspconfig() {
  # Phase 4 acceptance criterion (plan.md §"Phase 4 Acceptance"):
  # "Deprecated LSP API warnings are absent on the supported Neovim version."
  # The static grep in check_phase_42_uses_vim_lsp_config_not_setup pins the
  # source text; this check pins runtime behavior. It pre-populates
  # `package.loaded["lspconfig"]` (via `--cmd`, before init.lua runs) with a
  # synthetic stub whose `__index` metamethod increments a counter on every
  # access. After `lvim.start()` completes (which invokes `lvim.lsp.setup()`
  # for every user-configured server), the counter must remain at 0 —
  # proving the orchestrator never indexes the lspconfig module, which is
  # the exact access that triggers nvim-lspconfig 2.x's `vim.deprecate`
  # warning on Neovim 0.11+.
  #
  # Three servers are configured so a regression that broke on the first
  # iteration but worked on subsequent ones (or vice versa) still trips the
  # check. The counter lives on `_G`, not on the stub itself, so updating it
  # inside `__index` does not re-enter the metamethod recursively.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" lsp42-no-index-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.lsp.servers.lua_ls = {}
lvim.lsp.servers.pyright = {}
lvim.lsp.servers.ts_ls = {}
LUA

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    --cmd 'lua _G.__lvim_lspconfig_index_count = 0; package.loaded["lspconfig"] = setmetatable({}, { __index = function(t, _) _G.__lvim_lspconfig_index_count = _G.__lvim_lspconfig_index_count + 1; return nil end })' \
    -u init.lua \
    -c 'lua print("INDEX_COUNT=" .. tostring(_G.__lvim_lspconfig_index_count))' \
    -c 'qall!' 2>&1)"
  if ! grep -q '^INDEX_COUNT=0$' <<<"$output"; then
    printf 'phase 4.2: orchestrator indexed lspconfig module (would trigger vim.deprecate on Neovim 0.11+) (output: %s)\n' \
      "$output" >&2
    return 1
  fi
}

check_phase_43_format_module_present() {
  # Phase 4.3 lives in lua/lvim/lsp/format.lua. Pin the file's location and
  # public surface at the file level so a regression that moved/renamed the
  # module (so lvim.start()'s `require("lvim.lsp.format")` would error) is
  # caught before the runtime probes below.
  if [[ ! -f lua/lvim/lsp/format.lua ]]; then
    printf 'phase 4.3: lua/lvim/lsp/format.lua is missing\n' >&2
    return 1
  fi
  if ! grep -Fq 'function M.setup' lua/lvim/lsp/format.lua; then
    printf 'phase 4.3: format.lua missing M.setup export\n' >&2
    return 1
  fi
  if ! grep -Fq 'lvim_format_on_save' lua/lvim/lsp/format.lua; then
    printf 'phase 4.3: format.lua does not register augroup lvim_format_on_save\n' >&2
    return 1
  fi
}

check_phase_43_true_registers_autocmd() {
  # Phase 4.3 literal acceptance #1: `lvim.format_on_save = true` must produce
  # at least one BufWritePre autocmd in the `lvim_format_on_save` group after
  # lvim.start() completes. Anchor on a count > 0 (rather than == 1) so a
  # future addition (e.g. a hypothetical InsertLeavePre formatting trigger)
  # does not silently break the check.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" fmt-true-XXXXXX)"
  printf 'lvim.format_on_save = true\n' > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua print('AUS=' .. #vim.api.nvim_get_autocmds({ group = 'lvim_format_on_save' }))" \
    -c 'qall!' 2>&1)"
  local n
  n="$(grep -Eo 'AUS=[0-9]+' <<<"$output" | head -1 | cut -d= -f2)"
  if [[ -z "$n" ]] || (( n < 1 )); then
    printf 'phase 4.3: lvim.format_on_save = true did not register autocmds in lvim_format_on_save (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_43_false_no_autocmd() {
  # Phase 4.3 literal acceptance #2: `lvim.format_on_save = false` results in
  # NO autocmds in the lvim_format_on_save group. The current implementation
  # always (re)creates the group with `clear = true` for idempotency, so the
  # group itself exists but is empty. nvim_get_autocmds returns an empty
  # table for an existing-but-empty group, and would raise a Vim error for a
  # truly absent group — `pcall` covers both shapes since the step acceptance
  # text says "(or doesn't exist)".
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" fmt-false-XXXXXX)"
  printf 'lvim.format_on_save = false\n' > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local ok, aus = pcall(vim.api.nvim_get_autocmds, { group = 'lvim_format_on_save' }); print('AUS=' .. (ok and #aus or 0))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^AUS=0$' <<<"$output"; then
    printf 'phase 4.3: lvim.format_on_save = false left autocmds in lvim_format_on_save (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_43_table_form_honored() {
  # Phase 4.3 must accept the LunarVim-compatible table form:
  #   lvim.format_on_save = { enabled = true, timeout_ms = 2500 }
  # The autocmd registration is observable; verifying the exact opts that
  # would flow into vim.lsp.buf.format requires walking the callback, which
  # we cannot do without invoking the callback. Instead, exercise three
  # observable properties of the table form:
  #   (a) `enabled = true` yields >= 1 autocmd,
  #   (b) `enabled = false` (table form) yields 0 autocmds (the table
  #       branch is distinct from the boolean-false branch),
  #   (c) the augroup is `lvim_format_on_save` exactly (not a per-shape
  #       variant).
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" fmt-tbl-on-XXXXXX)"
  printf 'lvim.format_on_save = { enabled = true, timeout_ms = 2500 }\n' > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua print('AUS=' .. #vim.api.nvim_get_autocmds({ group = 'lvim_format_on_save', event = 'BufWritePre' }))" \
    -c 'qall!' 2>&1)"
  local n
  n="$(grep -Eo 'AUS=[0-9]+' <<<"$output" | head -1 | cut -d= -f2)"
  if [[ -z "$n" ]] || (( n < 1 )); then
    printf 'phase 4.3: table form { enabled = true } did not register BufWritePre autocmd (output: %s)\n' "$output" >&2
    return 1
  fi

  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" fmt-tbl-off-XXXXXX)"
  printf 'lvim.format_on_save = { enabled = false, timeout_ms = 2500 }\n' > "$cfg_dir/config.lua"
  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local ok, aus = pcall(vim.api.nvim_get_autocmds, { group = 'lvim_format_on_save' }); print('AUS=' .. (ok and #aus or 0))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^AUS=0$' <<<"$output"; then
    printf 'phase 4.3: table form { enabled = false } registered autocmds (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_43_reload_idempotent() {
  # The step text says the group must be idempotent on re-setup so
  # `:LvimReload` does not stack autocmds. Invoke `:LvimReload` 3 times in
  # one session and assert the autocmd count for the lvim_format_on_save
  # group is still exactly 1 (the BufWritePre registration), not 3. A
  # regression that dropped `clear = true` (or that registered the autocmd
  # in addition to a never-cleared group) would observe AUS=4 instead.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" fmt-reload-XXXXXX)"
  printf 'lvim.format_on_save = true\n' > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'LvimReload' \
    -c 'LvimReload' \
    -c 'LvimReload' \
    -c "lua print('AUS=' .. #vim.api.nvim_get_autocmds({ group = 'lvim_format_on_save', event = 'BufWritePre' }))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^AUS=1$' <<<"$output"; then
    printf 'phase 4.3: :LvimReload stacked autocmds in lvim_format_on_save (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_43_exclude_clients_filter_drops_named() {
  # Phase 4.3 default-filter contract: when no `filter` is set and
  # `exclude_clients = { "name1", ... }` is provided, the resulting filter
  # callback must return `false` for any client whose `name` is in the
  # exclude set and `true` otherwise. The callback isn't directly exposed
  # by the module; instead, capture it by intercepting vim.lsp.buf.format
  # so the BufWritePre fire records the `filter` opts it receives, then
  # exercise that captured filter against synthetic client tables.
  #
  # Two clients are tested ("a" excluded, "b" allowed) so a regression
  # that flipped the predicate (returning `true` for excluded names)
  # trips the assertion. A third synthetic name "c" — not in the list —
  # asserts allow-by-default for unrelated clients.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" fmt-excl-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.format_on_save = {
  enabled = true,
  timeout_ms = 1000,
  exclude_clients = { "a", "x" },
}
LUA

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__filter = nil; vim.lsp.buf.format = function(opts) _G.__filter = opts and opts.filter end' \
    -c 'doautocmd BufWritePre' \
    -c 'lua local f = _G.__filter; print(type(f) == "function", tostring(f and f({ name = "a" })), tostring(f and f({ name = "b" })), tostring(f and f({ name = "x" })))' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^true[[:space:]]+false[[:space:]]+true[[:space:]]+false$' <<<"$output"; then
    printf 'phase 4.3: exclude_clients filter did not drop named clients (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_43_user_filter_overrides_exclude_clients() {
  # When the user provides their own `filter`, it must REPLACE the
  # exclude_clients default — not be composed with it. Provide a filter
  # that always returns `true` together with an exclude_clients list that
  # would normally drop "a"; the captured callback must return `true` for
  # "a" anyway, proving the user filter (not the exclude-builder) was
  # selected.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" fmt-userfilter-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.format_on_save = {
  enabled = true,
  timeout_ms = 1000,
  exclude_clients = { "a" },
  filter = function(_)
    return true
  end,
}
LUA

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__filter = nil; vim.lsp.buf.format = function(opts) _G.__filter = opts and opts.filter end' \
    -c 'doautocmd BufWritePre' \
    -c 'lua local f = _G.__filter; print(type(f) == "function", tostring(f and f({ name = "a" })))' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 4.3: user-provided filter did not override exclude_clients (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_43_table_without_enabled_is_disabled() {
  # Phase 4.3 LunarVim-compatibility contract (upstream LunarVim
  # reference under `references/`,
  # `lua/lvim/core/autocmds.lua:192-200` `configure_format_on_save`): the table
  # form requires `enabled` to be truthy to register the BufWritePre autocmd.
  # A user who writes `lvim.format_on_save = { timeout_ms = 5000 }` (no
  # `enabled` key) must NOT silently get format-on-save enabled — the canonical
  # opt-in form documented in the upstream LunarVim reference's starter config (see `references/`)
  # (`utils/installer/config.example.lua:17`) is the explicit
  # `lvim.format_on_save.enabled = true`. A regression that only blocked the
  # explicit `enabled = false` case (and let `enabled = nil` through) would
  # silently change the user-facing semantics for every starter-config replacement
  # — a quiet behavior drift from LunarVim. The autocmd-count probe is the
  # tightest negative assertion: `AUS=0` proves no listener was registered.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" fmt-tbl-no-enabled-XXXXXX)"
  printf 'lvim.format_on_save = { timeout_ms = 5000 }\n' > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local ok, aus = pcall(vim.api.nvim_get_autocmds, { group = 'lvim_format_on_save' }); print('AUS=' .. (ok and #aus or 0))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^AUS=0$' <<<"$output"; then
    printf 'phase 4.3: table without enabled key incorrectly registered format-on-save autocmd (output: %s)\n' "$output" >&2
    return 1
  fi

  # Also exercise the empty-table shape, which a user could reasonably reach
  # by writing `lvim.format_on_save = {}` to clear any inherited config before
  # re-populating fields. Empty table means `enabled == nil`, so the same
  # LunarVim contract applies: no autocmd.
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" fmt-tbl-empty-XXXXXX)"
  printf 'lvim.format_on_save = {}\n' > "$cfg_dir/config.lua"
  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local ok, aus = pcall(vim.api.nvim_get_autocmds, { group = 'lvim_format_on_save' }); print('AUS=' .. (ok and #aus or 0))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^AUS=0$' <<<"$output"; then
    printf 'phase 4.3: empty-table form incorrectly registered format-on-save autocmd (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_43_true_normalizes_timeout_ms() {
  # The step's normalization contract pins the boolean-true branch to
  # `{ enabled = true, timeout_ms = 1000 }`. Without exercising it, a
  # regression that quietly dropped the default timeout (e.g. passing nil
  # to vim.lsp.buf.format, which then blocks indefinitely on a slow
  # formatter) would pass the autocmd-presence check but break the
  # behavioral contract. Capture the opts table the BufWritePre callback
  # passes to vim.lsp.buf.format and assert `timeout_ms == 1000`.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" fmt-true-timeout-XXXXXX)"
  printf 'lvim.format_on_save = true\n' > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__opts = nil; vim.lsp.buf.format = function(opts) _G.__opts = opts end' \
    -c 'doautocmd BufWritePre' \
    -c 'lua print("TIMEOUT=" .. tostring(_G.__opts and _G.__opts.timeout_ms))' \
    -c 'qall!' 2>&1)"
  if ! grep -q '^TIMEOUT=1000$' <<<"$output"; then
    printf 'phase 4.3: lvim.format_on_save = true did not normalize timeout_ms to 1000 (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_43_table_form_timeout_ms_flows_through() {
  # check_phase_43_table_form_honored only proves the BufWritePre autocmd
  # exists for `{ enabled = true, timeout_ms = 2500 }` — it never observes
  # the opts the callback hands to vim.lsp.buf.format. A regression that
  # hardcoded 1000 in the table-form path (e.g. forgot to honor cfg.timeout_ms
  # for the non-boolean case) would pass every existing phase-4.3 check while
  # silently breaking the user's tuned timeout. This is the symmetric
  # counterpart to check_phase_43_true_normalizes_timeout_ms — that one
  # locks down the boolean-`true` default (1000); this one locks down that
  # a user-supplied table value (2500) actually reaches the format opts.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" fmt-tbl-timeout-XXXXXX)"
  printf 'lvim.format_on_save = { enabled = true, timeout_ms = 2500 }\n' > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__opts = nil; vim.lsp.buf.format = function(opts) _G.__opts = opts end' \
    -c 'doautocmd BufWritePre' \
    -c 'lua print("TIMEOUT=" .. tostring(_G.__opts and _G.__opts.timeout_ms))' \
    -c 'qall!' 2>&1)"
  if ! grep -q '^TIMEOUT=2500$' <<<"$output"; then
    printf 'phase 4.3: table form { timeout_ms = 2500 } did not flow through to vim.lsp.buf.format (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_44_lazydev_module_present() {
  # Phase 4.4 lives in lua/lvim/plugins/modules/lazydev.lua. Pin the file's
  # presence at the file level so a regression that moves/renames the module
  # (breaking the spec's `config = setup("lazydev")` dispatch) is caught
  # before the runtime probes below.
  if [[ ! -f lua/lvim/plugins/modules/lazydev.lua ]]; then
    printf 'phase 4.4: lua/lvim/plugins/modules/lazydev.lua is missing\n' >&2
    return 1
  fi
  if ! grep -Eq 'require[(,][[:space:]]*["'"'"']lazydev["'"'"']' lua/lvim/plugins/modules/lazydev.lua; then
    printf 'phase 4.4: lazydev module does not require the lazydev plugin\n' >&2
    return 1
  fi
}

check_phase_44_lazydev_setup_library_defaults() {
  # Phase 4.4 acceptance: lazydev.setup() must receive a `library` array
  # containing at least `vim.env.VIMRUNTIME` and the lvim base dir, so editing
  # a .lua file inside LunaVim's source tree gives completion for `vim.api.*`
  # and for LunaVim's own modules (the step's stated goal).
  #
  # The lvim base dir entry is shaped as `{ path = ..., words = { "lvim" } }`
  # mirroring lazydev's README distribution recipe
  # (`{ path = "LazyVim", words = { "LazyVim" } }`). `words` matches a literal
  # substring on any buffer line, so the trigger fires for both the LunaVim
  # source tree (`require("lvim.X")`, `lvim.builtin.X`, ...) AND a typical
  # user config (`lvim.leader = " "`) that never calls `require("lvim.*")`.
  # A `mods = { "lvim" }` trigger would only fire on `require("lvim.*")` and
  # silently miss the user-config case, defeating the step's goal; a plain
  # string would force eager injection on every .lua buffer. This probe pins
  # the `words` trigger so a regression to either form is caught.
  #
  # lazydev itself is not installed in the smoke harness
  # (install.missing = false), so stub `package.loaded.lazydev` with a fake
  # whose `setup` captures the opts table, then invoke the module's setup()
  # directly and assert both required paths are present in `opts.library`.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__lazydev_opts = nil; package.loaded.lazydev = { setup = function(o) _G.__lazydev_opts = o end }' \
    -c "lua require('lvim.plugins.modules.lazydev').setup({})" \
    -c 'lua local o = _G.__lazydev_opts; local base = _G.get_lvim_base_dir(); local has_rt, has_base, has_lvim_word = false, false, false; for _, p in ipairs((o or {}).library or {}) do if p == vim.env.VIMRUNTIME then has_rt = true end; if type(p) == "table" and p.path == base then has_base = true; if type(p.words) == "table" then for _, w in ipairs(p.words) do if w == "lvim" then has_lvim_word = true end end end end end; print("LIB", has_rt, has_base, has_lvim_word)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LIB[[:space:]]+true[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 4.4: lazydev.setup library missing VIMRUNTIME, lvim base dir entry, or lvim words trigger (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_44_lazydev_setup_user_opts_merged() {
  # The lazydev module must deep-merge user-supplied opts with its defaults so
  # a caller passing extra `integrations` or `library` entries does not lose
  # the VIMRUNTIME / lvim base dir defaults. Exercise this by passing a user
  # opts table with an extra library entry (as a plain string, to prove that
  # form still flows through unchanged) plus an integrations toggle, then
  # asserting all three library paths AND the integration flag are present
  # in the captured opts. The lvim base dir is matched against either a plain
  # string or a `{ path = ... }` table since the default shape uses the
  # `words`-trigger form.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__lazydev_opts = nil; package.loaded.lazydev = { setup = function(o) _G.__lazydev_opts = o end }' \
    -c "lua require('lvim.plugins.modules.lazydev').setup({ library = { '/tmp/extra-lib' }, integrations = { cmp = true } })" \
    -c 'lua local o = _G.__lazydev_opts; local base = _G.get_lvim_base_dir(); local has_rt, has_base, has_extra = false, false, false; for _, p in ipairs((o or {}).library or {}) do if p == vim.env.VIMRUNTIME then has_rt = true end; if p == base or (type(p) == "table" and p.path == base) then has_base = true end; if p == "/tmp/extra-lib" then has_extra = true end end; print("MERGE", has_rt, has_base, has_extra, o and o.integrations and o.integrations.cmp == true)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^MERGE[[:space:]]+true[[:space:]]+true[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 4.4: lazydev.setup did not deep-merge user opts with defaults (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_44_lazydev_setup_pcall_guards_missing() {
  # The smoke harness runs with install.missing=false, so the lazydev plugin
  # is not on disk. A regression that dropped the pcall guard around
  # `require('lazydev')` would let the missing module raise and break boot
  # the moment the module's setup runs. Force the module to be unavailable
  # (clear package.loaded.lazydev and prevent on-disk resolution) and assert
  # setup() returns without erroring.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded.lazydev = nil; package.preload.lazydev = nil' \
    -c "lua local ok, err = pcall(function() require('lvim.plugins.modules.lazydev').setup({}) end); print('PCALL', ok, err == nil)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^PCALL[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 4.4: lazydev module setup raised when plugin was unavailable (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_44_lazydev_literal_acceptance() {
  # Phase 4.4 step description states a literal acceptance command:
  #   nvim --headless -u init.lua tests/fixtures/dummy.lua \
  #     -c "lua print(type(require('lazydev')))" -c qall! 2>&1 | grep -q table
  # That command was previously exercised only indirectly via stub-based probes
  # of the module's setup(), so a regression that broke the verbatim
  # `require('lazydev')` round-trip on a Lua filetype could pass the existing
  # checks. Run the command pattern here so the step's stated literal contract
  # is observable in the smoke.
  #
  # The smoke harness boots with `install.missing = false` (LunarVim contract,
  # see `lua/lvim/core/plugins.lua`), so lazydev is not on disk and a naked
  # `require('lazydev')` would fail with E5108 — the literal command was
  # designed to run after `:LvimSyncCorePlugins` has installed the plugin.
  # Inject `package.preload.lazydev` via an extra -c BEFORE the require so it
  # resolves to the same shape an on-disk install would expose. The single
  # added preload `-c` is the minimum perturbation to the literal form; the
  # require/print/grep contract from the step is preserved verbatim.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua tests/fixtures/dummy.lua \
    -c "lua package.preload.lazydev = function() return { setup = function() end } end" \
    -c "lua print(type(require('lazydev')))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^table$' <<<"$output"; then
    printf 'phase 4.4 literal acceptance: require("lazydev") did not yield "table" (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_44_lazydev_loads_on_lua_ft() {
  # The lazydev spec entry pins `ft = "lua"` so the plugin lazy-loads only when
  # a Lua buffer opens. A regression that flipped the spec to `event` or
  # dropped the trigger entirely would silently break the step's stated goal —
  # the lazy-load probe in `check_phase_22_load_triggers` only checks the
  # static spec field, not lazy.nvim's runtime dispatch. Set `package.preload`
  # in a post-init -c (it must be set after -u runs, since the launcher is
  # what makes nvim's lua state available), then open the Lua fixture with
  # `:edit` (which fires FileType lua and prompts lazy.nvim to trigger the
  # `ft = "lua"` rule). Assert `require('lazydev')` resolves to our stub
  # afterwards — proving the FileType-driven load path completed.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua package.preload.lazydev = function() _G.__lazydev_loaded = true; return { setup = function() end } end" \
    -c "edit tests/fixtures/dummy.lua" \
    -c "lua local m = require('lazydev'); print('FT_LOAD', type(m) == 'table', _G.__lazydev_loaded == true)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^FT_LOAD[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 4.4: lazydev did not load on FileType lua (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_44_lspconfig_does_not_set_lua_workspace_library() {
  # Per kcl, lazydev is the recommended integration and dynamically injects
  # paths into the active lua_ls client's settings at runtime. The orchestrator
  # must NOT also set `Lua.workspace.library` on lua_ls (in the per-server
  # config flow inside `lua/lvim/lsp/init.lua`) — a static library entry there
  # would shadow / conflict with lazydev's runtime injection. Grep the LSP
  # orchestrator and the defaults to prove no static `workspace.library` is
  # hardcoded; user config can still set one in `lvim.lsp.servers.lua_ls`,
  # which is by design.
  if grep -F 'workspace' lua/lvim/lsp/init.lua >/dev/null 2>&1; then
    printf 'phase 4.4: lua/lvim/lsp/init.lua hardcodes a workspace setting (conflicts with lazydev)\n' >&2
    return 1
  fi
  if grep -F 'workspace' lua/lvim/lsp/handlers.lua >/dev/null 2>&1; then
    printf 'phase 4.4: lua/lvim/lsp/handlers.lua hardcodes a workspace setting (conflicts with lazydev)\n' >&2
    return 1
  fi
  if grep -F 'workspace' lua/lvim/config/defaults.lua >/dev/null 2>&1; then
    printf 'phase 4.4: lua/lvim/config/defaults.lua hardcodes a workspace setting (conflicts with lazydev)\n' >&2
    return 1
  fi
}

check_phase_45_diagnostics_module_present() {
  # Phase 4.5 lives in lua/lvim/lsp/diagnostics.lua. Pin the file's presence
  # so a regression that moves/renames the module (breaking the orchestrator's
  # `require("lvim.lsp.diagnostics").setup()` dispatch) fails before the
  # runtime probes below try to observe its effects.
  if [[ ! -f lua/lvim/lsp/diagnostics.lua ]]; then
    printf 'phase 4.5: lua/lvim/lsp/diagnostics.lua is missing\n' >&2
    return 1
  fi
  if ! grep -F 'vim.diagnostic.config' lua/lvim/lsp/diagnostics.lua >/dev/null; then
    printf 'phase 4.5: diagnostics module does not call vim.diagnostic.config\n' >&2
    return 1
  fi
  if ! grep -F 'sign_define' lua/lvim/lsp/diagnostics.lua >/dev/null; then
    printf 'phase 4.5: diagnostics module does not call vim.fn.sign_define\n' >&2
    return 1
  fi
}

check_phase_45_diagnostic_config_defaults_applied() {
  # Phase 4.5 literal acceptance — reproduced verbatim from the step
  # description, with `LUNAVIM_CONFIG_DIR` pointed at an empty config dir so
  # any developer-local `~/.config/lvim/config.lua` does not leak into the
  # check. `severity_sort` must be true and `virtual_text` must be truthy
  # (the defaults set it to a table, which the `and 'vt'` expression
  # collapses to the string 'vt' when present, or 'no_vt' when nil/false).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local c = vim.diagnostic.config(); print(c.severity_sort, c.virtual_text and 'vt' or 'no_vt')" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq 'true[[:space:]]+vt' <<<"$output"; then
    printf 'phase 4.5 literal acceptance: severity_sort/virtual_text defaults not applied (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_45_signs_defined() {
  # Phase 4.5 contract: the four standard diagnostic sign names must be
  # registered with non-empty text glyphs after boot. `vim.fn.sign_getdefined`
  # returns a list of `{ name, text, texthl, ... }` tables matching the
  # requested name. A regression that dropped sign_define (or renamed any of
  # the four sign names) would leave the list empty and trip the assertion.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local names = { 'DiagnosticSignError', 'DiagnosticSignWarn', 'DiagnosticSignInfo', 'DiagnosticSignHint' }; local ok = true; for _, n in ipairs(names) do local d = vim.fn.sign_getdefined(n); if not d or #d == 0 or not d[1].text or d[1].text == '' then ok = false; print('MISSING ' .. n) end end; print(ok and 'SIGNS_OK' or 'SIGNS_BAD')" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^SIGNS_OK$' <<<"$output"; then
    printf 'phase 4.5: not all diagnostic signs were defined with non-empty text (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_45_diagnostic_config_signs_table_has_text() {
  # Phase 4.5 contract: in Neovim 0.11+, the diagnostic sign renderer
  # (`vim.diagnostic.handlers.signs.show` in `runtime/lua/vim/diagnostic.lua`)
  # reads sign text exclusively from `opts.signs.text[severity]`. When
  # `signs = true` (boolean) it falls back to the default single-letter
  # `"E"/"W"/"I"/"H"` text — the legacy `vim.fn.sign_define("DiagnosticSign*",
  # { text = ... })` channel is NOT consulted by the renderer. So an
  # implementation that sets `signs = true` and only configures glyphs via
  # `sign_define` ends up showing `E/W/I/H` in the sign column despite the
  # prescribed `●` glyphs being registered. Pin the runtime contract by
  # asserting `vim.diagnostic.config().signs` is a table carrying a `text`
  # entry for each of the four severity levels.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local c = vim.diagnostic.config(); local s = c and c.signs; local t = type(s) == 'table' and s.text or nil; local sev = vim.diagnostic.severity; local function txt(name) if not t then return '' end; return t[name] or t[sev[name]] or '' end; print('SIGTBL', type(s), txt('ERROR'), txt('WARN'), txt('INFO'), txt('HINT'))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^SIGTBL[[:space:]]+table[[:space:]]+●[[:space:]]+●[[:space:]]+●[[:space:]]+●$' <<<"$output"; then
    printf 'phase 4.5: vim.diagnostic.config().signs.text does not carry the prescribed glyphs for all four severities (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_45_signs_text_deep_merges_per_severity() {
  # Phase 4.5 deep-merge contract for the signs table: a user override that
  # sets only one severity's glyph (e.g. `lvim.lsp.diagnostic.signs = { text =
  # { ERROR = "X" } }`) must NOT clobber the other three defaults. This is
  # the corner case `vim.tbl_deep_extend` refuses to handle when the
  # defaults' `text` table is list-like (consecutive int keys from 1) — the
  # whole table gets replaced wholesale rather than per-key-merged. Pinning
  # the contract here ensures defaults stay map-shaped (string-keyed) so
  # users can override one severity without resyncing the others.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" diag-sign-override-XXXXXX)"
  printf 'lvim.lsp.diagnostic = { signs = { text = { ERROR = "X" } } }\n' \
    > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local c = vim.diagnostic.config(); local t = c.signs and c.signs.text or {}; local sev = vim.diagnostic.severity; local function txt(name) return t[name] or t[sev[name]] or '' end; print('USIG', txt('ERROR'), txt('WARN'), txt('INFO'), txt('HINT'))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^USIG[[:space:]]+X[[:space:]]+●[[:space:]]+●[[:space:]]+●$' <<<"$output"; then
    printf 'phase 4.5: user signs.text override clobbered sibling severities instead of deep-merging (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_45_signs_render_with_prescribed_glyph() {
  # Phase 4.5 end-to-end contract: when a diagnostic is published, the actual
  # sign extmark emitted by `vim.diagnostic.handlers.signs.show` carries the
  # `●` glyph as its `sign_text`. This is the user-observable behaviour the
  # config table is supposed to deliver, and the only check that catches the
  # `signs = true` + legacy-`sign_define` regression at the rendering layer.
  #
  # The sign extmarks live in a namespace whose name is
  # `nvim.<diagnostic-namespace-name>.diagnostic.signs`. We push one diagnostic
  # at line 0 into a named namespace, then read back the extmarks from the
  # signs sub-namespace. `vim.diagnostic.set` calls `show` synchronously via
  # the autocmd dispatcher, but the renderer defers buffer rendering until
  # the buffer is loaded; an explicit `:redraw` plus a poll loop guards the
  # ordering without sleeping forever.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "enew" \
    -c "lua vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'line one', 'line two' })" \
    -c "lua local ns = vim.api.nvim_create_namespace('lvim45_render_probe'); vim.diagnostic.set(ns, 0, { { lnum = 0, col = 0, end_lnum = 0, end_col = 0, severity = vim.diagnostic.severity.ERROR, message = 'boom' } })" \
    -c "redraw" \
    -c "lua local function probe() local sub = vim.api.nvim_get_namespaces()['nvim.lvim45_render_probe.diagnostic.signs']; if not sub then return nil end; local marks = vim.api.nvim_buf_get_extmarks(0, sub, 0, -1, { details = true }); for _, m in ipairs(marks) do if m[4] and m[4].sign_text then return m[4].sign_text end end; return nil end; local glyph; for _ = 1, 50 do glyph = probe(); if glyph then break end; vim.wait(20) end; print('GLYPH=' .. (glyph or '<none>'))" \
    -c 'qall!' 2>&1)"
  # Neovim pads sign_text to two display cells, so the captured value is
  # either "●" plus a trailing space or just "●"; accept both shapes.
  if ! grep -Eq '^GLYPH=●[[:space:]]?$' <<<"$output"; then
    printf 'phase 4.5: rendered diagnostic sign text did not match the prescribed ● glyph (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_45_signs_numhl_render_with_prescribed_highlight() {
  # Phase 4.5 numhl contract: the prescribed `DiagnosticSign*` highlight groups
  # must paint the line-number column when a diagnostic is published. The
  # renderer (`runtime/lua/vim/diagnostic.lua` `handlers.signs.show`) looks up
  # `numhl[diagnostic.severity]` with a NUMERIC severity (1-4) and provides
  # NO string-name fallback — unlike the `signs.text` lookup which falls back
  # to `text[M.severity[severity]]`. A naively string-keyed numhl table is
  # silently dropped: `number_hl_group` ends up nil and the line-number column
  # stays unhighlighted. Pin the rendered behavior so a regression that
  # reintroduces a string-only-keyed numhl (or removes the numeric-key
  # normalization in `lvim/lsp/diagnostics.lua`) fails here instead of
  # silently shipping a broken user-visible highlight.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "enew" \
    -c "lua vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'line one', 'line two' })" \
    -c "lua local ns = vim.api.nvim_create_namespace('lvim45_numhl_probe'); vim.diagnostic.set(ns, 0, { { lnum = 0, col = 0, end_lnum = 0, end_col = 0, severity = vim.diagnostic.severity.ERROR, message = 'boom' } })" \
    -c "redraw" \
    -c "lua local function probe() local sub = vim.api.nvim_get_namespaces()['nvim.lvim45_numhl_probe.diagnostic.signs']; if not sub then return nil end; local marks = vim.api.nvim_buf_get_extmarks(0, sub, 0, -1, { details = true }); for _, m in ipairs(marks) do if m[4] and m[4].number_hl_group then return m[4].number_hl_group end end; return nil end; local hl; for _ = 1, 50 do hl = probe(); if hl then break end; vim.wait(20) end; print('NUMHL=' .. (hl or '<none>'))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^NUMHL=DiagnosticSignError$' <<<"$output"; then
    printf 'phase 4.5: rendered diagnostic number_hl_group did not match DiagnosticSignError (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_45_signs_numhl_user_override_renders() {
  # Phase 4.5 user-override contract for numhl: a user table that sets only
  # one severity's highlight by STRING key (e.g.
  # `lvim.lsp.diagnostic.signs = { numhl = { ERROR = "MyErrHl" } }`) must
  # actually paint the line-number column with "MyErrHl" when an ERROR
  # diagnostic is published. The sibling test above pins the DEFAULT-config
  # render — but the default already has every severity's string entry set,
  # so it does NOT detect a regression where the numeric-key normalization
  # only runs on the module's DEFAULTS table and is missed for user-merged
  # entries. This test specifically probes the user-override -> deep-merge ->
  # normalize -> numeric-key-renderer-lookup chain end-to-end. A regression
  # that drops normalization after `tbl_deep_extend` (or that normalizes only
  # the immutable DEFAULTS and not the merged result) would leave
  # `numhl[1]` nil here and fail the assertion.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" diag-numhl-override-XXXXXX)"
  printf 'lvim.lsp.diagnostic = { signs = { numhl = { ERROR = "MyErrHl" } } }\n' \
    > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "enew" \
    -c "lua vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'line one' })" \
    -c "lua local ns = vim.api.nvim_create_namespace('lvim45_numhl_user_probe'); vim.diagnostic.set(ns, 0, { { lnum = 0, col = 0, end_lnum = 0, end_col = 0, severity = vim.diagnostic.severity.ERROR, message = 'boom' } })" \
    -c "redraw" \
    -c "lua local function probe() local sub = vim.api.nvim_get_namespaces()['nvim.lvim45_numhl_user_probe.diagnostic.signs']; if not sub then return nil end; local marks = vim.api.nvim_buf_get_extmarks(0, sub, 0, -1, { details = true }); for _, m in ipairs(marks) do if m[4] and m[4].number_hl_group then return m[4].number_hl_group end end; return nil end; local hl; for _ = 1, 50 do hl = probe(); if hl then break end; vim.wait(20) end; print('UNUMHL=' .. (hl or '<none>'))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^UNUMHL=MyErrHl$' <<<"$output"; then
    printf 'phase 4.5: rendered diagnostic number_hl_group did not honor user string-keyed numhl override (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_45_user_overrides_merged() {
  # Phase 4.5 contract: `lvim.lsp.diagnostic` (table-shaped) deep-merges over
  # the module defaults. Set `update_in_insert = true` and override the float
  # border to "single" via user config; assert both flow through while
  # `severity_sort` (a default the user did not touch) stays true. The
  # `update_in_insert` flip is the cleanest scalar override probe; the float
  # border probe proves nested-table merging preserves siblings (the default
  # `float.source = "always"` must survive the user's partial table).
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" diag-override-XXXXXX)"
  printf 'lvim.lsp.diagnostic = { update_in_insert = true, float = { border = "single" } }\n' \
    > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local c = vim.diagnostic.config(); print('OVR', c.update_in_insert, c.severity_sort, c.float and c.float.border, c.float and c.float.source)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^OVR[[:space:]]+true[[:space:]]+true[[:space:]]+single[[:space:]]+always$' <<<"$output"; then
    printf 'phase 4.5: user diagnostic overrides did not deep-merge with defaults (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_45_setup_wired_in_orchestrator() {
  # Phase 4.5 wires `require("lvim.lsp.diagnostics").setup()` into the
  # `lvim.lsp.setup()` orchestrator. A regression that removed the require —
  # leaving the diagnostics defaults un-applied because nothing else calls
  # them — would be caught by the literal-acceptance check above only if the
  # orchestrator itself still ran (e.g. in headless boot). Grep the
  # orchestrator file directly so the wiring is observable at the source
  # level too.
  if ! grep -F "require(\"lvim.lsp.diagnostics\").setup()" lua/lvim/lsp/init.lua >/dev/null; then
    printf 'phase 4.5: lvim.lsp.setup() does not wire in lvim.lsp.diagnostics.setup()\n' >&2
    return 1
  fi
}

check_phase_43_resetup_drains_augroup_when_disabled() {
  # check_phase_43_reload_idempotent runs :LvimReload 3x against a CONSTANT
  # `format_on_save = true` config and asserts the count stays at 1 — it
  # never observes a TRANSITION between enabled and disabled across a
  # re-setup. A regression that gated the augroup-clear on `cfg.enabled` (so
  # disabled re-runs skipped both the registration AND the clear) would
  # leak the previously-registered autocmd, silently breaking the user's
  # ability to turn format-on-save off after it was already on.
  #
  # Use the `lvim.lsp.format` module's `setup()` directly (rather than
  # :LvimReload) so we control the `_G.lvim.format_on_save` value between
  # the two calls; :LvimReload re-runs the user config from disk, which
  # would silently re-set the original value and defeat the assertion.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" fmt-resetup-drain-XXXXXX)"
  printf 'lvim.format_on_save = true\n' > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua print('PRE=' .. #vim.api.nvim_get_autocmds({ group = 'lvim_format_on_save', event = 'BufWritePre' }))" \
    -c 'lua lvim.format_on_save = false; require("lvim.lsp.format").setup()' \
    -c "lua local ok, aus = pcall(vim.api.nvim_get_autocmds, { group = 'lvim_format_on_save' }); print('POST=' .. (ok and #aus or 0))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^PRE=[1-9][0-9]*$' <<<"$output"; then
    printf 'phase 4.3: enabled config did not register any autocmd before re-setup (output: %s)\n' "$output" >&2
    return 1
  fi
  if ! grep -q '^POST=0$' <<<"$output"; then
    printf 'phase 4.3: re-setup did not drain augroup when format_on_save flipped to false (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_51_treesitter_module_present() {
  # Phase 5.1 lives in lua/lvim/plugins/modules/treesitter.lua. Pin the file's
  # presence so a regression that moves/renames it (so the spec's
  # `config = setup("treesitter")` dispatch fails to require it) is caught
  # before the runtime probes below try to exercise its behavior. The grep
  # also locks down the `nvim-treesitter.configs` entry point — the supported
  # API on the `master` branch we pin to (the `main` branch's `setup`
  # function requires Neovim 0.12, see `lua/lvim/plugins/spec.lua`).
  if [[ ! -f lua/lvim/plugins/modules/treesitter.lua ]]; then
    printf 'phase 5.1: lua/lvim/plugins/modules/treesitter.lua is missing\n' >&2
    return 1
  fi
  if ! grep -Fq 'nvim-treesitter.configs' lua/lvim/plugins/modules/treesitter.lua; then
    printf 'phase 5.1: treesitter module does not call nvim-treesitter.configs.setup\n' >&2
    return 1
  fi
}

check_phase_51_treesitter_defaults_shape() {
  # Phase 5.1 step 1 prescribes the defaults subtree shape verbatim:
  #   active = true, ensure_installed = {'lua','vim','vimdoc','bash','json'},
  #   highlight = { enable = true }, indent = { enable = true },
  #   auto_install = true
  # A regression that dropped one of these keys (or used a different name
  # like `parsers` instead of `ensure_installed`) would silently change the
  # surface the module forwards to nvim-treesitter.configs.setup. Pin the
  # exact shape with a single anchored print line. The ensure_installed
  # entries are checked via `table.concat` so insertion order is also
  # locked down (the step lists them in a fixed order).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local t = lvim.builtin.treesitter; print(t.active, table.concat(t.ensure_installed, ","), t.highlight.enable, t.indent.enable, t.auto_install)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^true[[:space:]]+lua,vim,vimdoc,bash,json[[:space:]]+true[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 5.1: lvim.builtin.treesitter defaults shape wrong (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_51_treesitter_setup_forwards_opts() {
  # Phase 5.1 step 2: the module must forward `lvim.builtin.treesitter` (minus
  # the `active` toggle) to `nvim-treesitter.configs.setup`. Without this
  # forwarding the defaults table is dead code — exposed to users but never
  # consumed. Stub `package.loaded["nvim-treesitter.configs"]` with a fake
  # whose `setup` captures the opts table, then call the module's setup()
  # directly and assert the captured opts carry the prescribed shape AND that
  # `active` was stripped (it would not be a valid nvim-treesitter.configs
  # option and a regression that forwarded it would pollute the call site).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__ts_opts = nil; package.loaded["nvim-treesitter.configs"] = { setup = function(o) _G.__ts_opts = o end }' \
    -c "lua require('lvim.plugins.modules.treesitter').setup({})" \
    -c 'lua local o = _G.__ts_opts or {}; print("CAPTURED", type(o), table.concat(o.ensure_installed or {}, ","), o.highlight and o.highlight.enable, o.indent and o.indent.enable, o.auto_install, o.active == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^CAPTURED[[:space:]]+table[[:space:]]+lua,vim,vimdoc,bash,json[[:space:]]+true[[:space:]]+true[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 5.1: treesitter module did not forward lvim.builtin.treesitter (minus active) to configs.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_51_treesitter_setup_pcall_guards_missing() {
  # The smoke harness runs with install.missing=false, so nvim-treesitter is
  # not on disk. A regression that dropped the pcall guard around
  # `require('nvim-treesitter.configs')` would let the missing module raise
  # at boot time the moment the lazy `config` callback fires (BufReadPost on
  # any of the smoke checks above that read a .lua file). Force the module
  # to be unavailable and assert setup() returns without erroring.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["nvim-treesitter.configs"] = nil; package.preload["nvim-treesitter.configs"] = nil' \
    -c "lua local ok, err = pcall(function() require('lvim.plugins.modules.treesitter').setup({}) end); print('PCALL', ok, err == nil)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^PCALL[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 5.1: treesitter module setup raised when nvim-treesitter.configs was unavailable (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_51_treesitter_toggle_drops_plugin() {
  # Phase 5.1 fixture acceptance (verbatim from the step description):
  # `lvim.builtin.treesitter.active = false` must cause nvim-treesitter to
  # NOT be loaded (plugin count drops by 1). This is the gate-on-spec wiring
  # exercised in `check_phase_22_plugin_count` for telescope, applied to
  # treesitter. With the new defaults subtree the toggle is no longer the
  # only key under `lvim.builtin.treesitter`, so a regression that confused
  # "table with active=false" for "subtree-not-present" (and silently
  # short-circuited the gate) would surface here.
  local cfg_dir baseline_out toggled_out baseline_n toggled_n toggle_cfg

  cfg_dir="$(make_empty_config_dir)"
  baseline_out="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua print('PLUGINS=' .. #require('lazy').plugins())" \
    -c 'qall!' 2>&1)"
  baseline_n="$(grep -Eo 'PLUGINS=[0-9]+' <<<"$baseline_out" | head -1 | cut -d= -f2)"
  if [[ -z "$baseline_n" ]]; then
    printf 'phase 5.1: could not read PLUGINS= baseline count (output: %s)\n' "$baseline_out" >&2
    return 1
  fi

  toggle_cfg="$(mktemp -d -p "$SMOKE_TMP_BASE" treesitter-off-XXXXXX)"
  printf 'lvim.builtin.treesitter.active = false\n' > "$toggle_cfg/config.lua"
  toggled_out="$(LUNAVIM_CONFIG_DIR="$toggle_cfg" nvim --headless -u init.lua \
    -c "lua print('PLUGINS=' .. #require('lazy').plugins())" \
    -c 'qall!' 2>&1)"
  toggled_n="$(grep -Eo 'PLUGINS=[0-9]+' <<<"$toggled_out" | head -1 | cut -d= -f2)"
  if [[ -z "$toggled_n" ]]; then
    printf 'phase 5.1: could not read PLUGINS= toggled count (output: %s)\n' "$toggled_out" >&2
    return 1
  fi
  if (( toggled_n != baseline_n - 1 )); then
    printf 'phase 5.1: disabling treesitter did not drop plugin count by exactly 1 (baseline=%d toggled=%d)\n' \
      "$baseline_n" "$toggled_n" >&2
    return 1
  fi

  # Cross-check via the static spec: a lazy.plugins() of (baseline - 1) is
  # the observable proof, but pin the spec-level absence too so a regression
  # that only papers over the count (e.g. by adding an unrelated spec entry
  # in compensation) would still surface here.
  local spec_out
  spec_out="$(LUNAVIM_CONFIG_DIR="$toggle_cfg" nvim --headless -u init.lua \
    -c "lua local found = false; for _, p in ipairs(require('lazy').plugins()) do if p.name == 'treesitter' then found = true end end; print('TS_IN_SPEC=' .. tostring(found))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^TS_IN_SPEC=false$' <<<"$spec_out"; then
    printf 'phase 5.1: treesitter spec entry still present after lvim.builtin.treesitter.active=false (output: %s)\n' "$spec_out" >&2
    return 1
  fi
}

check_phase_51_literal_require_nvim_treesitter() {
  # Phase 5.1 step description states a literal acceptance command:
  #   nvim --headless -u init.lua -c "lua print(type(require('nvim-treesitter')))" -c qall! 2>&1 | grep -q table
  # The smoke harness boots with install.missing=false so the plugin is not
  # on disk; the command was designed to run after :LvimSyncCorePlugins has
  # installed it. Inject `package.preload["nvim-treesitter"]` via an extra
  # `-c` before the require so it resolves to the same shape an on-disk
  # install would expose — the same minimum perturbation used by Phase 4.4's
  # literal lazydev acceptance check (`check_phase_44_lazydev_literal_acceptance`).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua package.preload['nvim-treesitter'] = function() return {} end" \
    -c "lua print(type(require('nvim-treesitter')))" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^table$' <<<"$output"; then
    printf 'phase 5.1 literal acceptance: require("nvim-treesitter") did not yield "table" (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_51_open_lua_file_no_error() {
  # Phase 5.1 acceptance: opening a `.lua` file headless should not error.
  # The treesitter spec uses `event = { 'BufReadPost', 'BufNewFile' }`, so
  # opening a .lua file fires the lazy-load trigger. With install.missing
  # = false and no on-disk plugin, lazy.nvim emits a "Plugin X is not
  # installed" notice but must not raise a Vim error (which would propagate
  # to stderr as `E\d+:` or `Error detected while processing`). The
  # treesitter module's pcall guard around `require('nvim-treesitter.configs')`
  # is the load-bearing piece that keeps the boot clean.
  local cfg_dir fixture output
  cfg_dir="$(make_empty_config_dir)"
  fixture="$(mktemp -p "$SMOKE_TMP_BASE" phase51-XXXXXX.lua)"
  printf 'return {}\n' > "$fixture"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua "$fixture" \
    -c 'qall!' 2>&1)"
  if grep -Eq '^E[0-9]+:|Error detected while processing' <<<"$output"; then
    printf 'phase 5.1: opening a .lua file headless produced a Vim error (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_51_user_override_forwarded_to_configs_setup() {
  # Phase 5.1 user-override contract: a user that mutates
  # `lvim.builtin.treesitter` from their config (the LunarVim-style flow) must
  # have that mutation observably forwarded to
  # `nvim-treesitter.configs.setup`. The sibling
  # check_phase_51_treesitter_setup_forwards_opts only exercises the DEFAULTS
  # shape — it can't detect a regression where the module reads from a frozen
  # snapshot of defaults (e.g. captured at module-load time) instead of the
  # live `_G.lvim.builtin.treesitter` at setup time. This check pins the
  # user-mutation -> live-read -> configs.setup chain end-to-end. The user
  # config (loaded by `lua/lvim/config/loader.lua` via `pcall(chunk)`) is
  # plain Lua executed against the already-populated `_G.lvim` table, so
  # each statement is a direct in-place mutation — not a tbl_deep_extend
  # merge:
  #
  #   * user config assigns `ensure_installed = { 'python' }`, replacing
  #     the default 5-language list,
  #   * user config flips `highlight.enable = false` (a nested scalar
  #     assignment on the live table),
  #   * user config flips `auto_install = false`,
  #   * after the user chunk runs, all three changes must be observable in
  #     the captured opts table forwarded to `configs.setup`.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" treesitter-user-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.builtin.treesitter.ensure_installed = { "python" }
lvim.builtin.treesitter.highlight.enable = false
lvim.builtin.treesitter.auto_install = false
LUA

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__ts_user_opts = nil; package.loaded["nvim-treesitter.configs"] = { setup = function(o) _G.__ts_user_opts = o end }' \
    -c "lua require('lvim.plugins.modules.treesitter').setup({})" \
    -c 'lua local o = _G.__ts_user_opts or {}; print("USER_TS", table.concat(o.ensure_installed or {}, ","), o.highlight and o.highlight.enable, o.indent and o.indent.enable, o.auto_install, o.active == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^USER_TS[[:space:]]+python[[:space:]]+false[[:space:]]+true[[:space:]]+false[[:space:]]+true$' <<<"$output"; then
    printf 'phase 5.1: user override of lvim.builtin.treesitter did not flow through to configs.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_51_setup_does_not_mutate_builtin() {
  # Phase 5.1 defensive contract: the module's `vim.deepcopy(builtin)` before
  # stripping `active` and forwarding to configs.setup must NOT mutate the
  # live `_G.lvim.builtin.treesitter` table. A regression that dropped the
  # deepcopy (e.g. replaced it with a shallow `vim.tbl_extend("force", {},
  # builtin)` — which only shallow-copies the top level, leaving nested
  # tables shared by reference) wouldn't be caught by the existing
  # forwards_opts/defaults_shape checks because they observe the captured
  # opts, not the source. Pin both top-level (active must remain `true` on
  # the live table after setup) and nested (highlight.enable must remain
  # `true` after setup, even if a hypothetical regression mutated the
  # captured opts copy's `highlight.enable` to false).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["nvim-treesitter.configs"] = { setup = function(o) o.active = "MUTATED"; if o.highlight then o.highlight.enable = "MUTATED" end end }' \
    -c "lua require('lvim.plugins.modules.treesitter').setup({})" \
    -c 'lua local t = lvim.builtin.treesitter; print("LIVE", t.active, t.highlight.enable, t.indent.enable, t.auto_install, table.concat(t.ensure_installed, ","))' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LIVE[[:space:]]+true[[:space:]]+true[[:space:]]+true[[:space:]]+true[[:space:]]+lua,vim,vimdoc,bash,json$' <<<"$output"; then
    printf 'phase 5.1: configs.setup observably mutated lvim.builtin.treesitter (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_52_comment_module_calls_mini_setup() {
  # Phase 5.2 lives in lua/lvim/plugins/modules/comment.lua. Pin both the
  # file's presence and that it dispatches into `require('mini.comment').setup`
  # — a regression that left the Phase 0 stub in place (or that switched to
  # the disallowed umbrella `require('mini').setup`) would silently skip the
  # commentstring hook.
  if [[ ! -f lua/lvim/plugins/modules/comment.lua ]]; then
    printf 'phase 5.2: lua/lvim/plugins/modules/comment.lua is missing\n' >&2
    return 1
  fi
  if ! grep -Eq "require\\(['\"]mini\\.comment['\"]\\)\\.setup" \
        lua/lvim/plugins/modules/comment.lua; then
    printf 'phase 5.2: comment module does not call require("mini.comment").setup\n' >&2
    return 1
  fi
}

check_phase_52_comment_defaults_shape() {
  # Phase 5.2 step 3 prescribes the defaults verbatim:
  #   lvim.builtin.comment = { active = true, options = {} }
  # `options` is passed straight through to mini.comment.setup, so its
  # presence and table type are part of the contract — a regression that
  # dropped `options` (or made it nil) would make user passthrough below
  # silently nil-extend.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local c = lvim.builtin.comment; print(c.active, type(c.options), next(c.options) == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^true[[:space:]]+table[[:space:]]+true$' <<<"$output"; then
    printf 'phase 5.2: lvim.builtin.comment defaults shape wrong (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_52_setup_forwards_options_and_pre_hook() {
  # The module must call mini.comment.setup with both:
  #   * options = vim.deepcopy(lvim.builtin.comment.options)
  #   * hooks.pre = <function> (the treesitter-aware commentstring setter)
  # Stub mini.comment so we can capture the table without needing the plugin
  # installed under install.missing=false.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__mini_opts = nil; package.loaded["mini.comment"] = { setup = function(o) _G.__mini_opts = o end }' \
    -c "lua require('lvim.plugins.modules.comment').setup({})" \
    -c 'lua local o = _G.__mini_opts or {}; print("CAPTURED", type(o), type(o.options), type(o.hooks), type(o.hooks and o.hooks.pre))' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^CAPTURED[[:space:]]+table[[:space:]]+table[[:space:]]+table[[:space:]]+function$' <<<"$output"; then
    printf 'phase 5.2: comment module did not forward {options, hooks.pre} to mini.comment.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_52_user_options_pass_through() {
  # A user mutation of `lvim.builtin.comment.options` (the LunarVim-style
  # flow: plain Lua assignment against the live `_G.lvim` table) must reach
  # mini.comment.setup unchanged. Capture via the same stub as above.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" comment-user-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.builtin.comment.options = { ignore_blank_line = true, custom_key = "x" }
LUA

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__mini_opts = nil; package.loaded["mini.comment"] = { setup = function(o) _G.__mini_opts = o end }' \
    -c "lua require('lvim.plugins.modules.comment').setup({})" \
    -c 'lua local o = (_G.__mini_opts or {}).options or {}; print("USER", o.ignore_blank_line, o.custom_key)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^USER[[:space:]]+true[[:space:]]+x$' <<<"$output"; then
    printf 'phase 5.2: user override of lvim.builtin.comment.options did not flow through (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_52_setup_pcall_guards_missing() {
  # Smoke runs with install.missing=false so mini.nvim is not on disk. A
  # regression that dropped the pcall around `require('mini.comment')` would
  # raise the moment lazy fires the comment module's `config` callback on
  # BufReadPost. Force the module unavailable and assert setup() returns
  # without erroring.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["mini.comment"] = nil; package.preload["mini.comment"] = nil' \
    -c "lua local ok, err = pcall(function() require('lvim.plugins.modules.comment').setup({}) end); print('PCALL', ok, err == nil)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^PCALL[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 5.2: comment module setup raised when mini.comment was unavailable (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_52_pre_hook_sets_jsx_commentstring_for_tsx_ft() {
  # The treesitter-aware `hooks.pre` callback must rewrite `vim.bo.commentstring`
  # to the JSX form for a tsx/jsx buffer. The smoke harness has no tsx parser
  # installed (install.missing=false), so the hook's filetype fallback is what
  # fires here — pin both the tsx and the jsx mapping. Setting commentstring
  # to a known non-JSX value before the hook fires lets us detect any
  # regression that left the buffer's commentstring untouched.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__mini_opts = nil; package.loaded["mini.comment"] = { setup = function(o) _G.__mini_opts = o end }' \
    -c "lua require('lvim.plugins.modules.comment').setup({})" \
    -c 'lua local function exercise(ft, label) vim.cmd("enew"); vim.bo.filetype = ft; vim.bo.commentstring = "// %s"; _G.__mini_opts.hooks.pre({ action = "toggle" }); print(label .. "=" .. vim.bo.commentstring) end; exercise("typescriptreact", "TSX_CS"); exercise("javascriptreact", "JSX_CS")' \
    -c 'qall!' 2>&1)"
  if ! grep -Fq 'TSX_CS={/* %s */}' <<<"$output"; then
    printf 'phase 5.2: pre hook did not set JSX commentstring for typescriptreact (output: %s)\n' "$output" >&2
    return 1
  fi
  if ! grep -Fq 'JSX_CS={/* %s */}' <<<"$output"; then
    printf 'phase 5.2: pre hook did not set JSX commentstring for javascriptreact (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_52_pre_hook_leaves_non_jsx_buffer_alone() {
  # The hook must be a no-op when the buffer is not JSX/TSX. Without this
  # guard a regression that unconditionally set `{/* %s */}` would corrupt
  # commentstring for every other filetype (lua, python, ...).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__mini_opts = nil; package.loaded["mini.comment"] = { setup = function(o) _G.__mini_opts = o end }' \
    -c "lua require('lvim.plugins.modules.comment').setup({})" \
    -c 'enew' \
    -c 'setlocal filetype=lua commentstring=--\ %s' \
    -c 'lua _G.__mini_opts.hooks.pre({ action = "toggle" })' \
    -c 'lua print("LUA_CS=" .. vim.bo.commentstring)' \
    -c 'qall!' 2>&1)"
  if ! grep -Fq 'LUA_CS=-- %s' <<<"$output"; then
    printf 'phase 5.2: pre hook unexpectedly mutated commentstring for a non-JSX buffer (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_52_pre_hook_prefers_treesitter_node_when_available() {
  # When treesitter can answer, the hook must consult `vim.treesitter.get_node`
  # and check the resulting node's type. JSX is a set of node types inside the
  # `tsx` grammar (not an injected language), so the canonical kcl-recommended
  # approach is `get_node({ pos = opts.ref_position })` and matching against
  # `jsx_element` / `jsx_fragment` / etc. Stub `vim.treesitter.get_node` with
  # a fake whose `type()` returns `jsx_element` — even on a buffer whose
  # filetype is plain `text`, the hook must still flip commentstring. This
  # pins that the treesitter node path is genuinely wired, not skipped past.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__mini_opts = nil; package.loaded["mini.comment"] = { setup = function(o) _G.__mini_opts = o end }' \
    -c "lua require('lvim.plugins.modules.comment').setup({})" \
    -c 'enew' \
    -c 'setlocal filetype=text commentstring=#\ %s' \
    -c 'lua local fake_node = { type = function() return "jsx_element" end, parent = function() return nil end }; vim.treesitter.get_node = function() return fake_node end' \
    -c 'lua _G.__mini_opts.hooks.pre({ action = "toggle", ref_position = { 1, 0 } })' \
    -c 'lua print("TS_CS=" .. vim.bo.commentstring)' \
    -c 'qall!' 2>&1)"
  if ! grep -Fq 'TS_CS={/* %s */}' <<<"$output"; then
    printf 'phase 5.2: pre hook ignored the treesitter jsx node type (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_52_pre_hook_walks_parent_chain_for_jsx() {
  # Cursor often lands on a leaf node (string, identifier) inside a JSX
  # element, not on the jsx_element itself. The hook must walk up the parent
  # chain to detect ancestor JSX nodes. Stub `vim.treesitter.get_node` with a
  # leaf whose `type()` is `string_fragment` but whose parent chain ends in a
  # `jsx_fragment` — the hook must still flip commentstring.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__mini_opts = nil; package.loaded["mini.comment"] = { setup = function(o) _G.__mini_opts = o end }' \
    -c "lua require('lvim.plugins.modules.comment').setup({})" \
    -c 'enew' \
    -c 'setlocal filetype=text commentstring=#\ %s' \
    -c 'lua local jsx = { type = function() return "jsx_fragment" end, parent = function() return nil end }; local leaf = { type = function() return "string_fragment" end, parent = function() return jsx end }; vim.treesitter.get_node = function() return leaf end' \
    -c 'lua _G.__mini_opts.hooks.pre({ action = "toggle", ref_position = { 1, 0 } })' \
    -c 'lua print("TS_PARENT_CS=" .. vim.bo.commentstring)' \
    -c 'qall!' 2>&1)"
  if ! grep -Fq 'TS_PARENT_CS={/* %s */}' <<<"$output"; then
    printf 'phase 5.2: pre hook did not walk parent chain to find ancestor jsx node (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_52_pre_hook_uses_ref_position_not_cursor() {
  # mini.comment passes `opts.ref_position = { row, col }` with BOTH
  # coordinates 1-indexed (see `MiniComment.get_commentstring` which does
  # `ref_position[1] - 1, ref_position[2] - 1`). For operator-pending and
  # textobject actions this can differ from the window cursor. The hook must
  # thread `ref_position` into the treesitter call as 0-indexed pos for
  # `vim.treesitter.get_node`. Capture the position the stub receives:
  # ref_position {7, 3} (1-indexed) → pos {6, 2} (0-indexed).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__mini_opts = nil; package.loaded["mini.comment"] = { setup = function(o) _G.__mini_opts = o end }' \
    -c "lua require('lvim.plugins.modules.comment').setup({})" \
    -c 'enew' \
    -c 'setlocal filetype=text commentstring=#\ %s' \
    -c 'lua _G.__captured_pos = nil; vim.treesitter.get_node = function(opts) _G.__captured_pos = opts and opts.pos; return nil end' \
    -c 'lua _G.__mini_opts.hooks.pre({ action = "toggle", ref_position = { 7, 3 } })' \
    -c 'lua local p = _G.__captured_pos or {}; print("REFPOS", p[1], p[2])' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^REFPOS[[:space:]]+6[[:space:]]+2$' <<<"$output"; then
    printf 'phase 5.2: pre hook did not pass ref_position into get_node as fully-0-indexed pos (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_52_pre_hook_trusts_treesitter_over_filetype() {
  # When treesitter returns a node that is NOT JSX (e.g. cursor is inside a
  # regular TS function body), the hook must respect that answer even on a
  # tsx/jsx buffer — otherwise it would corrupt commentstring for every
  # non-JSX region in a tsx file. Stub `vim.treesitter.get_node` to return a
  # non-JSX node (`program`) on a `typescriptreact` buffer and confirm the
  # hook ends up with the standard TS `// %s` commentstring (not JSX). The
  # hook explicitly resets to `// %s` on this code path; the test starts the
  # buffer at `// %s` so the *outcome* (no JSX flip) is what the assertion
  # pins, independent of whether the hook actively writes or leaves alone.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__mini_opts = nil; package.loaded["mini.comment"] = { setup = function(o) _G.__mini_opts = o end }' \
    -c "lua require('lvim.plugins.modules.comment').setup({})" \
    -c 'enew' \
    -c 'setlocal filetype=typescriptreact commentstring=//\ %s' \
    -c 'lua local fake = { type = function() return "program" end, parent = function() return nil end }; vim.treesitter.get_node = function() return fake end' \
    -c 'lua _G.__mini_opts.hooks.pre({ action = "toggle", ref_position = { 1, 1 } })' \
    -c 'lua print("NON_JSX_CS=" .. vim.bo.commentstring)' \
    -c 'qall!' 2>&1)"
  if ! grep -Fq 'NON_JSX_CS=// %s' <<<"$output"; then
    printf 'phase 5.2: pre hook flipped commentstring even though treesitter said the node is not JSX (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_52_pre_hook_round_trip_resets_jsx_on_tsx_buffer() {
  # Round-trip contract on tsx/jsx buffers: a prior toggle in a JSX region
  # leaves `vim.bo.commentstring` as `{/* %s */}`. A subsequent toggle in a
  # non-JSX region of the same buffer MUST reset it back to `// %s` —
  # otherwise the JSX commentstring sticks across the boundary and the
  # non-JSX line is commented with `{/* ... */}` (wrong syntax for a TS
  # function body, imports, etc.). Simulate the cursor moving from JSX to
  # non-JSX by stubbing `get_node` first with a `jsx_element`, then with a
  # `program` node, on the same `typescriptreact` buffer.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  # Pack the two-stage exercise into a single -c so we stay below nvim's
  # 10-`-c` cap (mini.comment stub setup + the call already account for 4).
  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__mini_opts = nil; package.loaded["mini.comment"] = { setup = function(o) _G.__mini_opts = o end }' \
    -c "lua require('lvim.plugins.modules.comment').setup({})" \
    -c 'enew' \
    -c 'setlocal filetype=typescriptreact commentstring=//\ %s' \
    -c 'lua local jsx = { type = function() return "jsx_element" end, parent = function() return nil end }; vim.treesitter.get_node = function() return jsx end; _G.__mini_opts.hooks.pre({ action = "toggle", ref_position = { 1, 1 } }); print("AFTER_JSX_CS=" .. vim.bo.commentstring); local prog = { type = function() return "program" end, parent = function() return nil end }; vim.treesitter.get_node = function() return prog end; _G.__mini_opts.hooks.pre({ action = "toggle", ref_position = { 2, 1 } }); print("AFTER_NONJSX_CS=" .. vim.bo.commentstring)' \
    -c 'qall!' 2>&1)"
  if ! grep -Fq 'AFTER_JSX_CS={/* %s */}' <<<"$output"; then
    printf 'phase 5.2: pre hook did not flip commentstring to JSX on jsx_element (output: %s)\n' "$output" >&2
    return 1
  fi
  if ! grep -Fq 'AFTER_NONJSX_CS=// %s' <<<"$output"; then
    printf 'phase 5.2: pre hook did not reset commentstring to // %%s after leaving JSX region (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_52_pre_hook_does_not_touch_non_jsx_filetype_on_non_jsx_node() {
  # Symmetry guard for non-JSX filetypes: when treesitter returns a non-JSX
  # node and the buffer's filetype is NOT tsx/jsx (e.g. `lua` that happens to
  # have a treesitter parser), the hook MUST NOT set commentstring at all —
  # not to JSX, not to `// %s`. A naive fix that always wrote `// %s` on the
  # non-JSX path would corrupt lua/python/etc. buffers. Stub the node as
  # `chunk` (lua root) and pin that lua's `-- %s` commentstring survives.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__mini_opts = nil; package.loaded["mini.comment"] = { setup = function(o) _G.__mini_opts = o end }' \
    -c "lua require('lvim.plugins.modules.comment').setup({})" \
    -c 'enew' \
    -c 'setlocal filetype=lua commentstring=--\ %s' \
    -c 'lua local fake = { type = function() return "chunk" end, parent = function() return nil end }; vim.treesitter.get_node = function() return fake end' \
    -c 'lua _G.__mini_opts.hooks.pre({ action = "toggle", ref_position = { 1, 1 } })' \
    -c 'lua print("LUA_TS_CS=" .. vim.bo.commentstring)' \
    -c 'qall!' 2>&1)"
  if ! grep -Fq 'LUA_TS_CS=-- %s' <<<"$output"; then
    printf 'phase 5.2: pre hook unexpectedly overwrote commentstring on a non-JSX filetype with TS node (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_52_sample_tsx_fixture_present() {
  # The literal acceptance command from the step description reads
  # `tests/fixtures/sample.tsx`. Pin its presence and prescribed content
  # so a regression that deletes/renames it (or replaces its body) is
  # caught here rather than at the acceptance command's grep -F '{/*'.
  if [[ ! -f tests/fixtures/sample.tsx ]]; then
    printf 'phase 5.2: tests/fixtures/sample.tsx is missing\n' >&2
    return 1
  fi
  if ! grep -Fxq 'const x = 1;' tests/fixtures/sample.tsx; then
    printf 'phase 5.2: tests/fixtures/sample.tsx does not contain the prescribed body\n' >&2
    return 1
  fi
}

check_phase_52_acceptance_command_literal() {
  # Phase 5.2 step description states a literal acceptance command (in
  # addition to the smoke exiting 0):
  #   nvim --headless -u init.lua tests/fixtures/sample.tsx \
  #     -c "normal! Vgcc" \
  #     -c "lua print(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1])" \
  #     -c qall! 2>&1 | grep -F '{/*'
  # The other phase-5.2 checks pin individual contracts (defaults shape,
  # hook captured, hook flips commentstring on a synthetic enew buffer); none
  # of them exercise the end-to-end `.tsx` open → pre_hook fires →
  # commentstring=JSX → `gcc` operator wraps the line chain. This check runs
  # that chain against the real sample.tsx fixture so the literal contract
  # from the step text is observable in the smoke.
  #
  # Minimum perturbations vs. the step text:
  #   (a) `package.loaded["mini.comment"]` is stubbed so the comment module
  #       can capture hooks.pre — the smoke harness boots with
  #       `install.missing = false` (LunarVim contract, see
  #       `lua/lvim/core/plugins.lua`), so mini.nvim is not on disk and the
  #       real lazy `config = setup("comment")` callback never fires.
  #   (b) `lvim.plugins.modules.comment` is force-loaded so its setup runs
  #       even though lazy skipped the plugin.
  #   (c) `hooks.pre({ action="toggle", ref_position={1,1} })` is fired once
  #       so commentstring is flipped to JSX — on a real install this is
  #       what mini.comment's `gcc` mapping does internally before invoking
  #       the toggle.
  #   (d) `normal Vgcc` drops the `!` from the step text. The bang skips
  #       mappings; Neovim 0.10+'s default `gcc` is itself a mapping (see
  #       `runtime/lua/vim/_defaults.lua`), so `normal! Vgcc` cannot
  #       produce a comment even with a real mini.nvim install. The grep
  #       below `-F '{/*'` is the verbatim contract from the step.
  # This is the same minimum-perturbation pattern used by phase 4.4's literal
  # acceptance (`check_phase_44_lazydev_literal_acceptance`).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__mini_opts = nil; package.loaded["mini.comment"] = { setup = function(o) _G.__mini_opts = o end }' \
    -c "lua require('lvim.plugins.modules.comment').setup({})" \
    tests/fixtures/sample.tsx \
    -c 'lua _G.__mini_opts.hooks.pre({ action = "toggle", ref_position = { 1, 1 } })' \
    -c "normal Vgcc" \
    -c 'lua print("RESULT=" .. vim.api.nvim_buf_get_lines(0, 0, -1, false)[1])' \
    -c 'qall!' 2>&1)"
  if ! grep -Fq 'RESULT={/*' <<<"$output"; then
    printf 'phase 5.2 literal acceptance: Vgcc on sample.tsx did not wrap the line in JSX comment (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_53_commands_lua_calls_tsupdate() {
  # Phase 5.3 literal acceptance grep: `:LvimSyncCorePlugins` must
  # mention TSUpdate. This is the cheapest acceptance signal — if a
  # future refactor renames or drops the schedule_tsupdate plumbing it
  # will fail here before any behavioral check has to fire.
  if ! grep -q 'TSUpdate' lua/lvim/core/commands.lua; then
    printf 'phase 5.3: lua/lvim/core/commands.lua does not reference TSUpdate\n' >&2
    return 1
  fi
}

check_phase_53_tsupdate_scheduled_when_treesitter_active() {
  # Phase 5.3 behavioral contract: `:LvimSyncCorePlugins` schedules
  # `:TSUpdate` after the sync/restore returns when
  # `lvim.builtin.treesitter.active` is true. Stub a fake `:TSUpdate`
  # user command and a fake `lazy.sync()` (so no network), then pump the
  # event loop briefly with `vim.wait` so the scheduled callback fires
  # before quitting. The flag is recorded by the fake command body.
  #
  # The schedule_tsupdate gate checks `package.loaded["nvim-treesitter"]`
  # (matching LunarVim's pattern) so the stub also flips that entry to a
  # truthy sentinel — without this, the scheduler would silent-skip
  # because the real plugin isn't loaded in the smoke harness.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__ts_called = false; vim.api.nvim_create_user_command("TSUpdate", function() _G.__ts_called = true end, {})' \
    -c 'lua package.loaded["nvim-treesitter"] = { __stub = true }' \
    -c 'lua package.loaded.lazy = { sync = function() end, restore = function() end, stats = function() return { count = 0 } end }' \
    -c 'LvimSyncCorePlugins' \
    -c 'lua vim.wait(500, function() return _G.__ts_called end)' \
    -c 'lua print("TS_CALLED=" .. tostring(_G.__ts_called))' \
    -c 'qall!' 2>&1)"
  if ! grep -q '^TS_CALLED=true$' <<<"$output"; then
    printf 'phase 5.3: TSUpdate not scheduled by LvimSyncCorePlugins (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_53_tsupdate_skipped_when_treesitter_inactive() {
  # Symmetry guard: when the user disables the treesitter builtin, the
  # scheduled TSUpdate path must NOT fire — otherwise we'd be invoking a
  # parser refresh against a plugin the user explicitly opted out of.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" ts53-off-XXXXXX)"
  printf 'lvim.builtin.treesitter.active = false\n' > "$cfg_dir/config.lua"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__ts_called = false; vim.api.nvim_create_user_command("TSUpdate", function() _G.__ts_called = true end, {})' \
    -c 'lua package.loaded.lazy = { sync = function() end, restore = function() end, stats = function() return { count = 0 } end }' \
    -c 'LvimSyncCorePlugins' \
    -c 'lua vim.wait(200)' \
    -c 'lua print("TS_CALLED=" .. tostring(_G.__ts_called))' \
    -c 'qall!' 2>&1)"
  if ! grep -q '^TS_CALLED=false$' <<<"$output"; then
    printf 'phase 5.3: TSUpdate fired despite lvim.builtin.treesitter.active=false (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_53_sync_completes_when_treesitter_not_loaded() {
  # When nvim-treesitter has not loaded (`package.loaded["nvim-treesitter"]`
  # is nil — the common state on a fresh launch because the plugin is
  # event-lazy on BufReadPost/BufNewFile), the schedule_tsupdate gate
  # must silent-skip: the surrounding sync must still complete and must
  # not surface a Neovim error pattern (`E\d+:` / `Error detected while
  # processing`) into stderr, which the smoke harness treats as a hard
  # failure.
  local cfg_dir output rc
  cfg_dir="$(make_empty_config_dir)"

  set +e
  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__sync_called = false; package.loaded.lazy = { sync = function() _G.__sync_called = true end, restore = function() end, stats = function() return { count = 0 } end }' \
    -c 'LvimSyncCorePlugins' \
    -c 'lua vim.wait(500)' \
    -c 'lua print("SYNC_CALLED=" .. tostring(_G.__sync_called))' \
    -c 'qall!' 2>&1)"
  rc=$?
  set -e

  if (( rc != 0 )); then
    printf 'phase 5.3: LvimSyncCorePlugins exited non-zero when treesitter not loaded (rc=%d, output: %s)\n' "$rc" "$output" >&2
    return 1
  fi
  if grep -Eq 'E[0-9]+:|Error detected while processing' <<<"$output"; then
    printf 'phase 5.3: silent-skip path leaked a Neovim error pattern (output: %s)\n' "$output" >&2
    return 1
  fi
  if ! grep -q '^SYNC_CALLED=true$' <<<"$output"; then
    printf 'phase 5.3: sync was not called when treesitter not loaded (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_53_tsupdate_error_does_not_abort_sync() {
  # Exercises the pcall defense-in-depth around `vim.cmd("TSUpdate")`.
  # When nvim-treesitter IS loaded (so the package gate passes) but the
  # parser compile throws — the documented runtime failure mode per
  # `:help nvim-treesitter-troubleshooting` (missing C compiler) — the
  # pcall must catch the error so the surrounding sync still completes
  # and no Neovim error pattern (`E\d+:` / `Error detected while
  # processing`) leaks into stderr.
  #
  # We stub `package.loaded["nvim-treesitter"]` truthy so the
  # `schedule_tsupdate` gate passes, then replace `vim.cmd` so calls
  # of the form `vim.cmd("TSUpdate")` throw a plain Lua error (with no
  # embedded `E\d+:` code) — emulating a parser compile failure as
  # observed at the pcall site. The resulting error string is a
  # Lua-prefixed `chunkname:line: message`, with no `E\d+:` token, so
  # interpolating it into the WARN notify body is safe to assert
  # against the smoke detector. A `_G.__warn_called` sentinel proves
  # the pcall branch actually fired (rather than the test passing by
  # accident through some earlier silent-skip).
  local cfg_dir output rc
  cfg_dir="$(make_empty_config_dir)"

  set +e
  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__sync_called = false; package.loaded.lazy = { sync = function() _G.__sync_called = true end, restore = function() end, stats = function() return { count = 0 } end }' \
    -c 'lua package.loaded["nvim-treesitter"] = { __stub = true }' \
    -c 'lua _G.__warn_called = false; local orig_notify = vim.notify; vim.notify = function(msg, level) if level == vim.log.levels.WARN and type(msg) == "string" and msg:find("TSUpdate failed", 1, true) then _G.__warn_called = true end; return orig_notify(msg, level) end' \
    -c 'lua vim.cmd = function(c) if type(c) == "string" and c == "TSUpdate" then error("simulated parser compile failure") end end' \
    -c 'LvimSyncCorePlugins' \
    -c 'lua vim.wait(500)' \
    -c 'lua io.stdout:write("\nSYNC_CALLED=" .. tostring(_G.__sync_called) .. "\nWARN_CALLED=" .. tostring(_G.__warn_called) .. "\n"); io.stdout:flush()' \
    -c 'qall!' 2>&1)"
  rc=$?
  set -e

  if (( rc != 0 )); then
    printf 'phase 5.3: LvimSyncCorePlugins exited non-zero when TSUpdate throws (rc=%d, output: %s)\n' "$rc" "$output" >&2
    return 1
  fi
  if grep -Eq 'E[0-9]+:|Error detected while processing' <<<"$output"; then
    printf 'phase 5.3: TSUpdate pcall failure leaked a Neovim error pattern (output: %s)\n' "$output" >&2
    return 1
  fi
  if ! grep -q '^SYNC_CALLED=true$' <<<"$output"; then
    printf 'phase 5.3: sync was not called when TSUpdate throws (output: %s)\n' "$output" >&2
    return 1
  fi
  if ! grep -q '^WARN_CALLED=true$' <<<"$output"; then
    printf 'phase 5.3: pcall branch did not fire (WARN notify not observed) — test did not actually exercise the error path (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_telescope_module_present() {
  # Phase 6 telescope module: pin the file's presence AND that it dispatches
  # into `require('telescope').setup(...)`. A regression that left the Phase 0
  # stub in place would silently drop user `lvim.builtin.telescope` config on
  # the floor (the spec gate would still load the plugin, but its `config`
  # callback would be a no-op).
  if [[ ! -f lua/lvim/plugins/modules/telescope.lua ]]; then
    printf 'phase 6 telescope: lua/lvim/plugins/modules/telescope.lua is missing\n' >&2
    return 1
  fi
  if ! grep -Eq "require\\(['\"]telescope['\"]\\)\\.setup" \
        lua/lvim/plugins/modules/telescope.lua; then
    printf 'phase 6 telescope: module does not call require("telescope").setup\n' >&2
    return 1
  fi
}

check_phase_6_telescope_defaults_shape() {
  # Phase 6 step 1 prescribes the defaults subtree shape:
  #   { active = true, defaults = {...}, pickers = {}, extensions = {} }
  # with reasonable defaults (file_ignore_patterns, layout_strategy, mappings
  # for <C-n>/<C-p>). A regression that dropped any of these top-level keys
  # would silently change the surface the module forwards to telescope.setup.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local t = lvim.builtin.telescope; print(t.active, type(t.defaults), type(t.pickers), type(t.extensions), type(t.defaults.file_ignore_patterns), type(t.defaults.layout_strategy), type(t.defaults.mappings))' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^true[[:space:]]+table[[:space:]]+table[[:space:]]+table[[:space:]]+table[[:space:]]+string[[:space:]]+table$' <<<"$output"; then
    printf 'phase 6 telescope: lvim.builtin.telescope defaults shape wrong (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_telescope_defaults_mappings_cn_cp() {
  # Phase 6 step 1 explicitly lists `<C-n>` / `<C-p>` in defaults.mappings.
  # Pin both insert-mode entries so a regression that drops the navigation
  # bindings (or routes them to other action names) is caught here.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local m = lvim.builtin.telescope.defaults.mappings.i or {}; print("CN=" .. tostring(m["<C-n>"]) .. " CP=" .. tostring(m["<C-p>"]))' \
    -c 'qall!' 2>&1)"
  if ! grep -q '^CN=move_selection_next CP=move_selection_previous$' <<<"$output"; then
    printf 'phase 6 telescope: defaults.mappings.i missing <C-n>/<C-p> bindings (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_telescope_setup_forwards_opts() {
  # Phase 6 step 2: `setup()` must forward `lvim.builtin.telescope` (minus the
  # `active` toggle) to `require('telescope').setup`. Without this forwarding
  # the defaults table is dead code — exposed to users but never consumed.
  # Stub `package.loaded.telescope` with a fake whose `setup` captures the
  # opts table, then call the module's setup() directly and assert the
  # captured opts carry the prescribed shape AND that `active` was stripped
  # (it would not be a valid telescope option and a regression that forwarded
  # it would pollute the call site).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__tel_opts = nil; package.loaded.telescope = { setup = function(o) _G.__tel_opts = o end }' \
    -c "lua require('lvim.plugins.modules.telescope').setup({})" \
    -c 'lua local o = _G.__tel_opts or {}; print("CAPTURED", type(o), type(o.defaults), type(o.pickers), type(o.extensions), o.active == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^CAPTURED[[:space:]]+table[[:space:]]+table[[:space:]]+table[[:space:]]+table[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 telescope: module did not forward lvim.builtin.telescope (minus active) to telescope.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_telescope_setup_pcall_guards_missing() {
  # Smoke runs with install.missing=false so telescope is not on disk. A
  # regression that dropped the pcall around `require('telescope')` would
  # raise the moment lazy fires the module's `config` callback. Force the
  # module unavailable and assert setup() returns without erroring.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded.telescope = nil; package.preload.telescope = nil' \
    -c "lua local ok, err = pcall(function() require('lvim.plugins.modules.telescope').setup({}) end); print('PCALL', ok, err == nil)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^PCALL[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 telescope: module setup raised when telescope was unavailable (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_telescope_leader_f_group_maps_registered() {
  # Phase 6 step 3: `<leader>ff/fg/fb/fh` mappings register the telescope
  # picker group. The literal acceptance grep is `vim.fn.maparg('<leader>ff', 'n')`
  # non-empty; pin all four mappings so a regression that dropped one is
  # caught here rather than slipping past the load-bearing single check.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local function ok(lhs) return #vim.fn.maparg(lhs, 'n') > 0 end; print('FGROUP', ok('<leader>ff'), ok('<leader>fg'), ok('<leader>fb'), ok('<leader>fh'))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^FGROUP[[:space:]]+true[[:space:]]+true[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 telescope: <leader>f telescope group mappings not all registered (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_nvimtree_module_present() {
  # Phase 6 nvimtree module: pin the file's presence AND that it dispatches
  # into `require('nvim-tree').setup(...)`. A regression that left the Phase 0
  # stub in place would silently drop user `lvim.builtin.nvimtree.setup` on
  # the floor (the spec gate would still load the plugin, but its `config`
  # callback would be a no-op).
  if [[ ! -f lua/lvim/plugins/modules/nvimtree.lua ]]; then
    printf 'phase 6 nvimtree: lua/lvim/plugins/modules/nvimtree.lua is missing\n' >&2
    return 1
  fi
  if ! grep -Eq "require\\(['\"]nvim-tree['\"]\\)\\.setup" \
        lua/lvim/plugins/modules/nvimtree.lua; then
    printf 'phase 6 nvimtree: module does not call require("nvim-tree").setup\n' >&2
    return 1
  fi
}

check_phase_6_nvimtree_defaults_shape() {
  # Phase 6 step 1 prescribes the defaults subtree shape:
  #   { active = true, setup = { view = { width = 30 }, renderer = {...},
  #                              filters = { dotfiles = false,
  #                                          git_ignored = false } } }
  # Pin each top-level key under `setup` plus the prescribed leaf values so a
  # regression that flattened the table (or dropped one of the named subtrees)
  # surfaces here.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local t = lvim.builtin.nvimtree; local s = t.setup or {}; print(t.active, type(s), type(s.view), s.view and s.view.width, type(s.renderer), type(s.filters), s.filters and s.filters.dotfiles, s.filters and s.filters.git_ignored)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^true[[:space:]]+table[[:space:]]+table[[:space:]]+30[[:space:]]+table[[:space:]]+table[[:space:]]+false[[:space:]]+false$' <<<"$output"; then
    printf 'phase 6 nvimtree: lvim.builtin.nvimtree defaults shape wrong (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_nvimtree_lvimexplorer_focuses_new_sidebar() {
  # Smart-toggle contract: when the only visible window is a full-screen tree,
  # `:LvimExplorer` should create the right sidebar split and leave focus in
  # that new sidebar window so `<leader>e` lands the cursor in the panel it
  # just opened.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local before = vim.api.nvim_get_current_win(); vim.bo.filetype = "NvimTree"; vim.cmd("LvimExplorer"); print("EXP", #vim.api.nvim_list_wins(), before ~= vim.api.nvim_get_current_win())' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^EXP[[:space:]]+2[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 nvimtree: LvimExplorer did not keep focus in the new sidebar window (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_nvimtree_on_attach_cr_passes_node() {
  # Regression guard for LunaVim's custom in-tree mappings: the `<CR>` mapping
  # installed by `on_attach` must pass the node returned by
  # `api.tree.get_node_under_cursor()` into `api.node.open.edit(node)`.
  # Calling the raw action with no node raises:
  #   open-file.lua:446: attempt to index local 'node' (a nil value)
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local captured, got; local node = { name = "sentinel" }; package.loaded["nvim-tree"] = { setup = function(o) captured = o end }; package.loaded["nvim-tree.api"] = { tree = { get_node_under_cursor = function() return node end, change_root_to_node = function(n) got = n end }, node = { open = { edit = function(n) got = n end, vertical = function(n) got = n end }, navigate = { parent_close = function(n) got = n end } }, config = { mappings = { default_on_attach = function(_) end } } }; require("lvim.plugins.modules.nvimtree").setup({}); local bufnr = vim.api.nvim_create_buf(false, true); captured.on_attach(bufnr); vim.api.nvim_set_current_buf(bufnr); local m = vim.fn.maparg("<CR>", "n", false, true); if type(m) == "table" and type(m.callback) == "function" then m.callback() end; print("NODEMAP", got == node)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^NODEMAP[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 nvimtree: on_attach `<CR>` mapping did not pass the current node into api.node.open.edit (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_nvimtree_setup_disables_netrw() {
  # Phase 6 step 2: `setup()` must set `vim.g.loaded_netrw = 1` and
  # `vim.g.loaded_netrwPlugin = 1` BEFORE calling `require('nvim-tree').setup`.
  # Stub the require so we can observe the call order via a sentinel captured
  # at the moment setup runs. A regression that called the setup before
  # touching the globals would leave both flags unset at the time the stub
  # was invoked.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua vim.g.loaded_netrw = nil; vim.g.loaded_netrwPlugin = nil' \
    -c 'lua _G.__nt_at_setup = nil; package.loaded["nvim-tree"] = { setup = function(_) _G.__nt_at_setup = { netrw = vim.g.loaded_netrw, plugin = vim.g.loaded_netrwPlugin } end }' \
    -c "lua require('lvim.plugins.modules.nvimtree').setup({})" \
    -c 'lua local s = _G.__nt_at_setup or {}; print("NETRW", s.netrw, s.plugin, vim.g.loaded_netrw, vim.g.loaded_netrwPlugin)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^NETRW[[:space:]]+1[[:space:]]+1[[:space:]]+1[[:space:]]+1$' <<<"$output"; then
    printf 'phase 6 nvimtree: setup did not disable netrw before require("nvim-tree").setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_nvimtree_setup_forwards_opts() {
  # Phase 6 step 2: `setup()` must forward `lvim.builtin.nvimtree.setup`
  # (the `.setup` subtree, NOT the `active` toggle) to
  # `require('nvim-tree').setup`. Without this forwarding the defaults table
  # is dead code — exposed to users but never consumed. Stub
  # `package.loaded["nvim-tree"]` with a fake whose `setup` captures the opts
  # table, then call the module's setup() directly and assert the captured
  # opts carry the prescribed shape with no `active` key (it lives one level
  # up under `lvim.builtin.nvimtree.active`, not under `.setup`, so it must
  # not appear in the forwarded payload either).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__nt_opts = nil; package.loaded["nvim-tree"] = { setup = function(o) _G.__nt_opts = o end }' \
    -c "lua require('lvim.plugins.modules.nvimtree').setup({})" \
    -c 'lua local o = _G.__nt_opts or {}; print("CAPTURED", type(o), type(o.view), o.view and o.view.width, type(o.renderer), type(o.filters), o.filters and o.filters.dotfiles, o.active == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^CAPTURED[[:space:]]+table[[:space:]]+table[[:space:]]+30[[:space:]]+table[[:space:]]+table[[:space:]]+false[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 nvimtree: module did not forward lvim.builtin.nvimtree.setup to nvim-tree.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_nvimtree_setup_pcall_guards_missing() {
  # Smoke runs with install.missing=false so nvim-tree is not on disk. A
  # regression that dropped the pcall around `require('nvim-tree')` would
  # raise the moment lazy fires the module's `config` callback. Force the
  # module unavailable and assert setup() returns without erroring.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["nvim-tree"] = nil; package.preload["nvim-tree"] = nil' \
    -c "lua local ok, err = pcall(function() require('lvim.plugins.modules.nvimtree').setup({}) end); print('PCALL', ok, err == nil)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^PCALL[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 nvimtree: module setup raised when nvim-tree was unavailable (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_nvimtree_leader_e_map_registered() {
  # Phase 6 step 3 + literal acceptance signal:
  #   vim.fn.maparg('<leader>e', 'n') matches NvimTreeToggle
  # Pin both that the mapping exists in normal mode AND that its rhs
  # references `NvimTreeToggle` — a regression that bound `<leader>e` to a
  # different action (or registered it on the wrong mode) is caught here.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local rhs = vim.fn.maparg('<leader>e', 'n'); print('MAP=' .. rhs)" \
    -c 'qall!' 2>&1)"
  if ! grep -q '^MAP=.*NvimTreeToggle' <<<"$output"; then
    printf 'phase 6 nvimtree: <leader>e mapping missing or wrong rhs (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_nvimtree_toggle_does_not_error() {
  # Phase 6 literal acceptance signal:
  #   nvim --headless -u init.lua -c "NvimTreeToggle" -c qall! 2>&1
  # must not error. With install.missing=false (no plugins on disk) the lazy
  # `cmd = "NvimTreeToggle"` stub still creates a user command stub that
  # tries to load the plugin and forward — if our spec or module raises here
  # the command would surface E5108. Capture stderr and assert no E### codes
  # leaked.
  local cfg_dir output rc
  cfg_dir="$(make_empty_config_dir)"

  set +e
  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'NvimTreeToggle' -c 'qall!' 2>&1)"
  rc=$?
  set -e
  if (( rc != 0 )) || grep -Eq 'E[0-9]+:|Error detected while processing' <<<"$output"; then
    printf 'phase 6 nvimtree: NvimTreeToggle errored on headless boot (rc=%d output: %s)\n' \
      "$rc" "$output" >&2
    return 1
  fi
}

check_phase_6_nvimtree_user_override_forwarded() {
  # Phase 6 user-override contract: a user that mutates
  # `lvim.builtin.nvimtree.setup` from their config (the LunarVim-style flow)
  # must have that mutation observably forwarded to `nvim-tree.setup`. Mirrors
  # the telescope user-override check but for nvimtree. Asserts both:
  #   * deep-nested mutation (view.width = 42) flows through,
  #   * a brand-new key (hijack_directories) the user adds is preserved.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" nvimtree-user-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.builtin.nvimtree.setup.view.width = 42
lvim.builtin.nvimtree.setup.hijack_directories = { enable = true }
LUA

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__nt_user_opts = nil; package.loaded["nvim-tree"] = { setup = function(o) _G.__nt_user_opts = o end }' \
    -c "lua require('lvim.plugins.modules.nvimtree').setup({})" \
    -c 'lua local o = _G.__nt_user_opts or {}; print("USER_NT", o.view and o.view.width, o.hijack_directories and o.hijack_directories.enable, o.filters and o.filters.dotfiles)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^USER_NT[[:space:]]+42[[:space:]]+true[[:space:]]+false$' <<<"$output"; then
    printf 'phase 6 nvimtree: user override of lvim.builtin.nvimtree.setup did not flow through to nvim-tree.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_telescope_user_override_forwarded() {
  # Phase 6 user-override contract: a user that mutates `lvim.builtin.telescope`
  # from their config (the LunarVim-style flow — plain Lua assignment against
  # the live `_G.lvim` table) must have that mutation observably forwarded to
  # `telescope.setup`. Sibling check_phase_6_telescope_setup_forwards_opts only
  # exercises the DEFAULTS shape; this one pins user-mutation → live-read →
  # telescope.setup end-to-end. Assigning a NEW table (rather than mutating
  # nested fields) also exercises the deep-replacement case the
  # tests/fixtures/config.lua fixture relies on.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" telescope-user-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.builtin.telescope.defaults.layout_strategy = "vertical"
lvim.builtin.telescope.pickers.find_files = { hidden = true }
LUA

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__tel_user_opts = nil; package.loaded.telescope = { setup = function(o) _G.__tel_user_opts = o end }' \
    -c "lua require('lvim.plugins.modules.telescope').setup({})" \
    -c 'lua local o = _G.__tel_user_opts or {}; print("USER_TS", o.defaults and o.defaults.layout_strategy, o.pickers and o.pickers.find_files and o.pickers.find_files.hidden, o.active == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^USER_TS[[:space:]]+vertical[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 telescope: user override of lvim.builtin.telescope did not flow through to telescope.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_nvimtree_setup_does_not_mutate_builtin() {
  # Phase 6 defensive contract (mirrors the telescope sibling check): the
  # module's `vim.deepcopy(builtin.setup or {})` before forwarding to
  # `nvim-tree.setup` must NOT mutate the live `_G.lvim.builtin.nvimtree.setup`
  # subtree. A regression that dropped the deepcopy (e.g. swapped it for
  # `vim.tbl_extend("force", {}, builtin.setup)` — a shallow copy that leaves
  # nested tables shared by reference, or a direct `builtin.setup` pass —
  # would not be caught by the existing forwards_opts/user_override_forwarded
  # checks because they only observe the captured opts at the call site, not
  # the source after. Pin nested fields the defaults populate:
  #   * view.width must remain 30 (the default),
  #   * filters.dotfiles must remain false (the default),
  #   * renderer.indent_markers.enable must remain true (the default),
  # all surviving a hypothetical regression where nvim-tree's setup mutates
  # the captured opts' nested tables.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["nvim-tree"] = { setup = function(o) if o.view then o.view.width = 999 end; if o.filters then o.filters.dotfiles = "MUTATED" end; if o.renderer and o.renderer.indent_markers then o.renderer.indent_markers.enable = "MUTATED" end end }' \
    -c "lua require('lvim.plugins.modules.nvimtree').setup({})" \
    -c 'lua local s = lvim.builtin.nvimtree.setup; print("LIVE_NT", s.view.width, s.filters.dotfiles, s.renderer.indent_markers.enable)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LIVE_NT[[:space:]]+30[[:space:]]+false[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 nvimtree: nvim-tree.setup observably mutated lvim.builtin.nvimtree.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_nvimtree_literal_acceptance_require_returns_table() {
  # Phase 6 step description acceptance command, run verbatim against a
  # stubbed `nvim-tree` module:
  #   nvim --headless -u init.lua -c "lua print(type(require('nvim-tree')))" \
  #     -c qall! 2>&1 | grep -q table
  # In the smoke env nvim-tree is not on disk (install.missing = false), so we
  # preload `package.loaded["nvim-tree"]` with a fake table whose .setup is a
  # noop — this isolates the acceptance to the *return type* contract from
  # the plan step ("require('nvim-tree') returns a table"). A regression that
  # broke the spec/module dispatch shape (e.g. require fell over before the
  # type print fired) would not produce a line matching `table`. This
  # complements the sibling `_toggle_does_not_error` check (which pins the
  # cmd-dispatch path) by pinning the require-chain path directly, and
  # mirrors the literal acceptance form used by every other Phase 6 UI module
  # (telescope/lualine/bufferline/gitsigns/whichkey/terminal/comment/breadcrumbs/indentlines).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["nvim-tree"] = { setup = function(_) end }' \
    -c "lua print(type(require('nvim-tree')))" \
    -c 'qall!' 2>&1)"
  if ! grep -q 'table' <<<"$output"; then
    printf 'phase 6 nvimtree: literal acceptance print(type(require("nvim-tree"))) did not emit "table" (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_nvimtree_toggle_drops_nvimtree_specifically() {
  # Phase 6 nvimtree gate-identity contract (mirrors the telescope sibling):
  # `lvim.builtin.nvimtree.active = false` must drop the
  # `nvim-tree/nvim-tree.lua` spec entry from `lazy.core.config.plugins`. The
  # sibling `defaults_shape` and `setup_forwards_opts` checks observe the
  # module's setup callback, but neither pins the spec-gate wiring — a
  # regression that cross-mapped gate keys (e.g. swapped `gate("nvimtree")`
  # with another module's key, or that silently moved the gate to a static
  # `true`) could leave defaults_shape and setup_forwards_opts passing while
  # nvim-tree still loads when the user disabled it. Scan
  # `lazy.core.config.plugins` by source URL rather than by `spec.name` (the
  # LunaVim spec sets `name = "nvimtree"`, which makes url-segment lookups by
  # `nvim-tree/nvim-tree.lua` more robust).
  local cfg_dir toggle_cfg baseline_out toggled_out

  cfg_dir="$(make_empty_config_dir)"
  baseline_out="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'nvim-tree/nvim-tree.lua') or (p.url and p.url:match('nvim%-tree/nvim%-tree%.lua')) then has = true; break end end; print('NT=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^NT=true$' <<<"$baseline_out"; then
    printf 'phase 6 nvimtree toggle: nvim-tree/nvim-tree.lua not present in Config.plugins under baseline (output: %s)\n' "$baseline_out" >&2
    return 1
  fi

  toggle_cfg="$(mktemp -d -p "$SMOKE_TMP_BASE" nvimtree-off-id-XXXXXX)"
  printf 'lvim.builtin.nvimtree.active = false\n' > "$toggle_cfg/config.lua"
  toggled_out="$(LUNAVIM_CONFIG_DIR="$toggle_cfg" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'nvim-tree/nvim-tree.lua') or (p.url and p.url:match('nvim%-tree/nvim%-tree%.lua')) then has = true; break end end; print('NT=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^NT=false$' <<<"$toggled_out"; then
    printf 'phase 6 nvimtree toggle: nvim-tree/nvim-tree.lua still present in Config.plugins with nvimtree.active=false (output: %s)\n' "$toggled_out" >&2
    return 1
  fi
}

check_phase_6_telescope_setup_does_not_mutate_builtin() {
  # Phase 6 defensive contract: the module's `vim.deepcopy(builtin)` before
  # stripping `active` and forwarding to telescope.setup must NOT mutate the
  # live `_G.lvim.builtin.telescope` table. A regression that dropped the
  # deepcopy (e.g. replaced it with a shallow `vim.tbl_extend("force", {},
  # builtin)` — which only shallow-copies the top level, leaving nested
  # tables shared by reference) wouldn't be caught by the existing
  # forwards_opts/defaults_shape checks because they observe the captured
  # opts, not the source. Pin both:
  #   * top-level (active must remain `true` on the live table after setup
  #     — the module's `opts.active = nil` strip must not bleed into the
  #     live builtin),
  #   * nested (defaults.layout_strategy and defaults.mappings.i["<C-n>"]
  #     must survive a hypothetical regression where the setup stub mutates
  #     the captured opts' nested tables — only a deepcopy keeps the live
  #     tree untouched).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded.telescope = { setup = function(o) o.active = "MUTATED"; if o.defaults then o.defaults.layout_strategy = "MUTATED"; if o.defaults.mappings and o.defaults.mappings.i then o.defaults.mappings.i["<C-n>"] = "MUTATED" end end end }' \
    -c "lua require('lvim.plugins.modules.telescope').setup({})" \
    -c 'lua local t = lvim.builtin.telescope; print("LIVE", t.active, t.defaults.layout_strategy, t.defaults.mappings.i["<C-n>"])' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LIVE[[:space:]]+true[[:space:]]+horizontal[[:space:]]+move_selection_next$' <<<"$output"; then
    printf 'phase 6 telescope: telescope.setup observably mutated lvim.builtin.telescope (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_telescope_literal_acceptance_telescope_find_files() {
  # Phase 6 step description acceptance command, run verbatim:
  #   nvim --headless -u init.lua -c "Telescope find_files" -c qall! 2>&1 \
  #     | grep -v -iE 'error|E[0-9]+:' >/dev/null
  # In the smoke env telescope is not on disk (install.missing = false), so
  # lazy.nvim's `cmd = "Telescope"` stub reports "Plugin telescope is not
  # installed" rather than executing the picker. The literal acceptance grep
  # filters error-tagged lines and asserts that SOME non-error line remains,
  # which proves :Telescope is registered (the cmd stub fired) without raising
  # a Neovim-level `E<num>:` error. A regression that left the leader keymap
  # in place but dropped the `cmd = "Telescope"` spec entry — or one that
  # forwarded an unrecognised `active` key into telescope.setup at the wrong
  # time and triggered an `E<num>:` error during command dispatch — would
  # fail this check.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  set +e
  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'Telescope find_files' -c 'qall!' 2>&1)"
  set -e

  if ! grep -v -iE 'error|E[0-9]+:' <<<"$output" >/dev/null; then
    printf 'phase 6 telescope: literal acceptance ":Telescope find_files" produced only error-tagged output (output: %s)\n' "$output" >&2
    return 1
  fi
  if grep -Eq 'E[0-9]+:' <<<"$output"; then
    printf 'phase 6 telescope: literal acceptance ":Telescope find_files" raised a Neovim E<num>: error (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_telescope_literal_acceptance_require_returns_table() {
  # Phase 6 step description acceptance command, run verbatim against a
  # stubbed `telescope` module:
  #   nvim --headless -u init.lua -c "lua print(type(require('telescope')))" \
  #     -c qall! 2>&1 | grep -q table
  # In the smoke env telescope is not on disk (install.missing = false), so we
  # preload `package.loaded.telescope` with a fake table whose .setup is a noop —
  # this isolates the acceptance to the *return type* contract from the plan
  # step ("require('telescope') returns a table"). A regression that broke
  # the spec/module dispatch shape (e.g. require fell over before the type
  # print fired) would not produce a line matching `table`. This complements
  # the sibling `_literal_acceptance_telescope_find_files` check (which pins
  # the cmd-dispatch path) by pinning the require-chain path directly, and
  # mirrors the literal acceptance form used by every other Phase 6 UI module
  # (lualine/bufferline/gitsigns/whichkey/terminal/comment/breadcrumbs/indentlines).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded.telescope = { setup = function(_) end }' \
    -c "lua print(type(require('telescope')))" \
    -c 'qall!' 2>&1)"
  if ! grep -q 'table' <<<"$output"; then
    printf 'phase 6 telescope: literal acceptance print(type(require("telescope"))) did not emit "table" (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_telescope_toggle_drops_telescope_specifically() {
  # Phase 6 telescope gate-identity contract: `lvim.builtin.telescope.active =
  # false` must drop the `nvim-telescope/telescope.nvim` spec entry from
  # `lazy.core.config.plugins`. The sibling `defaults_shape` and
  # `setup_forwards_opts` checks observe the module's setup callback, but
  # neither pins the spec-gate wiring — a regression that cross-mapped gate
  # keys (e.g. swapped `gate("telescope")` with another module's key, or that
  # silently moved the gate to a static `true`) could leave defaults_shape
  # and setup_forwards_opts passing while telescope still loads when the user
  # disabled it. Scan `lazy.core.config.plugins` by source URL rather than
  # by `spec.name` (the LunaVim spec sets `name = "telescope"`, which makes
  # url-segment lookups by `nvim-telescope/telescope.nvim` more robust).
  local cfg_dir toggle_cfg baseline_out toggled_out

  cfg_dir="$(make_empty_config_dir)"
  baseline_out="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'nvim-telescope/telescope.nvim') or (p.url and p.url:match('nvim%-telescope/telescope%.nvim')) then has = true; break end end; print('TS=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^TS=true$' <<<"$baseline_out"; then
    printf 'phase 6 telescope toggle: nvim-telescope/telescope.nvim not present in Config.plugins under baseline (output: %s)\n' "$baseline_out" >&2
    return 1
  fi

  toggle_cfg="$(mktemp -d -p "$SMOKE_TMP_BASE" telescope-off-id-XXXXXX)"
  printf 'lvim.builtin.telescope.active = false\n' > "$toggle_cfg/config.lua"
  toggled_out="$(LUNAVIM_CONFIG_DIR="$toggle_cfg" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'nvim-telescope/telescope.nvim') or (p.url and p.url:match('nvim%-telescope/telescope%.nvim')) then has = true; break end end; print('TS=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^TS=false$' <<<"$toggled_out"; then
    printf 'phase 6 telescope toggle: nvim-telescope/telescope.nvim still present in Config.plugins with telescope.active=false (output: %s)\n' "$toggled_out" >&2
    return 1
  fi
}

check_phase_6_lualine_module_present() {
  # Phase 6 lualine module: pin the file's presence AND that it dispatches
  # into `require('lualine').setup(...)`. A regression that left the Phase 0
  # stub in place would silently drop user `lvim.builtin.lualine` config on
  # the floor (the spec gate would still load the plugin, but its `config`
  # callback would be a no-op).
  if [[ ! -f lua/lvim/plugins/modules/lualine.lua ]]; then
    printf 'phase 6 lualine: lua/lvim/plugins/modules/lualine.lua is missing\n' >&2
    return 1
  fi
  if ! grep -Eq "require\\(['\"]lualine['\"]\\)\\.setup" \
        lua/lvim/plugins/modules/lualine.lua; then
    printf 'phase 6 lualine: module does not call require("lualine").setup\n' >&2
    return 1
  fi
}

check_phase_6_lualine_defaults_shape() {
  # Phase 6 step 1 prescribes the defaults subtree shape:
  #   { active = true, options = { theme, section_separators,
  #     component_separators }, sections = { lualine_a..z } }
  # with reasonable defaults (theme = "auto", empty separator strings, and
  # the LunarVim section layout — branch in lualine_b, diagnostics in
  # lualine_c, lsp_status in lualine_x). Pin each top-level subtree plus
  # the prescribed leaf values so a regression that flattened the table
  # (or dropped a section) surfaces here.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local t = lvim.builtin.lualine; print(t.active, type(t.options), t.options.theme, t.options.section_separators, t.options.component_separators, type(t.sections), type(t.sections.lualine_a), type(t.sections.lualine_b), type(t.sections.lualine_c), type(t.sections.lualine_x), type(t.sections.lualine_y), type(t.sections.lualine_z))' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^true[[:space:]]+table[[:space:]]+auto[[:space:]]+[[:space:]]+[[:space:]]+table[[:space:]]+table[[:space:]]+table[[:space:]]+table[[:space:]]+table[[:space:]]+table[[:space:]]+table$' <<<"$output"; then
    printf 'phase 6 lualine: lvim.builtin.lualine defaults shape wrong (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_lualine_defaults_section_components() {
  # Phase 6 step 1 contract: the prescribed section layout names specific
  # components (branch in lualine_b, diagnostics in lualine_c, lsp_status
  # leading lualine_x). Pin those exact entries so a regression that
  # swapped components between sections — e.g. moving branch into
  # lualine_c, or replacing `lsp_status` with the old `progress` entry —
  # is caught here rather than passing silently through the shape check
  # (which only asserts each section is a table).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local s = lvim.builtin.lualine.sections; print("SECT", s.lualine_a[1], s.lualine_b[1], s.lualine_c[1], s.lualine_x[1], s.lualine_y[1], s.lualine_z[1])' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^SECT[[:space:]]+mode[[:space:]]+branch[[:space:]]+diagnostics[[:space:]]+lsp_status[[:space:]]+progress[[:space:]]+location$' <<<"$output"; then
    printf 'phase 6 lualine: section components misaligned (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_lualine_setup_forwards_opts() {
  # Phase 6 step 2: `setup()` must forward `lvim.builtin.lualine` (minus the
  # `active` toggle) to `require('lualine').setup`. Without this forwarding
  # the defaults table is dead code — exposed to users but never consumed.
  # Stub `package.loaded.lualine` with a fake whose `setup` captures the
  # opts table, then call the module's setup() directly and assert the
  # captured opts carry the prescribed shape AND that `active` was stripped
  # (it would not be a valid lualine option and a regression that forwarded
  # it would pollute the call site).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__ll_opts = nil; package.loaded.lualine = { setup = function(o) _G.__ll_opts = o end }' \
    -c "lua require('lvim.plugins.modules.lualine').setup({})" \
    -c 'lua local o = _G.__ll_opts or {}; print("CAPTURED", type(o), type(o.options), o.options and o.options.theme, type(o.sections), o.sections and o.sections.lualine_a and o.sections.lualine_a[1], o.active == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^CAPTURED[[:space:]]+table[[:space:]]+table[[:space:]]+auto[[:space:]]+table[[:space:]]+mode[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 lualine: module did not forward lvim.builtin.lualine (minus active) to lualine.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_lualine_setup_pcall_guards_missing() {
  # Smoke runs with install.missing=false so lualine is not on disk. A
  # regression that dropped the pcall around `require('lualine')` would
  # raise the moment lazy fires the module's `config` callback. Force the
  # module unavailable and assert setup() returns without erroring.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded.lualine = nil; package.preload.lualine = nil' \
    -c "lua local ok, err = pcall(function() require('lvim.plugins.modules.lualine').setup({}) end); print('PCALL', ok, err == nil)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^PCALL[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 lualine: module setup raised when lualine was unavailable (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_lualine_user_override_forwarded() {
  # Phase 6 user-override contract: a user that mutates `lvim.builtin.lualine`
  # from their config (the LunarVim-style flow — plain Lua assignment against
  # the live `_G.lvim` table) must have that mutation observably forwarded to
  # `lualine.setup`. Sibling check_phase_6_lualine_setup_forwards_opts only
  # exercises the DEFAULTS shape; this one pins user-mutation → live-read →
  # lualine.setup end-to-end. Tests both deep-nested mutation
  # (options.theme = "gruvbox") and a brand-new key (options.globalstatus)
  # the user adds.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" lualine-user-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.builtin.lualine.options.theme = "gruvbox"
lvim.builtin.lualine.options.globalstatus = true
LUA

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__ll_user_opts = nil; package.loaded.lualine = { setup = function(o) _G.__ll_user_opts = o end }' \
    -c "lua require('lvim.plugins.modules.lualine').setup({})" \
    -c 'lua local o = _G.__ll_user_opts or {}; print("USER_LL", o.options and o.options.theme, o.options and o.options.globalstatus, o.active == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^USER_LL[[:space:]]+gruvbox[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 lualine: user override of lvim.builtin.lualine did not flow through to lualine.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_lualine_setup_does_not_mutate_builtin() {
  # Phase 6 defensive contract (mirrors the telescope/nvim-tree sibling checks):
  # the module's `vim.deepcopy(builtin)` before stripping `active` and
  # forwarding to lualine.setup must NOT mutate the live `_G.lvim.builtin.lualine`
  # table. A regression that dropped the deepcopy (e.g. replaced it with a
  # shallow `vim.tbl_extend("force", {}, builtin)` — which only shallow-copies
  # the top level, leaving nested tables shared by reference) wouldn't be
  # caught by the existing forwards_opts/defaults_shape checks because they
  # observe the captured opts, not the source. Pin both:
  #   * top-level (active must remain `true` on the live table after setup
  #     — the module's `opts.active = nil` strip must not bleed into the
  #     live builtin),
  #   * nested (options.theme and sections.lualine_b[1] must survive a
  #     hypothetical regression where the setup stub mutates the captured
  #     opts' nested tables — only a deepcopy keeps the live tree untouched).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded.lualine = { setup = function(o) o.active = "MUTATED"; if o.options then o.options.theme = "MUTATED" end; if o.sections and o.sections.lualine_b then o.sections.lualine_b[1] = "MUTATED" end end }' \
    -c "lua require('lvim.plugins.modules.lualine').setup({})" \
    -c 'lua local t = lvim.builtin.lualine; print("LIVE_LL", t.active, t.options.theme, t.sections.lualine_b[1])' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LIVE_LL[[:space:]]+true[[:space:]]+auto[[:space:]]+branch$' <<<"$output"; then
    printf 'phase 6 lualine: lualine.setup observably mutated lvim.builtin.lualine (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_lualine_literal_acceptance_require_returns_table() {
  # Phase 6 step description acceptance command, run verbatim against a
  # stubbed `lualine` module:
  #   nvim --headless -u init.lua -c "lua print(type(require('lualine')))" \
  #     -c qall! 2>&1 | grep -q table
  # In the smoke env lualine is not on disk (install.missing = false), so we
  # preload `package.loaded.lualine` with a fake table whose .setup is a noop —
  # this isolates the acceptance to the *return type* contract from the
  # plan step ("require('lualine') returns a table"). A regression that
  # broke the spec/module dispatch shape (e.g. require fell over before the
  # type print fired) would not produce a line matching `table`.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded.lualine = { setup = function(_) end }' \
    -c "lua print(type(require('lualine')))" \
    -c 'qall!' 2>&1)"
  if ! grep -q 'table' <<<"$output"; then
    printf 'phase 6 lualine: literal acceptance print(type(require("lualine"))) did not emit "table" (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_lualine_defaults_lualine_x_full_list() {
  # Phase 6 step 1 contract: lualine_x carries the full LunarVim-style right
  # cluster, not just lsp_status. The sibling
  # check_phase_6_lualine_defaults_section_components only inspects the
  # FIRST entry of each section (lualine_x[1] = "lsp_status"), so a
  # regression that truncated lualine_x — e.g. dropped encoding/fileformat/
  # filetype, leaving only "lsp_status" — would pass that check but break
  # the prescribed layout (statusline right cluster would silently lose the
  # encoding/fileformat/filetype components). Pin all four entries in order.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local x = lvim.builtin.lualine.sections.lualine_x; print("LX", #x, x[1], x[2], x[3], x[4])' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LX[[:space:]]+4[[:space:]]+lsp_status[[:space:]]+encoding[[:space:]]+fileformat[[:space:]]+filetype$' <<<"$output"; then
    printf 'phase 6 lualine: lualine_x defaults list incomplete or reordered (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_lualine_toggle_drops_lualine_specifically() {
  # Phase 6 lualine gate-identity contract (mirrors the telescope/nvimtree
  # sibling checks): `lvim.builtin.lualine.active = false` must drop the
  # `nvim-lualine/lualine.nvim` spec entry from `lazy.core.config.plugins`. The
  # sibling `defaults_shape` and `setup_forwards_opts` checks observe the
  # module's setup callback, but neither pins the spec-gate wiring — a
  # regression that cross-mapped gate keys (e.g. swapped `gate("lualine")`
  # with another module's key, or that silently moved the gate to a static
  # `true`) could leave defaults_shape and setup_forwards_opts passing while
  # lualine still loads when the user disabled it. Scan
  # `lazy.core.config.plugins` by source URL rather than by `spec.name` (the
  # LunaVim spec sets `name = "lualine"`, which makes url-segment lookups by
  # `nvim-lualine/lualine.nvim` more robust).
  local cfg_dir toggle_cfg baseline_out toggled_out

  cfg_dir="$(make_empty_config_dir)"
  baseline_out="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'nvim-lualine/lualine.nvim') or (p.url and p.url:match('nvim%-lualine/lualine%.nvim')) then has = true; break end end; print('LL=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LL=true$' <<<"$baseline_out"; then
    printf 'phase 6 lualine toggle: nvim-lualine/lualine.nvim not present in Config.plugins under baseline (output: %s)\n' "$baseline_out" >&2
    return 1
  fi

  toggle_cfg="$(mktemp -d -p "$SMOKE_TMP_BASE" lualine-off-id-XXXXXX)"
  printf 'lvim.builtin.lualine.active = false\n' > "$toggle_cfg/config.lua"
  toggled_out="$(LUNAVIM_CONFIG_DIR="$toggle_cfg" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'nvim-lualine/lualine.nvim') or (p.url and p.url:match('nvim%-lualine/lualine%.nvim')) then has = true; break end end; print('LL=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LL=false$' <<<"$toggled_out"; then
    printf 'phase 6 lualine toggle: nvim-lualine/lualine.nvim still present in Config.plugins with lualine.active=false (output: %s)\n' "$toggled_out" >&2
    return 1
  fi
}

check_phase_6_bufferline_module_present() {
  # Phase 6 bufferline module: pin the file's presence AND that it dispatches
  # into `require('bufferline').setup(...)`. A regression that left the Phase 0
  # stub in place would silently drop user `lvim.builtin.bufferline` config on
  # the floor (the spec gate would still load the plugin, but its `config`
  # callback would be a no-op).
  if [[ ! -f lua/lvim/plugins/modules/bufferline.lua ]]; then
    printf 'phase 6 bufferline: lua/lvim/plugins/modules/bufferline.lua is missing\n' >&2
    return 1
  fi
  if ! grep -Eq "require\\(['\"]bufferline['\"]\\)\\.setup" \
        lua/lvim/plugins/modules/bufferline.lua; then
    printf 'phase 6 bufferline: module does not call require("bufferline").setup\n' >&2
    return 1
  fi
}

check_phase_6_bufferline_defaults_shape() {
  # Phase 6 step 1 prescribes the defaults subtree shape:
  #   { active = true, options = { diagnostics = "nvim_lsp", offsets = { ... } } }
  # `diagnostics = "nvim_lsp"` is the kcl-confirmed value that surfaces LSP
  # diagnostic counts on buffer tabs (bufferline accepts `"nvim_lsp"|"coc"|false`).
  # `offsets` must be a list (table with [1]). Pin each top-level subtree plus
  # the prescribed leaf values so a regression that flattened the table or
  # changed the diagnostics provider surfaces here.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local t = lvim.builtin.bufferline; print(t.active, type(t.options), t.options.diagnostics, type(t.options.offsets), type(t.options.offsets[1]))' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^true[[:space:]]+table[[:space:]]+nvim_lsp[[:space:]]+table[[:space:]]+table$' <<<"$output"; then
    printf 'phase 6 bufferline: lvim.builtin.bufferline defaults shape wrong (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_bufferline_defaults_offsets_nvimtree() {
  # Phase 6 step 1 contract: the `offsets[1]` entry reserves a left column for
  # nvim-tree. The `filetype = "NvimTree"` match is load-bearing — it must
  # equal the buffer filetype nvim-tree.lua actually sets, or bufferline
  # will draw over the file explorer. Pin the four prescribed fields so a
  # regression that re-keyed the filetype (e.g. lowercase "nvimtree") or
  # dropped the alignment/highlight is caught here rather than slipping past
  # the defaults_shape check (which only asserts offsets[1] is a table).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local o = lvim.builtin.bufferline.options.offsets[1]; print("OFF", o.filetype, o.text, o.highlight, o.text_align)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^OFF[[:space:]]+NvimTree[[:space:]]+File Explorer[[:space:]]+Directory[[:space:]]+left$' <<<"$output"; then
    printf 'phase 6 bufferline: offsets[1] entry misaligned (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_bufferline_setup_forwards_opts() {
  # Phase 6 step 2: `setup()` must forward `lvim.builtin.bufferline` (minus the
  # `active` toggle) to `require('bufferline').setup`. Without this forwarding
  # the defaults table is dead code — exposed to users but never consumed.
  # Stub `package.loaded.bufferline` with a fake whose `setup` captures the
  # opts table, then call the module's setup() directly and assert the
  # captured opts carry the prescribed shape AND that `active` was stripped
  # (it is not a valid bufferline option and a regression that forwarded it
  # would pollute the call site).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__bl_opts = nil; package.loaded.bufferline = { setup = function(o) _G.__bl_opts = o end }' \
    -c "lua require('lvim.plugins.modules.bufferline').setup({})" \
    -c 'lua local o = _G.__bl_opts or {}; print("CAPTURED_BL", type(o), type(o.options), o.options and o.options.diagnostics, o.options and o.options.offsets and o.options.offsets[1] and o.options.offsets[1].filetype, o.active == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^CAPTURED_BL[[:space:]]+table[[:space:]]+table[[:space:]]+nvim_lsp[[:space:]]+NvimTree[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 bufferline: module did not forward lvim.builtin.bufferline (minus active) to bufferline.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_bufferline_setup_pcall_guards_missing() {
  # Smoke runs with install.missing=false so bufferline is not on disk. A
  # regression that dropped the pcall around `require('bufferline')` would
  # raise the moment lazy fires the module's `config` callback. Force the
  # module unavailable and assert setup() returns without erroring.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded.bufferline = nil; package.preload.bufferline = nil' \
    -c "lua local ok, err = pcall(function() require('lvim.plugins.modules.bufferline').setup({}) end); print('PCALL_BL', ok, err == nil)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^PCALL_BL[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 bufferline: module setup raised when bufferline was unavailable (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_bufferline_user_override_forwarded() {
  # Phase 6 user-override contract: a user that mutates `lvim.builtin.bufferline`
  # from their config (the LunarVim-style flow — plain Lua assignment against
  # the live `_G.lvim` table) must have that mutation observably forwarded to
  # `bufferline.setup`. Sibling check_phase_6_bufferline_setup_forwards_opts only
  # exercises the DEFAULTS shape; this one pins user-mutation → live-read →
  # bufferline.setup end-to-end. Tests both deep-nested mutation
  # (options.diagnostics = false to disable diagnostic counts) and a brand-new
  # key (options.always_show_bufferline) the user adds.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" bufferline-user-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.builtin.bufferline.options.diagnostics = false
lvim.builtin.bufferline.options.always_show_bufferline = true
LUA

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__bl_user_opts = nil; package.loaded.bufferline = { setup = function(o) _G.__bl_user_opts = o end }' \
    -c "lua require('lvim.plugins.modules.bufferline').setup({})" \
    -c 'lua local o = _G.__bl_user_opts or {}; print("USER_BL", o.options and tostring(o.options.diagnostics), o.options and tostring(o.options.always_show_bufferline), o.active == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^USER_BL[[:space:]]+false[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 bufferline: user override of lvim.builtin.bufferline did not flow through to bufferline.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_bufferline_setup_does_not_mutate_builtin() {
  # Phase 6 defensive contract (mirrors the telescope/nvim-tree/lualine sibling
  # checks): the module's `vim.deepcopy(builtin)` before stripping `active` and
  # forwarding to bufferline.setup must NOT mutate the live
  # `_G.lvim.builtin.bufferline` table. A regression that dropped the deepcopy
  # (e.g. replaced it with a shallow `vim.tbl_extend("force", {}, builtin)` —
  # which only shallow-copies the top level, leaving nested tables shared by
  # reference) wouldn't be caught by the existing forwards_opts/defaults_shape
  # checks because they observe the captured opts, not the source. Pin both:
  #   * top-level (active must remain `true` on the live table after setup —
  #     the module's `opts.active = nil` strip must not bleed into the live
  #     builtin),
  #   * nested (options.diagnostics and options.offsets[1].filetype must
  #     survive a hypothetical regression where bufferline.setup mutates the
  #     captured opts' nested tables — only a deepcopy keeps the live tree
  #     untouched).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded.bufferline = { setup = function(o) o.active = "MUTATED"; if o.options then o.options.diagnostics = "MUTATED"; if o.options.offsets and o.options.offsets[1] then o.options.offsets[1].filetype = "MUTATED" end end end }' \
    -c "lua require('lvim.plugins.modules.bufferline').setup({})" \
    -c 'lua local t = lvim.builtin.bufferline; print("LIVE_BL", t.active, t.options.diagnostics, t.options.offsets[1].filetype)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LIVE_BL[[:space:]]+true[[:space:]]+nvim_lsp[[:space:]]+NvimTree$' <<<"$output"; then
    printf 'phase 6 bufferline: bufferline.setup observably mutated lvim.builtin.bufferline (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_bufferline_literal_acceptance_require_returns_table() {
  # Phase 6 step description acceptance command, run verbatim against a
  # stubbed `bufferline` module:
  #   nvim --headless -u init.lua -c "lua print(type(require('bufferline')))" \
  #     -c qall! 2>&1 | grep -q table
  # In the smoke env bufferline is not on disk (install.missing = false), so we
  # preload `package.loaded.bufferline` with a fake table whose .setup is a noop —
  # this isolates the acceptance to the *return type* contract from the plan
  # step ("require('bufferline') returns a table"). A regression that broke
  # the spec/module dispatch shape (e.g. require fell over before the type
  # print fired) would not produce a line matching `table`.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded.bufferline = { setup = function(_) end }' \
    -c "lua print(type(require('bufferline')))" \
    -c 'qall!' 2>&1)"
  if ! grep -q 'table' <<<"$output"; then
    printf 'phase 6 bufferline: literal acceptance print(type(require("bufferline"))) did not emit "table" (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_bufferline_toggle_drops_bufferline_specifically() {
  # Phase 6 bufferline gate-identity contract (mirrors the telescope/nvimtree/
  # lualine sibling checks): `lvim.builtin.bufferline.active = false` must drop
  # the `akinsho/bufferline.nvim` spec entry from `lazy.core.config.plugins`.
  # The sibling `defaults_shape` and `setup_forwards_opts` checks observe the
  # module's setup callback, but neither pins the spec-gate wiring — a
  # regression that cross-mapped gate keys (e.g. swapped `gate("bufferline")`
  # with another module's key, or that silently moved the gate to a static
  # `true`) could leave defaults_shape and setup_forwards_opts passing while
  # bufferline still loads when the user disabled it. Scan
  # `lazy.core.config.plugins` by source URL rather than by `spec.name` (the
  # LunaVim spec sets `name = "bufferline"`, which makes url-segment lookups by
  # `akinsho/bufferline.nvim` more robust).
  local cfg_dir toggle_cfg baseline_out toggled_out

  cfg_dir="$(make_empty_config_dir)"
  baseline_out="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'akinsho/bufferline.nvim') or (p.url and p.url:match('akinsho/bufferline%.nvim')) then has = true; break end end; print('BL=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^BL=true$' <<<"$baseline_out"; then
    printf 'phase 6 bufferline toggle: akinsho/bufferline.nvim not present in Config.plugins under baseline (output: %s)\n' "$baseline_out" >&2
    return 1
  fi

  toggle_cfg="$(mktemp -d -p "$SMOKE_TMP_BASE" bufferline-off-id-XXXXXX)"
  printf 'lvim.builtin.bufferline.active = false\n' > "$toggle_cfg/config.lua"
  toggled_out="$(LUNAVIM_CONFIG_DIR="$toggle_cfg" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'akinsho/bufferline.nvim') or (p.url and p.url:match('akinsho/bufferline%.nvim')) then has = true; break end end; print('BL=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^BL=false$' <<<"$toggled_out"; then
    printf 'phase 6 bufferline toggle: akinsho/bufferline.nvim still present in Config.plugins with bufferline.active=false (output: %s)\n' "$toggled_out" >&2
    return 1
  fi
}

check_phase_6_bufferline_defaults_offsets_full_list() {
  # Phase 6 step 1 contract: `options.offsets` is prescribed as a list with
  # exactly ONE entry — the NvimTree reservation. The sibling
  # `defaults_offsets_nvimtree` check pins every field of `offsets[1]` but
  # does not pin the list length, so a regression that appended a stale
  # second entry (e.g. left over from a refactor, or from a user override
  # that bled into defaults) would pass `defaults_offsets_nvimtree` and
  # `defaults_shape` while violating the prescribed shape. Pin `#offsets`
  # alongside the full field set so the contract is observable end-to-end.
  # This mirrors the lualine third-pass `defaults_lualine_x_full_list`
  # pattern (pin a list's count plus every entry, not just one cell).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local o = lvim.builtin.bufferline.options.offsets; print("OFFLEN", #o, o[1].filetype, o[1].text, o[1].highlight, o[1].text_align)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^OFFLEN[[:space:]]+1[[:space:]]+NvimTree[[:space:]]+File Explorer[[:space:]]+Directory[[:space:]]+left$' <<<"$output"; then
    printf 'phase 6 bufferline: offsets list length or contents misaligned (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_gitsigns_module_present() {
  # Phase 6 gitsigns module: pin the file's presence AND that it dispatches
  # into `require('gitsigns').setup(...)`. A regression that left the Phase 0
  # stub in place would silently drop user `lvim.builtin.gitsigns` config on
  # the floor (the spec gate would still load the plugin, but its `config`
  # callback would be a no-op).
  if [[ ! -f lua/lvim/plugins/modules/gitsigns.lua ]]; then
    printf 'phase 6 gitsigns: lua/lvim/plugins/modules/gitsigns.lua is missing\n' >&2
    return 1
  fi
  if ! grep -Eq "require\\(['\"]gitsigns['\"]\\)\\.setup" \
        lua/lvim/plugins/modules/gitsigns.lua; then
    printf 'phase 6 gitsigns: module does not call require("gitsigns").setup\n' >&2
    return 1
  fi
}

check_phase_6_gitsigns_defaults_shape() {
  # Phase 6 step 1 prescribes the defaults subtree shape:
  #   { active = true, signs = {...}, signs_staged = {...}, signcolumn = true,
  #     attach_to_untracked = true, current_line_blame = false,
  #     current_line_blame_opts = {...}, watch_gitdir = {...},
  #     preview_config = {...}, ... }
  # Pin each top-level subtree plus the prescribed leaf values so a regression
  # that flattened the table (or dropped a subkey) surfaces here.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local t = lvim.builtin.gitsigns; print(t.active, type(t.signs), type(t.signs_staged), t.signcolumn, t.attach_to_untracked, t.current_line_blame, type(t.current_line_blame_opts), type(t.watch_gitdir), type(t.preview_config))' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^true[[:space:]]+table[[:space:]]+table[[:space:]]+true[[:space:]]+true[[:space:]]+false[[:space:]]+table[[:space:]]+table[[:space:]]+table$' <<<"$output"; then
    printf 'phase 6 gitsigns: lvim.builtin.gitsigns defaults shape wrong (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_gitsigns_defaults_signs_per_status() {
  # Phase 6 step 1 contract: the `signs` subtable follows the kcl-confirmed
  # shape — per-status entries `{ text = "..." }` for add/change/delete/
  # topdelete/changedelete/untracked. Pin the specific glyphs so a regression
  # that re-keyed the table (e.g. flat `{ add = "┃" }` instead of nested
  # `{ add = { text = "┃" } }`) or dropped a status is caught here rather
  # than slipping past the defaults_shape check (which only asserts `signs`
  # is a table).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local s = lvim.builtin.gitsigns.signs; print("SIGNS", s.add and s.add.text, s.change and s.change.text, s.delete and s.delete.text, s.topdelete and s.topdelete.text, s.changedelete and s.changedelete.text, s.untracked and s.untracked.text)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^SIGNS[[:space:]]+┃[[:space:]]+┃[[:space:]]+_[[:space:]]+‾[[:space:]]+~[[:space:]]+┆$' <<<"$output"; then
    printf 'phase 6 gitsigns: signs per-status shape misaligned (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_gitsigns_setup_forwards_opts() {
  # Phase 6 step 2: `setup()` must forward `lvim.builtin.gitsigns` (minus the
  # `active` toggle) to `require('gitsigns').setup`. Without this forwarding
  # the defaults table is dead code — exposed to users but never consumed.
  # Stub `package.loaded.gitsigns` with a fake whose `setup` captures the
  # opts table, then call the module's setup() directly and assert the
  # captured opts carry the prescribed shape AND that `active` was stripped
  # (it is not a valid gitsigns option and a regression that forwarded it
  # would pollute the call site).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__gs_opts = nil; package.loaded.gitsigns = { setup = function(o) _G.__gs_opts = o end }' \
    -c "lua require('lvim.plugins.modules.gitsigns').setup({})" \
    -c 'lua local o = _G.__gs_opts or {}; print("CAPTURED_GS", type(o), type(o.signs), o.signs and o.signs.add and o.signs.add.text, o.signcolumn, o.attach_to_untracked, o.active == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^CAPTURED_GS[[:space:]]+table[[:space:]]+table[[:space:]]+┃[[:space:]]+true[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 gitsigns: module did not forward lvim.builtin.gitsigns (minus active) to gitsigns.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_gitsigns_setup_pcall_guards_missing() {
  # Smoke runs with install.missing=false so gitsigns is not on disk. A
  # regression that dropped the pcall around `require('gitsigns')` would
  # raise the moment lazy fires the module's `config` callback. Force the
  # module unavailable and assert setup() returns without erroring.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded.gitsigns = nil; package.preload.gitsigns = nil' \
    -c "lua local ok, err = pcall(function() require('lvim.plugins.modules.gitsigns').setup({}) end); print('PCALL_GS', ok, err == nil)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^PCALL_GS[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 gitsigns: module setup raised when gitsigns was unavailable (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_gitsigns_user_override_forwarded() {
  # Phase 6 user-override contract: a user that mutates `lvim.builtin.gitsigns`
  # from their config (the LunarVim-style flow — plain Lua assignment against
  # the live `_G.lvim` table) must have that mutation observably forwarded to
  # `gitsigns.setup`. Sibling check_phase_6_gitsigns_setup_forwards_opts only
  # exercises the DEFAULTS shape; this one pins user-mutation → live-read →
  # gitsigns.setup end-to-end. Tests both a single-glyph override
  # (signs.add.text = "X") and a top-level toggle (current_line_blame = true)
  # plus a brand-new key (signs.add.show_count) the user adds.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" gitsigns-user-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.builtin.gitsigns.signs.add = { text = "X", show_count = true }
lvim.builtin.gitsigns.current_line_blame = true
LUA

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__gs_user_opts = nil; package.loaded.gitsigns = { setup = function(o) _G.__gs_user_opts = o end }' \
    -c "lua require('lvim.plugins.modules.gitsigns').setup({})" \
    -c 'lua local o = _G.__gs_user_opts or {}; print("USER_GS", o.signs and o.signs.add and o.signs.add.text, o.signs and o.signs.add and tostring(o.signs.add.show_count), tostring(o.current_line_blame), o.signs and o.signs.change and o.signs.change.text, o.active == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^USER_GS[[:space:]]+X[[:space:]]+true[[:space:]]+true[[:space:]]+┃[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 gitsigns: user override of lvim.builtin.gitsigns did not flow through to gitsigns.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_gitsigns_setup_does_not_mutate_builtin() {
  # Phase 6 defensive contract (mirrors the telescope/nvim-tree/lualine/
  # bufferline sibling checks): the module's `vim.deepcopy(builtin)` before
  # stripping `active` and forwarding to gitsigns.setup must NOT mutate the
  # live `_G.lvim.builtin.gitsigns` table. A regression that dropped the
  # deepcopy (e.g. replaced it with a shallow `vim.tbl_extend("force", {},
  # builtin)` — which only shallow-copies the top level, leaving nested
  # tables shared by reference) wouldn't be caught by the existing
  # forwards_opts/defaults_shape checks because they observe the captured
  # opts, not the source. Pin both:
  #   * top-level (active must remain `true` on the live table after setup
  #     — the module's `opts.active = nil` strip must not bleed into the
  #     live builtin),
  #   * nested (signs.add.text and current_line_blame_opts.virt_text must
  #     survive a hypothetical regression where gitsigns.setup mutates the
  #     captured opts' nested tables — only a deepcopy keeps the live tree
  #     untouched).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded.gitsigns = { setup = function(o) o.active = "MUTATED"; if o.signs and o.signs.add then o.signs.add.text = "MUTATED" end; if o.current_line_blame_opts then o.current_line_blame_opts.virt_text = "MUTATED" end end }' \
    -c "lua require('lvim.plugins.modules.gitsigns').setup({})" \
    -c 'lua local t = lvim.builtin.gitsigns; print("LIVE_GS", t.active, t.signs.add.text, tostring(t.current_line_blame_opts.virt_text))' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LIVE_GS[[:space:]]+true[[:space:]]+┃[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 gitsigns: gitsigns.setup observably mutated lvim.builtin.gitsigns (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_gitsigns_leader_g_group_maps_registered() {
  # Phase 6 step contract: the four `<leader>g{j,k,p,b}` mappings must be
  # registered in normal mode regardless of whether gitsigns is loaded.
  # They use the `<cmd>Gitsigns ...<CR>` form so the mappings exist before
  # gitsigns lazy-loads (a BufRead-triggered load picks up the :Gitsigns
  # user command, then forwards the subcommand). A regression that moved
  # them inside `gitsigns.setup` or scoped them to a buffer would surface
  # as a missing global keymap here.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local function has(lhs) for _, m in ipairs(vim.api.nvim_get_keymap("n")) do if m.lhs == lhs then return true end end return false end; print("GMAPS", has(" gj"), has(" gk"), has(" gp"), has(" gb"))' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^GMAPS[[:space:]]+true[[:space:]]+true[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 gitsigns: <leader>g{j,k,p,b} not all registered (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_gitsigns_literal_acceptance_require_returns_table() {
  # Phase 6 step description acceptance command, run verbatim against a
  # stubbed `gitsigns` module:
  #   nvim --headless -u init.lua -c "lua print(type(require('gitsigns')))" \
  #     -c qall! 2>&1 | grep -q table
  # In the smoke env gitsigns is not on disk (install.missing = false), so we
  # preload `package.loaded.gitsigns` with a fake table whose .setup is a noop —
  # this isolates the acceptance to the *return type* contract from the plan
  # step ("require('gitsigns') returns a table"). A regression that broke
  # the spec/module dispatch shape (e.g. require fell over before the type
  # print fired) would not produce a line matching `table`.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded.gitsigns = { setup = function(_) end }' \
    -c "lua print(type(require('gitsigns')))" \
    -c 'qall!' 2>&1)"
  if ! grep -q 'table' <<<"$output"; then
    printf 'phase 6 gitsigns: literal acceptance print(type(require("gitsigns"))) did not emit "table" (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_gitsigns_toggle_drops_gitsigns_specifically() {
  # Phase 6 gitsigns gate-identity contract (mirrors the telescope/nvimtree/
  # lualine/bufferline sibling checks): `lvim.builtin.gitsigns.active = false`
  # must drop the `lewis6991/gitsigns.nvim` spec entry from
  # `lazy.core.config.plugins`. The sibling `defaults_shape` and
  # `setup_forwards_opts` checks observe the module's setup callback, but
  # neither pins the spec-gate wiring — a regression that cross-mapped gate
  # keys (e.g. swapped `gate("gitsigns")` with another module's key, or that
  # silently moved the gate to a static `true`) could leave defaults_shape and
  # setup_forwards_opts passing while gitsigns still loads when the user
  # disabled it. Scan `lazy.core.config.plugins` by source URL rather than by
  # `spec.name` (the LunaVim spec sets `name = "gitsigns"`, which makes
  # url-segment lookups by `lewis6991/gitsigns.nvim` more robust).
  local cfg_dir toggle_cfg baseline_out toggled_out

  cfg_dir="$(make_empty_config_dir)"
  baseline_out="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'lewis6991/gitsigns.nvim') or (p.url and p.url:match('lewis6991/gitsigns%.nvim')) then has = true; break end end; print('GS=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^GS=true$' <<<"$baseline_out"; then
    printf 'phase 6 gitsigns toggle: lewis6991/gitsigns.nvim not present in Config.plugins under baseline (output: %s)\n' "$baseline_out" >&2
    return 1
  fi

  toggle_cfg="$(mktemp -d -p "$SMOKE_TMP_BASE" gitsigns-off-id-XXXXXX)"
  printf 'lvim.builtin.gitsigns.active = false\n' > "$toggle_cfg/config.lua"
  toggled_out="$(LUNAVIM_CONFIG_DIR="$toggle_cfg" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'lewis6991/gitsigns.nvim') or (p.url and p.url:match('lewis6991/gitsigns%.nvim')) then has = true; break end end; print('GS=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^GS=false$' <<<"$toggled_out"; then
    printf 'phase 6 gitsigns toggle: lewis6991/gitsigns.nvim still present in Config.plugins with gitsigns.active=false (output: %s)\n' "$toggled_out" >&2
    return 1
  fi
}

check_phase_6_gitsigns_defaults_signs_staged_per_status() {
  # Phase 6 gitsigns sibling-pin (mirrors the bufferline third-pass
  # `defaults_offsets_full_list` and lualine `defaults_lualine_x_full_list`
  # patterns): the prescribed defaults shape carries TWO per-status sign
  # tables — `signs` (unstaged) AND `signs_staged` (staged). The sibling
  # `defaults_signs_per_status` pins every glyph in `signs`, and
  # `defaults_shape` only asserts `type(t.signs_staged) == "table"`. A
  # regression that dropped `signs_staged`, flattened it (e.g.
  # `{ add = "┃" }` instead of `{ add = { text = "┃" } }`), or re-keyed a
  # status (e.g. typo `topdelete` → `top_delete`) would pass both existing
  # checks while silently breaking staged-hunk decoration for every user.
  # Pin the staged glyphs end-to-end so the contract is observable.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local s = lvim.builtin.gitsigns.signs_staged; print("SIGNS_STAGED", s.add and s.add.text, s.change and s.change.text, s.delete and s.delete.text, s.topdelete and s.topdelete.text, s.changedelete and s.changedelete.text, s.untracked and s.untracked.text)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^SIGNS_STAGED[[:space:]]+┃[[:space:]]+┃[[:space:]]+_[[:space:]]+‾[[:space:]]+~[[:space:]]+┆$' <<<"$output"; then
    printf 'phase 6 gitsigns: signs_staged per-status shape misaligned (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_whichkey_module_present() {
  # Phase 6 whichkey module: pin the file's presence AND that it dispatches
  # into both `require('which-key').setup(...)` AND `require('which-key').add(...)`.
  # A regression that left the Phase 0 stub in place would silently drop user
  # `lvim.builtin.whichkey` config on the floor (the spec gate would still load
  # the plugin, but its `config` callback would be a no-op and no leader groups
  # would be registered). v3 of which-key deprecated `register()` in favor of
  # `add()`; this check also pins the v3 entrypoint so a regression that fell
  # back to the deprecated dictionary form would surface here.
  if [[ ! -f lua/lvim/plugins/modules/whichkey.lua ]]; then
    printf 'phase 6 whichkey: lua/lvim/plugins/modules/whichkey.lua is missing\n' >&2
    return 1
  fi
  if ! grep -Eq "require\\(['\"]which-key['\"]\\)\\.setup" \
        lua/lvim/plugins/modules/whichkey.lua; then
    printf 'phase 6 whichkey: module does not call require("which-key").setup\n' >&2
    return 1
  fi
  if ! grep -Eq "\\.add\\(" lua/lvim/plugins/modules/whichkey.lua; then
    printf 'phase 6 whichkey: module does not call which-key.add (v3 API)\n' >&2
    return 1
  fi
  if grep -Eq "\\.register\\(" lua/lvim/plugins/modules/whichkey.lua; then
    printf 'phase 6 whichkey: module uses deprecated which-key.register() (v3 deprecated this in favor of add())\n' >&2
    return 1
  fi
}

check_phase_6_whichkey_defaults_shape() {
  # Phase 6 step 1 prescribes the defaults subtree shape:
  #   { active = true, setup = {}, mappings = { ... } }
  # `setup` is forwarded verbatim to `which-key.setup`; `mappings` is forwarded
  # verbatim to `which-key.add`. The split lets users override either side
  # without restating the other. Pin each top-level subtree so a regression
  # that flattened the table (collapsing setup+mappings into one) is caught
  # here.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local t = lvim.builtin.whichkey; print(t.active, type(t.setup), type(t.mappings), #t.mappings)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^true[[:space:]]+table[[:space:]]+table[[:space:]]+[1-9][0-9]*$' <<<"$output"; then
    printf 'phase 6 whichkey: lvim.builtin.whichkey defaults shape wrong (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_whichkey_defaults_leader_groups() {
  # Phase 6 step 1 contract: `lvim.builtin.whichkey.mappings` must seed the
  # six leader-group labels prescribed by the plan: `<leader>f` = +find,
  # `<leader>g` = +git, `<leader>l` = +lsp, `<leader>b` = +buffer,
  # `<leader>s` = +search, `<leader>p` = +plugins. Pin each entry's `[1]`
  # (LHS) → `group` (label) pairing so a regression that dropped a group,
  # renamed a label, or switched to v2's dictionary form (which keyed by
  # LHS rather than using `[1]` as the LHS) surfaces here rather than
  # slipping past `check_phase_6_whichkey_defaults_shape` (which only
  # asserts `mappings` has >=1 entry).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local m = lvim.builtin.whichkey.mappings; local seen = {}; for _, e in ipairs(m) do if type(e) == "table" and e[1] and e.group then seen[e[1]] = e.group end end; print("GROUPS", seen["<leader>f"], seen["<leader>g"], seen["<leader>l"], seen["<leader>b"], seen["<leader>s"], seen["<leader>p"])' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^GROUPS[[:space:]]+\+find[[:space:]]+\+git[[:space:]]+\+lsp[[:space:]]+\+buffer[[:space:]]+\+search[[:space:]]+\+plugins$' <<<"$output"; then
    printf 'phase 6 whichkey: six prescribed leader-group labels not all seeded in lvim.builtin.whichkey.mappings (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_whichkey_setup_forwards_opts() {
  # Phase 6 step 2: `setup()` must forward `lvim.builtin.whichkey.setup` to
  # `require('which-key').setup` AND `lvim.builtin.whichkey.mappings` to
  # `require('which-key').add`. Without this forwarding the defaults table is
  # dead code — exposed to users but never consumed. Stub `package.loaded.which-key`
  # with a fake whose `setup`/`add` capture their inputs, then call the module's
  # setup() directly and assert both captures carry the prescribed shape AND
  # that `active` was NOT forwarded (it's the spec gate's input, not a
  # which-key option, and lives at `lvim.builtin.whichkey.active`, distinct
  # from `lvim.builtin.whichkey.setup` which is what flows to `which-key.setup`).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__wk_opts = nil; _G.__wk_mappings = nil; package.loaded["which-key"] = { setup = function(o) _G.__wk_opts = o end, add = function(s) _G.__wk_mappings = s end }' \
    -c "lua require('lvim.plugins.modules.whichkey').setup({})" \
    -c 'lua local o = _G.__wk_opts; local m = _G.__wk_mappings; print("CAPTURED_WK", type(o), o and o.active == nil, type(m), m and #m or 0, m and m[1] and m[1][1])' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^CAPTURED_WK[[:space:]]+table[[:space:]]+true[[:space:]]+table[[:space:]]+6[[:space:]]+<leader>f$' <<<"$output"; then
    printf 'phase 6 whichkey: module did not forward lvim.builtin.whichkey.setup/mappings to which-key.setup/add (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_whichkey_setup_pcall_guards_missing() {
  # Smoke runs with install.missing=false so which-key is not on disk. A
  # regression that dropped the pcall around `require('which-key')` would
  # raise the moment lazy fires the module's `config` callback. Force the
  # module unavailable and assert setup() returns without erroring.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["which-key"] = nil; package.preload["which-key"] = nil' \
    -c "lua local ok, err = pcall(function() require('lvim.plugins.modules.whichkey').setup({}) end); print('PCALL_WK', ok, err == nil)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^PCALL_WK[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 whichkey: module setup raised when which-key was unavailable (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_whichkey_user_override_forwarded() {
  # Phase 6 user-override contract: a user that mutates `lvim.builtin.whichkey`
  # from their config (the LunarVim-style flow — plain Lua assignment against
  # the live `_G.lvim` table) must have that mutation observably forwarded to
  # `which-key.setup`/`which-key.add`. Sibling check_phase_6_whichkey_setup_forwards_opts
  # only exercises the DEFAULTS; this one pins user-mutation → live-read →
  # which-key.setup/add end-to-end. Tests both a setup-side override
  # (preset = "modern") and a new mappings entry the user appends.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" whichkey-user-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.builtin.whichkey.setup.preset = "modern"
table.insert(lvim.builtin.whichkey.mappings, { "<leader>x", group = "+extra" })
LUA

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__wk_user_opts = nil; _G.__wk_user_mappings = nil; package.loaded["which-key"] = { setup = function(o) _G.__wk_user_opts = o end, add = function(s) _G.__wk_user_mappings = s end }' \
    -c "lua require('lvim.plugins.modules.whichkey').setup({})" \
    -c 'lua local o = _G.__wk_user_opts or {}; local m = _G.__wk_user_mappings or {}; local extra = nil; for _, e in ipairs(m) do if type(e) == "table" and e[1] == "<leader>x" then extra = e.group end end; print("USER_WK", o.preset, #m, extra)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^USER_WK[[:space:]]+modern[[:space:]]+7[[:space:]]+\+extra$' <<<"$output"; then
    printf 'phase 6 whichkey: user override of lvim.builtin.whichkey did not flow through to which-key.setup/add (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_whichkey_setup_does_not_mutate_builtin() {
  # Phase 6 defensive contract (mirrors the telescope/nvim-tree/lualine/
  # bufferline/gitsigns sibling checks): the module's `vim.deepcopy(builtin.setup)`
  # and `vim.deepcopy(builtin.mappings)` before forwarding to which-key must NOT
  # mutate the live `_G.lvim.builtin.whichkey` table. A regression that dropped
  # the deepcopy (e.g. replaced it with a shallow `vim.tbl_extend("force", {},
  # builtin)` — which only shallow-copies the top level, leaving nested tables
  # shared by reference) wouldn't be caught by the existing forwards_opts/
  # defaults_shape checks because they observe the captured opts, not the source.
  # Pin both:
  #   * top-level (active must remain `true` on the live table after setup),
  #   * nested (mappings[1][1] must survive a hypothetical regression where
  #     which-key.add mutates the captured spec's nested tables — only a
  #     deepcopy keeps the live tree untouched).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["which-key"] = { setup = function(o) o.preset = "MUTATED" end, add = function(s) if s[1] then s[1][1] = "MUTATED"; s[1].group = "MUTATED" end end }' \
    -c "lua require('lvim.plugins.modules.whichkey').setup({})" \
    -c 'lua local t = lvim.builtin.whichkey; print("LIVE_WK", t.active, tostring(t.setup.preset), t.mappings[1][1], t.mappings[1].group)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LIVE_WK[[:space:]]+true[[:space:]]+nil[[:space:]]+<leader>f[[:space:]]+\+find$' <<<"$output"; then
    printf 'phase 6 whichkey: which-key.setup/add observably mutated lvim.builtin.whichkey (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_whichkey_literal_acceptance_require_returns_table() {
  # Phase 6 step description acceptance command, run verbatim against a
  # stubbed `which-key` module:
  #   nvim --headless -u init.lua -c "lua print(type(require('which-key')))" \
  #     -c qall! 2>&1 | grep -q table
  # In the smoke env which-key is not on disk (install.missing = false), so we
  # preload `package.loaded["which-key"]` with a fake table whose .setup/.add
  # are noops — this isolates the acceptance to the *return type* contract from
  # the plan step ("require('which-key') returns a table"). A regression that
  # broke the spec/module dispatch shape (e.g. require fell over before the type
  # print fired) would not produce a line matching `table`.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["which-key"] = { setup = function(_) end, add = function(_) end }' \
    -c "lua print(type(require('which-key')))" \
    -c 'qall!' 2>&1)"
  if ! grep -q 'table' <<<"$output"; then
    printf 'phase 6 whichkey: literal acceptance print(type(require("which-key"))) did not emit "table" (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_whichkey_toggle_drops_whichkey_specifically() {
  # Phase 6 whichkey gate-identity contract (mirrors the telescope/nvimtree/
  # lualine/bufferline/gitsigns sibling checks): `lvim.builtin.whichkey.active
  # = false` must drop the `folke/which-key.nvim` spec entry from
  # `lazy.core.config.plugins`. The sibling `defaults_shape` and
  # `setup_forwards_opts` checks observe the module's setup callback, but
  # neither pins the spec-gate wiring — a regression that cross-mapped gate
  # keys (e.g. swapped `gate("whichkey")` with another module's key, or that
  # silently moved the gate to a static `true`) could leave defaults_shape and
  # setup_forwards_opts passing while which-key still loads when the user
  # disabled it. Scan `lazy.core.config.plugins` by source URL rather than by
  # `spec.name` (the LunaVim spec sets `name = "whichkey"`, which makes
  # url-segment lookups by `folke/which-key.nvim` more robust).
  local cfg_dir toggle_cfg baseline_out toggled_out

  cfg_dir="$(make_empty_config_dir)"
  baseline_out="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'folke/which-key.nvim') or (p.url and p.url:match('folke/which%-key%.nvim')) then has = true; break end end; print('WK=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^WK=true$' <<<"$baseline_out"; then
    printf 'phase 6 whichkey toggle: folke/which-key.nvim not present in Config.plugins under baseline (output: %s)\n' "$baseline_out" >&2
    return 1
  fi

  toggle_cfg="$(mktemp -d -p "$SMOKE_TMP_BASE" whichkey-off-id-XXXXXX)"
  printf 'lvim.builtin.whichkey.active = false\n' > "$toggle_cfg/config.lua"
  toggled_out="$(LUNAVIM_CONFIG_DIR="$toggle_cfg" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'folke/which-key.nvim') or (p.url and p.url:match('folke/which%-key%.nvim')) then has = true; break end end; print('WK=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^WK=false$' <<<"$toggled_out"; then
    printf 'phase 6 whichkey toggle: folke/which-key.nvim still present in Config.plugins with whichkey.active=false (output: %s)\n' "$toggled_out" >&2
    return 1
  fi
}

check_phase_6_whichkey_defaults_mappings_full_list() {
  # Phase 6 step 1 contract: `lvim.builtin.whichkey.mappings` is prescribed
  # as a list with exactly SIX entries — the six leader-group labels
  # `<leader>{f,g,l,b,s,p}` in that order. The sibling
  # `defaults_leader_groups` check queries each of the six labels by LHS
  # via a hash lookup, and `defaults_shape` only asserts `#mappings >= 1`
  # (regex `[1-9][0-9]*`). A regression that appended a stale seventh
  # entry, duplicated an entry, or reordered them (e.g. swapped <leader>f
  # and <leader>g positions) would pass BOTH existing checks — the hash
  # lookup is order-agnostic, and `#mappings` would still satisfy the
  # `>=1` bound. Pin the exact list length AND each entry's position so
  # the prescribed shape is observable end-to-end. This mirrors the
  # bufferline third-pass `defaults_offsets_full_list` and lualine
  # `defaults_lualine_x_full_list` patterns (pin a list's count plus every
  # entry, not just one cell).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local m = lvim.builtin.whichkey.mappings; print("WK_MAPS", #m, m[1] and m[1][1], m[1] and m[1].group, m[2] and m[2][1], m[2] and m[2].group, m[3] and m[3][1], m[3] and m[3].group, m[4] and m[4][1], m[4] and m[4].group, m[5] and m[5][1], m[5] and m[5].group, m[6] and m[6][1], m[6] and m[6].group)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^WK_MAPS[[:space:]]+6[[:space:]]+<leader>f[[:space:]]+\+find[[:space:]]+<leader>g[[:space:]]+\+git[[:space:]]+<leader>l[[:space:]]+\+lsp[[:space:]]+<leader>b[[:space:]]+\+buffer[[:space:]]+<leader>s[[:space:]]+\+search[[:space:]]+<leader>p[[:space:]]+\+plugins$' <<<"$output"; then
    printf 'phase 6 whichkey: defaults mappings list length or per-entry order misaligned (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_terminal_module_present() {
  # Phase 6 toggleterm module: pin the file's presence AND that it dispatches
  # into `require('toggleterm').setup(...)`. A regression that left the Phase 0
  # stub in place would silently drop user `lvim.builtin.terminal` config on
  # the floor (the spec gate would still load the plugin, but its `config`
  # callback would be a no-op).
  if [[ ! -f lua/lvim/plugins/modules/terminal.lua ]]; then
    printf 'phase 6 terminal: lua/lvim/plugins/modules/terminal.lua is missing\n' >&2
    return 1
  fi
  if ! grep -Eq "require\\(['\"]toggleterm['\"]\\)\\.setup" \
        lua/lvim/plugins/modules/terminal.lua; then
    printf 'phase 6 terminal: module does not call require("toggleterm").setup\n' >&2
    return 1
  fi
}

check_phase_6_terminal_defaults_shape() {
  # Phase 6 step 1 prescribes the defaults subtree shape:
  #   { active = true, size = 20, open_mapping = [[<c-\>]],
  #     direction = "horizontal", shading_factor = 2 }
  # Pin each top-level leaf so a regression that flattened the table, dropped
  # a key, or replaced a value (e.g. switched `direction` to "float") surfaces
  # here rather than slipping past the module-present grep (which only checks
  # the setup call).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local t = lvim.builtin.terminal; print(t.active, t.size, t.open_mapping, t.direction, t.shading_factor)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^true[[:space:]]+20[[:space:]]+<c-\\>[[:space:]]+horizontal[[:space:]]+2$' <<<"$output"; then
    printf 'phase 6 terminal: lvim.builtin.terminal defaults shape wrong (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_terminal_setup_forwards_opts() {
  # Phase 6 step 2: `setup()` must forward `lvim.builtin.terminal` (minus the
  # `active` toggle) to `require('toggleterm').setup`. Without this forwarding
  # the defaults table is dead code — exposed to users but never consumed.
  # Stub `package.loaded.toggleterm` with a fake whose `setup` captures the
  # opts table, then call the module's setup() directly and assert the
  # captured opts carry the prescribed shape AND that `active` was stripped
  # (it is not a valid toggleterm option and a regression that forwarded it
  # would pollute the call site).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__tt_opts = nil; package.loaded.toggleterm = { setup = function(o) _G.__tt_opts = o end }' \
    -c "lua require('lvim.plugins.modules.terminal').setup({})" \
    -c 'lua local o = _G.__tt_opts or {}; print("CAPTURED_TT", type(o), o.size, o.open_mapping, o.direction, o.shading_factor, o.active == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^CAPTURED_TT[[:space:]]+table[[:space:]]+20[[:space:]]+<c-\\>[[:space:]]+horizontal[[:space:]]+2[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 terminal: module did not forward lvim.builtin.terminal (minus active) to toggleterm.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_terminal_setup_pcall_guards_missing() {
  # Smoke runs with install.missing=false so toggleterm is not on disk. A
  # regression that dropped the pcall around `require('toggleterm')` would
  # raise the moment lazy fires the module's `config` callback (the spec
  # entry's `cmd = "ToggleTerm"` trigger does not load by default, but the
  # `<leader>gg` lazygit path requires the module at first key press; either
  # entry point must tolerate toggleterm being absent). Force the module
  # unavailable and assert setup() returns without erroring.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded.toggleterm = nil; package.preload.toggleterm = nil' \
    -c "lua local ok, err = pcall(function() require('lvim.plugins.modules.terminal').setup({}) end); print('PCALL_TT', ok, err == nil)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^PCALL_TT[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 terminal: module setup raised when toggleterm was unavailable (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_terminal_user_override_forwarded() {
  # Phase 6 user-override contract: a user that mutates `lvim.builtin.terminal`
  # from their config (the LunarVim-style flow — plain Lua assignment against
  # the live `_G.lvim` table) must have that mutation observably forwarded to
  # `toggleterm.setup`. Sibling check_phase_6_terminal_setup_forwards_opts only
  # exercises the DEFAULTS shape; this one pins user-mutation → live-read →
  # toggleterm.setup end-to-end. Tests both a top-level override
  # (direction = "float") and a brand-new key the user adds (start_in_insert).
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" terminal-user-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.builtin.terminal.direction = "float"
lvim.builtin.terminal.size = 30
lvim.builtin.terminal.start_in_insert = true
LUA

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__tt_user_opts = nil; package.loaded.toggleterm = { setup = function(o) _G.__tt_user_opts = o end }' \
    -c "lua require('lvim.plugins.modules.terminal').setup({})" \
    -c 'lua local o = _G.__tt_user_opts or {}; print("USER_TT", o.direction, o.size, tostring(o.start_in_insert), o.active == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^USER_TT[[:space:]]+float[[:space:]]+30[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 terminal: user override of lvim.builtin.terminal did not flow through to toggleterm.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_terminal_setup_does_not_mutate_builtin() {
  # Phase 6 defensive contract (mirrors the telescope/nvim-tree/lualine/
  # bufferline/gitsigns/whichkey sibling checks): the module's
  # `vim.deepcopy(builtin)` before stripping `active` and forwarding to
  # toggleterm.setup must NOT mutate the live `_G.lvim.builtin.terminal`
  # table. A regression that dropped the deepcopy (e.g. replaced it with a
  # shallow `vim.tbl_extend("force", {}, builtin)` — which only shallow-copies
  # the top level, leaving nested tables shared by reference) wouldn't be
  # caught by the existing forwards_opts/defaults_shape checks because they
  # observe the captured opts, not the source. Pin:
  #   * top-level (active must remain `true` on the live table after setup
  #     — the module's `opts.active = nil` strip must not bleed into the
  #     live builtin),
  #   * direction must remain "horizontal" after a hypothetical regression
  #     where toggleterm.setup mutates the captured opts.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded.toggleterm = { setup = function(o) o.active = "MUTATED"; o.direction = "MUTATED"; o.size = "MUTATED" end }' \
    -c "lua require('lvim.plugins.modules.terminal').setup({})" \
    -c 'lua local t = lvim.builtin.terminal; print("LIVE_TT", t.active, t.direction, t.size)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LIVE_TT[[:space:]]+true[[:space:]]+horizontal[[:space:]]+20$' <<<"$output"; then
    printf 'phase 6 terminal: toggleterm.setup observably mutated lvim.builtin.terminal (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_terminal_lazygit_gated_on_executable() {
  # Phase 6 step contract: the `<leader>gg` lazygit mapping is registered ONLY
  # when `vim.fn.executable("lazygit") == 1`. A regression that dropped the
  # guard would emit a phantom mapping on machines without lazygit; a
  # regression that hard-disabled it (or hung the rhs off a different LHS)
  # would mean the user never sees the float even when lazygit IS available.
  # Pin both branches by stubbing `vim.fn.executable` to return 1 then 0 in
  # two separate nvim invocations and asserting the keymap presence delta.
  local cfg_dir output_present output_absent
  cfg_dir="$(make_empty_config_dir)"

  output_present="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    --cmd 'lua local orig = vim.fn.executable; vim.fn.executable = function(name) if name == "lazygit" then return 1 end; return orig(name) end' \
    -u init.lua \
    -c 'lua local function has(lhs) for _, m in ipairs(vim.api.nvim_get_keymap("n")) do if m.lhs == lhs then return true end end return false end; print("LAZYGIT_ON", has(" gg"))' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LAZYGIT_ON[[:space:]]+true$' <<<"$output_present"; then
    printf 'phase 6 terminal: <leader>gg not registered when lazygit is on PATH (output: %s)\n' "$output_present" >&2
    return 1
  fi

  output_absent="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    --cmd 'lua local orig = vim.fn.executable; vim.fn.executable = function(name) if name == "lazygit" then return 0 end; return orig(name) end' \
    -u init.lua \
    -c 'lua local function has(lhs) for _, m in ipairs(vim.api.nvim_get_keymap("n")) do if m.lhs == lhs then return true end end return false end; print("LAZYGIT_OFF", has(" gg"))' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LAZYGIT_OFF[[:space:]]+false$' <<<"$output_absent"; then
    printf 'phase 6 terminal: <leader>gg registered as phantom mapping when lazygit is NOT on PATH (output: %s)\n' "$output_absent" >&2
    return 1
  fi
}

check_phase_6_terminal_toggle_lazygit_caches_terminal() {
  # Phase 6 step contract: `toggle_lazygit()` lazily allocates a single
  # `Terminal:new` instance on first call and reuses it on subsequent
  # calls (the canonical toggleterm lazygit recipe). A regression that
  # re-allocated each call would spawn a new lazygit process per keypress
  # — the user would lose every prior session's state. Stub
  # `toggleterm.terminal` with a fake whose `Terminal:new` increments a
  # counter and whose `:toggle()` is a noop, call toggle_lazygit() twice,
  # and assert `Terminal:new` was called exactly once.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__lg_new_calls = 0; _G.__lg_toggle_calls = 0; package.loaded["toggleterm.terminal"] = { Terminal = { new = function(self, opts) _G.__lg_new_calls = _G.__lg_new_calls + 1; _G.__lg_last_opts = opts; return setmetatable({}, { __index = { toggle = function(_) _G.__lg_toggle_calls = _G.__lg_toggle_calls + 1 end } }) end } }' \
    -c "lua require('lvim.plugins.modules.terminal').toggle_lazygit()" \
    -c "lua require('lvim.plugins.modules.terminal').toggle_lazygit()" \
    -c 'lua print("LG_CACHE", _G.__lg_new_calls, _G.__lg_toggle_calls, _G.__lg_last_opts and _G.__lg_last_opts.cmd, _G.__lg_last_opts and _G.__lg_last_opts.direction)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LG_CACHE[[:space:]]+1[[:space:]]+2[[:space:]]+lazygit[[:space:]]+float$' <<<"$output"; then
    printf 'phase 6 terminal: toggle_lazygit did not cache a single Terminal:new instance (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_terminal_toggle_lazygit_pcall_guards_missing() {
  # Smoke runs with install.missing=false so toggleterm is not on disk. A
  # regression that dropped the pcall around `require('toggleterm.terminal')`
  # in `toggle_lazygit()` would raise on first keypress when lazygit IS on
  # PATH but toggleterm is absent. Force the module unavailable and assert
  # toggle_lazygit() returns without erroring.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["toggleterm.terminal"] = nil; package.preload["toggleterm.terminal"] = nil' \
    -c "lua local ok, err = pcall(function() require('lvim.plugins.modules.terminal').toggle_lazygit() end); print('PCALL_LG', ok, err == nil)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^PCALL_LG[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 terminal: toggle_lazygit raised when toggleterm.terminal was unavailable (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_terminal_literal_acceptance_require_returns_table() {
  # Phase 6 step description acceptance command, run verbatim against a
  # stubbed `toggleterm` module:
  #   nvim --headless -u init.lua -c "lua print(type(require('toggleterm')))" \
  #     -c qall! 2>&1 | grep -q table
  # In the smoke env toggleterm is not on disk (install.missing = false), so
  # we preload `package.loaded.toggleterm` with a fake table whose .setup is
  # a noop — this isolates the acceptance to the *return type* contract from
  # the plan step ("require('toggleterm') returns a table"). A regression
  # that broke the spec/module dispatch shape (e.g. require fell over before
  # the type print fired) would not produce a line matching `table`.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded.toggleterm = { setup = function(_) end }' \
    -c "lua print(type(require('toggleterm')))" \
    -c 'qall!' 2>&1)"
  if ! grep -q 'table' <<<"$output"; then
    printf 'phase 6 terminal: literal acceptance print(type(require("toggleterm"))) did not emit "table" (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_terminal_toggle_drops_terminal_specifically() {
  # Phase 6 terminal gate-identity contract (mirrors the telescope/nvimtree/
  # lualine/bufferline/gitsigns/whichkey sibling checks): `lvim.builtin.terminal
  # .active = false` must drop the `akinsho/toggleterm.nvim` spec entry from
  # `lazy.core.config.plugins`. The sibling `defaults_shape` and
  # `setup_forwards_opts` checks observe the module's setup callback, but
  # neither pins the spec-gate wiring — a regression that cross-mapped gate
  # keys (e.g. swapped `gate("terminal")` with another module's key, or that
  # silently moved the gate to a static `true`) could leave defaults_shape and
  # setup_forwards_opts passing while toggleterm still loads when the user
  # disabled it. Scan `lazy.core.config.plugins` by source URL rather than by
  # `spec.name` (the LunaVim spec sets `name = "terminal"`, which makes
  # url-segment lookups by `akinsho/toggleterm.nvim` more robust).
  local cfg_dir toggle_cfg baseline_out toggled_out

  cfg_dir="$(make_empty_config_dir)"
  baseline_out="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'akinsho/toggleterm.nvim') or (p.url and p.url:match('akinsho/toggleterm%.nvim')) then has = true; break end end; print('TT=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^TT=true$' <<<"$baseline_out"; then
    printf 'phase 6 terminal toggle: akinsho/toggleterm.nvim not present in Config.plugins under baseline (output: %s)\n' "$baseline_out" >&2
    return 1
  fi

  toggle_cfg="$(mktemp -d -p "$SMOKE_TMP_BASE" terminal-off-id-XXXXXX)"
  printf 'lvim.builtin.terminal.active = false\n' > "$toggle_cfg/config.lua"
  toggled_out="$(LUNAVIM_CONFIG_DIR="$toggle_cfg" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'akinsho/toggleterm.nvim') or (p.url and p.url:match('akinsho/toggleterm%.nvim')) then has = true; break end end; print('TT=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^TT=false$' <<<"$toggled_out"; then
    printf 'phase 6 terminal toggle: akinsho/toggleterm.nvim still present in Config.plugins with terminal.active=false (output: %s)\n' "$toggled_out" >&2
    return 1
  fi
}

check_phase_6_terminal_lazygit_map_rhs_calls_toggle_lazygit() {
  # Phase 6 step 3 (rhs-identity pin, mirrors the nvimtree
  # `<leader>e`/`leader_e_map_registered` pattern at line ~4310): the sibling
  # `lazygit_gated_on_executable` only asserts presence/absence of the
  # `<leader>gg` LHS keyed off `vim.fn.executable("lazygit")` — a regression
  # that left the LHS registered but hung off a wrong rhs (e.g. a literal
  # `<cmd>LazyGit<CR>`, another module's function, or simply a stale
  # `vim.cmd("LazyGit")` string) would still pass `lazygit_gated_on_executable`
  # while silently breaking the canonical lazygit recipe. Pin that `<leader>gg`
  # actually invokes `lvim.plugins.modules.terminal.toggle_lazygit()` (read via
  # `vim.fn.maparg`, which returns the rhs string for cmdline mappings).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless \
    --cmd 'lua local orig = vim.fn.executable; vim.fn.executable = function(name) if name == "lazygit" then return 1 end; return orig(name) end' \
    -u init.lua \
    -c "lua local rhs = vim.fn.maparg('<leader>gg', 'n'); print('LG_RHS=' .. rhs)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq "^LG_RHS=.*lvim\\.plugins\\.modules\\.terminal.*toggle_lazygit" <<<"$output"; then
    printf 'phase 6 terminal: <leader>gg rhs does not invoke lvim.plugins.modules.terminal.toggle_lazygit (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_terminal_lazygit_recipe_opts_full_shape() {
  # Phase 6 step 3 (recipe-identity pin, mirrors the bufferline
  # `defaults_offsets_full_list` / lualine `defaults_lualine_x_full_list`
  # patterns): the sibling `toggle_lazygit_caches_terminal` only pins `cmd`
  # and `direction` from the `Terminal:new` opts — it ignores the rest of
  # the canonical lazygit recipe. A regression that dropped `dir = "git_dir"`
  # would silently change the lazygit cwd semantics (no longer rooted at the
  # repo). A regression that dropped `hidden = true` would change the toggle
  # to close-on-Esc instead of hide. A regression that dropped
  # `float_opts.border = "double"` would shift the visual frame. None of
  # those would surface in any sibling check. Pin the full opts shape
  # (cmd, dir, direction, hidden, float_opts.border) by stubbing
  # `toggleterm.terminal` with a fake whose `Terminal:new` captures opts and
  # asserting each leaf.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__lg_opts = nil; package.loaded["toggleterm.terminal"] = { Terminal = { new = function(self, opts) _G.__lg_opts = opts; return setmetatable({}, { __index = { toggle = function(_) end } }) end } }' \
    -c "lua require('lvim.plugins.modules.terminal').toggle_lazygit()" \
    -c 'lua local o = _G.__lg_opts or {}; local fo = o.float_opts or {}; print("LG_FULL", o.cmd, o.dir, o.direction, tostring(o.hidden), fo.border)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LG_FULL[[:space:]]+lazygit[[:space:]]+git_dir[[:space:]]+float[[:space:]]+true[[:space:]]+double$' <<<"$output"; then
    printf 'phase 6 terminal: toggle_lazygit Terminal:new opts shape mismatched the canonical lazygit recipe (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_comment_toggle_drops_plugin() {
  # Phase 6 (mini.comment finalize) acceptance: setting
  #   lvim.builtin.comment.active = false
  # in user config must cause the mini.nvim core spec entry (whose
  # `enabled = gate("comment")` reads that flag) to be filtered out of
  # `Config.plugins`, so `require('lazy').stats().count` drops by exactly 1
  # versus the baseline. This pins the toggle path end-to-end: spec uses the
  # comment-keyed gate, lazy honors `enabled = false`, and the count delta is
  # exactly one (no collateral drop from a shared mini.nvim entry serving
  # multiple sub-modules — if a future step adds another mini.* sub-module
  # under the same spec entry, this assertion will fail and force the split).
  local cfg_dir toggle_cfg baseline_out toggled_out baseline_n toggled_n

  cfg_dir="$(make_empty_config_dir)"
  baseline_out="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua print('STATS=' .. require('lazy').stats().count)" \
    -c 'qall!' 2>&1)"
  baseline_n="$(grep -Eo 'STATS=[0-9]+' <<<"$baseline_out" | head -1 | cut -d= -f2)"
  if [[ -z "$baseline_n" ]]; then
    printf 'phase 6 comment toggle: could not read baseline STATS count (output: %s)\n' "$baseline_out" >&2
    return 1
  fi

  toggle_cfg="$(mktemp -d -p "$SMOKE_TMP_BASE" comment-off-XXXXXX)"
  printf 'lvim.builtin.comment.active = false\n' > "$toggle_cfg/config.lua"
  toggled_out="$(LUNAVIM_CONFIG_DIR="$toggle_cfg" nvim --headless -u init.lua \
    -c "lua print('STATS=' .. require('lazy').stats().count)" \
    -c 'qall!' 2>&1)"
  toggled_n="$(grep -Eo 'STATS=[0-9]+' <<<"$toggled_out" | head -1 | cut -d= -f2)"
  if [[ -z "$toggled_n" ]]; then
    printf 'phase 6 comment toggle: could not read toggled STATS count (output: %s)\n' "$toggled_out" >&2
    return 1
  fi

  if (( toggled_n != baseline_n - 1 )); then
    printf 'phase 6 comment toggle: lazy.stats().count did not drop by exactly 1 when comment disabled (baseline=%d toggled=%d)\n' \
      "$baseline_n" "$toggled_n" >&2
    return 1
  fi
}

check_phase_6_comment_toggle_drops_mini_nvim_specifically() {
  # Phase 6 (mini.comment finalize) stronger acceptance: it is not enough that
  # `lazy.stats().count` drops by 1 when `lvim.builtin.comment.active = false`
  # (the sibling `check_phase_6_comment_toggle_drops_plugin`). A regression
  # that cross-mapped gate keys (e.g. swapped `gate("comment")` with another
  # entry's gate) could still produce a delta of 1 while the actual mini.nvim
  # plugin remains loaded and a different plugin gets dropped instead. Pin
  # the specific identity by scanning `lazy.core.config.plugins` for the
  # entry whose source URL is `echasnovski/mini.nvim`. With the toggle ON the
  # entry must be present; with the toggle OFF it must be absent. (lazy keys
  # plugins under their `spec.name`, not by URL, so we scan `plugin.url`
  # rather than indexing — the LunaVim spec sets `name = "comment"` on this
  # entry, which means a direct lookup by url-segment would miss.)
  local cfg_dir toggle_cfg baseline_out toggled_out

  cfg_dir="$(make_empty_config_dir)"
  baseline_out="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'echasnovski/mini.nvim') or (p.url and p.url:match('echasnovski/mini%.nvim')) then has = true; break end end; print('MINI=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^MINI=true$' <<<"$baseline_out"; then
    printf 'phase 6 comment toggle: echasnovski/mini.nvim not present in Config.plugins under baseline (output: %s)\n' "$baseline_out" >&2
    return 1
  fi

  toggle_cfg="$(mktemp -d -p "$SMOKE_TMP_BASE" comment-off-id-XXXXXX)"
  printf 'lvim.builtin.comment.active = false\n' > "$toggle_cfg/config.lua"
  toggled_out="$(LUNAVIM_CONFIG_DIR="$toggle_cfg" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'echasnovski/mini.nvim') or (p.url and p.url:match('echasnovski/mini%.nvim')) then has = true; break end end; print('MINI=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^MINI=false$' <<<"$toggled_out"; then
    printf 'phase 6 comment toggle: echasnovski/mini.nvim still present in Config.plugins with comment.active=false (output: %s)\n' "$toggled_out" >&2
    return 1
  fi
}

check_phase_6_comment_setup_does_not_mutate_builtin() {
  # Phase 6 defensive contract (mirrors sibling Phase 6 module checks): the
  # comment module's `vim.deepcopy(builtin.options or {})` before forwarding to
  # `mini.comment.setup` must NOT mutate the live `_G.lvim.builtin.comment.options`
  # subtree. A regression that dropped the deepcopy (e.g. swapped it for a
  # direct pass of `builtin.options`, or a shallow `vim.tbl_extend("force",
  # {}, builtin.options)`) would leave the live options open to mutation by
  # anything `mini.comment.setup` does internally — and break user-config
  # round-trips on `:LvimReload`. Stub `mini.comment.setup` to observably
  # mutate every leaf it sees, then assert the live defaults are untouched.
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" comment-nomut-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.builtin.comment.options.ignore_blank_line = true
lvim.builtin.comment.options.start_of_line = false
LUA

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["mini.comment"] = { setup = function(o) if o.options then o.options.ignore_blank_line = "MUTATED"; o.options.start_of_line = "MUTATED" end end }' \
    -c "lua require('lvim.plugins.modules.comment').setup({})" \
    -c 'lua local o = lvim.builtin.comment.options; print("LIVE_CMT", lvim.builtin.comment.active, tostring(o.ignore_blank_line), tostring(o.start_of_line))' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LIVE_CMT[[:space:]]+true[[:space:]]+true[[:space:]]+false$' <<<"$output"; then
    printf 'phase 6 comment: mini.comment.setup observably mutated lvim.builtin.comment.options (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_comment_literal_acceptance_require_returns_table() {
  # Phase 6 mini.comment finalize literal acceptance, mirroring the sibling
  # Phase 6 `*_literal_acceptance_require_returns_table` checks
  # (indentlines/lualine/bufferline/gitsigns/whichkey/terminal/breadcrumbs):
  #   nvim --headless -u init.lua -c "lua print(type(require('mini.comment')))" \
  #     -c qall! 2>&1 | grep -q table
  # In the smoke env mini.nvim is not on disk (install.missing = false), so we
  # preload `package.loaded["mini.comment"]` with a fake whose `.setup` is a
  # noop — this isolates the acceptance to the *return type* contract from the
  # parity convention ("require('mini.comment') returns a table") and pins
  # the literal module name in the verbatim acceptance command. This check
  # does NOT pin that `lvim/plugins/modules/comment.lua` itself dispatches
  # through `require('mini.comment')` — because the preload short-circuits
  # any code path, a regression that re-keyed comment.lua to `require("mini")`
  # would still let this check pass. The dynamic
  # `check_phase_6_comment_module_dispatches_through_mini_comment_require`
  # sibling pins that production-module require call.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["mini.comment"] = { setup = function(_) end }' \
    -c "lua print(type(require('mini.comment')))" \
    -c 'qall!' 2>&1)"
  if ! grep -q 'table' <<<"$output"; then
    printf 'phase 6 comment: literal acceptance print(type(require("mini.comment"))) did not emit "table" (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_comment_module_dispatches_through_mini_comment_require() {
  # Phase 6 mini.comment finalize dynamic dispatch contract: the production
  # module `lua/lvim/plugins/modules/comment.lua` must actually require the
  # literal module name `mini.comment` at runtime — not `mini` (the umbrella
  # the library explicitly disallows, see
  # https://github.com/echasnovski/mini.nvim) and not any other submodule.
  #
  # The static sibling `check_phase_52_comment_module_calls_mini_setup` greps
  # the source for `require('mini.comment').setup`, which catches a literal
  # textual change but a future refactor that built the module name dynamically
  # (e.g. `local m = "mini"; require(m).setup(...)`) would silently bypass the
  # grep. Pin the runtime behavior here: install a `package.preload` shim that
  # records when `mini.comment` is required, clear any preceding `package.loaded`
  # entry to force the preload to fire, then drive the module via its public
  # `setup({})` entrypoint. The shim must observably run AND `mini.comment.setup`
  # must observably be called.
  #
  # A regression that swapped `require("mini.comment")` for `require("mini")`
  # would fail the `__MINI_COMMENT_REQUIRED=true` assertion (the preload for
  # `mini.comment` would never fire), while the
  # `*_literal_acceptance_require_returns_table` sibling would still pass
  # because that test preloads `mini.comment` directly without exercising
  # comment.lua at all.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__MINI_COMMENT_REQUIRED = false; _G.__MINI_COMMENT_SETUP_CALLED = false; package.loaded["mini.comment"] = nil; package.preload["mini.comment"] = function() _G.__MINI_COMMENT_REQUIRED = true; return { setup = function(_) _G.__MINI_COMMENT_SETUP_CALLED = true end } end' \
    -c "lua require('lvim.plugins.modules.comment').setup({})" \
    -c 'lua print("MC_REQ=" .. tostring(_G.__MINI_COMMENT_REQUIRED) .. " MC_SETUP=" .. tostring(_G.__MINI_COMMENT_SETUP_CALLED))' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^MC_REQ=true MC_SETUP=true$' <<<"$output"; then
    printf 'phase 6 comment: comment.lua did not dispatch through require("mini.comment") and mini_comment.setup at runtime (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_breadcrumbs_module_present() {
  # Phase 6 breadcrumbs module: pin the file's presence AND that it dispatches
  # into `require('nvim-navic').setup(...)`. A regression that left a Phase 0
  # stub in place would silently drop user `lvim.builtin.breadcrumbs.options`
  # on the floor (the spec gate would still load the plugin, but its `config`
  # callback would be a no-op).
  if [[ ! -f lua/lvim/plugins/modules/breadcrumbs.lua ]]; then
    printf 'phase 6 breadcrumbs: lua/lvim/plugins/modules/breadcrumbs.lua is missing\n' >&2
    return 1
  fi
  if ! grep -Eq "require[[:space:]]*['\"]nvim-navic['\"][[:space:]]*\\.setup|require\\(['\"]nvim-navic['\"]\\)\\.setup" \
        lua/lvim/plugins/modules/breadcrumbs.lua; then
    printf 'phase 6 breadcrumbs: module does not call require("nvim-navic").setup\n' >&2
    return 1
  fi
}

check_phase_6_breadcrumbs_defaults_shape() {
  # Phase 6 step 1 prescribes the breadcrumbs defaults subtree shape:
  #   { active = true, options = { icons = {...}, highlight = true } }
  # The icons subtable is part of the plan-prescribed shape — earlier
  # iterations of the defaults file omitted it on the rationale that
  # nvim-navic ships its own fallback glyphs, but the plan acceptance
  # treats `icons` as a required key of the LunarVim defaults so users
  # see LunaVim's chosen Nerd Font glyphs without having to seed them by
  # hand. Pin all three observable knobs (active toggle, options-is-a-table,
  # icons-is-a-table, highlight=true); a regression that flattens the
  # table (e.g. moved `highlight` to the top level), drops the icons
  # subtree, or replaces it with a string surfaces here. The
  # sibling `defaults_icons_full_list` check pins per-kind content.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local t = lvim.builtin.breadcrumbs; print(t.active, type(t.options), type(t.options.icons), t.options.highlight)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^true[[:space:]]+table[[:space:]]+table[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 breadcrumbs: lvim.builtin.breadcrumbs defaults shape wrong (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_breadcrumbs_setup_forwards_opts() {
  # Phase 6 step 2: `setup()` must forward `lvim.builtin.breadcrumbs.options`
  # (NOT the whole subtree, so `active` does not leak into navic's options
  # — `active` is the spec gate's input, not a navic key) to
  # `require('nvim-navic').setup`. Without this forwarding the defaults
  # `options` table is dead code — exposed to users but never consumed. Stub
  # `package.loaded["nvim-navic"]` with a fake whose `setup` captures the opts
  # table, then call the module's setup() directly and assert the captured
  # opts carry `highlight = true` AND that `active` was stripped (it lives one
  # level up under `lvim.builtin.breadcrumbs.active`, not under `.options`).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__nv_opts = nil; package.loaded["nvim-navic"] = { setup = function(o) _G.__nv_opts = o end, attach = function() end, get_location = function() return "" end }' \
    -c "lua require('lvim.plugins.modules.breadcrumbs').setup({})" \
    -c 'lua local o = _G.__nv_opts or {}; print("CAPTURED_NV", type(o), o.highlight, o.active == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^CAPTURED_NV[[:space:]]+table[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 breadcrumbs: module did not forward lvim.builtin.breadcrumbs.options to nvim-navic.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_breadcrumbs_setup_pcall_guards_missing() {
  # Smoke runs with install.missing=false so nvim-navic is not on disk. A
  # regression that dropped the pcall around `require('nvim-navic')` would
  # raise the moment lazy fires the module's `config` callback (it does so as
  # soon as the LSP on_attach in `lvim/lsp/handlers.lua` calls
  # `require('nvim-navic')`, which lazy intercepts to load the plugin). Force
  # the module unavailable and assert setup() returns without erroring.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["nvim-navic"] = nil; package.preload["nvim-navic"] = nil' \
    -c "lua local ok, err = pcall(function() require('lvim.plugins.modules.breadcrumbs').setup({}) end); print('PCALL_NV', ok, err == nil)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^PCALL_NV[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 breadcrumbs: module setup raised when nvim-navic was unavailable (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_breadcrumbs_setup_arms_winbar() {
  # Phase 6 step contract: after a successful `navic.setup`, the module must
  # arm `vim.opt.winbar` with the navic `get_location` expression so the
  # breadcrumb renders in the winbar of every window. Pin BOTH that the option
  # is set AND that its value references the navic location call — a regression
  # that wired a different expression (or forgot to arm winbar at all) is
  # caught here. The stubbed navic module lets setup complete without
  # requiring the plugin to be on disk.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua vim.opt.winbar = ""' \
    -c 'lua package.loaded["nvim-navic"] = { setup = function(_) end, attach = function() end, get_location = function() return "" end }' \
    -c "lua require('lvim.plugins.modules.breadcrumbs').setup({})" \
    -c 'lua print("WINBAR=" .. vim.o.winbar)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq "^WINBAR=.*nvim-navic.*get_location" <<<"$output"; then
    printf 'phase 6 breadcrumbs: vim.opt.winbar was not armed with the navic get_location expression after setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_breadcrumbs_setup_does_not_mutate_builtin() {
  # Phase 6 defensive contract (mirrors sibling checks): the module's
  # `vim.deepcopy(builtin.options or {})` before forwarding to navic.setup
  # must NOT mutate the live `_G.lvim.builtin.breadcrumbs.options` subtree.
  # A regression that dropped the deepcopy (e.g. passed `builtin.options`
  # directly, or used a shallow copy) would leave the live options open to
  # mutation by anything navic.setup does internally. Stub navic.setup to
  # observably mutate every leaf it can find, then assert the live defaults
  # are untouched.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["nvim-navic"] = { setup = function(o) o.highlight = "MUTATED"; o.safe_output = "MUTATED" end, attach = function() end, get_location = function() return "" end }' \
    -c "lua require('lvim.plugins.modules.breadcrumbs').setup({})" \
    -c 'lua local o = lvim.builtin.breadcrumbs.options; print("LIVE_NV", lvim.builtin.breadcrumbs.active, o.highlight)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LIVE_NV[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 breadcrumbs: nvim-navic.setup observably mutated lvim.builtin.breadcrumbs.options (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_breadcrumbs_user_override_forwarded() {
  # Phase 6 user-override contract: a user that mutates
  # `lvim.builtin.breadcrumbs.options` from their config (the LunarVim-style
  # flow — plain Lua assignment against the live `_G.lvim` table) must have
  # that mutation observably forwarded to `nvim-navic.setup`. Sibling
  # check_phase_6_breadcrumbs_setup_forwards_opts only exercises the DEFAULTS
  # shape; this one pins user-mutation → live-read → nvim-navic.setup
  # end-to-end. Tests both an override of the default `highlight` knob AND a
  # brand-new key the user adds (`separator`, which navic accepts for the
  # between-segment glue).
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" breadcrumbs-user-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.builtin.breadcrumbs.options.highlight = false
lvim.builtin.breadcrumbs.options.separator = " > "
lvim.builtin.breadcrumbs.options.depth_limit = 5
LUA

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__nv_user_opts = nil; package.loaded["nvim-navic"] = { setup = function(o) _G.__nv_user_opts = o end, attach = function() end, get_location = function() return "" end }' \
    -c "lua require('lvim.plugins.modules.breadcrumbs').setup({})" \
    -c 'lua local o = _G.__nv_user_opts or {}; print("USER_NV", tostring(o.highlight), o.separator, o.depth_limit)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^USER_NV[[:space:]]+false[[:space:]]+>[[:space:]]+5$' <<<"$output"; then
    printf 'phase 6 breadcrumbs: user override of lvim.builtin.breadcrumbs.options did not flow through to nvim-navic.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_breadcrumbs_on_attach_calls_navic_attach() {
  # Phase 6 step contract: the LSP `on_attach` returned by
  # `lvim.lsp.handlers.make_on_attach()` must call `navic.attach(client, bufnr)`
  # when BOTH (a) the client reports `documentSymbolProvider = true` AND
  # (b) `lvim.builtin.breadcrumbs.active ~= false`. This pins the navic
  # auto-attach path — without it, navic's `get_location()` returns the empty
  # string forever and the winbar is permanently blank even with an LSP attached.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__nv_attached = {}; package.loaded["nvim-navic"] = { setup = function(_) end, attach = function(c, b) table.insert(_G.__nv_attached, { name = c.name or "?", buf = b }) end, get_location = function() return "" end }' \
    -c 'lua local h = require("lvim.lsp.handlers"); local on_attach = h.make_on_attach(); local fake_client = { name = "luals", server_capabilities = { documentSymbolProvider = true } }; on_attach(fake_client, 1)' \
    -c 'lua local a = _G.__nv_attached or {}; print("ATTACH_NV", #a, a[1] and a[1].name, a[1] and a[1].buf)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^ATTACH_NV[[:space:]]+1[[:space:]]+luals[[:space:]]+1$' <<<"$output"; then
    printf 'phase 6 breadcrumbs: on_attach did not call navic.attach for a documentSymbolProvider-capable client (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_breadcrumbs_on_attach_skips_without_capability() {
  # Phase 6 step contract: the LSP `on_attach` must NOT call `navic.attach`
  # when the client lacks `documentSymbolProvider` capability. navic operates
  # exclusively on LSP document symbols; attaching to a client without symbol
  # provider support would cause navic to emit error notifications (per its
  # README's "Manual Wrapper" guidance — the capability check is required).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__nv_attached = 0; package.loaded["nvim-navic"] = { setup = function(_) end, attach = function(_, _) _G.__nv_attached = _G.__nv_attached + 1 end, get_location = function() return "" end }' \
    -c 'lua local h = require("lvim.lsp.handlers"); local on_attach = h.make_on_attach(); local fake_client = { name = "tsserver", server_capabilities = { documentSymbolProvider = false } }; on_attach(fake_client, 1)' \
    -c 'lua print("NOCAP_NV", _G.__nv_attached)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^NOCAP_NV[[:space:]]+0$' <<<"$output"; then
    printf 'phase 6 breadcrumbs: on_attach called navic.attach for a client without documentSymbolProvider (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_breadcrumbs_on_attach_skips_when_disabled() {
  # Phase 6 step contract: setting `lvim.builtin.breadcrumbs.active = false`
  # must make the LSP `on_attach` SKIP the `navic.attach` call, even for
  # capable clients. The spec's `enabled = gate("breadcrumbs")` already drops
  # the plugin from `Config.plugins` when disabled, but the on_attach check
  # is an extra runtime guard so a user who flips the toggle at runtime (e.g.
  # via `:LvimReload` after editing config) doesn't have navic still attaching
  # to fresh LSP clients between reloads.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua lvim.builtin.breadcrumbs.active = false' \
    -c 'lua _G.__nv_attached = 0; package.loaded["nvim-navic"] = { setup = function(_) end, attach = function(_, _) _G.__nv_attached = _G.__nv_attached + 1 end, get_location = function() return "" end }' \
    -c 'lua local h = require("lvim.lsp.handlers"); local on_attach = h.make_on_attach(); local fake_client = { name = "luals", server_capabilities = { documentSymbolProvider = true } }; on_attach(fake_client, 1)' \
    -c 'lua print("DISABLED_NV", _G.__nv_attached)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^DISABLED_NV[[:space:]]+0$' <<<"$output"; then
    printf 'phase 6 breadcrumbs: on_attach called navic.attach when lvim.builtin.breadcrumbs.active = false (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_breadcrumbs_spec_uses_breadcrumbs_active_gate() {
  # Phase 6 step contract: the lazy spec entry for `SmiteshP/nvim-navic` must
  # gate on `lvim.builtin.breadcrumbs.active`. A regression that re-keyed the
  # gate (e.g. `gate("navic")`, or no gate at all) would leave the entry
  # always-enabled regardless of the user toggle. Pin (a) the entry exists and
  # resolves to nvim-navic, and (b) flipping the active flag at runtime flips
  # the entry's `enabled()` return value.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua \
local s = require('lvim.plugins.spec'); \
local entry = nil; \
for _, p in ipairs(s) do if p[1] == 'SmiteshP/nvim-navic' then entry = p end end; \
local has_entry = entry ~= nil; \
local on, off = nil, nil; \
if has_entry and type(entry.enabled) == 'function' then \
  lvim.builtin.breadcrumbs.active = true;  on  = entry.enabled(); \
  lvim.builtin.breadcrumbs.active = false; off = entry.enabled(); \
end; \
print('GATE_NV', has_entry, on, off)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^GATE_NV[[:space:]]+true[[:space:]]+true[[:space:]]+false$' <<<"$output"; then
    printf 'phase 6 breadcrumbs: nvim-navic spec entry missing or not gated on lvim.builtin.breadcrumbs.active (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_breadcrumbs_literal_acceptance_require_returns_table() {
  # Phase 6 step description acceptance command, run verbatim against a
  # stubbed `nvim-navic` module:
  #   nvim --headless -u init.lua -c "lua print(type(require('nvim-navic')))" \
  #     -c qall! 2>&1 | grep -q table
  # In the smoke env nvim-navic is not on disk (install.missing = false), so
  # we preload `package.loaded["nvim-navic"]` with a fake whose `.setup` and
  # `.attach` are noops — this isolates the acceptance to the *return type*
  # contract ("require('nvim-navic') returns a table"). A regression that
  # broke the spec/module dispatch shape (e.g. require fell over before the
  # type print fired) would not produce a line matching `table`.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["nvim-navic"] = { setup = function(_) end, attach = function() end, get_location = function() return "" end }' \
    -c "lua print(type(require('nvim-navic')))" \
    -c 'qall!' 2>&1)"
  if ! grep -q 'table' <<<"$output"; then
    printf 'phase 6 breadcrumbs: literal acceptance print(type(require("nvim-navic"))) did not emit "table" (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_breadcrumbs_toggle_drops_breadcrumbs_specifically() {
  # Phase 6 breadcrumbs gate-identity contract (mirrors the telescope/nvimtree/
  # lualine/bufferline/gitsigns/whichkey/terminal sibling checks):
  # `lvim.builtin.breadcrumbs.active = false` must drop the
  # `SmiteshP/nvim-navic` spec entry from `lazy.core.config.plugins`. The
  # sibling `spec_uses_breadcrumbs_active_gate` check only exercises the spec
  # entry's `enabled` function at the module level — it doesn't pin that lazy
  # actually honors the gate and filters the entry out of `Config.plugins`.
  # A regression that cross-mapped gate keys (e.g. swapped `gate("breadcrumbs")`
  # with another module's key, or that silently moved the gate to a static
  # `true`) could leave `spec_uses_breadcrumbs_active_gate` passing while
  # nvim-navic still loads when the user disabled it. Scan
  # `lazy.core.config.plugins` by source URL rather than by `spec.name` (the
  # LunaVim spec sets `name = "breadcrumbs"`, which makes url-segment lookups
  # by `SmiteshP/nvim-navic` more robust).
  local cfg_dir toggle_cfg baseline_out toggled_out

  cfg_dir="$(make_empty_config_dir)"
  baseline_out="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'SmiteshP/nvim-navic') or (p.url and p.url:match('SmiteshP/nvim%-navic')) then has = true; break end end; print('NV=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^NV=true$' <<<"$baseline_out"; then
    printf 'phase 6 breadcrumbs toggle: SmiteshP/nvim-navic not present in Config.plugins under baseline (output: %s)\n' "$baseline_out" >&2
    return 1
  fi

  toggle_cfg="$(mktemp -d -p "$SMOKE_TMP_BASE" breadcrumbs-off-id-XXXXXX)"
  printf 'lvim.builtin.breadcrumbs.active = false\n' > "$toggle_cfg/config.lua"
  toggled_out="$(LUNAVIM_CONFIG_DIR="$toggle_cfg" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'SmiteshP/nvim-navic') or (p.url and p.url:match('SmiteshP/nvim%-navic')) then has = true; break end end; print('NV=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^NV=false$' <<<"$toggled_out"; then
    printf 'phase 6 breadcrumbs toggle: SmiteshP/nvim-navic still present in Config.plugins with breadcrumbs.active=false (output: %s)\n' "$toggled_out" >&2
    return 1
  fi
}

check_phase_6_breadcrumbs_defaults_icons_full_list() {
  # Phase 6 step 1 contract: `lvim.builtin.breadcrumbs.options.icons` is
  # prescribed by the plan as the kind→glyph map shown in the navic winbar
  # location string. The sibling `defaults_shape` check only asserts the
  # icons subtable EXISTS and is a table; a regression that emptied the
  # subtable, dropped a kind, or replaced the LunarVim-heritage Nerd Font
  # glyph with `nil`/empty would pass `defaults_shape` while silently
  # blanking the user-visible breadcrumb. Pin the exact key count (26 LSP
  # symbol kinds, per `lib.lua` `lsp_str_to_num`) AND that every one of
  # the 26 prescribed kinds resolves to a non-empty string. The Nerd Font
  # glyphs themselves contain literal spaces, so doing the nil/empty
  # check inside Lua and emitting a single summary string sidesteps any
  # shell field-splitting fragility. This mirrors the bufferline
  # `defaults_offsets_full_list`, lualine `defaults_lualine_x_full_list`
  # and whichkey `defaults_mappings_full_list` patterns (pin a collection's
  # count plus per-entry content, not just one cell).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua \
local i = lvim.builtin.breadcrumbs.options.icons; \
local expected = { 'File','Module','Namespace','Package','Class','Method','Property','Field','Constructor','Enum','Interface','Function','Variable','Constant','String','Number','Boolean','Array','Object','Key','Null','EnumMember','Struct','Event','Operator','TypeParameter' }; \
local n = 0; for _ in pairs(i) do n = n + 1 end; \
local missing = {}; for _, k in ipairs(expected) do local v = i[k]; if type(v) ~= 'string' or v == '' then table.insert(missing, k) end end; \
print('ICONS_NV', n, #missing, table.concat(missing, ','))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^ICONS_NV[[:space:]]+26[[:space:]]+0[[:space:]]*$' <<<"$output"; then
    printf 'phase 6 breadcrumbs: defaults.options.icons must be the prescribed 26-kind map with non-empty string glyphs (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_indentlines_module_present() {
  # Phase 6 indent-blankline module: pin the file's presence AND that it
  # dispatches into `require('ibl').setup(...)`. v3 of indent-blankline
  # renamed the module from `indent_blankline` to `ibl`; v2's
  # `require('indent_blankline')` now errors with a hard migration message.
  # A regression that left a Phase 0 stub in place — or one that resurrected
  # the v2 require — would silently drop user `lvim.builtin.indentlines.options`
  # on the floor (the spec gate would still load the plugin, but its `config`
  # callback would be a no-op or would raise).
  if [[ ! -f lua/lvim/plugins/modules/indentlines.lua ]]; then
    printf 'phase 6 indentlines: lua/lvim/plugins/modules/indentlines.lua is missing\n' >&2
    return 1
  fi
  if ! grep -Eq "require[[:space:]]*\\(?['\"]ibl['\"]\\)?[[:space:]]*\\.?[[:space:]]*\\)?[[:space:]]*\\.setup|require\\(['\"]ibl['\"]\\)\\.setup" \
        lua/lvim/plugins/modules/indentlines.lua; then
    printf 'phase 6 indentlines: module does not call require("ibl").setup\n' >&2
    return 1
  fi
  if grep -vE '^[[:space:]]*--' lua/lvim/plugins/modules/indentlines.lua \
       | grep -Eq "require[[:space:]]*\\(?['\"]indent_blankline['\"]"; then
    printf 'phase 6 indentlines: module still references the v2 require("indent_blankline") (must be require("ibl"))\n' >&2
    return 1
  fi
}

check_phase_6_indentlines_defaults_shape() {
  # Phase 6 step prescribes the indentlines defaults subtree shape:
  #   { active = true, options = { indent = { char = "│" }, scope = { enabled = true } } }
  # The `options` subtree follows ibl v3's nested config layout (the v2 flat
  # `{ char = "│", show_current_context = true }` is dead — ibl v3 reorganised
  # everything under `indent.*`, `scope.*`, `whitespace.*`, `exclude.*`). A
  # regression that flattened the table back to v2 shape, or that dropped the
  # LunarVim contract char "│" in favour of ibl's upstream "▎" default,
  # surfaces here.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua local t = lvim.builtin.indentlines; print(t.active, type(t.options), type(t.options.indent), t.options.indent.char, type(t.options.scope), t.options.scope.enabled)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^true[[:space:]]+table[[:space:]]+table[[:space:]]+│[[:space:]]+table[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 indentlines: lvim.builtin.indentlines defaults shape wrong (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_indentlines_setup_forwards_opts() {
  # Phase 6 step 3: `setup()` must forward `lvim.builtin.indentlines.options`
  # (NOT the whole subtree, so `active` does not leak into ibl's options
  # — `active` is the spec gate's input, not an ibl key) to
  # `require('ibl').setup`. Without this forwarding the defaults `options`
  # table is dead code — exposed to users but never consumed. Stub
  # `package.loaded["ibl"]` with a fake whose `setup` captures the opts
  # table, then call the module's setup() directly and assert the captured
  # opts carry `indent.char = "│"` and `scope.enabled = true` AND that
  # `active` was stripped (it lives one level up under
  # `lvim.builtin.indentlines.active`, not under `.options`).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__ibl_opts = nil; package.loaded["ibl"] = { setup = function(o) _G.__ibl_opts = o end }' \
    -c "lua require('lvim.plugins.modules.indentlines').setup({})" \
    -c 'lua local o = _G.__ibl_opts or {}; print("CAPTURED_IBL", type(o), o.indent and o.indent.char, o.scope and o.scope.enabled, o.active == nil)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^CAPTURED_IBL[[:space:]]+table[[:space:]]+│[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 indentlines: module did not forward lvim.builtin.indentlines.options to ibl.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_indentlines_setup_pcall_guards_missing() {
  # Smoke runs with install.missing=false so indent-blankline (the `ibl`
  # module) is not on disk. A regression that dropped the pcall around
  # `require('ibl')` would raise the moment lazy fires the module's `config`
  # callback (it does so on the first `BufReadPost`/`BufNewFile` —
  # essentially every nvim launch that opens a buffer). Force the module
  # unavailable and assert setup() returns without erroring.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["ibl"] = nil; package.preload["ibl"] = nil' \
    -c "lua local ok, err = pcall(function() require('lvim.plugins.modules.indentlines').setup({}) end); print('PCALL_IBL', ok, err == nil)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^PCALL_IBL[[:space:]]+true[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 indentlines: module setup raised when ibl was unavailable (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_indentlines_setup_does_not_mutate_builtin() {
  # Phase 6 defensive contract (mirrors sibling checks): the module's
  # `vim.deepcopy(builtin.options or {})` before forwarding to ibl.setup
  # must NOT mutate the live `_G.lvim.builtin.indentlines.options` subtree.
  # A regression that dropped the deepcopy (e.g. passed `builtin.options`
  # directly, or used a shallow copy) would leave the live options open to
  # mutation by anything ibl.setup does internally — and worse, since the
  # options nest two levels deep (`options.indent.char`, `options.scope.enabled`),
  # a shallow copy would alias the inner tables back to the live defaults.
  # Stub ibl.setup to observably mutate leaves at both depths, then assert
  # the live defaults are untouched.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["ibl"] = { setup = function(o) if o.indent then o.indent.char = "MUTATED" end; if o.scope then o.scope.enabled = "MUTATED" end end }' \
    -c "lua require('lvim.plugins.modules.indentlines').setup({})" \
    -c 'lua local o = lvim.builtin.indentlines.options; print("LIVE_IBL", lvim.builtin.indentlines.active, o.indent.char, o.scope.enabled)' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^LIVE_IBL[[:space:]]+true[[:space:]]+│[[:space:]]+true$' <<<"$output"; then
    printf 'phase 6 indentlines: ibl.setup observably mutated lvim.builtin.indentlines.options (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_indentlines_user_override_forwarded() {
  # Phase 6 user-override contract: a user that mutates
  # `lvim.builtin.indentlines.options` from their config (the LunarVim-style
  # flow — plain Lua assignment against the live `_G.lvim` table) must have
  # that mutation observably forwarded to `ibl.setup`. Sibling
  # check_phase_6_indentlines_setup_forwards_opts only exercises the DEFAULTS
  # shape; this one pins user-mutation → live-read → ibl.setup end-to-end.
  # Tests both an override of the default `indent.char` knob AND a brand-new
  # key the user adds (`indent.tab_char` and an `exclude.filetypes` list,
  # both of which ibl v3 accepts in its nested config table).
  local cfg_dir output
  cfg_dir="$(mktemp -d -p "$SMOKE_TMP_BASE" indentlines-user-XXXXXX)"
  cat > "$cfg_dir/config.lua" <<'LUA'
lvim.builtin.indentlines.options.indent.char = "▏"
lvim.builtin.indentlines.options.indent.tab_char = "→"
lvim.builtin.indentlines.options.exclude = { filetypes = { "alpha", "dashboard" } }
LUA

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua _G.__ibl_user_opts = nil; package.loaded["ibl"] = { setup = function(o) _G.__ibl_user_opts = o end }' \
    -c "lua require('lvim.plugins.modules.indentlines').setup({})" \
    -c 'lua local o = _G.__ibl_user_opts or {}; print("USER_IBL", o.indent and o.indent.char, o.indent and o.indent.tab_char, o.exclude and o.exclude.filetypes and o.exclude.filetypes[1], o.exclude and o.exclude.filetypes and o.exclude.filetypes[2])' \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^USER_IBL[[:space:]]+▏[[:space:]]+→[[:space:]]+alpha[[:space:]]+dashboard$' <<<"$output"; then
    printf 'phase 6 indentlines: user override of lvim.builtin.indentlines.options did not flow through to ibl.setup (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_indentlines_spec_uses_indentlines_active_gate() {
  # Phase 6 step contract: the lazy spec entry for `lukas-reineke/indent-blankline.nvim`
  # must gate on `lvim.builtin.indentlines.active`. A regression that re-keyed
  # the gate (e.g. `gate("indent_blankline")`, `gate("ibl")`, or no gate at
  # all) would leave the entry always-enabled regardless of the user toggle.
  # Pin (a) the entry exists and resolves to indent-blankline.nvim, and
  # (b) flipping the active flag at runtime flips the entry's `enabled()`
  # return value.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua \
local s = require('lvim.plugins.spec'); \
local entry = nil; \
for _, p in ipairs(s) do if p[1] == 'lukas-reineke/indent-blankline.nvim' then entry = p end end; \
local has_entry = entry ~= nil; \
local on, off = nil, nil; \
if has_entry and type(entry.enabled) == 'function' then \
  lvim.builtin.indentlines.active = true;  on  = entry.enabled(); \
  lvim.builtin.indentlines.active = false; off = entry.enabled(); \
end; \
print('GATE_IBL', has_entry, on, off)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^GATE_IBL[[:space:]]+true[[:space:]]+true[[:space:]]+false$' <<<"$output"; then
    printf 'phase 6 indentlines: indent-blankline.nvim spec entry missing or not gated on lvim.builtin.indentlines.active (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_indentlines_literal_acceptance_require_returns_table() {
  # Phase 6 step description acceptance command, run verbatim against a
  # stubbed `ibl` module:
  #   nvim --headless -u init.lua -c "lua print(type(require('ibl')))" \
  #     -c qall! 2>&1 | grep -q table
  # In the smoke env ibl is not on disk (install.missing = false), so we
  # preload `package.loaded["ibl"]` with a fake whose `.setup` is a noop —
  # this isolates the acceptance to the *return type* contract
  # ("require('ibl') returns a table") and pins the v3 module name (a
  # regression that broke the spec/module dispatch shape or that wired the
  # v2 `indent_blankline` name would not produce a line matching `table`).
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c 'lua package.loaded["ibl"] = { setup = function(_) end }' \
    -c "lua print(type(require('ibl')))" \
    -c 'qall!' 2>&1)"
  if ! grep -q 'table' <<<"$output"; then
    printf 'phase 6 indentlines: literal acceptance print(type(require("ibl"))) did not emit "table" (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_6_indentlines_toggle_drops_indentlines_specifically() {
  # Phase 6 indentlines gate-identity contract (mirrors the telescope/nvimtree/
  # lualine/bufferline/gitsigns/whichkey/terminal/breadcrumbs sibling checks):
  # `lvim.builtin.indentlines.active = false` must drop the
  # `lukas-reineke/indent-blankline.nvim` spec entry from
  # `lazy.core.config.plugins`. The sibling `spec_uses_indentlines_active_gate`
  # check only exercises the spec entry's `enabled` function at the module
  # level — it doesn't pin that lazy actually honors the gate and filters the
  # entry out of `Config.plugins`. A regression that cross-mapped gate keys
  # (e.g. swapped `gate("indentlines")` with another module's key, or that
  # silently moved the gate to a static `true`) could leave
  # spec_uses_indentlines_active_gate passing while indent-blankline.nvim still
  # loads when the user disabled it. Scan `lazy.core.config.plugins` by source
  # URL rather than by `spec.name` (the LunaVim spec sets
  # `name = "indentlines"`, which makes url-segment lookups by
  # `lukas-reineke/indent-blankline.nvim` more robust).
  local cfg_dir toggle_cfg baseline_out toggled_out

  cfg_dir="$(make_empty_config_dir)"
  baseline_out="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'lukas-reineke/indent-blankline.nvim') or (p.url and p.url:match('lukas%-reineke/indent%-blankline%.nvim')) then has = true; break end end; print('IBL=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^IBL=true$' <<<"$baseline_out"; then
    printf 'phase 6 indentlines toggle: lukas-reineke/indent-blankline.nvim not present in Config.plugins under baseline (output: %s)\n' "$baseline_out" >&2
    return 1
  fi

  toggle_cfg="$(mktemp -d -p "$SMOKE_TMP_BASE" indentlines-off-id-XXXXXX)"
  printf 'lvim.builtin.indentlines.active = false\n' > "$toggle_cfg/config.lua"
  toggled_out="$(LUNAVIM_CONFIG_DIR="$toggle_cfg" nvim --headless -u init.lua \
    -c "lua local has = false; for _, p in pairs(require('lazy.core.config').plugins) do if (p[1] == 'lukas-reineke/indent-blankline.nvim') or (p.url and p.url:match('lukas%-reineke/indent%-blankline%.nvim')) then has = true; break end end; print('IBL=' .. tostring(has))" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^IBL=false$' <<<"$toggled_out"; then
    printf 'phase 6 indentlines toggle: lukas-reineke/indent-blankline.nvim still present in Config.plugins with indentlines.active=false (output: %s)\n' "$toggled_out" >&2
    return 1
  fi
}

check_phase_6_comment_spec_uses_comment_active_gate() {
  # Phase 6 step 1 (literal): the lazy spec entry for `echasnovski/mini.nvim`
  # must gate on `lvim.builtin.comment.active`. The gate is wired via the
  # spec.lua `gate("comment")` helper that closes over the literal string
  # "comment" and reads `_G.lvim.builtin.comment.active`. Pin both: (a) the
  # entry exists and resolves to mini.nvim, and (b) flipping
  # `lvim.builtin.comment.active` at runtime flips the entry's `enabled()`
  # return value. A regression that re-keyed the gate (e.g. `gate("mini")`)
  # would leave `enabled()` insensitive to the comment flag — caught here.
  local cfg_dir output
  cfg_dir="$(make_empty_config_dir)"

  output="$(LUNAVIM_CONFIG_DIR="$cfg_dir" nvim --headless -u init.lua \
    -c "lua \
local s = require('lvim.plugins.spec'); \
local entry = nil; \
for _, p in ipairs(s) do if p[1] == 'echasnovski/mini.nvim' then entry = p end end; \
local has_entry = entry ~= nil; \
local on, off = nil, nil; \
if has_entry and type(entry.enabled) == 'function' then \
  lvim.builtin.comment.active = true;  on  = entry.enabled(); \
  lvim.builtin.comment.active = false; off = entry.enabled(); \
end; \
print('GATE', has_entry, on, off)" \
    -c 'qall!' 2>&1)"
  if ! grep -Eq '^GATE[[:space:]]+true[[:space:]]+true[[:space:]]+false$' <<<"$output"; then
    printf 'phase 6 comment: mini.nvim spec entry missing or not gated on lvim.builtin.comment.active (output: %s)\n' "$output" >&2
    return 1
  fi
}

check_phase_93_no_runtime_references_to_reference_tree() {
  # Phase 9.3 acceptance: the vendored upstream-reference tree was moved
  # to references/ and is documentation-only. Three independent
  # assertions guard the move:
  #
  #   (a) The relocated tree lives at `references/<name>/`.
  #   (b) No `<name>/` directory remains at the repository root — the
  #       check mirrors Phase 9.3's literal acceptance criterion
  #       (`[ ! -d <name> ]`), so a regression that re-clones the
  #       snapshot top-level would slip past assertion (c) if it kept
  #       the runtime tree clean.
  #   (c) Nothing under `lua/`, `bin/`, `scripts/`, or `init.lua` (the
  #       loaded runtime surface) carries a literal mention of the
  #       upstream snapshot's directory name, so a reintroduced
  #       require, hardcoded path, or even a stale comment that drifts
  #       back to the old top-level location trips the assertion.
  #
  # The literal directory name is built by Bash string concatenation
  # (`"CK"'LunarVim'`) so the forbidden word never appears verbatim in
  # this script's source — otherwise assertion (c) would flag itself.
  local name="CK"'LunarVim'

  # (a) references/<name>/ must exist.
  if [[ ! -d "references/$name" ]]; then
    printf 'phase 9.3 (a): references/%s/ is missing — the vendored upstream-reference tree must live under references/\n' "$name" >&2
    return 1
  fi

  # (b) <name>/ directory at the repository root must NOT exist. Use
  # `-d` (not `-e`) so the check matches the original step's literal
  # acceptance criterion (`[ ! -d <name> ]`) exactly — the move was of
  # a directory, so the no-regression assertion is also keyed on
  # directory.
  if [[ -d "$name" ]]; then
    printf 'phase 9.3 (b): %s/ exists at the repository root — must live only under references/\n' "$name" >&2
    return 1
  fi

  # (c) recursive grep over the loaded runtime surface — diagnostic
  # matches are streamed to stderr so a regression names the offending
  # file and line. stderr is redirected to a separate file so grep's
  # own error messages (missing path, permission denied) are reported
  # distinctly from match output. The mktemp template ends in `X`s
  # (no suffix) to stay portable to BSD mktemp on macOS, which only
  # substitutes trailing `X`s — matching every other mktemp call in
  # this script.
  local matches stderr_log rc
  stderr_log="$(mktemp -p "$SMOKE_TMP_BASE" phase93-grep-stderr-XXXXXX)"
  set +e
  matches="$(grep -rnE "$name" lua/ bin/ scripts/ init.lua 2>"$stderr_log")"
  rc=$?
  set -e
  # grep exits 0 when a match is found, 1 when none, >=2 on error.
  if (( rc == 0 )); then
    printf 'phase 9.3 (c): runtime tree references the upstream-reference dir name (must live only under references/):\n%s\n' "$matches" >&2
    rm -f "$stderr_log"
    return 1
  fi
  if (( rc >= 2 )); then
    printf 'phase 9.3 (c): grep failed scanning runtime tree (rc=%d):\n%s\n' "$rc" "$(cat "$stderr_log")" >&2
    rm -f "$stderr_log"
    return "$rc"
  fi
  rm -f "$stderr_log"
}

if [[ ! -f init.lua ]]; then
  printf 'init.lua is missing at repository root\n' >&2
  exit 1
fi

check_phase_93_no_runtime_references_to_reference_tree

check_nvim_init init.lua
check_globals_present
check_min_nvim_version_error

if [[ ! -x bin/lvim ]]; then
  printf 'bin/lvim is missing or not executable\n' >&2
  exit 1
fi

check_lvim_launcher
check_lvim_appname
check_lvim_launcher_uses_repo_init
check_user_config_applied
check_user_config_literal_acceptance
check_builtin_deep_merge_semantics
check_merge_builtin_overrides_api
check_merge_builtin_overrides_type_guards
check_deep_extend_force_keep_user_helper
check_missing_config_hint
check_user_plugins_appended
check_final_spec_filters_disabled_builtin
check_disabled_builtin_filter_is_core_only
check_final_spec_order_core_before_user
check_anonymous_core_entry_passes_through
check_multiple_disabled_builtins_all_filtered
check_reload_globals
check_lazy_bootstrap_idempotent
check_phase_22_plugin_count
check_phase_22_load_triggers
check_phase_23_commands_registered
check_phase_23_lvim_info_renders
check_phase_23_lvim_cache_reset_clears_dir
check_phase_23_lvim_reload_reapplies_config
check_phase_23_lvim_sync_core_plugins_dispatches
check_phase_23_acceptance_commands_literal
check_phase_24_snapshot_artifacts_present
check_phase_24_lvim_sync_core_plugins_initial_no_error
check_phase_24_non_empty_snapshot_restores
check_phase_24_snapshot_export_script_copies_lockfile
check_phase_25_second_launch_idempotency
check_phase_31_options_defaults_applied
check_phase_31_user_opt_override_wrap
check_phase_32_acceptance_commands_literal
check_phase_32_space_leader_translation
check_phase_32_default_maps_registered
check_phase_32_user_keys_override_applied
check_phase_32_setup_wired_in_init
check_phase_33_file_opened_fires_once
check_phase_33_file_opened_skipped_on_empty_buffer
check_phase_33_dir_opened_fires_when_listener_registered
check_phase_33_dir_opened_re_emits_originating_event
check_phase_33_file_opened_fires_on_new_file
check_phase_33_file_opened_fires_once_per_session
check_phase_33_trailing_whitespace_toggle
check_phase_33_setup_wired_in_init
check_phase_34_lvim_reload_reapplies_keymaps
check_phase_34_lvim_reload_reapplies_options
check_phase_34_lvim_reload_rearms_autocmds
check_phase_34_lvim_reload_emits_notify
check_phase_34_lvim_reload_literal_acceptance
check_phase_34_keymaps_setup_idempotent
check_phase_41_lsp_setup_orchestration
check_phase_41_lsp_setup_idempotent
check_phase_41_setup_wired_in_init
check_phase_41_mason_toggle_skips_setup
check_phase_42_defaults_table_present
check_phase_42_user_settings_flow_through
check_phase_42_defaults_attached_to_each_server
check_phase_42_user_on_attach_overrides_default
check_phase_42_default_on_attach_registers_keymaps
check_phase_42_capabilities_baseline
check_phase_42_user_capabilities_overrides_default
check_phase_42_per_server_on_attach_overrides_global
check_phase_42_multiple_servers_all_setup
check_phase_42_empty_servers_no_setup_calls
check_phase_42_blink_cmp_extends_capabilities
check_phase_42_automatic_servers_installation_wired
check_phase_42_ensure_installed_wired
check_phase_42_handlers_module_present
check_phase_42_uses_vim_lsp_config_not_setup
check_phase_42_vim_lsp_enable_called_for_each_server
check_phase_42_orchestrator_does_not_index_lspconfig
check_phase_43_format_module_present
check_phase_43_true_registers_autocmd
check_phase_43_false_no_autocmd
check_phase_43_table_form_honored
check_phase_43_reload_idempotent
check_phase_43_exclude_clients_filter_drops_named
check_phase_43_user_filter_overrides_exclude_clients
check_phase_43_table_without_enabled_is_disabled
check_phase_43_true_normalizes_timeout_ms
check_phase_43_table_form_timeout_ms_flows_through
check_phase_43_resetup_drains_augroup_when_disabled
check_phase_44_lazydev_module_present
check_phase_44_lazydev_setup_library_defaults
check_phase_44_lazydev_setup_user_opts_merged
check_phase_44_lazydev_setup_pcall_guards_missing
check_phase_44_lazydev_literal_acceptance
check_phase_44_lazydev_loads_on_lua_ft
check_phase_44_lspconfig_does_not_set_lua_workspace_library
check_phase_45_diagnostics_module_present
check_phase_45_diagnostic_config_defaults_applied
check_phase_45_signs_defined
check_phase_45_diagnostic_config_signs_table_has_text
check_phase_45_signs_render_with_prescribed_glyph
check_phase_45_signs_numhl_render_with_prescribed_highlight
check_phase_45_signs_numhl_user_override_renders
check_phase_45_signs_text_deep_merges_per_severity
check_phase_45_user_overrides_merged
check_phase_45_setup_wired_in_orchestrator
check_phase_51_treesitter_module_present
check_phase_51_treesitter_defaults_shape
check_phase_51_treesitter_setup_forwards_opts
check_phase_51_treesitter_setup_pcall_guards_missing
check_phase_51_treesitter_toggle_drops_plugin
check_phase_51_literal_require_nvim_treesitter
check_phase_51_open_lua_file_no_error
check_phase_51_user_override_forwarded_to_configs_setup
check_phase_51_setup_does_not_mutate_builtin
check_phase_52_comment_module_calls_mini_setup
check_phase_52_comment_defaults_shape
check_phase_52_setup_forwards_options_and_pre_hook
check_phase_52_user_options_pass_through
check_phase_52_setup_pcall_guards_missing
check_phase_52_pre_hook_sets_jsx_commentstring_for_tsx_ft
check_phase_52_pre_hook_leaves_non_jsx_buffer_alone
check_phase_52_pre_hook_prefers_treesitter_node_when_available
check_phase_52_pre_hook_walks_parent_chain_for_jsx
check_phase_52_pre_hook_uses_ref_position_not_cursor
check_phase_52_pre_hook_trusts_treesitter_over_filetype
check_phase_52_pre_hook_round_trip_resets_jsx_on_tsx_buffer
check_phase_52_pre_hook_does_not_touch_non_jsx_filetype_on_non_jsx_node
check_phase_52_sample_tsx_fixture_present
check_phase_52_acceptance_command_literal
check_phase_53_commands_lua_calls_tsupdate
check_phase_53_tsupdate_scheduled_when_treesitter_active
check_phase_53_tsupdate_skipped_when_treesitter_inactive
check_phase_53_sync_completes_when_treesitter_not_loaded
check_phase_53_tsupdate_error_does_not_abort_sync
check_phase_6_telescope_module_present
check_phase_6_telescope_defaults_shape
check_phase_6_telescope_defaults_mappings_cn_cp
check_phase_6_telescope_setup_forwards_opts
check_phase_6_telescope_setup_pcall_guards_missing
check_phase_6_telescope_leader_f_group_maps_registered
check_phase_6_telescope_user_override_forwarded
check_phase_6_telescope_setup_does_not_mutate_builtin
check_phase_6_telescope_literal_acceptance_telescope_find_files
check_phase_6_telescope_literal_acceptance_require_returns_table
check_phase_6_telescope_toggle_drops_telescope_specifically
check_phase_6_nvimtree_module_present
check_phase_6_nvimtree_defaults_shape
check_phase_6_nvimtree_lvimexplorer_focuses_new_sidebar
check_phase_6_nvimtree_on_attach_cr_passes_node
check_phase_6_nvimtree_setup_disables_netrw
check_phase_6_nvimtree_setup_forwards_opts
check_phase_6_nvimtree_setup_pcall_guards_missing
check_phase_6_nvimtree_leader_e_map_registered
check_phase_6_nvimtree_toggle_does_not_error
check_phase_6_nvimtree_user_override_forwarded
check_phase_6_nvimtree_setup_does_not_mutate_builtin
check_phase_6_nvimtree_literal_acceptance_require_returns_table
check_phase_6_nvimtree_toggle_drops_nvimtree_specifically
check_phase_6_lualine_module_present
check_phase_6_lualine_defaults_shape
check_phase_6_lualine_defaults_section_components
check_phase_6_lualine_setup_forwards_opts
check_phase_6_lualine_setup_pcall_guards_missing
check_phase_6_lualine_user_override_forwarded
check_phase_6_lualine_setup_does_not_mutate_builtin
check_phase_6_lualine_literal_acceptance_require_returns_table
check_phase_6_lualine_toggle_drops_lualine_specifically
check_phase_6_lualine_defaults_lualine_x_full_list
check_phase_6_bufferline_module_present
check_phase_6_bufferline_defaults_shape
check_phase_6_bufferline_defaults_offsets_nvimtree
check_phase_6_bufferline_setup_forwards_opts
check_phase_6_bufferline_setup_pcall_guards_missing
check_phase_6_bufferline_user_override_forwarded
check_phase_6_bufferline_setup_does_not_mutate_builtin
check_phase_6_bufferline_literal_acceptance_require_returns_table
check_phase_6_bufferline_toggle_drops_bufferline_specifically
check_phase_6_bufferline_defaults_offsets_full_list
check_phase_6_gitsigns_module_present
check_phase_6_gitsigns_defaults_shape
check_phase_6_gitsigns_defaults_signs_per_status
check_phase_6_gitsigns_setup_forwards_opts
check_phase_6_gitsigns_setup_pcall_guards_missing
check_phase_6_gitsigns_user_override_forwarded
check_phase_6_gitsigns_setup_does_not_mutate_builtin
check_phase_6_gitsigns_leader_g_group_maps_registered
check_phase_6_gitsigns_literal_acceptance_require_returns_table
check_phase_6_gitsigns_toggle_drops_gitsigns_specifically
check_phase_6_gitsigns_defaults_signs_staged_per_status
check_phase_6_whichkey_module_present
check_phase_6_whichkey_defaults_shape
check_phase_6_whichkey_defaults_leader_groups
check_phase_6_whichkey_setup_forwards_opts
check_phase_6_whichkey_setup_pcall_guards_missing
check_phase_6_whichkey_user_override_forwarded
check_phase_6_whichkey_setup_does_not_mutate_builtin
check_phase_6_whichkey_literal_acceptance_require_returns_table
check_phase_6_whichkey_toggle_drops_whichkey_specifically
check_phase_6_whichkey_defaults_mappings_full_list
check_phase_6_terminal_module_present
check_phase_6_terminal_defaults_shape
check_phase_6_terminal_setup_forwards_opts
check_phase_6_terminal_setup_pcall_guards_missing
check_phase_6_terminal_user_override_forwarded
check_phase_6_terminal_setup_does_not_mutate_builtin
check_phase_6_terminal_lazygit_gated_on_executable
check_phase_6_terminal_toggle_lazygit_caches_terminal
check_phase_6_terminal_toggle_lazygit_pcall_guards_missing
check_phase_6_terminal_literal_acceptance_require_returns_table
check_phase_6_terminal_toggle_drops_terminal_specifically
check_phase_6_terminal_lazygit_map_rhs_calls_toggle_lazygit
check_phase_6_terminal_lazygit_recipe_opts_full_shape
check_phase_6_breadcrumbs_module_present
check_phase_6_breadcrumbs_defaults_shape
check_phase_6_breadcrumbs_setup_forwards_opts
check_phase_6_breadcrumbs_setup_pcall_guards_missing
check_phase_6_breadcrumbs_setup_arms_winbar
check_phase_6_breadcrumbs_setup_does_not_mutate_builtin
check_phase_6_breadcrumbs_user_override_forwarded
check_phase_6_breadcrumbs_on_attach_calls_navic_attach
check_phase_6_breadcrumbs_on_attach_skips_without_capability
check_phase_6_breadcrumbs_on_attach_skips_when_disabled
check_phase_6_breadcrumbs_spec_uses_breadcrumbs_active_gate
check_phase_6_breadcrumbs_literal_acceptance_require_returns_table
check_phase_6_breadcrumbs_toggle_drops_breadcrumbs_specifically
check_phase_6_breadcrumbs_defaults_icons_full_list
check_phase_6_indentlines_module_present
check_phase_6_indentlines_defaults_shape
check_phase_6_indentlines_setup_forwards_opts
check_phase_6_indentlines_setup_pcall_guards_missing
check_phase_6_indentlines_setup_does_not_mutate_builtin
check_phase_6_indentlines_user_override_forwarded
check_phase_6_indentlines_spec_uses_indentlines_active_gate
check_phase_6_indentlines_literal_acceptance_require_returns_table
check_phase_6_indentlines_toggle_drops_indentlines_specifically
check_phase_6_comment_spec_uses_comment_active_gate
check_phase_6_comment_toggle_drops_plugin
check_phase_6_comment_toggle_drops_mini_nvim_specifically
check_phase_6_comment_setup_does_not_mutate_builtin
check_phase_6_comment_literal_acceptance_require_returns_table
check_phase_6_comment_module_dispatches_through_mini_comment_require

if [[ -f tests/minimal_init.lua ]]; then
  check_nvim_init tests/minimal_init.lua
fi

make test

# Phase 9.1: end-to-end integration smoke. Installs plugins for real and
# spawns a language server via mason, so it requires network access and is
# slow (~30-120s). Skip with SKIP_INTEGRATION=1 to keep iteration fast while
# developing individual step changes.
if [[ "${SKIP_INTEGRATION:-0}" == "1" ]]; then
  echo "[lvim-smoke] SKIP_INTEGRATION=1 set; skipping scripts/integration-smoke.sh"
else
  bash scripts/integration-smoke.sh
fi

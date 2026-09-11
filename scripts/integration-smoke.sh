#!/usr/bin/env bash
# Phase 9.1 — full integration smoke.
#
# Boots lvim in a single isolated headless session and exercises the major
# user paths end-to-end: LSP attach, telescope, nvim-tree, gitsigns, and the
# Phase 5.2 JSX commentstring hook. Plugins are installed for real via
# `:LvimSyncCorePlugins!` and lua-language-server is fetched via mason — so
# this script requires network access on first run and is slow (~30-120s).
# `scripts/lvim-smoke.sh` invokes this at the end and honors SKIP_INTEGRATION=1
# for the fast iteration path.
#
# Everything lives under a single mktemp'd dir (runtime, config, working tree).
# `g:lunavim_isolated_xdg = v:true` is set BEFORE `-u init.lua` so the bootstrap
# remaps XDG_*_HOME to LUNAVIM_RUNTIME_DIR and mason installs land inside the
# tempdir rather than the developer's real `~/.local/share/`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v tree-sitter >/dev/null 2>&1; then
  echo "[integration-smoke] missing required dependency: tree-sitter CLI" >&2
  exit 1
fi

# The resync probes below extract a pin from snapshots/default.json with
# python3 (same dependency snapshot-export.sh already assumes).
if ! command -v python3 >/dev/null 2>&1; then
  echo "[integration-smoke] missing required dependency: python3" >&2
  exit 1
fi

TMP="$(mktemp -d -t lvim-integration-XXXXXX)"
# Cleanup must never change the script's exit status.
#
# This run spawns real background processes -- mason installers, a language
# server, treesitter parser builds -- and some can still be writing under $TMP
# when the trap fires. `rm -rf` then fails with "Directory not empty", and
# because the trap runs under `set -e` that turned a PASSING integration run
# into a non-zero exit. It was timing-dependent: seen on Neovim 0.11, not 0.12,
# with no behavioral difference between them.
#
# So: give stragglers a moment, retry a few times, and if the directory still
# will not go, say so on stderr and leave it under /tmp rather than failing a
# run that already reported OK.
cleanup() {
  local status=$?

  if [[ -n "${TMP:-}" && -d "$TMP" ]]; then
    local _try
    for _try in 1 2 3; do
      if rm -rf "$TMP" 2>/dev/null; then
        break
      fi
      sleep 1
    done
    if [[ -d "$TMP" ]]; then
      printf '[integration-smoke] note: could not fully remove %s (a background process may still hold it)\n' \
        "$TMP" >&2
    fi
  fi

  return "$status"
}
trap cleanup EXIT

RUNTIME_DIR="$TMP/runtime"
CONFIG_DIR="$TMP/config"
WORK_DIR="$TMP/work"
mkdir -p "$RUNTIME_DIR" "$CONFIG_DIR" "$WORK_DIR"

# Set up the working tree. Local git config (not --global) so we don't touch
# the developer's ~/.gitconfig.
(
  cd "$WORK_DIR"
  git init -q
  git config user.email integration@test.local
  git config user.name "Integration Smoke"
  git config commit.gpgsign false
)

cat > "$WORK_DIR/.gitignore" <<'EOF'
node_modules/
dist/
EOF

cat > "$WORK_DIR/sample.lua" <<'EOF'
local M = {}

function M.greet(name)
  return "hello " .. name
end

return M
EOF

cat > "$WORK_DIR/sample.json" <<'EOF'
{
  "name": "integration-smoke",
  "version": "0.0.1"
}
EOF

cat > "$WORK_DIR/Component.tsx" <<'EOF'
import React from 'react';

export const Component = () => {
  return (
    <div>Hello</div>
  );
};
EOF

(
  cd "$WORK_DIR"
  git add -A
  git commit -q -m "initial"
)

# Add an unstaged change so gitsigns has hunks to render after attach.
printf '\n-- local change\n' >> "$WORK_DIR/sample.lua"

# User config: opt lua_ls in. mason-lspconfig's automatic_installation is a
# no-op under headless mode (kcl-confirmed against mason-lspconfig 2.x), so
# the integration driver explicitly installs lua-language-server via mason
# below and then re-runs `lvim.lsp.setup()` once the binary is on disk.
cat > "$CONFIG_DIR/config.lua" <<'EOF'
lvim.lsp.servers = { lua_ls = {} }
lvim.lsp.ensure_installed = { "lua_ls" }

-- Registering a linter here is load-bearing for step (g) below: config.lua runs
-- BEFORE lazy.nvim is bootstrapped, so this call can only record the
-- registration. Something after plugins.load() has to apply it.
require("lvim.lsp.null-ls.linters").setup({
  { name = "shellcheck", filetypes = { "sh" } },
})
EOF

export LUNAVIM_RUNTIME_DIR="$RUNTIME_DIR"
export LUNAVIM_CONFIG_DIR="$CONFIG_DIR"

# Drive the actual assertions from a Lua script. Using a file (rather than
# multiple `-c` flags) keeps the control flow linear and the failure messages
# specific. Any `error()` from inside the steps below propagates to the
# `die()` handler which calls `cquit 1`, so a failing step ends the process
# with a non-zero exit code.
INTEGRATION_LUA="$TMP/integration.lua"
cat > "$INTEGRATION_LUA" <<'LUA'
local WORK_DIR = vim.env.LVIM_INTEGRATION_WORK_DIR

local function die(msg)
  io.stderr:write("integration-smoke FAIL: " .. msg .. "\n")
  vim.cmd("cquit 1")
end

local function step(name, fn)
  io.stdout:write("[step] " .. name .. "\n")
  io.stdout:flush()
  local ok, err = pcall(fn)
  if not ok then
    die(name .. ": " .. tostring(err))
  end
end

step("(a) lvim.leader is set", function()
  if type(_G.lvim) ~= "table" then
    error("global lvim table missing")
  end
  if _G.lvim.leader == nil or _G.lvim.leader == "" then
    error("lvim.leader is nil/empty")
  end
end)

step("install core plugins via lazy.sync", function()
  -- Drive `lazy.sync` directly with `wait = true` so the call BLOCKS until
  -- every clone/install task completes. The user-facing `:LvimSyncCorePlugins!`
  -- command leaves the sync running in the background (`wait` defaults to
  -- false), which works fine for interactive use but loses the determinism
  -- we need for a single-process integration test: subsequent steps must
  -- be able to `require()` plugin modules immediately after this call
  -- returns.
  require("lazy").sync({ wait = true, show = false })

  -- lazy.nvim's module cache (`lazy.core.cache`) is populated at startup
  -- when none of the plugins are on disk yet. After `sync` clones them in
  -- the SAME process, the cache still holds "not found" entries for module
  -- names like `mason` / `mason-lspconfig` / `nvim-treesitter`, so
  -- subsequent `require()` calls hit the stale negative cache and fail
  -- even though the files are now on disk and on `runtimepath`. Resetting
  -- the cache forces the next lookup to walk the unloaded plugin dirs
  -- afresh. Reproduced in isolation: without this reset, `require("mason")`
  -- after sync errors with `module 'mason' not found` even though
  -- `vim.api.nvim_get_runtime_file("lua/mason/init.lua", false)` returns
  -- the path. This wouldn't happen in normal interactive use, where the
  -- user restarts nvim between install and use.
  require("lazy.core.cache").reset()
end)

step("install lua-language-server via mason", function()
  -- mason is lazy-loaded behind `cmd = "Mason"` in the spec. After the
  -- cache reset above, `require("mason")` triggers lazy's auto-load path:
  -- lazy's package.loader walks unloaded plugin dirs, finds mason, calls
  -- `M.load(mason)` (which adds mason.dir to rtp and packadds it), then
  -- returns the loaded module. So a single `require` is enough — no
  -- explicit `lazy.load({ plugins = { "mason" } })` needed.

  -- mason was not on disk when lvim.start()'s `lvim.lsp.setup()` first ran,
  -- so the pcall returned ok=false and mason.setup() never executed. Call it
  -- now so `<mason-install-root>/bin` joins PATH before we ask
  -- vim.lsp to spawn the server.
  require("mason").setup({})

  local registry = require("mason-registry")

  local refreshed = false
  registry.refresh(function() refreshed = true end)
  if not vim.wait(60000, function() return refreshed end, 200) then
    error("mason-registry refresh timed out (60s)")
  end

  local pkg = registry.get_package("lua-language-server")
  if pkg:is_installed() then return end

  local done, install_err = false, nil
  pkg:install({}, function(ok, err_or_receipt)
    done = true
    if not ok then install_err = err_or_receipt end
  end)
  if not vim.wait(180000, function() return done end, 500) then
    error("lua-language-server install timed out (180s)")
  end
  if install_err ~= nil then
    error("lua-language-server install failed: " .. tostring(install_err))
  end
end)

step("re-bootstrap LSP stack now that plugins+mason are on disk", function()
  -- lvim.lsp.setup() guards with `did_setup` so it runs exactly once per
  -- module load. Evict the cached module so the next require re-loads it
  -- fresh and re-runs mason/mason-lspconfig/lspconfig setup with the now-
  -- installed sources.
  package.loaded["lvim.lsp"] = nil
  require("lvim.lsp").setup()
end)

step("(b) open lua file, LSP client attaches within 5s", function()
  vim.cmd("edit " .. WORK_DIR .. "/sample.lua")
  if vim.bo.filetype ~= "lua" then
    error("sample.lua not detected as lua, got: " .. vim.bo.filetype)
  end
  -- vim.lsp.enable('lua_ls') wires a FileType autocmd; the server spawns
  -- async, so poll vim.lsp.get_clients. The 5s budget matches the step
  -- acceptance criteria literally — lua-language-server has already been
  -- installed via mason (so the binary is on PATH and warm in disk cache),
  -- and `lvim.lsp.setup()` has been re-bootstrapped, so spawn+attach is
  -- a normal (sub-second) lspconfig handshake.
  local attached = vim.wait(5000, function()
    return #vim.lsp.get_clients({ bufnr = 0 }) > 0
  end, 100)
  if not attached then
    error(string.format(
      "LSP did not attach within 5s (filetype=%s, mason-bin=%s)",
      vim.bo.filetype,
      vim.fn.exepath("lua-language-server")
    ))
  end
end)

local function buffer_filetypes()
  local seen = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local ft = vim.bo[b].filetype
    if ft ~= "" then seen[ft] = true end
  end
  return seen
end

step("(c) :Telescope find_files opens a picker buffer", function()
  vim.cmd("Telescope find_files")
  -- vim.wait returns true the moment the predicate succeeds, so we drive
  -- assertion off its return value rather than re-iterating buffers after
  -- timeout. The 2s budget is generous: telescope's picker buffer is created
  -- synchronously inside `find_files`; the wait just covers the FileType
  -- autocmd that stamps `TelescopePrompt`.
  local found = vim.wait(2000, function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].filetype == "TelescopePrompt" then return true end
    end
    return false
  end, 50)
  local seen = buffer_filetypes()
  io.stdout:write("[step] (c) buffer filetypes seen: " .. vim.inspect(seen) .. "\n")
  if not found then
    error("no TelescopePrompt buffer after :Telescope find_files (filetypes seen: " ..
      vim.inspect(seen) .. ")")
  end
  -- Close the picker so its floating window does not steal focus from the
  -- subsequent step. `telescope.actions.close` is the supported teardown path
  -- (vs. raw :close, which would error if the picker auto-closed itself).
  pcall(function() require("telescope.actions").close(vim.api.nvim_get_current_buf()) end)
end)

step("(d) :NvimTreeToggle opens an NvimTree buffer", function()
  vim.cmd("NvimTreeToggle")
  local found = vim.wait(2000, function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].filetype == "NvimTree" then return true end
    end
    return false
  end, 50)
  io.stdout:write("[step] (d) buffer filetypes seen: " .. vim.inspect(buffer_filetypes()) .. "\n")
  if not found then
    error("no NvimTree buffer after :NvimTreeToggle")
  end
  -- Close the tree window so step (e)'s `:edit sample.lua` lands in a normal
  -- editor window. If we left the cursor in the NvimTree window, `:edit`
  -- would either replace the tree buffer (losing the explorer state) or
  -- delegate to nvim-tree's `actions.open_file` window picker, which behaves
  -- inconsistently under headless. Closing makes the next-window state
  -- deterministic.
  vim.cmd("NvimTreeClose")
end)

step("(e) :Gitsigns toggle_signs does not error", function()
  -- gitsigns is event-lazy on BufReadPre and attaches per-buffer. Step (d)
  -- closed NvimTree so the current window is back to a normal editor window;
  -- re-edit sample.lua to make it the active buffer, then verify gitsigns
  -- actually attached before toggling. Without the attach check, a silent
  -- failure to attach (e.g. lazy-load misfire) would leave the toggle as a
  -- no-op and the test would still pass — defeating the point.
  --
  -- The wait is 15s, not 2s. gitsigns attaches asynchronously: it shells out to
  -- `git` to resolve the repo root and the file's index entry before it
  -- populates `b:gitsigns_status_dict`, and in this harness that runs against a
  -- freshly `git init`-ed tree on a machine that is simultaneously finishing a
  -- plugin install and a treesitter parser build. 2s was measured to be
  -- unreliable -- it failed on 3 of 3 runs at f5ccbfa on a developer machine,
  -- with no code change involved -- so it was testing machine load as much as
  -- the attach. A generous ceiling costs nothing on a fast run (the poll exits
  -- as soon as the value appears) and removes a flake that would otherwise
  -- train people to re-run CI until it passes.
  -- Wipe the buffer before re-editing so the file is genuinely READ again.
  --
  -- gitsigns' only lazy trigger is `event = "BufReadPre"`. Earlier steps
  -- already loaded sample.lua, and `:edit` on an loaded, unmodified buffer does
  -- not re-read it -- so BufReadPre never fires a second time. Whether gitsigns
  -- was live therefore depended on whether some earlier step happened to
  -- trigger its load first, which is why this step failed intermittently (3 of
  -- 3 runs at f5ccbfa, 1 of 4 after) with no code change involved. Wiping
  -- forces a real read, which fires BufReadPre, which loads gitsigns and lets
  -- it attach. That is also the honest thing to test: a user opening a file in
  -- a git repo.
  local prior = vim.fn.bufnr(WORK_DIR .. "/sample.lua")
  if prior ~= -1 then
    pcall(vim.cmd, "bwipeout! " .. prior)
  end
  vim.cmd("edit " .. WORK_DIR .. "/sample.lua")
  local bufnr = vim.api.nvim_get_current_buf()
  local ATTACH_TIMEOUT_MS = 15000
  local attached = vim.wait(ATTACH_TIMEOUT_MS, function()
    return vim.b[bufnr].gitsigns_status_dict ~= nil
  end, 50)
  if not attached then
    error(("gitsigns did not attach to sample.lua within %dms"):format(ATTACH_TIMEOUT_MS))
  end

  -- Drive the toggle and observe the side-effect: `:Gitsigns toggle_signs`
  -- inverts `require('gitsigns.config').config.signcolumn`. Watching the
  -- value flip before/after each invocation proves the command did real work
  -- — a silent no-op (e.g. if `:Gitsigns` resolved to a stub command) would
  -- leave the value unchanged and fail loudly here, instead of passing the
  -- weaker "didn't error" assertion that the spec literally asks for.
  local gs_config = require("gitsigns.config").config
  local before = gs_config.signcolumn
  vim.cmd("Gitsigns toggle_signs")
  if gs_config.signcolumn == before then
    error("Gitsigns toggle_signs did not flip config.signcolumn (still " ..
      tostring(before) .. ")")
  end
  vim.cmd("Gitsigns toggle_signs")
  if gs_config.signcolumn ~= before then
    error("Gitsigns toggle_signs (second invocation) did not restore config.signcolumn (got " ..
      tostring(gs_config.signcolumn) .. ", expected " .. tostring(before) .. ")")
  end
end)

step("(f) gcc on TSX uses {/* %s */} commentstring", function()
  vim.cmd("edit " .. WORK_DIR .. "/Component.tsx")
  if vim.bo.filetype ~= "typescriptreact" then
    error("Component.tsx not detected as typescriptreact, got: " .. vim.bo.filetype)
  end

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local target_line
  for i, l in ipairs(lines) do
    if l:match("<div>") then target_line = i; break end
  end
  if not target_line then
    error("could not find <div> in Component.tsx")
  end

  -- Position cursor inside the JSX element so the treesitter-aware pre-hook
  -- in lvim.plugins.modules.comment has a JSX-flavored ref_position to walk.
  vim.api.nvim_win_set_cursor(0, { target_line, 0 })

  -- Confirm mini.comment is loaded and its `gcc` keymap is in place — opening
  -- Component.tsx above fired BufReadPost which lazy-loads the `comment`
  -- plugin entry (mini.nvim → mini.comment.setup), but the assert here makes
  -- the failure mode "no gcc keymap" instead of "gcc produced no change".
  if not pcall(require, "mini.comment") then
    error("mini.comment not available after plugin install")
  end
  local gcc = vim.fn.maparg("gcc", "n")
  if gcc == "" then
    error("`gcc` normal-mode keymap not set up by mini.comment")
  end

  -- Fire the actual `gcc` keymap (not the underlying API). `:normal` (without
  -- bang) honors user-defined mappings, so this exercises the same code path
  -- a real keystroke would — including dispatch through the treesitter-aware
  -- pre-hook in `lvim.plugins.modules.comment`.
  vim.cmd("normal gcc")

  local after = vim.api.nvim_buf_get_lines(0, target_line - 1, target_line, false)[1]
  if not after or not after:match("{/%*.*%*/}") then
    error("expected JSX commentstring `{/* ... */}`, got: " .. tostring(after))
  end
end)

print("INTEGRATION_OK")
vim.cmd("qall!")
LUA

echo "[integration-smoke] runtime=$RUNTIME_DIR config=$CONFIG_DIR work=$WORK_DIR"

LOG="$TMP/log"
set +e
LVIM_INTEGRATION_WORK_DIR="$WORK_DIR" \
  nvim --headless \
    --cmd "let g:lunavim_isolated_xdg = v:true" \
    -u "$REPO_ROOT/init.lua" \
    -c "lua dofile('$INTEGRATION_LUA')" \
    > "$LOG" 2>&1
rc=$?
set -e

cat "$LOG"

if (( rc != 0 )); then
  echo "[integration-smoke] nvim exited with non-zero status: $rc" >&2
  exit "$rc"
fi

# The pattern tolerates a trailing CR: Neovim 0.11 terminates headless
# `print()` lines with CRLF (0.12 uses LF), so the driver's success token
# arrives as `INTEGRATION_OK\r` and a plain anchored match silently fails on the
# minimum supported version -- reporting "driver did not reach INTEGRATION_OK"
# for a run that had in fact completed every step.
#
# The CR is stripped into a variable first, rather than streamed as
# `tr -d '\r' | grep -q`. This script runs under `set -o pipefail`, and
# `grep -q` exits as soon as it matches; `tr` is then killed by SIGPIPE while
# still writing, and pipefail turns that into a failed condition -- so the
# streaming form would report failure precisely when the token WAS found early
# in a large log. A command substitution is not a pipeline, so it has neither
# problem, and it avoids embedding a literal CR in a regex (which the `grep`
# implementations in play do not agree on).
log_normalized="$(tr -d '\r' < "$LOG")"
# A second, cold startup against the now-populated runtime.
#
# This is the only place the startup ORDERING of the linter registration can be
# observed. config.lua runs before lazy.nvim is bootstrapped, so the shim there
# can only RECORD the registration; `lvim.start()` has to re-enter the backend
# after `plugins.load()` for it to take effect. The driver above cannot test
# this, because it installs the plugins mid-session -- at ITS startup nothing
# was on disk yet. Only a fresh launch, with plugins already present, exercises
# the real user's first-run-after-install path.
#
# `package.loaded["lint"]` is read WITHOUT requiring anything: a `require("lint")`
# here would itself make lazy load nvim-lint and run its config callback, which
# is the very thing under test -- a self-fulfilling assertion that passes with
# the bug present. (Verified: it did.)
echo "[integration-smoke] second startup: linter registration reaches nvim-lint"
LINT_LOG="$TMP/lint-log"
set +e
nvim --headless \
  --cmd "let g:lunavim_isolated_xdg = v:true" \
  -u "$REPO_ROOT/init.lua" \
  -c 'lua local l = package.loaded["lint"]; print("LINT_LOADED=" .. tostring(l ~= nil)); print("LINT_SH=" .. vim.inspect(l and l.linters_by_ft and l.linters_by_ft.sh or nil))' \
  -c 'qall!' > "$LINT_LOG" 2>&1
lint_rc=$?
set -e
lint_out="$(tr -d '\r' < "$LINT_LOG")"

if (( lint_rc != 0 )); then
  printf '[integration-smoke] second startup exited %d:\n%s\n' "$lint_rc" "$lint_out" >&2
  exit 1
fi
if ! grep -q '^LINT_LOADED=true$' <<<"$lint_out"; then
  printf '[integration-smoke] a linter registered in config.lua never reached nvim-lint.\n' >&2
  printf 'config.lua runs before lazy.nvim exists, so lvim.start() must re-enter the\n' >&2
  printf 'backend after plugins.load(). Output:\n%s\n' "$lint_out" >&2
  exit 1
fi
if ! grep -q 'shellcheck' <<<"$lint_out"; then
  printf '[integration-smoke] nvim-lint loaded but linters_by_ft.sh is wrong:\n%s\n' "$lint_out" >&2
  exit 1
fi

# :LvimSyncCorePlugins must INSTALL entries missing from disk, not just
# re-pin the installed set. lazy.restore()'s runner filters to
# already-installed plugins (`plugin.url and plugin._.installed` in
# lazy/manage/init.lua), so until the command chained
# lazy.install({ lockfile = true }) ahead of restore, a runtime missing a
# core plugin stayed missing forever: the command wrote the lockfile and
# checked out pins for whatever was already on disk, and the startup
# advisory kept telling the user to run the very command that could not
# fix the state it was reporting. A stubbed-lazy smoke check pins the
# dispatch; this probe pins the real behavior end-to-end.
#
# Probe both confirm branches, each from a FRESH session so lazy computes
# `_.installed` from disk and sees the deletion:
#   1. accept (`!` bang): the snapshot lockfile is written, and the missing
#      plugin must come back AT the snapshot's pinned commit.
#   2. decline (unbanged; a headless confirm answers the default "No"): the
#      user's lockfile is kept as-is, and the missing plugin must still come
#      back — at its pin in that lockfile.
echo "[integration-smoke] resync: missing core plugin is reinstalled at its pin"
ILLUMINATE_DIR="$RUNTIME_DIR/lazy/illuminate"
RESYNC_PIN="$(python3 - "$REPO_ROOT/snapshots/default.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["illuminate"]["commit"])
PY
)"
resync_probe() {
  local label="$1" cmd="$2" log="$3" normalized rc
  rm -rf "$ILLUMINATE_DIR"
  set +e
  LVIM_RESYNC_DIR="$ILLUMINATE_DIR" LVIM_RESYNC_PIN="$RESYNC_PIN" \
    nvim --headless \
      --cmd "let g:lunavim_isolated_xdg = v:true" \
      -u "$REPO_ROOT/init.lua" \
      -c "$cmd" \
      -c 'lua local d = vim.env.LVIM_RESYNC_DIR; local pin = vim.env.LVIM_RESYNC_PIN; local ok = vim.wait(120000, function() if vim.fn.isdirectory(d) ~= 1 then return false end; local out = vim.fn.system({ "git", "-C", d, "rev-parse", "HEAD" }); return vim.v.shell_error == 0 and vim.trim(out) == pin end, 250); if ok then print("RESYNC_OK") else print("RESYNC_FAIL") end' \
      -c 'qall!' > "$log" 2>&1
  rc=$?
  set -e
  normalized="$(tr -d '\r' < "$log")"
  if (( rc != 0 )) || ! grep -q '^RESYNC_OK$' <<<"$normalized"; then
    printf '[integration-smoke] %s probe failed (rc=%d):\n%s\n' "$label" "$rc" "$normalized" >&2
    exit 1
  fi
}
resync_probe "accept" 'LvimSyncCorePlugins!' "$TMP/resync-accept-log"
resync_probe "decline" 'LvimSyncCorePlugins' "$TMP/resync-decline-log"

if ! grep -q "^INTEGRATION_OK$" <<<"$log_normalized"; then
  echo "[integration-smoke] driver did not reach INTEGRATION_OK" >&2
  exit 1
fi

if grep -Eq 'Plugin .+ is not installed|Error during "tree-sitter build"' "$LOG"; then
  echo "[integration-smoke] runtime log contains bootstrap or treesitter build errors" >&2
  exit 1
fi

echo "[integration-smoke] OK"

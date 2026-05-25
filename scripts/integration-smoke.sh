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

TMP="$(mktemp -d -t lvim-integration-XXXXXX)"
cleanup() {
  if [[ -n "${TMP:-}" && -d "$TMP" ]]; then
    rm -rf "$TMP"
  fi
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
  vim.cmd("edit " .. WORK_DIR .. "/sample.lua")
  local bufnr = vim.api.nvim_get_current_buf()
  local attached = vim.wait(2000, function()
    return vim.b[bufnr].gitsigns_status_dict ~= nil
  end, 50)
  if not attached then
    error("gitsigns did not attach to sample.lua within 2s")
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

if ! grep -q "^INTEGRATION_OK$" "$LOG"; then
  echo "[integration-smoke] driver did not reach INTEGRATION_OK" >&2
  exit 1
fi

if grep -Eq 'Plugin .+ is not installed|Error during "tree-sitter build"' "$LOG"; then
  echo "[integration-smoke] runtime log contains bootstrap or treesitter build errors" >&2
  exit 1
fi

echo "[integration-smoke] OK"

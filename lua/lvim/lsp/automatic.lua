-- Automatic per-filetype language-server activation, with opt-in install.
--
-- The gap this closes: LunaVim ships `lvim.lsp.ensure_installed = {}` and
-- `lvim.lsp.servers = {}`, so out of the box no language gets a server. The
-- upstream LunarVim reference did not ship a server list either -- it generated
-- an ftplugin file per server (`lvim/lsp/templates.lua`) that called
-- `lvim.lsp.manager.setup(<server>)` when you opened a matching filetype, with
-- an 83-entry `skipped_servers` DENY-list to suppress the noise.
--
-- This does the same job from the other side, because the deny-list is the
-- wrong shape. mason's generated filetype map answers "python" with 16 packages
-- and "typescript" with 21 -- spell checkers (`harper_ls`, `codebook`),
-- formatters wearing an LSP hat (`dprint`), security scanners (`snyk_ls`), grep
-- tools (`ast_grep`). A deny-list has to name every one of those, forever, and
-- DEFAULTS TO YES for anything added upstream later: it fails open and it rots.
-- A short per-filetype preference list is a closed set. A server we have never
-- heard of is simply not picked until someone opts in.
--
-- `skipped_servers` / `skipped_filetypes` are still honoured -- they filter the
-- candidate list -- so a LunarVim config that sets them keeps working, and
-- "never offer me harper_ls" stays expressible.
--
-- Installing is always CONSENTED, never silent. Opening a file in a repository
-- you just cloned must not trigger a network fetch and a binary install; that
-- turns "read someone's code" into "run their toolchain choice". The answer --
-- including "no" -- is remembered under `<cache>/lsp-automatic/`, so the prompt
-- is once per machine per filetype rather than once per session, which is what
-- makes it feel automatic from day two.

local M = {}

local STATE_DIR = "lsp-automatic"

local function cache_dir()
  local ok, dir = pcall(function()
    return (type(_G.get_cache_dir) == "function") and _G.get_cache_dir() or vim.fn.stdpath("cache")
  end)
  if not ok or type(dir) ~= "string" or dir == "" then
    return vim.fn.stdpath("cache")
  end
  return dir
end

-- Decisions are ONE FILE PER FILETYPE, not one JSON document.
--
-- The obvious design -- a single `lsp-automatic.json` -- has a lost-update race
-- that neither an atomic rename nor a re-read-before-write closes: two Neovim
-- instances both read `{}`, one writes `{python = false}`, the other writes
-- `{rust = false}`, and whichever renames second erases the other's answer.
-- Getting that right needs a lock, with the stale-lock handling that implies.
--
-- A file per filetype removes the class of bug instead of guarding it. Two
-- instances answering about different filetypes touch different paths and
-- cannot interfere; two answering about the SAME filetype is one user
-- answering one question twice, where last-write-wins is the correct outcome.
-- Reading is likewise independent, so a torn or missing file costs one
-- filetype's memory rather than all of them.
function M.state_dir()
  return cache_dir() .. "/" .. STATE_DIR
end

-- Filetypes are Neovim identifiers, but nothing guarantees they are safe as
-- filenames. Percent-encode anything outside a conservative set.
local function state_path(ft)
  -- Uppercase is encoded too: on a case-insensitive filesystem `Python` and
  -- `python` would otherwise share one file and overwrite each other.
  local safe = ft:gsub("[^%l%d._-]", function(c)
    return ("%%%02X"):format(c:byte())
  end)
  -- `.` and `..` survive that unchanged and would resolve to the store itself
  -- and its parent. Encoding a leading dot makes them ordinary names.
  safe = safe:gsub("^%.", "%%2E")
  return M.state_dir() .. "/" .. safe
end

local function read_decision(ft)
  local ok, fh = pcall(io.open, state_path(ft), "r")
  if not ok or not fh then
    return nil
  end
  local read_ok, contents = pcall(fh.read, fh, "*a")
  pcall(fh.close, fh)
  if not read_ok or type(contents) ~= "string" or contents == "" then
    return nil
  end
  local decoded_ok, decoded = pcall(vim.json.decode, contents)
  if not decoded_ok then
    return nil
  end
  if decoded == false or type(decoded) == "string" then
    return decoded
  end
  return nil
end

---Write one filetype's decision, or remove it when `decision` is nil.
---
---Every step's result is checked rather than merely pcall'd: `io.open`,
---`write` and `os.rename` all report failure by RETURNING nil plus a message,
---which a bare `pcall` reads as success -- so a full disk would leave the temp
---file behind and the caller believing the answer was saved.
local function write_decision(ft, decision)
  local dir = M.state_dir()
  pcall(vim.fn.mkdir, dir, "p")

  local target = state_path(ft)
  if decision == nil then
    if vim.fn.filereadable(target) == 0 then
      return true
    end
    local removed_ok, removed = pcall(os.remove, target)
    return (removed_ok and removed ~= nil) or vim.fn.filereadable(target) == 0
  end

  local encoded_ok, encoded = pcall(vim.json.encode, decision)
  if not encoded_ok or type(encoded) ~= "string" then
    return false
  end

  -- Temp files live in their own subdirectory, NOT beside the decisions.
  -- `<ft>.tmp.<pid>` next to them would itself be a legal encoded filetype
  -- name -- writing python's decision would open, truncate and then rename
  -- away the decision file belonging to the filetype `python.tmp.1234`.
  -- A leading dot is always encoded for a filetype, so `.tmp` cannot collide.
  --
  -- Still inside the state dir, so the rename below cannot cross a filesystem
  -- boundary.
  local tmp_dir = dir .. "/.tmp"
  pcall(vim.fn.mkdir, tmp_dir, "p")
  local tmp = tmp_dir .. "/" .. tostring((vim.uv or vim.loop).getpid())
  local opened, fh = pcall(io.open, tmp, "w")
  if not opened or not fh then
    return false
  end

  -- Unlike the open and rename below, this branch has no test: forcing a
  -- write to a successfully-opened file to fail needs a full disk or a
  -- revoked handle, neither of which a unit test can arrange. It is here
  -- because the failure mode it guards -- a partial file renamed over a good
  -- one -- is worse than the code costs.
  local wrote_ok, wrote = pcall(fh.write, fh, encoded)
  local closed_ok, closed = pcall(fh.close, fh)
  if not wrote_ok or not wrote or not closed_ok or not closed then
    pcall(os.remove, tmp)
    return false
  end

  -- `vim.uv.fs_rename` rather than `os.rename`: on Windows the latter does not
  -- reliably replace an existing file, so a second answer for the same
  -- filetype would silently fail to apply. libuv replaces on every platform.
  local uv = vim.uv or vim.loop
  local renamed_ok, renamed = pcall(uv.fs_rename, tmp, target)
  if not renamed_ok or not renamed then
    pcall(os.remove, tmp)
    return false
  end
  return true
end

---The remembered answer for `ft`: a server name, `false` for "never ask", or
---nil when unanswered.
---
---Read from disk every time rather than cached in memory. These are rare, tiny
---reads, and a cache would go stale the moment another instance answered.
function M.decision(ft)
  if type(ft) ~= "string" or ft == "" then
    return nil
  end
  return read_decision(ft)
end

---Forget the remembered decision for `ft`, or all of them when `ft` is nil.
---Returns true when the store no longer holds the decision(s) asked about, so
---`:LvimLspForget` reports what happened rather than assuming it worked.
function M.forget(ft)
  if ft then
    return write_decision(ft, nil)
  end
  local dir = M.state_dir()
  if vim.fn.isdirectory(dir) == 0 then
    return true
  end
  local ok, deleted = pcall(vim.fn.delete, dir, "rf")
  -- Someone else removing it first satisfies the postcondition just as well.
  return (ok and deleted == 0) or vim.fn.isdirectory(dir) == 0
end

local function remember(ft, decision)
  write_decision(ft, decision)
end

-- Filetypes with a prompt open or an install running, so a re-entrant FileType
-- (we fire one ourselves after a successful install) does not queue a second
-- prompt.
--
-- A claim is `{ token, at }`, not a boolean, for two reasons.
--
-- IT EXPIRES, because the thing being waited on can fail to come back at all: a
-- picker that closes without invoking its callback (asynchronous pickers return
-- immediately, so that is indistinguishable at the call site from one that will
-- answer later), or an installer whose job stalls. A boolean would strand that
-- filetype for the rest of the session with no way to retry.
--
-- IT CARRIES A TOKEN, because expiry alone introduces overlap: once a second
-- prompt can open while the first is still up, a late answer from the first
-- would otherwise release the second's claim, or overwrite its decision. A
-- callback releases only the claim it took.
--
-- The clock is monotonic. `os.time()` is wall time, so an NTP correction could
-- stretch a claim by hours or expire one instantly.
local in_flight = {}
local next_token = 0

local DEFAULT_RETRY_AFTER = 300

-- A download is not an abandoned prompt. Expiring mid-install would let a
-- second prompt open and install a DIFFERENT package for the same filetype,
-- so the claim is re-stamped with a much longer window once an install starts;
-- a genuinely stuck install still recovers, just not in five minutes.
local DEFAULT_INSTALL_TIMEOUT = 1800

local function now_seconds()
  local uv = vim.uv or vim.loop
  return uv.hrtime() / 1e9
end

local function retry_after()
  local auto = (_G.lvim and _G.lvim.lsp and _G.lvim.lsp.automatic) or {}
  local configured = auto.retry_after_seconds
  if type(configured) == "number" and configured >= 0 then
    return configured
  end
  return DEFAULT_RETRY_AFTER
end

---Is a live claim held for `ft`? Does not take or renew one.
local function claimed(ft)
  local held = in_flight[ft]
  if not held then
    return false
  end
  return (now_seconds() - held.at) < (held.ttl or retry_after())
end

---Take the claim for `ft`, returning a token, or nil if one is already live.
local function claim(ft)
  if claimed(ft) then
    return nil
  end
  next_token = next_token + 1
  in_flight[ft] = { token = next_token, at = now_seconds(), ttl = retry_after() }
  return next_token
end

---Extend the live claim, for work that legitimately takes longer than a prompt.
local function extend(ft, token, seconds)
  local held = in_flight[ft]
  if held and held.token == token then
    held.at = now_seconds()
    held.ttl = seconds
  end
end

---Is `token` still the live claim for `ft`?
---
---Checked before ACTING, not only before releasing. Once a claim can expire, an
---abandoned prompt can answer after a newer one has opened: without this, the
---stale answer would overwrite the newer decision, and two different candidates
---could both start installing for one filetype.
local function holds(ft, token)
  local held = in_flight[ft]
  return held ~= nil and held.token == token
end

---Release the claim for `ft`, but only if it is still the one `token` took.
local function release(ft, token)
  if holds(ft, token) then
    in_flight[ft] = nil
  end
end

local function config()
  local lsp = (_G.lvim and _G.lvim.lsp) or {}
  return lsp.automatic or {}, lsp.automatic_configuration or {}
end

---Is a builtin switched on? Absent or non-table means "yes", matching the
---defensive reading `lvim/plugins/spec.lua` uses for its gates.
local function builtin_active(name)
  local builtin = (_G.lvim and _G.lvim.builtin) or {}
  local toggle = builtin[name]
  return not (type(toggle) == "table" and toggle.active == false)
end

---Is nvim-lspconfig loaded, so its `lsp/` blueprints are on the runtimepath?
---
---`lvim.lsp.setup()` already requires it during startup for exactly this side
---effect, so in a healthy session this is a cache hit.
local function lspconfig_available()
  if not builtin_active("lspconfig") then
    return false
  end
  if package.loaded["lspconfig"] then
    return true
  end
  return (pcall(require, "lspconfig"))
end

---mason-lspconfig, or nil when it cannot be loaded.
---
---`lvim.builtin.mason.active` is not enough on its own. On a fresh install --
---or under the smoke harness, which boots with `install.missing = false` --
---the toggle is true while the plugin sources are simply not on disk. Offering
---to install then leads to a dead end: the user says yes and the only thing
---that happens is "no mason package for basedpyright", because the name
---mapping we need lives in the plugin we could not load.
local function mason_lspconfig()
  if not builtin_active("mason") then
    return nil
  end
  local ok, mlc = pcall(require, "mason-lspconfig")
  if not ok or type(mlc) ~= "table" then
    return nil
  end
  return mlc
end

local function contains(list, value)
  return type(list) == "table" and vim.tbl_contains(list, value)
end

---Ordered candidate servers for `ft`, best first.
---
---`preferred` is read at call time rather than captured at setup, so a user's
---`config.lua` assignment (and a later `:LvimReload`) is always what is used.
---Both override shapes work: replacing one filetype
---(`lvim.lsp.automatic.preferred.python = { "pyright" }`) and replacing the
---whole table.
function M.candidates(ft)
  local auto, compat = config()

  if contains(compat.skipped_filetypes, ft) then
    return {}
  end

  local preferred = (type(auto.preferred) == "table" and auto.preferred[ft]) or nil
  local list

  if type(preferred) == "table" then
    list = vim.deepcopy(preferred)
  elseif auto.unknown_filetypes == "ignore" then
    -- No opinion recorded for this filetype and the user asked us not to go
    -- looking. Nothing to offer.
    return {}
  else
    local mlc = mason_lspconfig()
    if not mlc or type(mlc.get_available_servers) ~= "function" then
      return {}
    end
    local got_ok, available = pcall(mlc.get_available_servers, { filetype = ft })
    if not got_ok or type(available) ~= "table" then
      return {}
    end
    list = available
  end

  return vim.tbl_filter(function(name)
    return not contains(compat.skipped_servers, name)
  end, list)
end

---The resolved lspconfig blueprint for `server`, or nil.
local function blueprint(server)
  local ok, resolved = pcall(function()
    return vim.lsp.config[server]
  end)
  if ok and type(resolved) == "table" then
    return resolved
  end
  return nil
end

---Does `server` serve `ft` according to its own blueprint?
---
---The blueprint is the authority whenever it resolves: mason's generated
---filetype map can be stale, and a preference can simply be wrong --
---`preferred.python = { "gopls" }` must not install gopls for Python. A
---blueprint with no `filetypes` applies to every filetype, which is how Neovim
---reads it, and how attached clients are treated here too.
local function blueprint_serves(server, ft)
  local resolved = blueprint(server)
  if not resolved then
    return nil -- no opinion; the caller decides what that means
  end
  if resolved.filetypes == nil then
    return true
  end
  return type(resolved.filetypes) == "table" and vim.tbl_contains(resolved.filetypes, ft)
end

---Servers that already cover `ft`, from any source.
---
---Deliberately NOT limited to `preferred[ft]`. A user who already runs
---`lvim.lsp.servers = { pyright = {} }`, or lists pyright in
---`lvim.lsp.ensure_installed`, has a Python server; telling them "no language
---server for python" and offering basedpyright is wrong, and is the most
---likely way an existing user meets this feature. So the question asked here is
---"does anything serve this filetype", answered against everything that could:
---mason's installed set, the user's explicit `servers` table, and their
---`ensure_installed` list. Membership in the filetype is decided by mason's own
---filetype map rather than a list of our own.
function M.installed_for(ft, bufnr)
  local mlc = mason_lspconfig()
  if not mlc or type(mlc.get_available_servers) ~= "function" then
    return {}
  end

  -- Every server mason knows of that serves this filetype.
  local serves_ft = {}
  local available_ok, available = pcall(mlc.get_available_servers, { filetype = ft })
  if available_ok and type(available) == "table" then
    for _, name in ipairs(available) do
      serves_ft[name] = true
    end
  end
  -- A preferred server is by definition for this filetype, even if mason's map
  -- disagrees or the name is not a mason package at all.
  for _, name in ipairs(M.candidates(ft)) do
    serves_ft[name] = true
  end

  -- A client someone else already started for this filetype -- a native
  -- `vim.lsp.enable`, another plugin, a user autocmd -- is coverage whatever
  -- its origin, and mason has never heard of it.
  local attached = {}
  -- Buffer-scoped when we know the buffer. A global lookup would let a gopls
  -- attached to one project suppress the offer for a Go file in another, where
  -- that client cannot attach because the roots differ.
  local clients_ok, clients = pcall(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      return vim.lsp.get_clients({ bufnr = bufnr })
    end
    return vim.lsp.get_clients()
  end)
  if clients_ok and type(clients) == "table" then
    for _, client in ipairs(clients) do
      local filetypes = vim.tbl_get(client, "config", "filetypes")
      -- A client with no `filetypes` applies to every filetype, per Neovim's
      -- own semantics -- so it covers this one.
      if filetypes == nil or (type(filetypes) == "table" and vim.tbl_contains(filetypes, ft)) then
        attached[#attached + 1] = client.name
      end
    end
  end
  if #attached > 0 then
    return attached
  end

  local lsp_cfg = (_G.lvim and _G.lvim.lsp) or {}
  local covering, seen = {}, {}

  -- A name only counts once it can actually run. `lvim.lsp.servers.pyright = {}`
  -- is a statement of intent: if pyright is neither mason-installed nor on
  -- PATH, there is no Python client, and treating the declaration as coverage
  -- would suppress the offer forever for a user who has no server at all.
  -- Installed is not the same as usable, and neither half alone is enough.
  -- A blueprint that does not resolve means `vim.lsp.enable` starts no client.
  -- A `cmd[1]` that is not executable means Neovim refuses to start one -- and
  -- mason can report a package installed while its bin is not on Neovim's PATH,
  -- or a package install can simply be damaged. Either way, counting it as
  -- coverage suppresses every future offer forever.
  local function usable(name, mason_installed)
    local ok, resolved = pcall(function()
      return vim.lsp.config[name]
    end)
    if not ok or type(resolved) ~= "table" then
      -- Nothing to enable, whatever mason believes.
      return false
    end

    local cmd = resolved.cmd
    if type(cmd) == "table" and type(cmd[1]) == "string" then
      return vim.fn.executable(cmd[1]) == 1
    end
    if mason_installed then
      -- mason owns the binary and a blueprint resolves; a `cmd` built at
      -- attach time is as far as we can check.
      return true
    end
    -- A `cmd` we cannot inspect on a server the user merely DECLARED tells us
    -- nothing. Treat unknown as not covered: that errs towards offering a
    -- server they may already have, costing one "never ask again". The
    -- opposite error leaves someone with no language server and no prompt to
    -- tell them, which is the failure this feature exists to prevent.
    return false
  end

  -- Does `name` serve this filetype? Its own resolved blueprint is the
  -- authority whenever it has one: mason's generated map can be stale, and
  -- `preferred.python = { "gopls" }` is simply wrong. Only when nothing
  -- resolves do we fall back to the map and the preference list.
  local function serves(name)
    local declared = blueprint_serves(name, ft)
    if declared ~= nil then
      return declared
    end
    return serves_ft[name] == true
  end

  local function consider(name, mason_installed)
    if type(name) == "string" and serves(name) and not seen[name] and usable(name, mason_installed) then
      seen[name] = true
      covering[#covering + 1] = name
    end
  end

  if type(mlc.get_installed_servers) == "function" then
    local installed_ok, installed = pcall(mlc.get_installed_servers)
    if installed_ok and type(installed) == "table" then
      for _, name in ipairs(installed) do
        consider(name, true)
      end
    end
  end
  for name in pairs(type(lsp_cfg.servers) == "table" and lsp_cfg.servers or {}) do
    consider(name, false)
  end
  for _, name in ipairs(type(lsp_cfg.ensure_installed) == "table" and lsp_cfg.ensure_installed or {}) do
    consider(name, false)
  end

  return covering
end

---The mason package name backing an lspconfig server name.
local function package_for(server)
  local mlc = mason_lspconfig()
  if not mlc or type(mlc.get_mappings) ~= "function" then
    return nil
  end
  local mapped_ok, mappings = pcall(mlc.get_mappings)
  if not mapped_ok or type(mappings) ~= "table" then
    return nil
  end
  return vim.tbl_get(mappings, "lspconfig_to_package", server)
end

---Enable `server` and re-fire FileType so buffers already open pick it up.
---
---`vim.lsp.enable` registers the config; Neovim starts the client on the next
---matching FileType, which for the buffer that triggered all this has already
---passed. `in_flight` is still set while this runs, so the re-fire cannot
---re-enter the prompt.
local function enable_and_attach(server, ft)
  local ok = pcall(vim.lsp.enable, server)
  if not ok then
    return false
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == ft then
      pcall(vim.api.nvim_exec_autocmds, "FileType", { buffer = bufnr, modeline = false })
    end
  end
  return true
end

local function install(server, ft, token)
  local pkg_name = package_for(server)
  if not pkg_name then
    vim.notify(("lvim: no mason package for %s"):format(server), vim.log.levels.WARN)
    release(ft, token)
    return
  end

  local ok, registry = pcall(require, "mason-registry")
  if not ok then
    release(ft, token)
    return
  end
  local pkg_ok, pkg = pcall(registry.get_package, pkg_name)
  if not pkg_ok or not pkg then
    release(ft, token)
    return
  end

  -- mason asserts when asked to install a package whose install is already
  -- running (`:MasonInstall`, or a second offer for a shared package). That
  -- assertion would propagate out of the `vim.ui.select` callback and leave
  -- `in_flight[ft]` set forever, so the filetype could never be offered again
  -- this session. Check first, and pcall regardless.
  if type(pkg.is_installing) == "function" then
    local checked, installing = pcall(pkg.is_installing, pkg)
    if checked and installing then
      vim.notify(("lvim: %s is already installing"):format(pkg_name), vim.log.levels.INFO)
      release(ft, token)
      return
    end
  end

  local auto = config()
  local configured_timeout = auto.install_timeout_seconds
  -- Strictly positive: zero expires the claim the instant it is stamped, so
  -- reopening the file could start a SECOND install of a different candidate
  -- while the first is still running -- the race this window exists to prevent.
  local install_timeout = (type(configured_timeout) == "number" and configured_timeout > 0) and configured_timeout
    or DEFAULT_INSTALL_TIMEOUT
  extend(ft, token, install_timeout)

  vim.notify(("lvim: installing %s for %s..."):format(pkg_name, ft), vim.log.levels.INFO)

  -- Async: `FileType` must not block on a download. The callback runs off the
  -- installer's thread, so hop back to the main loop before touching Neovim.
  --
  -- `in_flight[ft]` is held until AFTER `enable_and_attach` has re-fired
  -- FileType for the matching buffers -- that re-fire lands back in
  -- `handle_filetype`, and clearing the flag first would let it open a second
  -- prompt whenever the freshly installed server is not yet visible to
  -- `get_installed_servers()`.
  local started = pcall(pkg.install, pkg, {}, function(success)
    vim.schedule(function()
      if not holds(ft, token) then
        return
      end
      if not success then
        release(ft, token)
        vim.notify(("lvim: failed to install %s"):format(pkg_name), vim.log.levels.ERROR)
        return
      end
      -- Not merely "a blueprint exists": it must still serve THIS filetype.
      -- A slow install spans a config reload, and a blueprint that has since
      -- moved to another filetype would be persisted and reported enabled
      -- while the re-fired event cannot attach it.
      if blueprint_serves(server, ft) ~= true then
        -- Deliberately NOT remembered: leaving the answer unrecorded is what
        -- lets the user be asked again once lspconfig catches up, instead of
        -- being stuck with an installed package and no client forever.
        release(ft, token)
        vim.notify(
          ("lvim: installed %s, but no lspconfig blueprint now serves %s; not enabling"):format(server, ft),
          vim.log.levels.WARN
        )
        return
      end
      remember(ft, server)
      local attached = enable_and_attach(server, ft)
      release(ft, token)
      if attached then
        vim.notify(("lvim: %s enabled for %s"):format(server, ft), vim.log.levels.INFO)
      end
    end)
  end)

  if not started then
    -- The installer raised before it could ever call back.
    release(ft, token)
    vim.notify(("lvim: could not start installing %s"):format(pkg_name), vim.log.levels.ERROR)
  end
end

local function prompt(ft, candidates, token)
  local items = vim.deepcopy(candidates)
  local NEVER = "Never ask again for " .. ft

  items[#items + 1] = NEVER

  -- pcall because a picker that raises would otherwise strand `in_flight[ft]`.
  -- A picker that simply RETURNS without answering cannot be detected here --
  -- that is what every asynchronous picker does -- so the stale-entry expiry
  -- in `claim` covers it instead.
  local asked = pcall(vim.ui.select, items, {
    prompt = ("No language server for %s. Install one?"):format(ft),
    format_item = function(item)
      return item == NEVER and item or ("Install " .. item)
    end,
  }, function(choice)
    -- A newer prompt has taken over since this one opened; its answer wins.
    if not holds(ft, token) then
      return
    end
    if not choice then
      -- Dismissed rather than answered: leave the decision unrecorded so the
      -- next buffer of this filetype asks again. Only an explicit "never"
      -- is persisted as a refusal.
      release(ft, token)
      return
    end
    if choice == NEVER then
      remember(ft, false)
      release(ft, token)
      return
    end
    install(choice, ft, token)
  end)

  if not asked then
    release(ft, token)
  end
end

---What, if anything, should be offered for `ft`? Returns the ordered candidate
---list, empty when there is nothing to do.
---
---Kept separate from `handle_filetype` so the whole decision -- toggles, skip
---lists, remembered answers, already-installed servers -- is reachable without a
---UI. `handle_filetype` is then just this plus a prompt.
function M.plan(ft, bufnr)
  if type(ft) ~= "string" or ft == "" then
    return {}
  end

  local auto = config()
  if auto.enabled == false then
    return {}
  end

  -- Nothing to offer without a mason we can actually load (see
  -- `mason_lspconfig`), or without lspconfig ACTUALLY LOADED. The toggle alone
  -- is not enough: nvim-lspconfig 2.x is a data-only plugin whose `lsp/<name>.lua`
  -- blueprints join the runtimepath when it loads, and `vim.lsp.enable` has
  -- nothing to enable without them. A partial install -- or starting with
  -- `lspconfig.active = false` and turning it on via `:LvimReload` -- leaves
  -- mason usable while lspconfig is absent, and we would install a package,
  -- persist the user's yes, and produce no client.
  if not mason_lspconfig() or not lspconfig_available() then
    return {}
  end

  if M.decision(ft) == false then
    return {}
  end

  -- Anything already installed for this filetype is mason-lspconfig's job to
  -- enable (`automatic_enable` defaults true) -- nothing to offer.
  if #M.installed_for(ft, bufnr) > 0 then
    return {}
  end

  -- Offer only what could actually work. A candidate whose blueprint does not
  -- resolve installs a package that `vim.lsp.enable` can do nothing with, and
  -- one whose blueprint serves a different filetype is simply the wrong server
  -- -- mason's map can be stale, and a preference can be wrong. Both would
  -- otherwise reach the prompt and then be rejected AFTER installing.
  return vim.tbl_filter(function(name)
    return blueprint_serves(name, ft) == true
  end, M.candidates(ft))
end

---Decide what to do for one filetype, prompting if there is something to offer.
---Safe to call repeatedly.
function M.handle_filetype(ft, bufnr)
  -- Checked, not taken. Taking the claim here and testing it again before
  -- prompting is the bug this shape avoids: the first call renews an expired
  -- claim, the second then sees a fresh one and returns, so an expired claim
  -- is renewed forever and the prompt never comes back.
  if claimed(ft) then
    return
  end

  local candidates = M.plan(ft, bufnr)
  if #candidates == 0 then
    return
  end

  -- A previously accepted server that is no longer installed lands here (the
  -- package was removed, or the cache is shared with a fresh machine). Drop the
  -- stale answer and re-offer rather than silently reinstalling.
  if M.decision(ft) then
    remember(ft, nil)
  end

  local token = claim(ft)
  if not token then
    return
  end
  prompt(ft, candidates, token)
end

local AUGROUP = "lvim_lsp_automatic"

function M.setup()
  local auto = config()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  if auto.enabled == false then
    return
  end

  -- Gated on mason (nothing to install into) and on lspconfig (nothing to
  -- enable the result with). `plan()` re-checks both at fire time, because a
  -- user can flip either after setup has run.
  if not builtin_active("mason") or not builtin_active("lspconfig") then
    return
  end

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    desc = "Offer to install a language server for this filetype",
    callback = function(args)
      -- Headless has no one to answer the prompt, and the smoke harness boots
      -- this way a few hundred times. The guard lives here rather than inside
      -- `handle_filetype` so the decision logic stays exercisable in tests,
      -- which also run headless.
      if #vim.api.nvim_list_uis() == 0 then
        return
      end
      -- Deferred so the FileType handler returns immediately; the candidate
      -- lookup walks mason's package registry.
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(args.buf) then
          M.handle_filetype(vim.bo[args.buf].filetype, args.buf)
        end
      end)
    end,
  })
end

return M

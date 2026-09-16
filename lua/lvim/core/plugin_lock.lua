-- Lockfile helpers for `:LvimSyncCorePlugins`.
--
-- lazy-lock.json records `{branch, commit}` per plugin name, not the git URL.
-- After a spec entry keeps its `name` but changes repository (comment:
-- mini.nvim → mini.comment; autopairs: blink.pairs → mini.pairs), restore
-- re-clones the new URL then checks out the lockfile SHA from the old repo.
-- `rebase_stale_pins` rewrites those names to the snapshot pin when the
-- on-disk origin no longer matches the spec URL.

local M = {}

function M.normalize_git_url(url)
  if type(url) ~= "string" or url == "" then
    return ""
  end
  local normalized = url:gsub("%s+", "")
  normalized = normalized:gsub("%.git$", "")
  normalized = normalized:gsub("^git@github%.com:", "https://github.com/")
  normalized = normalized:gsub("^ssh://git@github%.com/", "https://github.com/")
  return normalized:lower()
end

function M.urls_match(a, b)
  local na = M.normalize_git_url(a)
  local nb = M.normalize_git_url(b)
  return na ~= "" and na == nb
end

-- Read `remote.origin.url` from a plugin checkout without spawning git.
function M.read_origin(dir)
  if type(dir) ~= "string" or dir == "" then
    return nil
  end
  local fd = io.open(dir .. "/.git/config", "r")
  if not fd then
    return nil
  end
  local contents = fd:read("*a")
  fd:close()
  if type(contents) ~= "string" then
    return nil
  end

  local in_origin = false
  for line in contents:gmatch("[^\n]+") do
    local section = line:match("^%s*%[([^%]]+)%]")
    if section then
      in_origin = section:match('^remote%s+"origin"$') ~= nil
    elseif in_origin then
      local origin = line:match("^%s*url%s*=%s*(%S+)")
      if origin then
        return origin
      end
    end
  end
  return nil
end

function M.plugin_origin_mismatches(plugin)
  if type(plugin) ~= "table" or type(plugin.url) ~= "string" or plugin.url == "" then
    return false
  end
  local origin = M.read_origin(plugin.dir)
  if not origin then
    return false
  end
  return not M.urls_match(origin, plugin.url)
end

function M.is_under_root(dir, root)
  if type(dir) ~= "string" or type(root) ~= "string" or dir == "" or root == "" then
    return false
  end
  dir = dir:gsub("/+$", "")
  root = root:gsub("/+$", "")
  return dir:sub(1, #root + 1) == (root .. "/")
end

-- Plugins whose on-disk origin does not match `plugin.url`, limited to
-- checkouts under lazy's install root so we never delete a local/dev dir.
function M.list_mismatched(plugins, root)
  local found = {}
  if type(plugins) ~= "table" then
    return found
  end
  for _, plugin in pairs(plugins) do
    if
      type(plugin) == "table"
      and type(plugin.name) == "string"
      and M.plugin_origin_mismatches(plugin)
      and M.is_under_root(plugin.dir, root)
    then
      found[#found + 1] = { name = plugin.name, dir = plugin.dir }
    end
  end
  table.sort(found, function(a, b)
    return a.name < b.name
  end)
  return found
end

-- `lock` and `snapshot` are `{ [name] = { branch, commit } }`.
-- `installed` is `{ [name] = { spec_url = string, origin = string|nil } }`.
-- Names whose on-disk origin does not match the spec URL take the snapshot
-- pin when one exists, otherwise the stale lockfile entry is dropped.
function M.rebase_stale_pins(lock, snapshot, installed)
  local next_lock = {}
  if type(lock) == "table" then
    for name, pin in pairs(lock) do
      next_lock[name] = pin
    end
  end
  snapshot = type(snapshot) == "table" and snapshot or {}
  installed = type(installed) == "table" and installed or {}

  local rewritten = {}
  for name, info in pairs(installed) do
    if
      type(info) == "table"
      and type(info.origin) == "string"
      and info.origin ~= ""
      and type(info.spec_url) == "string"
      and info.spec_url ~= ""
    then
      if not M.urls_match(info.origin, info.spec_url) then
        if type(snapshot[name]) == "table" then
          next_lock[name] = {
            branch = snapshot[name].branch,
            commit = snapshot[name].commit,
          }
        else
          next_lock[name] = nil
        end
        rewritten[#rewritten + 1] = name
      end
    end
  end
  table.sort(rewritten)
  return next_lock, rewritten
end

-- After install/restore failed for `failed_names`, take the snapshot pin
-- for those names whose lockfile commit is not already the snapshot.
-- Does not treat "pin ~= snapshot" as a URL change on its own — only
-- names that already failed checkout are rewritten.
function M.pins_for_failed_checkouts(lock, snapshot, failed_names)
  local next_lock = {}
  if type(lock) == "table" then
    for name, pin in pairs(lock) do
      next_lock[name] = pin
    end
  end
  snapshot = type(snapshot) == "table" and snapshot or {}
  local applied = {}
  if type(failed_names) ~= "table" then
    return next_lock, applied
  end
  for _, name in ipairs(failed_names) do
    if type(name) == "string" then
      local snap = snapshot[name]
      local pin = next_lock[name]
      if type(snap) == "table" and type(snap.commit) == "string" and snap.commit ~= "" then
        if not (type(pin) == "table" and pin.commit == snap.commit) then
          next_lock[name] = {
            branch = snap.branch,
            commit = snap.commit,
          }
          applied[#applied + 1] = name
        end
      end
    end
  end
  table.sort(applied)
  return next_lock, applied
end

-- Names whose error tasks appear in `after` but not `before`. Used so a
-- leftover failed checkout from the previous install attempt (lazy keeps
-- error tasks for the UI) does not make a successful retry look failed.
function M.new_error_names(before, after)
  before = type(before) == "table" and before or {}
  after = type(after) == "table" and after or {}
  local names = {}
  local seen = {}
  for task, name in pairs(after) do
    if not before[task] and type(name) == "string" and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

function M.encode(lock)
  local names = {}
  if type(lock) == "table" then
    for name in pairs(lock) do
      names[#names + 1] = name
    end
  end
  table.sort(names)

  if #names == 0 then
    return "{}\n"
  end

  local parts = { "{\n" }
  for i, name in ipairs(names) do
    local pin = lock[name] or {}
    local tail = i == #names and "\n" or ",\n"
    parts[#parts + 1] = string.format(
      '  %s: { "branch": %s, "commit": %s }%s',
      vim.json.encode(name),
      vim.json.encode(pin.branch),
      vim.json.encode(pin.commit),
      tail
    )
  end
  parts[#parts + 1] = "}\n"
  return table.concat(parts)
end

return M

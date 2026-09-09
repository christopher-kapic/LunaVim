-- Minimal file logger behind `lvim.log`.
--
-- The key existed in the defaults for a long time with nothing reading it, and
-- was removed for that reason. This is what makes it real.
--
-- Deliberately not structlog.nvim (what the upstream LunarVim reference used).
-- The whole requirement is "append a filtered line to a file and mirror it to
-- `vim.notify`", which is a page of Lua; taking a dependency for it would add a
-- plugin to every user's install to save nothing.
--
-- Writes to `<cache>/lvim.log`, appending, so a crash report survives the
-- session that produced it. The file is opened per write rather than held open:
-- these are rare events, and a held handle would need flushing and closing on
-- exit to be crash-safe anyway.

local M = {}

local LEVELS = {
  trace = 1,
  debug = 2,
  info = 3,
  warn = 4,
  error = 5,
  fatal = 6,
}

local NOTIFY_LEVEL = {
  trace = vim.log.levels.TRACE,
  debug = vim.log.levels.DEBUG,
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
  fatal = vim.log.levels.ERROR,
}

-- Every entry point below is written on the assumption that it is called FROM a
-- failure path. A logger that raises turns "something went wrong" into "something
-- went wrong and then the error handler exploded", so each step that can throw --
-- `get_cache_dir`, `fnamemodify`, `mkdir`, `io.open`, `tostring` on a value with
-- a hostile `__tostring`, and `vim.notify` itself (which any plugin may have
-- replaced) -- is guarded.

local MAX_MESSAGE_BYTES = 8192

function M.path()
  local ok, cache = pcall(function()
    return (type(_G.get_cache_dir) == "function") and _G.get_cache_dir() or vim.fn.stdpath("cache")
  end)
  if not ok or type(cache) ~= "string" or cache == "" then
    cache = vim.fn.stdpath("cache")
  end
  return cache .. "/lvim.log"
end

local function configured_level()
  local cfg = (_G.lvim and _G.lvim.log) or {}
  return LEVELS[cfg.level or "warn"] or LEVELS.warn
end

---Should a message at `level` be recorded?
---@param level string
---@return boolean
function M.enabled(level)
  local want = LEVELS[level]
  if not want then
    return false
  end
  return want >= configured_level()
end

---`tostring` can raise via a hostile `__tostring` metamethod, and an unbounded
---message can blow up the log file, so both are handled here.
local function safe_message(msg)
  local ok, text = pcall(tostring, msg)
  if not ok or type(text) ~= "string" then
    text = "<un-stringifiable value>"
  end
  if #text > MAX_MESSAGE_BYTES then
    text = text:sub(1, MAX_MESSAGE_BYTES) .. "... <truncated>"
  end
  -- Newlines would split one record across several lines and break the
  -- one-record-per-line shape the file otherwise guarantees.
  return (text:gsub("[\r\n]", " "))
end

---@param level string one of trace|debug|info|warn|error|fatal
---@param msg string
function M.log(level, msg)
  if not M.enabled(level) then
    return
  end

  local text = safe_message(msg)

  local ok_stamp, stamp = pcall(os.date, "%Y-%m-%d %H:%M:%S")
  if not ok_stamp or type(stamp) ~= "string" then
    stamp = "unknown-time"
  end

  -- A single write per record. Two writes (`line` then `"\n"`) let two Neovim
  -- instances appending to the same file interleave mid-record.
  local line = string.format("[%s] %s %s\n", stamp, level:upper(), text)

  pcall(function()
    local path = M.path()
    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(dir) == 0 then
      vim.fn.mkdir(dir, "p")
    end
    local fd = io.open(path, "a")
    if fd then
      fd:write(line)
      fd:close()
    end
  end)

  local cfg = (_G.lvim and _G.lvim.log) or {}
  if cfg.notify == false then
    return
  end

  -- Only surface warn and above interactively; trace/debug/info belong in the
  -- file, not in the user's face. `vim.notify` is pcall'd because plugins
  -- routinely replace it, and a replacement that throws must not propagate out
  -- of a logging call.
  if LEVELS[level] >= LEVELS.warn then
    pcall(vim.notify, text, NOTIFY_LEVEL[level] or vim.log.levels.WARN)
  end
end

for name in pairs(LEVELS) do
  M[name] = function(msg)
    M.log(name, msg)
  end
end

return M

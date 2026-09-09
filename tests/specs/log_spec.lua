-- Coverage for `lvim.core.log`, the reader that makes `lvim.log` a real
-- setting rather than a key nothing consumes.

local function read_log()
  local path = require("lvim.core.log").path()
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  return vim.fn.readfile(path)
end

describe("lvim.core.log", function()
  local cache_dir

  before_each(function()
    require("lvim.config").load_defaults()
    -- Point the cache at a scratch dir so the suite never writes the
    -- developer's real ~/.cache/lvim/lvim.log.
    cache_dir = vim.fn.tempname()
    vim.fn.mkdir(cache_dir, "p")
    _G.get_cache_dir = function()
      return cache_dir
    end
    package.loaded["lvim.core.log"] = nil
  end)

  after_each(function()
    package.loaded["lvim.core.log"] = nil
  end)

  it("writes to <cache>/lvim.log", function()
    local log = require("lvim.core.log")
    assert.equals(cache_dir .. "/lvim.log", log.path())
  end)

  it("records messages at or above the configured level", function()
    _G.lvim.log.level = "warn"
    _G.lvim.log.notify = false
    local log = require("lvim.core.log")

    log.error("boom")
    local lines = read_log()

    assert.equals(1, #lines)
    assert.is_truthy(lines[1]:find("ERROR", 1, true))
    assert.is_truthy(lines[1]:find("boom", 1, true))
  end)

  it("drops messages below the configured level", function()
    _G.lvim.log.level = "warn"
    _G.lvim.log.notify = false
    local log = require("lvim.core.log")

    log.debug("chatter")
    log.info("more chatter")

    assert.same({}, read_log())
  end)

  it("honours a lowered level", function()
    _G.lvim.log.level = "trace"
    _G.lvim.log.notify = false
    local log = require("lvim.core.log")

    log.debug("now recorded")

    assert.equals(1, #read_log())
  end)

  it("appends rather than truncating", function()
    _G.lvim.log.level = "info"
    _G.lvim.log.notify = false
    local log = require("lvim.core.log")

    log.info("first")
    log.info("second")

    assert.equals(2, #read_log())
  end)

  it("notifies for warn and above, and not below", function()
    _G.lvim.log.level = "trace"
    _G.lvim.log.notify = true
    local seen = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level)
      seen[#seen + 1] = { msg = msg, level = level }
    end

    local log = require("lvim.core.log")
    log.info("quiet")
    log.warn("loud")
    vim.notify = real_notify

    assert.equals(1, #seen)
    assert.equals("loud", seen[1].msg)
  end)

  it("keeps messages out of vim.notify when notify = false", function()
    _G.lvim.log.level = "trace"
    _G.lvim.log.notify = false
    local seen = 0
    local real_notify = vim.notify
    vim.notify = function()
      seen = seen + 1
    end

    require("lvim.core.log").error("silent")
    vim.notify = real_notify

    assert.equals(0, seen)
    assert.equals(1, #read_log())
  end)

  it("does not raise when vim.notify itself throws", function()
    -- Plugins routinely replace vim.notify. A replacement that throws must not
    -- propagate out of a logging call, which is typically made FROM a failure
    -- path in the first place.
    _G.lvim.log.level = "trace"
    _G.lvim.log.notify = true
    local real_notify = vim.notify
    vim.notify = function()
      error("notify backend exploded")
    end

    local ok = pcall(function()
      require("lvim.core.log").error("still fine")
    end)
    vim.notify = real_notify

    assert.is_true(ok, "a throwing vim.notify must not escape lvim.core.log")
    assert.equals(1, #read_log(), "the record must still reach the file")
  end)

  it("does not raise on a value whose __tostring throws", function()
    _G.lvim.log.level = "trace"
    _G.lvim.log.notify = false
    local hostile = setmetatable({}, {
      __tostring = function()
        error("no string for you")
      end,
    })

    assert.has_no.errors(function()
      require("lvim.core.log").error(hostile)
    end)
    assert.equals(1, #read_log())
  end)

  it("writes each record as exactly one line", function()
    -- Two Neovim instances append to the same file; a record split across
    -- several writes can interleave mid-record. Embedded newlines in the
    -- message must not split it either.
    _G.lvim.log.level = "trace"
    _G.lvim.log.notify = false

    require("lvim.core.log").error("first line\nsecond line\nthird")

    assert.equals(1, #read_log())
  end)

  it("truncates an unbounded message", function()
    _G.lvim.log.level = "trace"
    _G.lvim.log.notify = false

    require("lvim.core.log").error(string.rep("x", 50000))
    local lines = read_log()

    assert.equals(1, #lines)
    assert.is_true(#lines[1] < 20000, "an oversized message must be truncated")
    assert.is_truthy(lines[1]:find("truncated", 1, true))
  end)

  it("does not raise when the log file cannot be written", function()
    _G.get_cache_dir = function()
      return "/proc/nonexistent-lvim-log-dir"
    end
    package.loaded["lvim.core.log"] = nil
    _G.lvim.log.notify = false

    assert.has_no.errors(function()
      require("lvim.core.log").error("unwritable")
    end)
  end)
end)

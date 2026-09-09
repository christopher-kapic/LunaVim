-- Coverage for `lvim.plugins.modules.dap`.
--
-- The claims pinned here are the ones that were argued in review but not
-- previously testable:
--   * adapters/configurations declared in `lvim.builtin.dap` actually reach
--     `dap.adapters` / `dap.configurations` -- the direct `require("dap")` in
--     config.lua that this replaces cannot work, because user config runs
--     before lazy.nvim is bootstrapped;
--   * `auto_open` is reconciled on every pass, so turning it off and reloading
--     actually stops the UI opening itself;
--   * `toggle_ui()` loads nvim-dap (the parent spec) before touching dap-ui,
--     so the UI is never opened unconfigured;
--   * which-key's gate does not LOAD nvim-dap merely to decide whether to show
--     the Debug group.

local function fresh_dap()
  return {
    adapters = {},
    configurations = {},
    listeners = {
      after = { event_initialized = {} },
      before = { event_terminated = {}, event_exited = {} },
    },
  }
end

local function fresh_dapui()
  local ui = { setup_calls = 0, toggled = 0 }
  ui.setup = function()
    ui.setup_calls = ui.setup_calls + 1
  end
  ui.toggle = function()
    ui.toggled = ui.toggled + 1
  end
  ui.open = function() end
  ui.close = function() end
  return ui
end

describe("lvim.plugins.modules.dap", function()
  local dap, dapui

  before_each(function()
    require("lvim.config").load_defaults()
    dap, dapui = fresh_dap(), fresh_dapui()
    package.loaded["dap"] = dap
    package.loaded["dapui"] = dapui
    package.loaded["lvim.plugins.modules.dap"] = nil
  end)

  after_each(function()
    package.loaded["dap"] = nil
    package.loaded["dapui"] = nil
    package.loaded["lvim.plugins.modules.dap"] = nil
  end)

  it("applies adapters and configurations declared in lvim.builtin.dap", function()
    _G.lvim.builtin.dap.adapters.python = { type = "executable", command = "debugpy-adapter" }
    _G.lvim.builtin.dap.configurations.python = { { type = "python", request = "launch" } }

    require("lvim.plugins.modules.dap").setup({})

    assert.equals("debugpy-adapter", dap.adapters.python.command)
    assert.equals("python", dap.configurations.python[1].type)
  end)

  it("installs the dapui listeners when auto_open is on", function()
    require("lvim.plugins.modules.dap").setup({})
    assert.is_function(dap.listeners.after.event_initialized["lvim_dapui"])
    assert.is_function(dap.listeners.before.event_terminated["lvim_dapui"])
    assert.is_function(dap.listeners.before.event_exited["lvim_dapui"])
  end)

  it("removes the listeners when auto_open is turned off and setup re-runs", function()
    local mod = require("lvim.plugins.modules.dap")
    mod.setup({})
    assert.is_function(dap.listeners.after.event_initialized["lvim_dapui"])

    -- The reload case: user flips auto_open off, :LvimReload re-enters setup.
    _G.lvim.builtin.dap.auto_open = false
    mod.setup({})

    assert.is_nil(dap.listeners.after.event_initialized["lvim_dapui"])
    assert.is_nil(dap.listeners.before.event_terminated["lvim_dapui"])
    assert.is_nil(dap.listeners.before.event_exited["lvim_dapui"])
  end)

  it("does not stack duplicate listeners across repeated setup calls", function()
    local mod = require("lvim.plugins.modules.dap")
    mod.setup({})
    local first = dap.listeners.after.event_initialized["lvim_dapui"]
    mod.setup({})
    assert.is_function(dap.listeners.after.event_initialized["lvim_dapui"])
    -- Same single keyed slot, replaced rather than appended.
    assert.is_not_nil(first)
    local count = 0
    for _ in pairs(dap.listeners.after.event_initialized) do
      count = count + 1
    end
    assert.equals(1, count)
  end)

  it("toggle_ui loads nvim-dap before touching dap-ui", function()
    -- dap-ui is a DEPENDENCY of the dap spec, so requiring it directly would
    -- load it without running the parent spec's config (where dapui.setup
    -- lives). Track which module is required first.
    local order = {}
    package.loaded["dap"] = nil
    package.loaded["dapui"] = nil
    package.preload["dap"] = function()
      order[#order + 1] = "dap"
      return dap
    end
    package.preload["dapui"] = function()
      order[#order + 1] = "dapui"
      return dapui
    end

    require("lvim.plugins.modules.dap").toggle_ui()

    package.preload["dap"] = nil
    package.preload["dapui"] = nil

    assert.equals("dap", order[1], "nvim-dap must be required before dap-ui")
    assert.equals(1, dapui.toggled)
  end)

  it("toggle_ui warns instead of erroring when nvim-dap is absent", function()
    package.loaded["dap"] = nil
    package.loaded["dapui"] = nil
    package.preload["dap"] = function()
      error("not installed")
    end

    assert.has_no.errors(function()
      require("lvim.plugins.modules.dap").toggle_ui()
    end)

    package.preload["dap"] = nil
  end)
end)

describe("which-key dap gate", function()
  before_each(function()
    require("lvim.config").load_defaults()
    package.loaded["dap"] = nil
    package.loaded["dapui"] = nil
    package.loaded["lvim.plugins.modules.whichkey"] = nil
  end)

  after_each(function()
    package.loaded["which-key"] = nil
    package.loaded["lvim.plugins.modules.whichkey"] = nil
  end)

  it("decides whether to show the Debug group without loading nvim-dap", function()
    -- Probing with `pcall(require, "dap")` would make lazy.nvim load the
    -- debugger during which-key's VeryLazy setup, on every launch, for a plugin
    -- most sessions never use.
    --
    -- The assertion is that the require is never ATTEMPTED, not merely that it
    -- failed. Asserting `package.loaded["dap"] == nil` was vacuous: dap is not
    -- installed in this harness, so a `pcall(require, "dap")` probe fails and
    -- leaves package.loaded untouched, and the test passed with the bug
    -- present. `package.preload` makes the require succeed if it happens, so
    -- the attempt is observable.
    local attempted = {}
    package.preload["dap"] = function()
      attempted[#attempted + 1] = "dap"
      return {}
    end
    package.preload["dapui"] = function()
      attempted[#attempted + 1] = "dapui"
      return {}
    end
    package.loaded["which-key"] = { setup = function() end, add = function() end }

    require("lvim.plugins.modules.whichkey").setup({})

    package.preload["dap"] = nil
    package.preload["dapui"] = nil
    package.loaded["dap"] = nil
    package.loaded["dapui"] = nil

    assert.same({}, attempted, "which-key setup must not require nvim-dap or dap-ui")
  end)
end)

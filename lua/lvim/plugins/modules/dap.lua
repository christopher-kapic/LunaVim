-- nvim-dap + nvim-dap-ui wiring.
--
-- `lvim.builtin.dap` is forwarded as follows:
--   * `signs`          -> `vim.fn.sign_define` for the breakpoint/stopped marks
--   * `ui`             -> `require("dapui").setup(opts)`
--   * `auto_open`      -> open dapui when a session starts, close it when it ends
--   * `adapters`       -> merged into `dap.adapters`
--   * `configurations` -> merged into `dap.configurations`
--
-- Adapters go through `lvim.builtin.dap.adapters` rather than a direct
-- `require("dap")` in config.lua. That matters: `lvim.start()` runs the user's
-- config BEFORE it bootstraps lazy.nvim, so `require("dap")` from config.lua
-- cannot resolve -- and because config.lua executes as one chunk, the resulting
-- error would silently skip every later line of it. Declaring the tables keeps
-- the config declarative and order-independent:
--
--   lvim.builtin.dap.adapters.python = {
--     type = "executable", command = "debugpy-adapter",
--   }
--   lvim.builtin.dap.configurations.python = {
--     { type = "python", request = "launch", name = "file", program = "${file}" },
--   }
--
-- No adapter is bundled. A debug adapter is per-language, needs its own binary,
-- and the right source varies by project, so a distribution guessing would
-- install debuggers most users do not want and still be wrong for the rest.

local M = {}

local function define_signs(signs)
  for name, sign in pairs(signs or {}) do
    if type(sign) == "table" and sign.text then
      vim.fn.sign_define(name, {
        text = sign.text,
        texthl = sign.texthl or "Comment",
        linehl = sign.linehl or "",
        numhl = sign.numhl or "",
      })
    end
  end
end

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.dap) or {}

  local ok, dap = pcall(require, "dap")
  if not ok then
    return
  end

  define_signs(builtin.signs)

  -- Adapters and configurations are applied before the UI, so a session
  -- started immediately after load has them in place.
  for name, adapter in pairs(builtin.adapters or {}) do
    dap.adapters[name] = adapter
  end
  for ft, configs in pairs(builtin.configurations or {}) do
    dap.configurations[ft] = configs
  end

  local ok_ui, dapui = pcall(require, "dapui")
  if not ok_ui then
    -- dap-ui unavailable: still drop any listeners a previous pass installed,
    -- so they cannot fire against a UI that is no longer loadable.
    dap.listeners.after.event_initialized["lvim_dapui"] = nil
    dap.listeners.before.event_terminated["lvim_dapui"] = nil
    dap.listeners.before.event_exited["lvim_dapui"] = nil
    return
  end

  local ui_opts = vim.deepcopy(builtin.ui or {})
  dapui.setup(ui_opts)

  -- Clear our listeners unconditionally before deciding whether to install
  -- them. Keying by a plugin-unique id already prevents stacking duplicates on
  -- a re-run, but it does not handle the case that matters here: a user who
  -- had auto_open on, turns it OFF, and reloads. Returning early would leave
  -- the previous session's listeners registered and the UI would keep opening
  -- itself. Clearing first makes each pass a full reconciliation.
  dap.listeners.after.event_initialized["lvim_dapui"] = nil
  dap.listeners.before.event_terminated["lvim_dapui"] = nil
  dap.listeners.before.event_exited["lvim_dapui"] = nil

  if builtin.auto_open == false then
    return
  end

  dap.listeners.after.event_initialized["lvim_dapui"] = function()
    dapui.open()
  end
  dap.listeners.before.event_terminated["lvim_dapui"] = function()
    dapui.close()
  end
  dap.listeners.before.event_exited["lvim_dapui"] = function()
    dapui.close()
  end
end

-- Toggle the dap-ui panels, ensuring the stack is actually configured first.
--
-- `<leader>dU` cannot simply `require('dapui')`. dap-ui is specced as a
-- DEPENDENCY of nvim-dap, so requiring it directly makes lazy.nvim load dap-ui
-- alone -- without running the parent dap spec's `config` callback, which is
-- where `dapui.setup()` and the listener wiring live. Pressing the UI binding
-- before any other dap key would then open an unconfigured UI. Routing through
-- this function requires `dap` first, which loads the parent spec and runs
-- setup, and only then touches dapui.
function M.toggle_ui()
  local ok = pcall(require, "dap")
  if not ok then
    vim.notify("lvim: nvim-dap is not installed", vim.log.levels.WARN)
    return
  end

  local ok_ui, dapui = pcall(require, "dapui")
  if not ok_ui then
    vim.notify("lvim: nvim-dap-ui is not installed", vim.log.levels.WARN)
    return
  end

  dapui.toggle({ reset = true })
end

return M

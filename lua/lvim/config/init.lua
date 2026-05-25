local M = {}

function M.load_defaults()
  local defaults = require("lvim.config.defaults")
  _G.lvim = vim.deepcopy(defaults)
  -- Attach the utils module after the deepcopy so deep_extend_force_keep_user
  -- / merge_builtin_overrides are reachable from user config as `lvim.utils.*`.
  _G.lvim.utils = require("lvim.utils")
  return _G.lvim
end

function M.load_user_config()
  return require("lvim.config.loader").load_user_config()
end

return M

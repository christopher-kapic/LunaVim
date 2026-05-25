local M = {}

local function file_exists(path)
  return vim.fn.filereadable(path) == 1
end

function M.load_user_config()
  local bootstrap = require("lvim.bootstrap")
  local config_dir = bootstrap.get_config_dir()
  local path = config_dir .. "/config.lua"

  if not file_exists(path) then
    vim.notify(
      string.format("No user config at %s; create one to customize.", path),
      vim.log.levels.INFO
    )
    return false
  end

  local chunk, load_err = loadfile(path)
  if not chunk then
    vim.notify(
      string.format("Failed to load user config %s: %s", path, load_err or "unknown error"),
      vim.log.levels.ERROR
    )
    return false
  end

  local ok, run_err = pcall(chunk)
  if not ok then
    vim.notify(
      string.format("Error running user config %s: %s", path, tostring(run_err)),
      vim.log.levels.ERROR
    )
    return false
  end

  return true
end

return M

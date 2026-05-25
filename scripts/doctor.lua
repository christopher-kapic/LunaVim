-- Headless entry point for `lvim doctor` (see bin/lvim).
--
-- `:checkhealth lvim` populates a scratch buffer with the report (via
-- `lua/lvim/health.lua`) but in headless mode that buffer is never shown.
-- We read the buffer back, stream the contents to stdout, then exit with a
-- non-zero code if any `vim.health.error()` line is present so this command
-- is scriptable (CI, install verification, etc).

vim.cmd("checkhealth lvim")

local report = nil
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[buf].filetype == "checkhealth" then
    report = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    break
  end
end

if not report then
  io.stderr:write("lvim doctor: failed to capture :checkhealth lvim output\n")
  vim.cmd("cquit 2")
  return
end

local had_error = false
for _, line in ipairs(report) do
  io.stdout:write(line .. "\n")
  -- `vim.health.error()` renders with the leading "❌ ERROR" tag (the
  -- ASCII "ERROR" token is stable across Neovim's emoji/no-emoji toggles).
  if line:find("ERROR", 1, true) then
    had_error = true
  end
end

if had_error then
  vim.cmd("cquit 1")
end

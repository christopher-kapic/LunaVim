-- Smoke fixture: leader is two backslashes (Lua "\\\\" == 2 chars) so
-- `print(lvim.leader)` output matches the acceptance grep `grep -F '\\'`
-- (bash single-quotes preserve both backslashes literally).
lvim.leader = "\\\\"
lvim.builtin.telescope.active = false
-- Phase 3.1: exercises the `lvim.opt` override path. Defaults set
-- `vim.opt.wrap = false`; the smoke harness asserts the user override flips
-- it back to true once `lvim.core.options.setup()` runs after user config.
lvim.opt = { wrap = true }

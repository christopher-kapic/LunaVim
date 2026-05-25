-- Loader-facing fixture used by the smoke harness via:
--   LUNAVIM_CONFIG_DIR=$(pwd)/tests/fixtures nvim --headless -u init.lua ...
--
-- Phase 1.2 acceptance requires `lvim.leader` and `lvim.builtin.telescope.active`
-- to reflect user-applied values. Phase 1.3 additionally exercises whole-table
-- replacement semantics on `lvim.builtin.<name>` to confirm that:
--   * the assignment overrides defaults at that subtree,
--   * other builtins (e.g. nvimtree) retain `active = true`, and
--   * nested keys like `defaults.custom` survive on the replaced subtree.
-- Phase 1.4 adds `lvim.plugins` so the smoke can prove that user-added specs
-- get appended to `lvim.plugins.final_spec()` after the core spec.
--
-- The leader value is two literal backslashes (Lua `"\\\\"` is a 2-char string
-- `\\`) so `print(lvim.leader)` matches the smoke grep `grep -F '\\'`.
lvim.leader = "\\\\"
lvim.builtin.telescope = { active = false, defaults = { custom = 1 } }
lvim.plugins = {
  { "foo/bar", name = "bar" },
}

-- Phase 4.4 acceptance fixture: a minimal `.lua` buffer used to trigger
-- lazydev's `ft = "lua"` lazy-load hook in the acceptance command
--   nvim --headless -u init.lua tests/fixtures/dummy.lua \
--     -c "lua print(type(require('lazydev')))" -c qall!
-- so the smoke harness can prove lazydev loads on Lua filetype.
return {}

-- Coverage for `lvim.core.project`, the native project-root helper that
-- replaces the reference's `ahmedkhalf/project.nvim` (no commit since 2023).

local function make_tree()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/pkg/src", "p")
  vim.fn.writefile({ "{}" }, root .. "/package.json")
  vim.fn.mkdir(root .. "/.git", "p")
  vim.fn.writefile({ "return {}" }, root .. "/pkg/src/mod.lua")
  -- `vim.fs.root` resolves symlinks in the buffer path, and macOS/tempname
  -- paths can be symlinked, so compare against the resolved root.
  return vim.fn.resolve(root)
end

local function buffer_for(path)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  return bufnr
end

describe("lvim.core.project", function()
  before_each(function()
    require("lvim.config").load_defaults()
  end)

  it("finds the nearest ancestor matching a configured pattern", function()
    local root = make_tree()
    local bufnr = buffer_for(root .. "/pkg/src/mod.lua")

    assert.equals(root, vim.fn.resolve(require("lvim.core.project").find_root(bufnr)))
  end)

  it("prefers a nearer manifest over an enclosing .git", function()
    -- `.git` is last in the default patterns so a package inside a monorepo
    -- resolves to the package, not the whole repository.
    local root = make_tree()
    vim.fn.writefile({ "{}" }, root .. "/pkg/package.json")
    local bufnr = buffer_for(root .. "/pkg/src/mod.lua")

    assert.equals(root .. "/pkg", vim.fn.resolve(require("lvim.core.project").find_root(bufnr)))
  end)

  it("returns nil for a buffer with no file", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    assert.is_nil(require("lvim.core.project").find_root(bufnr))
  end)

  it("returns nil for a non-file buftype", function()
    local root = make_tree()
    local bufnr = buffer_for(root .. "/pkg/src/mod.lua")
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })

    assert.is_nil(require("lvim.core.project").find_root(bufnr))
  end)

  it("never resolves to an excluded directory", function()
    -- A dotfiles repo makes $HOME match `.git`; cd-ing there is disorienting.
    local root = make_tree()
    local bufnr = buffer_for(root .. "/pkg/src/mod.lua")
    _G.lvim.builtin.project.exclude_dirs = { root }

    assert.is_nil(require("lvim.core.project").find_root(bufnr))
  end)

  it("never resolves to a shared system directory", function()
    -- A stray `.git` in a shared directory would otherwise make every loose
    -- file under it look like one enormous project and silently repoint the
    -- working directory there. `/tmp/.git` really existed on the machine this
    -- was developed on, which is how the gap was found.
    local project = require("lvim.core.project")
    for _, dir in ipairs({ "/", "/tmp", "/var/tmp", "/usr", "/etc", "/home", vim.fn.expand("~") }) do
      assert.is_true(project.is_excluded_dir(dir), string.format("%q must never be treated as a project root", dir))
    end
  end)

  it("still resolves a genuine project nested under an excluded directory", function()
    -- The guard rejects the shared directory itself, not everything beneath it:
    -- tempdirs live under /tmp and must still work.
    local root = make_tree()
    local bufnr = buffer_for(root .. "/pkg/src/mod.lua")

    assert.equals(root, vim.fn.resolve(require("lvim.core.project").find_root(bufnr)))
  end)

  it("actually changes the working directory when the autocmd fires", function()
    -- The other tests exercise find_root in isolation; this one drives the real
    -- BufEnter path and asserts the observable effect, which is the whole point
    -- of the feature and the part with real blast radius.
    local root = make_tree()
    local original = vim.fn.getcwd()
    require("lvim.core.project").setup()

    local bufnr = buffer_for(root .. "/pkg/src/mod.lua")
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_exec_autocmds("BufEnter", { buffer = bufnr })

    local got = vim.fn.resolve(vim.fn.getcwd())
    vim.cmd("tcd " .. vim.fn.fnameescape(original))

    assert.equals(root, got)
  end)

  it("leaves the working directory alone for a buffer with no project", function()
    local original = vim.fn.getcwd()
    require("lvim.core.project").setup()

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_exec_autocmds("BufEnter", { buffer = bufnr })

    assert.equals(original, vim.fn.getcwd())
  end)

  it("registers no autocmd in manual_mode", function()
    _G.lvim.builtin.project.manual_mode = true
    require("lvim.core.project").setup()

    local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = "lvim_project_root" })
    assert.is_true(not ok or #autocmds == 0)
  end)

  it("registers an autocmd when enabled", function()
    _G.lvim.builtin.project.manual_mode = false
    require("lvim.core.project").setup()

    local autocmds = vim.api.nvim_get_autocmds({ group = "lvim_project_root" })
    assert.is_true(#autocmds > 0)
  end)

  it("registers no autocmd when the builtin is disabled", function()
    _G.lvim.builtin.project.active = false
    require("lvim.core.project").setup()

    local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = "lvim_project_root" })
    assert.is_true(not ok or #autocmds == 0)
  end)
end)

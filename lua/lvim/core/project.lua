-- Project-root detection.
--
-- Changes the working directory to the root of whatever project the current
-- file belongs to, so `<leader>ff`, live grep and the file tree operate on the
-- project rather than on wherever the shell happened to be.
--
-- This is a small native helper rather than a plugin. The upstream LunarVim
-- reference used `ahmedkhalf/project.nvim`, which has had no commit since April
-- 2023; `plan.md` calls for replacing it with "coffebar/neovim-project or a
-- small native project-root helper". Neovim 0.10 added `vim.fs.root`, which
-- does the actual pattern search, so the helper is thin enough that taking on a
-- dependency -- dormant or otherwise -- would be the larger cost.
--
-- Triggered from the `User FileOpened` event layer that `lvim/core/autocmds.lua`
-- already publishes, so it runs once a real file is open and never on the
-- dashboard or a scratch buffer.

local M = {}

local AUGROUP = "lvim_project_root"

-- Directories that must never be treated as a project root, even when a
-- pattern matches inside them.
--
-- This is not hypothetical tidiness. A stray `.git` in a shared directory makes
-- every loose file under it look like one enormous project, and the editor then
-- silently changes the user's working directory there -- which quietly
-- repoints `<leader>ff`, live grep and the file tree at the whole of `/tmp`.
-- `/tmp/.git` was present on the machine this was developed on, so the bare
-- `$HOME`-only guard was not enough; `$HOME` itself is the other common case,
-- because dotfile repos put a `.git` there deliberately.
--
-- Users extend this through `lvim.builtin.project.exclude_dirs`; the entries
-- here are always applied on top of whatever they configure, because none of
-- them is ever a legitimate project root.
local ALWAYS_EXCLUDED = {
  "/",
  "/tmp",
  "/var",
  "/var/tmp",
  "/usr",
  "/etc",
  "/opt",
  "/home",
  "/Users",
}

---Exposed for tests: is `dir` barred from ever being a project root?
---@param dir string
---@param exclude string[]|nil
---@return boolean
function M.is_excluded_dir(dir, exclude)
  if dir == vim.fn.expand("~") then
    return true
  end

  for _, always in ipairs(ALWAYS_EXCLUDED) do
    if dir == always then
      return true
    end
  end

  for _, pattern in ipairs(exclude or {}) do
    if dir == vim.fn.expand(pattern) then
      return true
    end
  end

  return false
end

local is_excluded = M.is_excluded_dir

---Resolve the project root for a buffer, or nil when there is none.
---@param bufnr integer
---@return string|nil
function M.find_root(bufnr)
  local cfg = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.project) or {}
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end

  -- Only real, on-disk files. A terminal or plugin buffer has no project.
  local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
  if buftype ~= "" then
    return nil
  end

  local root = vim.fs.root(bufnr, cfg.patterns or {})
  if not root or is_excluded(root, cfg.exclude_dirs) then
    return nil
  end

  return root
end

local function change_directory(root, scope)
  local cmd = ({ global = "cd", tab = "tcd", window = "lcd" })[scope] or "tcd"
  pcall(vim.cmd, cmd .. " " .. vim.fn.fnameescape(root))
end

function M.setup()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  local cfg = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.project) or {}
  if cfg.active == false or cfg.manual_mode == true then
    return
  end

  vim.api.nvim_create_autocmd({ "BufEnter" }, {
    group = group,
    desc = "lvim: change directory to the project root of the current file",
    callback = function(args)
      local root = M.find_root(args.buf)
      if not root then
        return
      end
      if vim.fn.getcwd() == root then
        return
      end
      change_directory(root, cfg.scope)
    end,
  })
end

---`:LvimProjectRoot` -- change to the current file's project root on demand.
---This is the escape hatch for `manual_mode = true`.
function M.change_to_root()
  local root = M.find_root(vim.api.nvim_get_current_buf())
  if not root then
    vim.notify("lvim: no project root found for this buffer", vim.log.levels.WARN)
    return
  end
  local cfg = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.project) or {}
  change_directory(root, cfg.scope)
  vim.notify("lvim: cwd -> " .. root, vim.log.levels.INFO)
end

return M

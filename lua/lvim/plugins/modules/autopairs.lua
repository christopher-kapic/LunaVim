-- mini.pairs wiring.
--
-- `lvim.builtin.autopairs.options` is forwarded to
-- `require("mini.pairs").setup(options)`. `disabled_filetypes` is LunaVim-owned:
-- mini.pairs has no filetype filter and instead honors
-- `vim.b.minipairs_disable`, which this module sets on FileType.
--
-- LunarVim exposed this surface as `lvim.builtin.autopairs`; LunaVim keeps that
-- name for compatibility even though the implementation is mini.pairs rather
-- than windwp/nvim-autopairs. Completion-time brackets (`foo` → `foo()`) are
-- owned by blink.cmp's `completion.accept.auto_brackets` (see `lvim.builtin.cmp`).
local M = {}

local AUGROUP = "lvim_minipairs_disable"

local function apply_buffer(bufnr, disabled)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ft = vim.bo[bufnr].filetype
  if disabled[ft] then
    vim.b[bufnr].minipairs_disable = true
  else
    vim.b[bufnr].minipairs_disable = nil
  end
end

local function apply_disabled_filetypes(filetypes)
  -- Always drop the previous FileType rules, including when the user
  -- clears `disabled_filetypes`. Returning early on an empty table used
  -- to leave the old augroup (and sticky `vim.b.minipairs_disable`) in
  -- place.
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)

  local disabled = {}
  if type(filetypes) == "table" then
    for key, value in pairs(filetypes) do
      if type(key) == "number" and type(value) == "string" and value ~= "" then
        disabled[value] = true
      elseif type(key) == "string" and key ~= "" and value then
        disabled[key] = true
      end
    end
  end

  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    desc = "Disable mini.pairs for configured filetypes",
    callback = function(ev)
      local ft = ev.match
      if ft == nil or ft == "" then
        ft = vim.bo[ev.buf].filetype
      end
      if disabled[ft] then
        vim.b[ev.buf].minipairs_disable = true
      else
        vim.b[ev.buf].minipairs_disable = nil
      end
    end,
  })

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    apply_buffer(bufnr, disabled)
  end
end

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.autopairs) or {}
  local opts = vim.deepcopy(builtin.options or {})

  local ok, mini_pairs = pcall(require, "mini.pairs")
  if not ok then
    return
  end

  mini_pairs.setup(opts)
  apply_disabled_filetypes(builtin.disabled_filetypes)
end

return M

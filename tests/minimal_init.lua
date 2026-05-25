local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local plenary_dir = vim.env.PLENARY_DIR or (root .. "/tests/deps/plenary.nvim")
if vim.fn.isdirectory(plenary_dir) == 0 then
  vim.fn.mkdir(vim.fn.fnamemodify(plenary_dir, ":h"), "p")
  local result = vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/nvim-lua/plenary.nvim.git",
    plenary_dir,
  })

  if vim.v.shell_error ~= 0 then
    error("failed to clone plenary.nvim: " .. result)
  end
end

vim.opt.runtimepath:prepend(plenary_dir)
vim.cmd("runtime plugin/plenary.vim")

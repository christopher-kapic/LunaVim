describe("comment module", function()
  local original_lvim
  local original_mini_comment
  local original_preload
  local original_buf

  before_each(function()
    original_lvim = _G.lvim
    original_mini_comment = package.loaded["mini.comment"]
    original_preload = package.preload["mini.comment"]
    original_buf = vim.api.nvim_get_current_buf()

    package.loaded["lvim.plugins.modules.comment"] = nil
    package.loaded["mini.comment"] = nil
    package.preload["mini.comment"] = function()
      return {
        setup = function() end,
      }
    end
    _G.lvim = { builtin = { comment = { options = {} } } }
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "lvim_dotenv_commentstring")
    package.loaded["lvim.plugins.modules.comment"] = nil
    package.loaded["mini.comment"] = original_mini_comment
    package.preload["mini.comment"] = original_preload
    _G.lvim = original_lvim

    if vim.api.nvim_buf_is_valid(original_buf) then
      vim.api.nvim_set_current_buf(original_buf)
    end
  end)

  it("sets shell-style commentstring for the current .env buffer", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_name(bufnr, "/tmp/lvim-comment-spec/.env")
    vim.bo[bufnr].commentstring = ""

    require("lvim.plugins.modules.comment").setup()

    assert.equals("# %s", vim.bo[bufnr].commentstring)
  end)

  it("sets shell-style commentstring for future dotenv buffers", function()
    require("lvim.plugins.modules.comment").setup()

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_name(bufnr, "/tmp/lvim-comment-spec/.env.local")
    vim.bo[bufnr].commentstring = ""

    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })

    assert.equals("# %s", vim.bo[bufnr].commentstring)
  end)
end)

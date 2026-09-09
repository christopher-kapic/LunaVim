-- Coverage for `lvim.lsp.buffer_mappings`, the LunarVim-compatible surface that
-- lets a user retarget or drop an individual LSP key without having to supply a
-- whole replacement `lvim.lsp.on_attach`.
--
-- The defaults were previously hardcoded inside `make_on_attach()`. The smoke
-- suite only ever asserted the default key set, so overriding and removal --
-- the entire reason the table exists -- had no coverage at all.

local function attach_to_scratch()
  local bufnr = vim.api.nvim_create_buf(false, true)
  require("lvim.lsp.handlers").make_on_attach()(nil, bufnr)
  local seen = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    seen[m.lhs] = m.rhs or (m.callback and "<callback>") or ""
  end
  return seen, bufnr
end

describe("lvim.lsp.buffer_mappings", function()
  before_each(function()
    require("lvim.config").load_defaults()
  end)

  it("registers the documented default set buffer-locally", function()
    local seen = attach_to_scratch()
    for _, lhs in ipairs({ "gd", "gD", "gr", "gI", "gs", "gl", "K" }) do
      assert.is_not_nil(seen[lhs], "expected default mapping " .. lhs)
    end

    -- The two leader bindings are resolved by Neovim against `vim.g.mapleader`
    -- at map-creation time, so their stored LHS depends on the leader in force.
    -- This harness does not run `core.keymaps.setup()` (which pins the leader
    -- from `lvim.leader`), so derive the prefix rather than assuming a space.
    local leader = vim.g.mapleader or "\\"
    for _, suffix in ipairs({ "la", "lr" }) do
      assert.is_not_nil(seen[leader .. suffix], "expected default mapping <leader>" .. suffix)
    end
  end)

  it("lets a user retarget a single key without replacing on_attach", function()
    _G.lvim.lsp.buffer_mappings.normal_mode["gd"] =
      { "<cmd>Telescope lsp_definitions<cr>", "Goto definition (telescope)" }

    local seen = attach_to_scratch()
    assert.is_truthy(seen["gd"]:find("Telescope lsp_definitions", 1, true))
    -- Siblings are untouched.
    assert.is_not_nil(seen["gr"])
    assert.is_not_nil(seen["K"])
  end)

  it("removes a key set to false", function()
    _G.lvim.lsp.buffer_mappings.normal_mode["gs"] = false

    local seen = attach_to_scratch()
    assert.is_nil(seen["gs"])
    assert.is_not_nil(seen["gd"])
  end)

  it("removes an already-registered buffer-local map when a second attach sets false", function()
    -- Two servers attaching to one buffer re-runs on_attach. If the user
    -- flipped a key off between attaches, the stale mapping must go.
    local bufnr = vim.api.nvim_create_buf(false, true)
    local on_attach = require("lvim.lsp.handlers").make_on_attach()
    on_attach(nil, bufnr)

    _G.lvim.lsp.buffer_mappings.normal_mode["gI"] = false
    on_attach(nil, bufnr)

    local seen = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      seen[m.lhs] = true
    end
    assert.is_nil(seen["gI"])
  end)

  it("supports adding a mapping in another mode", function()
    _G.lvim.lsp.buffer_mappings.insert_mode["<C-s>"] = { "<cmd>lua vim.lsp.buf.signature_help()<cr>", "Signature help" }

    local bufnr = vim.api.nvim_create_buf(false, true)
    require("lvim.lsp.handlers").make_on_attach()(nil, bufnr)

    local seen = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "i")) do
      seen[m.lhs] = true
    end
    assert.is_true(seen["<C-S>"] == true or seen["<C-s>"] == true)
  end)

  it("accepts a bare string as the rhs", function()
    _G.lvim.lsp.buffer_mappings.normal_mode["gr"] = "<cmd>Telescope lsp_references<cr>"

    local seen = attach_to_scratch()
    assert.is_truthy(seen["gr"]:find("Telescope lsp_references", 1, true))
  end)
end)

describe("lvim.lsp capabilities", function()
  before_each(function()
    require("lvim.config").load_defaults()
  end)

  after_each(function()
    package.loaded["blink.cmp"] = nil
  end)

  it("folds blink.cmp's capabilities in when blink is available", function()
    package.loaded["blink.cmp"] = {
      get_lsp_capabilities = function()
        return { textDocument = { completion = { __lvim_blink_marker = true } } }
      end,
    }

    local caps = require("lvim.lsp.handlers").make_capabilities()
    assert.is_true(caps.textDocument.completion.__lvim_blink_marker == true)
  end)

  it("falls back to plain protocol capabilities when blink is absent", function()
    package.loaded["blink.cmp"] = nil

    local caps = require("lvim.lsp.handlers").make_capabilities()
    assert.is_table(caps.textDocument)
    assert.is_nil(caps.textDocument.completion and caps.textDocument.completion.__lvim_blink_marker)
  end)
end)

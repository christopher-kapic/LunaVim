-- Phase 5.2: seed `require('mini.comment').setup(opts)` with a treesitter-aware
-- `hooks.pre` callback. The hook inspects the treesitter node at the action's
-- reference position so that toggling a comment inside a JSX/TSX node uses the
-- `{/* ... */}` form. JSX is not an injected language inside the `tsx`
-- grammar — it's a set of node types — so the correct API is
-- `vim.treesitter.get_node({ pos = ... }):type()`, not
-- `parser:language_for_range` (which only sees injected child trees).
--
-- On a tsx/jsx buffer with treesitter available the hook ALWAYS rewrites
-- `commentstring` on every toggle (the JSX form when in a JSX node, or
-- back to the standard `// %s` when not). Without this round-trip a
-- previous toggle in a JSX region would leave `{/* %s */}` stuck on the
-- buffer; the next toggle in a non-JSX region (a function body, the
-- imports block) would then comment the line with `{/*...*/}` even though
-- it's regular TS/JS.
--
-- When no treesitter parser is available (typical under
-- `install.missing = false` before parsers are installed) we fall back to a
-- filetype lookup so `typescriptreact` / `javascriptreact` buffers still get
-- the JSX commentstring. In that fallback the hook cannot tell JSX from
-- non-JSX regions, so it sets the JSX form unconditionally on the tsx/jsx
-- filetypes — the right default for a fresh install before
-- `:LvimSyncCorePlugins` has fetched the tsx parser. Phase 6 layers the
-- user-facing toggle surface (`lvim.builtin.comment`) on top of this seed.
local M = {}

local JSX_COMMENTSTRING = "{/* %s */}"
-- The standard TypeScript/JavaScript commentstring used for non-JSX regions of
-- a tsx/jsx buffer. Restoring this on non-JSX nodes prevents the JSX form from
-- sticking after the cursor leaves the JSX region.
local TS_COMMENTSTRING = "// %s"

-- Filetypes whose outer language is JSX/TSX. When treesitter cannot answer
-- (parser not installed) we still flip commentstring for these so users on a
-- fresh install get the right behavior immediately.
local JSX_FILETYPES = {
  typescriptreact = true,
  javascriptreact = true,
}

-- Treesitter node types that indicate a JSX/TSX expression context. Walking
-- up from the cursor node and checking against this set lets us detect JSX
-- even when the cursor is on a leaf (e.g. a string or identifier) inside the
-- JSX element rather than on the element node itself.
local JSX_NODE_TYPES = {
  jsx_element = true,
  jsx_fragment = true,
  jsx_self_closing_element = true,
  jsx_opening_element = true,
  jsx_closing_element = true,
  jsx_attribute = true,
  jsx_expression = true,
  jsx_text = true,
}

local function is_jsx_node(node)
  while node do
    if JSX_NODE_TYPES[node:type()] then
      return true
    end
    node = node:parent()
  end
  return false
end

-- Resolve the action's reference position. mini.comment passes
-- `opts.ref_position = { row, col }` (1-indexed in BOTH dimensions; see
-- `MiniComment.get_commentstring` which subtracts 1 from each) so we drop one
-- from each to get the 0-indexed `pos` that `vim.treesitter.get_node` expects.
-- Fall back to the window cursor (row 1-indexed, col 0-indexed, per the
-- `nvim_win_get_cursor` contract) for completeness.
local function ref_position_zero_indexed(opts)
  local rp = opts and opts.ref_position
  if type(rp) == "table" and type(rp[1]) == "number" and type(rp[2]) == "number" then
    local row = rp[1] - 1
    if row < 0 then row = 0 end
    local col = rp[2] - 1
    if col < 0 then col = 0 end
    return row, col
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok or type(cursor) ~= "table" then
    return nil
  end
  local row = cursor[1] - 1
  if row < 0 then row = 0 end
  local col = cursor[2]
  if col < 0 then col = 0 end
  return row, col
end

local function pre_hook(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local is_jsx_ft = JSX_FILETYPES[vim.bo[bufnr].filetype] == true

  -- When treesitter returns a node, trust it exclusively. The treatment of a
  -- non-JSX node differs by filetype:
  --   * tsx/jsx buffer  → reset commentstring to `// %s` so a prior JSX
  --     toggle does not leak forward when the cursor has moved into a
  --     regular TS/JS region.
  --   * other buffer    → leave commentstring alone so we never corrupt the
  --     user's pre-existing commentstring on non-JSX filetypes (lua,
  --     python, …) that just happened to have a treesitter parser.
  local row, col = ref_position_zero_indexed(opts)
  if row and col then
    local ok_node, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col } })
    if ok_node and node then
      if is_jsx_node(node) then
        vim.bo[bufnr].commentstring = JSX_COMMENTSTRING
      elseif is_jsx_ft then
        vim.bo[bufnr].commentstring = TS_COMMENTSTRING
      end
      return
    end
  end

  -- No treesitter answer (parser not installed yet, or position out of range).
  -- Default tsx/jsx buffers to the JSX commentstring so users get sensible
  -- behavior on a fresh install before `:TSInstall tsx` has run.
  if is_jsx_ft then
    vim.bo[bufnr].commentstring = JSX_COMMENTSTRING
  end
end

function M.setup(_)
  local builtin = (_G.lvim and _G.lvim.builtin and _G.lvim.builtin.comment) or {}
  local options = vim.deepcopy(builtin.options or {})

  local ok, mini_comment = pcall(require, "mini.comment")
  if not ok then
    return
  end

  mini_comment.setup({
    options = options,
    hooks = { pre = pre_hook },
  })
end

return M

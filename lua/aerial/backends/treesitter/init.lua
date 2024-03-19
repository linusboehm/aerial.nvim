local backends = require("aerial.backends")
local config = require("aerial.config")
local helpers = require("aerial.backends.treesitter.helpers")
local util = require("aerial.backends.util")

local M = {}

-- Custom capture groups:
-- symbol: Used to determine to unique node that represents the symbol
-- name (optional): The text of this node will be used in the display
-- start (optional): The location of the start of this symbol (default @symbol)
-- end (optional): The location of the end of this symbol (default @start)

M.is_supported = function(bufnr)
  if vim.fn.has("nvim-0.9") == 0 and not pcall(require, "nvim-treesitter") then
    return false, "Neovim <0.9 requires nvim-treesitter"
  end
  local lang = helpers.get_buf_lang(bufnr)
  if not helpers.has_parser(lang) then
    return false, string.format("No treesitter parser for %s", lang)
  end
  if helpers.get_query(lang) == nil then
    return false, string.format("No queries defined for '%s'", lang)
  end
  return true, nil
end

local function dump(o, indent)
  indent = indent or ""
  if o == nil then
    return ""
  end
  if indent == "     " then
    return "abort"
  end
  for key, value in pairs(o) do
    if type(value) == "table" then
      print(indent .. tostring(key) .. ": ")
      dump(value, indent .. " ")
    else
      print(indent .. tostring(key) .. ": " .. tostring(value))
    end
  end
end

function FindTokens(tokens)
  -- Get the total number of lines in the current buffer
  local ret_lines = {}
  local ret_tokens = {}
  local line_count = vim.api.nvim_buf_line_count(0)
  for curr_line = 1, line_count do
    local line = vim.api.nvim_buf_get_lines(0, curr_line - 1, curr_line, false)[1]
    for _, v in ipairs(tokens) do
      if string.match(line, "^%s*" .. v .. ":") then
        table.insert(ret_lines, curr_line)
        table.insert(ret_tokens, v)
      end
    end
  end
  return ret_lines, ret_tokens
end

local function InsertItem(stack, symbol_node, items, item)
  if item.parent then
    if not item.parent.children then
      item.parent.children = {}
    end
    table.insert(item.parent.children, item)
  else
    table.insert(items, item)
  end
  table.insert(stack, { node = symbol_node, item = item })
end

local function AddCustomToken(stack, symbol_node, items, curr_class, curr_line, acc_spec)
  local acc_range = {
    lnum = curr_line,
    end_lnum = curr_line,
    col = 1,
    end_col = 1,
  }
  ---@type aerial.Symbol
  local acc_spec_sym = {
    kind = "Enum",
    name = acc_spec,
    level = curr_class["level"] + 1,
    parent = curr_class,
    selection_range = acc_range,
    scope = nil,
  }
  for k, v in pairs(acc_range) do
    acc_spec_sym[k] = v
  end
  InsertItem(stack, symbol_node, items, acc_spec_sym)
end

M.fetch_symbols_sync = function(bufnr)
  local token_lines, tokens = FindTokens({ "public", "private", "protected" })
  local last_sym_node = {}
  local classes = {}
  bufnr = bufnr or 0
  local extensions = require("aerial.backends.treesitter.extensions")
  local get_node_text = vim.treesitter.get_node_text
  local include_kind = config.get_filter_kind_map(bufnr)
  local parser = helpers.get_parser(bufnr)
  local items = {}
  if not parser then
    backends.set_symbols(bufnr, items, { backend_name = "treesitter", lang = "unknown" })
    return
  end
  local lang = parser:lang()
  local syntax_tree = parser:parse()[1]
  local query = helpers.get_query(lang)
  if not query or not syntax_tree then
    backends.set_symbols(
      bufnr,
      items,
      { backend_name = "treesitter", lang = lang, syntax_tree = syntax_tree }
    )
    return
  end
  -- This will track a loose hierarchy of recent node+items.
  -- It is used to determine node parents for the tree structure.
  local stack = {}
  local ext = extensions[lang]
  ---@diagnostic disable-next-line: missing-parameter
  for _, matches, metadata in query:iter_matches(syntax_tree:root(), bufnr) do
    ---@note mimic nvim-treesitter's query.iter_group_results return values:
    --       {
    --         kind = "Method",
    --         name = {
    --           metadata = {
    --             range = { 2, 11, 2, 20 }
    --           },
    --           node = <userdata 1>
    --         },
    --         type = {
    --           node = <userdata 2>
    --         }
    --       }
    --- Matches can overlap. The last match wins.
    local match = vim.tbl_extend("force", {}, metadata)
    for id, node in pairs(matches) do
      -- iter_group_results prefers `#set!` metadata, keeping the behaviour
      match = vim.tbl_extend("keep", match, {
        [query.captures[id]] = {
          metadata = metadata[id],
          node = node,
        },
      })
    end

    local name_match = match.name or {}
    local selection_match = match.selection or {}
    local symbol_node = (match.symbol or match.type or {}).node
    -- The location capture groups are optional. We default to the
    -- location of the @symbol capture
    local start_node = (match.start or {}).node or symbol_node
    local end_node = (match["end"] or {}).node or start_node
    local parent_item, parent_node, level = ext.get_parent(stack, match, symbol_node)
    -- Sometimes our queries will match the same node twice.
    -- Detect that (symbol_node == parent_node), and skip dupes.
    if not symbol_node or symbol_node == parent_node then
      goto continue
    end
    local kind = match.kind
    if not kind then
      vim.api.nvim_err_writeln(
        string.format("Missing 'kind' metadata in query file for language %s", lang)
      )
      break
    elseif not vim.lsp.protocol.SymbolKind[kind] then
      vim.api.nvim_err_writeln(
        string.format("Invalid 'kind' metadata '%s' in query file for language %s", kind, lang)
      )
      break
    end
    local range = helpers.range_from_nodes(start_node, end_node)
    local selection_range
    if selection_match.node then
      selection_range = helpers.range_from_nodes(selection_match.node, selection_match.node)
    end
    local name
    if name_match.node then
      name = get_node_text(name_match.node, bufnr, name_match) or "<parse error>"
      if not selection_range then
        selection_range = helpers.range_from_nodes(name_match.node, name_match.node)
      end
    else
      name = "<Anonymous>"
    end
    local scope
    if match.scope and match.scope.node then -- we've got a node capture on our hands
      scope = get_node_text(match.scope.node, bufnr, match.scope)
    else
      scope = match.scope
    end
    ---@type aerial.Symbol
    local item = {
      kind = kind,
      name = name,
      level = level,
      parent = parent_item,
      selection_range = selection_range,
      scope = scope,
    }
    for k, v in pairs(range) do
      item[k] = v
    end
    if ext.postprocess(bufnr, item, match) == false or not include_kind[item.kind] then
      goto continue
    end
    local ctx = {
      backend_name = "treesitter",
      lang = lang,
      syntax_tree = syntax_tree,
      match = match,
    }
    if config.post_parse_symbol and config.post_parse_symbol(bufnr, item, ctx) == false then
      goto continue
    end

    local added = {}

    for idx, curr_line in ipairs(token_lines) do
      -- remove all classes from list that are passed
      while #classes > 1 and curr_line > classes[#classes]["end_lnum"] do
        table.remove(classes)
      end
      -- stop if nor more classes or at current item
      if #classes == 0 or curr_line >= item["lnum"] then
        break
      end
      -- add access specifier if its before the end of last seen class
      if curr_line < classes[#classes]["end_lnum"] then
        AddCustomToken(stack, symbol_node, items, classes[#classes], curr_line, tokens[idx])
        table.insert(added, idx)
      end
    end

    if item["kind"] == "Class" or item["kind"] == "Struct" then
      table.insert(classes, item)
    end

    for i = #added, 1, -1 do
      local idx = added[i]
      table.remove(tokens, idx)
      table.remove(token_lines, idx)
    end

    InsertItem(stack, symbol_node, items, item)
    last_sym_node = symbol_node

    ::continue::
  end

  for idx, curr_line in ipairs(token_lines) do
    AddCustomToken(stack, last_sym_node, items, classes[#classes], curr_line, tokens[idx])
  end

  ext.postprocess_symbols(bufnr, items)
  backends.set_symbols(
    bufnr,
    items,
    { backend_name = "treesitter", lang = lang, syntax_tree = syntax_tree }
  )
end

M.fetch_symbols = M.fetch_symbols_sync

M.attach = function(bufnr)
  util.add_change_watcher(bufnr, "treesitter")
end

M.detach = function(bufnr)
  util.remove_change_watcher(bufnr, "treesitter")
end

return M

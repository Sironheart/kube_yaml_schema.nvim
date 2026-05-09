local kubectl = require("kube_yaml_schema.kubectl")
local parser = require("kube_yaml_schema.parser")
local state = require("kube_yaml_schema.state")
local util = require("kube_yaml_schema.util")

local M = {}

local SOURCE_NAME = "kube-yaml-schema"
local USER_DATA_SOURCE = "kube_yaml_schema"
local FALLBACK_OMNIFUNC = "v:lua.kube_yaml_schema_omnifunc"

---@type table<string, boolean>
local KUBERNETES_FIELDS = {
  apiVersion = true,
  kind = true,
}

---@param resource KubeYamlSchemaResource
---@return string
local function api_version(resource)
  if resource.group == "" then
    return resource.version
  end

  return string.format("%s/%s", resource.group, resource.version)
end

---@param list string[]
---@param value string
---@return nil
local function append_unique(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return
    end
  end

  table.insert(list, value)
end

---@param map table<string, string>
---@return string[]
local function sorted_keys(map)
  local keys = {}
  for key in pairs(map) do
    table.insert(keys, key)
  end

  table.sort(keys)
  return keys
end

---@param line string
---@return boolean
local function is_document_separator(line)
  return line:match("^%s*%-%-%-%s*$") ~= nil
end

---@param line string
---@return boolean
local function is_ignored_line(line)
  return line:match("^%s*$") ~= nil or line:match("^%s*#") ~= nil
end

---@param line string
---@return integer?
local function mapping_indent(line)
  local indent = line:match("^(%s*)[%a_][%w_]*%s*:%s*")
  return indent and #indent or nil
end

---@param bufnr integer
---@param row integer
---@return string[], integer, integer
local function document_lines(bufnr, row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local start_row = 0
  local end_row = #lines - 1

  for index = row, 0, -1 do
    if is_document_separator(lines[index + 1] or "") then
      start_row = index + 1
      break
    end
  end

  for index = row + 1, #lines - 1 do
    if is_document_separator(lines[index + 1] or "") then
      end_row = index - 1
      break
    end
  end

  return lines, start_row, end_row
end

---@param lines string[]
---@param start_row integer
---@param end_row integer
---@param fallback_indent integer
---@return integer
local function document_root_indent(lines, start_row, end_row, fallback_indent)
  for index = start_row, end_row do
    local line = lines[index + 1] or ""
    if not is_ignored_line(line) then
      local indent = mapping_indent(line)
      if indent then
        return indent
      end
    end
  end

  return fallback_indent
end

---@param lines string[]
---@param start_row integer
---@param end_row integer
---@param root_indent integer
---@return table<string, string>
local function document_field_values(lines, start_row, end_row, root_indent)
  local values = {}

  for index = start_row, end_row do
    local indent, key, raw = (lines[index + 1] or ""):match("^(%s*)([%a_][%w_]*)%s*:%s*(.-)%s*$")
    if KUBERNETES_FIELDS[key] and #indent == root_indent then
      local value = parser.parse_field_value(raw)
      if value then
        values[key] = value
      end
    end
  end

  return values
end

---@param ctx KubeYamlSchemaCompletionContext
---@param label string
---@param insert_text string
---@param kind integer
---@param detail string
---@param additional_text_edits lsp.TextEdit[]?
---@return lsp.CompletionItem
local function completion_item(ctx, label, insert_text, kind, detail, additional_text_edits)
  local item = {
    label = label,
    insertText = insert_text,
    insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
    kind = kind,
    detail = detail,
    sortText = label,
    textEdit = {
      newText = insert_text,
      range = {
        start = {
          line = ctx.row,
          character = ctx.start_col,
        },
        ["end"] = {
          line = ctx.row,
          character = ctx.end_col,
        },
      },
    },
  }

  if additional_text_edits and #additional_text_edits > 0 then
    item.additionalTextEdits = additional_text_edits
  end

  return item
end

---@param ctx KubeYamlSchemaCompletionContext
---@param api_version_value string?
---@return lsp.TextEdit[]?
local function api_version_insert_edits(ctx, api_version_value)
  if ctx.document.apiVersion or not api_version_value or api_version_value == "" then
    return nil
  end

  local line = vim.api.nvim_buf_get_lines(ctx.bufnr, ctx.row, ctx.row + 1, false)[1] or ""
  local indent = line:match("^(%s*)") or ""

  return {
    {
      newText = string.format("%sapiVersion: %s\n", indent, api_version_value),
      range = {
        start = {
          line = ctx.row,
          character = 0,
        },
        ["end"] = {
          line = ctx.row,
          character = 0,
        },
      },
    },
  }
end

---@param items lsp.CompletionItem[]
---@param prefix string
---@return lsp.CompletionItem[]
local function filter_items(items, prefix)
  if prefix == "" then
    return items
  end

  local filtered = {}
  local lower_prefix = prefix:lower()
  for _, item in ipairs(items) do
    if item.label:lower():find(lower_prefix, 1, true) == 1 then
      table.insert(filtered, item)
    end
  end

  return filtered
end

---@param bufnr integer
---@return boolean
function M.is_available(bufnr)
  return state.opts.context_completion and vim.api.nvim_buf_is_valid(bufnr) and util.is_yaml_filetype(bufnr)
end

---@param bufnr integer
---@param row integer
---@param col integer
---@return KubeYamlSchemaCompletionContext?
function M.context_for_position(bufnr, row, col)
  if not M.is_available(bufnr) then
    return nil
  end

  local lines, start_row, end_row = document_lines(bufnr, row)
  local line = lines[row + 1] or ""
  col = math.min(col, #line)

  local before_cursor = line:sub(1, col)
  local indent = before_cursor:match("^(%s*)") or ""
  local root_indent = document_root_indent(lines, start_row, end_row, #indent)
  if #indent ~= root_indent then
    return nil
  end

  local field_indent, field = before_cursor:match("^(%s*)([%a_][%w_]*)%s*:%s*.-$")
  if KUBERNETES_FIELDS[field] and #field_indent == root_indent then
    local _, value_start_col = before_cursor:find(":%s*")
    value_start_col = value_start_col or col

    local values = document_field_values(lines, start_row, end_row, root_indent)
    values[field] = nil

    return {
      type = "value",
      bufnr = bufnr,
      row = row,
      start_col = value_start_col,
      end_col = col,
      prefix = before_cursor:sub(value_start_col + 1),
      field = field,
      document = values,
    }
  end

  local key_indent, prefix = before_cursor:match("^(%s*)([%a_]*)$")
  if prefix and #key_indent == root_indent then
    return {
      type = "key",
      bufnr = bufnr,
      row = row,
      start_col = #key_indent,
      end_col = col,
      prefix = prefix,
      document = document_field_values(lines, start_row, end_row, root_indent),
    }
  end

  return nil
end

---@param ctx KubeYamlSchemaCompletionContext
---@param resources KubeYamlSchemaResource[]?
---@param opts { filter_prefix?: boolean }?
---@return lsp.CompletionItem[]
function M.items_from_context(ctx, resources, opts)
  opts = opts or {}
  local items = {}

  if ctx.type == "key" then
    table.insert(
      items,
      completion_item(
        ctx,
        "apiVersion",
        "apiVersion: ",
        vim.lsp.protocol.CompletionItemKind.Property,
        "Kubernetes apiVersion field"
      )
    )
    table.insert(
      items,
      completion_item(ctx, "kind", "kind: ", vim.lsp.protocol.CompletionItemKind.Property, "Kubernetes kind field")
    )
  elseif ctx.field == "apiVersion" then
    local values = {}
    for _, resource in ipairs(resources or {}) do
      if not ctx.document.kind or resource.kind == ctx.document.kind then
        values[api_version(resource)] = ctx.document.kind or "Kubernetes apiVersion"
      end
    end

    for _, value in ipairs(sorted_keys(values)) do
      table.insert(
        items,
        completion_item(ctx, value, value, vim.lsp.protocol.CompletionItemKind.EnumMember, values[value])
      )
    end
  elseif ctx.field == "kind" then
    local values = {}
    for _, resource in ipairs(resources or {}) do
      local resource_api_version = api_version(resource)
      if not ctx.document.apiVersion or resource_api_version == ctx.document.apiVersion then
        local existing = values[resource.kind]
        if existing then
          append_unique(existing, resource_api_version)
        else
          values[resource.kind] = { resource_api_version }
        end
      end
    end

    for _, value in ipairs(sorted_keys(values)) do
      table.sort(values[value])
      table.insert(
        items,
        completion_item(
          ctx,
          value,
          value,
          vim.lsp.protocol.CompletionItemKind.Class,
          table.concat(values[value], ", "),
          api_version_insert_edits(ctx, values[value][1])
        )
      )
    end
  end

  if opts.filter_prefix then
    return filter_items(items, ctx.prefix or "")
  end

  return items
end

---@param bufnr integer
---@return nil
function M.refresh(bufnr)
  if not M.is_available(bufnr) then
    state.completion_resources[bufnr] = nil
    return
  end

  kubectl.get_active_target(function(target)
    if not target or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    kubectl.get_api_resources(target, function(resources)
      if resources and vim.api.nvim_buf_is_valid(bufnr) then
        state.completion_resources[bufnr] = resources
      end
    end)
  end)
end

---@param bufnr integer
---@param row integer
---@param col integer
---@param callback fun(items: lsp.CompletionItem[])
---@return function
function M.get_lsp_items(bufnr, row, col, callback)
  local ctx = M.context_for_position(bufnr, row, col)
  if not ctx then
    callback({})
    return function() end
  end

  if ctx.type == "key" then
    callback(M.items_from_context(ctx, nil))
    return function() end
  end

  local cancelled = false
  kubectl.get_active_target(function(target)
    if cancelled or not target then
      callback({})
      return
    end

    kubectl.get_api_resources(target, function(resources)
      if cancelled then
        return
      end

      callback(M.items_from_context(ctx, resources))
    end)
  end)

  return function()
    cancelled = true
  end
end

---@param bufnr integer
---@param row integer
---@param col integer
---@return lsp.CompletionItem[]
function M.get_cached_lsp_items(bufnr, row, col)
  local ctx = M.context_for_position(bufnr, row, col)
  if not ctx then
    return {}
  end

  if ctx.type == "key" then
    return M.items_from_context(ctx, nil, { filter_prefix = true })
  end

  local resources = state.completion_resources[bufnr]
  if not resources then
    M.refresh(bufnr)
    return {}
  end

  return M.items_from_context(ctx, resources, { filter_prefix = true })
end

---@param item lsp.CompletionItem
---@return table
local function vim_complete_item(item)
  local complete_item = {
    word = item.textEdit and item.textEdit.newText or item.insertText or item.label,
    abbr = item.label,
    menu = "[kube]",
    kind = "v",
    info = item.detail,
  }

  if item.additionalTextEdits and #item.additionalTextEdits > 0 then
    complete_item.user_data = vim.json.encode({
      source = USER_DATA_SOURCE,
      additionalTextEdits = item.additionalTextEdits,
    })
  end

  return complete_item
end

---@param item table?
---@return table?
local function complete_item_user_data(item)
  local user_data = item and item.user_data or nil
  if type(user_data) == "table" then
    return user_data
  end

  if type(user_data) ~= "string" or user_data == "" then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, user_data)
  if not ok or type(decoded) ~= "table" then
    return nil
  end

  return decoded
end

---@param item table?
---@param bufnr integer?
---@return nil
function M.apply_complete_done_item(item, bufnr)
  if not state.opts.context_completion then
    return
  end

  local user_data = complete_item_user_data(item)
  if not user_data or user_data.source ~= USER_DATA_SOURCE or type(user_data.additionalTextEdits) ~= "table" then
    return
  end

  vim.lsp.util.apply_text_edits(user_data.additionalTextEdits, bufnr or vim.api.nvim_get_current_buf(), "utf-16")
end

---@return nil
local function register_default_completion_autocmd()
  if state.completion_client_registered.default then
    return
  end

  state.completion_client_registered.default = true
  local group = vim.api.nvim_create_augroup("kube-yaml-schema-completion", { clear = true })
  vim.api.nvim_create_autocmd("CompleteDone", {
    group = group,
    callback = function()
      M.apply_complete_done_item(vim.v.completed_item)
    end,
  })
end

---@param bufnr integer
---@param findstart integer
---@param base string
---@return any
local function call_previous_omnifunc(bufnr, findstart, base)
  local previous = state.default_omnifuncs[bufnr]
  if type(previous) ~= "string" or previous == "" or previous == FALLBACK_OMNIFUNC then
    return findstart == 1 and -3 or {}
  end

  if previous:find("^v:lua%.") then
    local chunk = loadstring("return " .. previous:sub(7))
    if chunk then
      local ok, fn = pcall(chunk)
      if ok and type(fn) == "function" then
        local call_ok, result = pcall(fn, findstart, base)
        if call_ok then
          return result
        end
      end
    end

    return findstart == 1 and -3 or {}
  end

  local ok, result = pcall(vim.fn.call, previous, { findstart, base })
  if ok then
    return result
  end

  return findstart == 1 and -3 or {}
end

---@param findstart integer
---@param base string
---@return any
function M.omnifunc(findstart, base)
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]

  if findstart == 1 then
    local ctx = M.context_for_position(bufnr, row, col)
    state.default_completion_contexts[bufnr] = ctx
    if ctx then
      return ctx.start_col
    end

    return call_previous_omnifunc(bufnr, findstart, base)
  end

  local ctx = state.default_completion_contexts[bufnr]
  if not ctx then
    return call_previous_omnifunc(bufnr, findstart, base)
  end

  local items = {}
  for _, item in ipairs(M.get_cached_lsp_items(bufnr, ctx.row, ctx.end_col)) do
    table.insert(items, vim_complete_item(item))
  end

  return items
end

---@param bufnr integer
---@return nil
function M.install_default_completion(bufnr)
  if not M.is_available(bufnr) then
    return
  end

  local register = loadstring([[
    kube_yaml_schema_omnifunc = function(findstart, base)
      return require("kube_yaml_schema.completion").omnifunc(findstart, base)
    end
  ]])
  if register then
    register()
  end

  local current = vim.bo[bufnr].omnifunc
  if current ~= FALLBACK_OMNIFUNC then
    state.default_omnifuncs[bufnr] = current
    vim.bo[bufnr].omnifunc = FALLBACK_OMNIFUNC
  end
end

---@return boolean
function M.register_blink()
  if state.completion_client_registered.blink then
    return true
  end

  local ok, blink = pcall(require, "blink.cmp")
  if not ok or type(blink) ~= "table" then
    return false
  end

  local registered = false
  if type(blink.add_source_provider) == "function" then
    registered = pcall(blink.add_source_provider, "kube_yaml_schema", {
      name = SOURCE_NAME,
      module = "kube_yaml_schema.completion.blink",
      score_offset = 50,
    }) or registered
  end

  if type(blink.add_filetype_source) == "function" then
    registered = pcall(blink.add_filetype_source, "yaml", "kube_yaml_schema") or registered
    registered = pcall(blink.add_filetype_source, "yml", "kube_yaml_schema") or registered
  end

  state.completion_client_registered.blink = registered
  return registered
end

---@return nil
function M.register_coq()
  if state.completion_client_registered.coq then
    return
  end

  local register = loadstring([[
    return function(source_name)
      COQsources = COQsources or {}
      COQsources.kube_yaml_schema = {
        name = source_name,
        fn = function(args, callback)
          return require("kube_yaml_schema.completion").coq_source(args, callback)
        end,
      }
    end
  ]])

  if register then
    register()(SOURCE_NAME)
  end

  state.completion_client_registered.coq = true
end

---@param args table?
---@param callback fun(response: table)
---@return function
function M.coq_source(args, callback)
  local pos = args and args.pos or nil
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = pos and pos[1] or (cursor[1] - 1)
  local col = pos and pos[2] or cursor[2]
  local bufnr = args and args.bufnr or vim.api.nvim_get_current_buf()

  return M.get_lsp_items(bufnr, row, col, function(items)
    callback({
      isIncomplete = true,
      items = items,
    })
  end)
end

---@param bufnr integer
---@return nil
function M.setup_buffer(bufnr)
  M.refresh(bufnr)
  M.install_default_completion(bufnr)
end

---@param bufnr integer
---@return nil
function M.clear_buffer(bufnr)
  state.completion_resources[bufnr] = nil
  state.default_completion_contexts[bufnr] = nil
  state.default_omnifuncs[bufnr] = nil
end

---@return nil
function M.setup()
  if not state.opts.context_completion then
    return
  end

  register_default_completion_autocmd()
  M.register_blink()
  M.register_coq()
end

return M

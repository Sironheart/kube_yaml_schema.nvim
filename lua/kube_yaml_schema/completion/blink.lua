local completion = require("kube_yaml_schema.completion")

local M = {}

---@param opts table?
---@return table
function M.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = M })
end

---@return boolean
function M:enabled()
  return completion.is_available(vim.api.nvim_get_current_buf())
end

---@return string[]
function M:get_trigger_characters()
  return { ":", " " }
end

---@param _ctx table
---@param callback fun(response: table)
---@return function
function M:get_completions(_ctx, callback)
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)

  return completion.get_lsp_items(bufnr, cursor[1] - 1, cursor[2], function(items)
    callback({
      items = items,
      is_incomplete_backward = true,
      is_incomplete_forward = true,
    })
  end)
end

return M

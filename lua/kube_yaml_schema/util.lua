local state = require("kube_yaml_schema.state")

local M = {}

---@param ... string
---@return string
function M.path_join(...)
  return table.concat({ ... }, "/")
end

---@param value string?
---@return string
function M.sanitize_filename(value)
  return (value or ""):gsub("[^%w%._%-]", "_")
end

---@param level integer
---@param message string
---@return nil
function M.notify(level, message)
  if not state.opts.notify then
    return
  end

  vim.notify(message, level, { title = "kube-yaml-schema" })
end

---@param bufnr integer
---@return boolean
function M.is_yaml_filetype(bufnr)
  local filetype = vim.bo[bufnr].filetype
  return filetype == "yaml" or filetype:match("^yaml") ~= nil
end

return M

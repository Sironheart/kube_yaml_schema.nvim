local constants = require("kube_yaml_schema.constants")

local M = {}

---@param resource KubeYamlSchemaResource
---@return string
function M.format_resource(resource)
  local api_version = resource.version
  if resource.group ~= "" then
    api_version = string.format("%s/%s", resource.group, resource.version)
  end

  return string.format("%s %s", api_version, resource.kind)
end

---@param api_version string
---@param kind string
---@return KubeYamlSchemaResource
local function build_resource(api_version, kind)
  local group, version = M.parse_api_version(api_version)
  return {
    group = group,
    version = version,
    kind = kind,
    core = constants.core_api_groups[group] == true,
  }
end

---@param resources KubeYamlSchemaResource[]
---@param current { kind?: string, api_version?: string }
---@return nil
local function append_resource(resources, current)
  if current.kind and current.api_version then
    table.insert(resources, build_resource(current.api_version, current.kind))
  end
end

---@param raw string?
---@return string?
local function parse_value(raw)
  if not raw then
    return nil
  end

  local value = vim.trim(raw)
  value = value:gsub("%s+#.*$", "")
  value = vim.trim(value)

  if value == "" then
    return nil
  end

  local quote = value:sub(1, 1)
  if (quote == '"' or quote == "'") and value:sub(-1) == quote then
    value = value:sub(2, -2)
  end

  if value:find("{{", 1, true) then
    return nil
  end

  return value
end

---@param api_version string?
---@return string, string
function M.parse_api_version(api_version)
  if not api_version or api_version == "" then
    return "", ""
  end

  local group, version = api_version:match("^([^/]+)/(.+)$")
  if group and version then
    return group, version
  end

  return "", api_version
end

---@param resources KubeYamlSchemaResource[]?
---@param max_items integer?
---@return string?
function M.summarize_resources(resources, max_items)
  if type(resources) ~= "table" or #resources == 0 then
    return nil
  end

  max_items = max_items or 5

  local formatted = {}
  for index, resource in ipairs(resources) do
    if index > max_items then
      break
    end

    table.insert(formatted, M.format_resource(resource))
  end

  if #resources > max_items then
    table.insert(formatted, string.format("+%d more", #resources - max_items))
  end

  local noun = #resources == 1 and "resource" or "resources"
  return string.format("detected %d %s: %s", #resources, noun, table.concat(formatted, ", "))
end

---@param bufnr integer
---@return KubeYamlSchemaResource[]
function M.parse_kubernetes_resources(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  ---@type KubeYamlSchemaResource[]
  local resources = {}
  ---@type { kind?: string, api_version?: string }
  local current = {}
  local root_indent = nil

  ---@return nil
  local function flush_document()
    append_resource(resources, current)
    current = {}
    root_indent = nil
  end

  for _, line in ipairs(lines) do
    if line:match("^%s*%-%-%-%s*$") then
      flush_document()
    else
      if root_indent == nil and not line:match("^%s*$") and not line:match("^%s*#") then
        local indent = line:match("^(%s*)[%a_][%w_]*%s*:%s*")
        if indent then
          root_indent = #indent
        end
      end

      if root_indent ~= nil then
        local kind_indent, kind = line:match("^(%s*)kind%s*:%s*(.-)%s*$")
        if kind and #kind_indent == root_indent and not current.kind then
          current.kind = parse_value(kind)
        end

        local api_indent, api_version = line:match("^(%s*)apiVersion%s*:%s*(.-)%s*$")
        if api_version and #api_indent == root_indent and not current.api_version then
          current.api_version = parse_value(api_version)
        end
      end
    end
  end

  flush_document()

  return resources
end

return M

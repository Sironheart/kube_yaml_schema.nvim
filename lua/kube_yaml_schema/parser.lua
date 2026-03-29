local constants = require("kube_yaml_schema.constants")

local M = {}

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

  if value:sub(1, 1) == '"' and value:sub(-1) == '"' then
    value = value:sub(2, -2)
  elseif value:sub(1, 1) == "'" and value:sub(-1) == "'" then
    value = value:sub(2, -2)
  end

  if value:find("{{", 1, true) then
    return nil
  end

  return value
end

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

function M.parse_kubernetes_resources(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local resources = {}
  local current = {}

  local function flush_resource()
    if current.kind and current.api_version then
      local group, version = M.parse_api_version(current.api_version)
      table.insert(resources, {
        group = group,
        version = version,
        kind = current.kind,
        core = constants.core_api_groups[group] == true,
      })
    end

    current = {}
  end

  for _, line in ipairs(lines) do
    if line:match("^%s*%-%-%-%s*$") then
      flush_resource()
    else
      local kind = parse_value(line:match("^%s*kind%s*:%s*(.-)%s*$"))
      if kind then
        current.kind = kind
      end

      local api_version = parse_value(line:match("^%s*apiVersion%s*:%s*(.-)%s*$"))
      if api_version then
        current.api_version = api_version
      end
    end
  end

  flush_resource()

  return resources
end

return M

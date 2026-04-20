local M = {}
local unpack = unpack or table.unpack

---@type table<string, boolean>
M.core_api_groups = {
  [""] = true,
  ["admissionregistration.k8s.io"] = true,
  ["apiextensions.k8s.io"] = true,
  ["apps"] = true,
  ["autoscaling"] = true,
  ["batch"] = true,
  ["certificates.k8s.io"] = true,
  ["coordination.k8s.io"] = true,
  ["discovery.k8s.io"] = true,
  ["events.k8s.io"] = true,
  ["flowcontrol.apiserver.k8s.io"] = true,
  ["networking.k8s.io"] = true,
  ["node.k8s.io"] = true,
  ["policy"] = true,
  ["rbac.authorization.k8s.io"] = true,
  ["scheduling.k8s.io"] = true,
  ["storage.k8s.io"] = true,
}

---@type KubeYamlSchemaNormalizedOptions
M.defaults = {
  kubectl_bin = "kubectl",
  kubectl_timeout_ms = 5000,
  context = nil,
  auto_refresh = true,
  refresh_events = { "BufEnter", "BufWritePost" },
  notify_on_auto_refresh = false,
  cache_ttl_seconds = 300,
  stale_on_error_seconds = 60,
  cache_dir = vim.fn.stdpath("cache") .. "/kube-yaml-schema",
  schema_store_url = "https://www.schemastore.org/api/json/catalog.json",
  notify = true,
}

---@type table<string, true>
M.option_keys = {
  kubectl_bin = true,
  kubectl_timeout_ms = true,
  context = true,
  auto_refresh = true,
  refresh_events = true,
  notify_on_auto_refresh = true,
  cache_ttl_seconds = true,
  stale_on_error_seconds = true,
  cache_dir = true,
  schema_store_url = true,
  notify = true,
}

---@param path string
---@param spec table<string, table>
---@return boolean, string?
local function validate_path(path, spec)
  for key, rule in pairs(spec) do
    local ok, err = pcall(vim.validate, path .. "." .. key, unpack(rule))
    if not ok then
      return false, err
    end
  end

  return true, nil
end

---@param value any
---@return boolean
local function is_legacy_cache_ttl(value)
  if type(value) ~= "table" then
    return false
  end

  local keys = { "server_version", "crd_index", "context_cluster", "current_context" }
  for _, key in ipairs(keys) do
    local entry = value[key]
    if entry ~= nil and type(entry) ~= "number" then
      return false
    end
  end

  return true
end

---@param value any
---@return boolean
local function is_refresh_events(value)
  if value == nil then
    return true
  end

  if type(value) ~= "table" or not vim.islist(value) then
    return false
  end

  for _, entry in ipairs(value) do
    if type(entry) ~= "string" then
      return false
    end
  end

  return true
end

---@param opts KubeYamlSchemaOptionsInput?
---@return string[]
function M.unknown_option_keys(opts)
  ---@type string[]
  local unknown = {}
  if type(opts) ~= "table" then
    return unknown
  end

  for key in pairs(opts) do
    if not M.option_keys[key] then
      table.insert(unknown, key)
    end
  end

  table.sort(unknown)
  return unknown
end

---@param opts KubeYamlSchemaOptionsInput?
---@param path string?
---@return boolean, string?, string[]
function M.validate_options(opts, path)
  local option_path = path or "kube_yaml_schema.options"
  if opts == nil then
    return true, nil, {}
  end

  if type(opts) ~= "table" then
    return false, string.format("%s: expected table, got %s", option_path, type(opts)), {}
  end

  local valid, err = validate_path(option_path, {
    kubectl_bin = { opts.kubectl_bin, "string", true },
    kubectl_timeout_ms = { opts.kubectl_timeout_ms, "number", true },
    context = { opts.context, "string", true },
    auto_refresh = { opts.auto_refresh, "boolean", true },
    refresh_events = { opts.refresh_events, is_refresh_events, "list of strings" },
    notify_on_auto_refresh = { opts.notify_on_auto_refresh, "boolean", true },
    cache_ttl_seconds = {
      opts.cache_ttl_seconds,
      function(value)
        return value == nil or type(value) == "number" or is_legacy_cache_ttl(value)
      end,
      "number or legacy TTL table",
    },
    stale_on_error_seconds = { opts.stale_on_error_seconds, "number", true },
    cache_dir = { opts.cache_dir, "string", true },
    schema_store_url = { opts.schema_store_url, "string", true },
    notify = { opts.notify, "boolean", true },
  })

  return valid, err, M.unknown_option_keys(opts)
end

---@param opts KubeYamlSchemaOptionsInput?
---@return number
local function parse_cache_ttl(opts)
  local default_ttl = M.defaults.cache_ttl_seconds
  local raw = opts and opts.cache_ttl_seconds or nil

  if type(raw) == "number" then
    return raw
  end

  if type(raw) == "table" then
    local legacy = raw.server_version or raw.crd_index or raw.context_cluster or raw.current_context
    if type(legacy) == "number" then
      return legacy
    end
  end

  return default_ttl
end

---@param opts KubeYamlSchemaOptionsInput?
---@return KubeYamlSchemaNormalizedOptions
function M.normalize_options(opts)
  ---@type KubeYamlSchemaNormalizedOptions
  local normalized = vim.deepcopy(M.defaults)

  if type(opts) ~= "table" then
    return normalized
  end

  if type(opts.kubectl_bin) == "string" and opts.kubectl_bin ~= "" then
    normalized.kubectl_bin = opts.kubectl_bin
  end

  if type(opts.kubectl_timeout_ms) == "number" and opts.kubectl_timeout_ms > 0 then
    normalized.kubectl_timeout_ms = opts.kubectl_timeout_ms
  end

  if type(opts.auto_refresh) == "boolean" then
    normalized.auto_refresh = opts.auto_refresh
  end

  if type(opts.notify_on_auto_refresh) == "boolean" then
    normalized.notify_on_auto_refresh = opts.notify_on_auto_refresh
  end

  if type(opts.notify) == "boolean" then
    normalized.notify = opts.notify
  end

  if type(opts.cache_dir) == "string" and opts.cache_dir ~= "" then
    normalized.cache_dir = opts.cache_dir
  end

  if type(opts.schema_store_url) == "string" and opts.schema_store_url ~= "" then
    normalized.schema_store_url = opts.schema_store_url
  end

  local cache_ttl = parse_cache_ttl(opts)
  if cache_ttl < 0 then
    cache_ttl = M.defaults.cache_ttl_seconds
  end

  normalized.cache_ttl_seconds = cache_ttl

  if type(normalized.stale_on_error_seconds) ~= "number" or normalized.stale_on_error_seconds < 0 then
    normalized.stale_on_error_seconds = M.defaults.stale_on_error_seconds
  end

  if type(opts.stale_on_error_seconds) == "number" and opts.stale_on_error_seconds >= 0 then
    normalized.stale_on_error_seconds = opts.stale_on_error_seconds
  end

  normalized.context = (type(opts.context) == "string" and opts.context ~= "") and opts.context or nil

  if type(opts.refresh_events) == "table" then
    ---@type string[]
    local events = {}
    for _, event in ipairs(opts.refresh_events) do
      if type(event) == "string" and event ~= "" then
        table.insert(events, event)
      end
    end

    if #events > 0 then
      normalized.refresh_events = events
    end
  end

  return normalized
end

return M

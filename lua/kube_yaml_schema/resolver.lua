local cache = require("kube_yaml_schema.cache")
local kubectl = require("kube_yaml_schema.kubectl")
local parser = require("kube_yaml_schema.parser")

local M = {}

---@param version string
---@return string
local function kubernetes_schema_uri(version)
  return string.format(
    "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/%s-standalone-strict/all.json",
    version
  )
end

---@param resource KubeYamlSchemaResource
---@return string
local function api_version(resource)
  if resource.group == "" then
    return resource.version
  end

  return string.format("%s/%s", resource.group, resource.version)
end

---@param resource KubeYamlSchemaResource
---@return string
local function resource_key(resource)
  return string.lower(api_version(resource) .. "|" .. resource.kind)
end

---@param a KubeYamlSchemaResource
---@param b KubeYamlSchemaResource
---@return boolean
local function resource_sort(a, b)
  local a_api_version = api_version(a)
  local b_api_version = api_version(b)

  if a_api_version == b_api_version then
    return a.kind < b.kind
  end

  return a_api_version < b_api_version
end

---@param resources KubeYamlSchemaResource[]
---@return KubeYamlSchemaResource[]
local function dedupe_resources(resources)
  local unique = {}

  for _, resource in ipairs(resources) do
    unique[resource_key(resource)] = resource
  end

  local deduped = vim.tbl_values(unique)
  table.sort(deduped, resource_sort)
  return deduped
end

---@param resource KubeYamlSchemaResource
---@param uri string
---@return table
local function schema_rule(resource, uri)
  return {
    ["if"] = {
      type = "object",
      properties = {
        apiVersion = { const = api_version(resource) },
        kind = { const = resource.kind },
      },
      required = { "apiVersion", "kind" },
    },
    ["then"] = {
      ["$ref"] = uri,
    },
  }
end

---@param entries KubeYamlSchemaResolverEntry[]
---@return string, table
local function compose_schema(entries)
  table.sort(entries, function(a, b)
    if a.rule_key == b.rule_key then
      return a.uri < b.uri
    end

    return a.rule_key < b.rule_key
  end)

  local rules = {}
  local signature = {}

  for _, entry in ipairs(entries) do
    table.insert(rules, schema_rule(entry.resource, entry.uri))
    table.insert(signature, {
      key = entry.rule_key,
      uri = entry.uri,
    })
  end

  local hash = vim.fn.sha256(vim.json.encode(signature))
  local cache_key = "composed-" .. hash
  local schema = {
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
    allOf = rules,
  }

  return cache_key, schema
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

---@param resource KubeYamlSchemaResource
---@param target KubeYamlSchemaTarget
---@param version string?
---@param index KubeYamlSchemaCrdIndex?
---@param errors string[]
---@param persist boolean
---@return KubeYamlSchemaResolverEntry?
local function resolve_resource_entry(resource, target, version, index, errors, persist)
  if resource.core then
    if not version then
      return nil
    end

    return {
      rule_key = resource_key(resource),
      resource = resource,
      uri = kubernetes_schema_uri(version),
      name = "Kubernetes " .. version,
    }
  end

  if not (index and index.by_key) then
    return nil
  end

  local key = string.lower(resource.group .. "|" .. resource.kind)
  local crd_entry = index.by_key[key]
  if not crd_entry then
    return nil
  end

  local schema_body, schema_version = kubectl.pick_crd_schema(crd_entry, resource.version)
  if not (schema_body and schema_version) then
    return nil
  end

  local entry = {
    rule_key = resource_key(resource),
    resource = resource,
    uri = "",
    name = string.format("%s %s/%s", crd_entry.kind, crd_entry.group, schema_version),
  }

  if not persist then
    return entry
  end

  local uri = cache.persist_schema(target.cluster, crd_entry.group, crd_entry.kind, schema_version, schema_body)
  if not uri then
    append_unique(errors, "failed to persist CRD schema to cache")
    return nil
  end

  entry.uri = uri
  return entry
end

---@param resources KubeYamlSchemaResource[]
---@param target KubeYamlSchemaTarget
---@param version string?
---@param index KubeYamlSchemaCrdIndex?
---@param errors string[]
---@param persist boolean
---@return KubeYamlSchemaResolverEntry[]
local function resolve_resource_entries(resources, target, version, index, errors, persist)
  local entries = {}

  for _, resource in ipairs(resources) do
    local entry = resolve_resource_entry(resource, target, version, index, errors, persist)
    if entry then
      table.insert(entries, entry)
    end
  end

  return entries
end

---@param bufnr integer
---@param callback KubeYamlSchemaResolveWaiter
---@return nil
function M.resolve_for_buffer(bufnr, callback)
  local parsed_resources = parser.parse_kubernetes_resources(bufnr)
  local resources = dedupe_resources(parsed_resources)
  if #resources == 0 then
    callback({ reason = "no-kubernetes-resource", resources = parsed_resources }, nil)
    return
  end

  kubectl.get_active_target(function(target, target_err)
    if not target then
      callback({ reason = "context-unavailable", resources = parsed_resources }, target_err)
      return
    end

    local core_count = 0
    local non_core_count = 0
    for _, resource in ipairs(resources) do
      if resource.core then
        core_count = core_count + 1
      else
        non_core_count = non_core_count + 1
      end
    end

    ---@param next KubeYamlSchemaVersionWaiter
    ---@return nil
    local function with_server_version(next)
      if core_count == 0 then
        next(nil, nil)
        return
      end

      kubectl.get_server_version(target, next)
    end

    ---@param next KubeYamlSchemaCrdIndexWaiter
    ---@return nil
    local function with_crd_index(next)
      if non_core_count == 0 then
        next(nil, nil)
        return
      end

      kubectl.get_crd_index(target, next)
    end

    with_server_version(function(version, version_err)
      with_crd_index(function(index, crd_err)
        ---@type string[]
        local errors = {}

        if version_err then
          append_unique(errors, version_err)
        end

        if crd_err then
          append_unique(errors, crd_err)
        end

        local entries = resolve_resource_entries(resources, target, version, index, errors, true)

        if #entries == 0 then
          if #errors > 0 then
            callback({ reason = "resolution-error", resources = parsed_resources }, table.concat(errors, "; "))
          else
            callback({ reason = "no-cluster-schema", resources = parsed_resources }, nil)
          end
          return
        end

        if #entries == 1 then
          callback({
            reason = "single-schema",
            resources = parsed_resources,
            schema = {
              name = entries[1].name,
              uri = entries[1].uri,
            },
          }, nil)
          return
        end

        local cache_key, schema = compose_schema(entries)
        local composed_uri = cache.persist_generated_schema(target.cluster, cache_key, schema)
        if not composed_uri then
          callback(
            { reason = "cache-write-failed", resources = parsed_resources },
            "failed to persist composed schema to cache"
          )
          return
        end

        local schema_name
        if #entries == #resources then
          schema_name = string.format("Kubernetes multi-doc (%d docs)", #entries)
        else
          schema_name = string.format("Kubernetes multi-doc (%d/%d docs)", #entries, #resources)
        end

        callback({
          reason = "multi-document",
          resources = parsed_resources,
          schema = {
            name = schema_name,
            uri = composed_uri,
          },
        }, nil)
      end)
    end)
  end)
end

return M

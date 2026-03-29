local state = require("kube_yaml_schema.state")

local M = {}

---@param client vim.lsp.Client
---@return table<string, any>
local function normalize_base_schemas(client)
  local schemas = ((client.settings or {}).yaml or {}).schemas
  if type(schemas) ~= "table" or vim.islist(schemas) then
    return {}
  end

  return vim.deepcopy(schemas)
end

---@param client vim.lsp.Client
---@param client_state KubeYamlSchemaClientState
---@return nil
local function merge_schema_overrides(client, client_state)
  local merged = vim.deepcopy(client_state.base_schemas)

  for bufnr, override in pairs(client_state.overrides) do
    if vim.api.nvim_buf_is_valid(bufnr) and override and override.uri then
      merged[override.uri] = vim.uri_from_bufnr(bufnr)
    else
      client_state.overrides[bufnr] = nil
    end
  end

  local encoded = vim.json.encode(merged)
  if encoded == client_state.last_applied then
    return
  end

  local settings = vim.tbl_deep_extend("force", vim.deepcopy(client.settings or {}), {
    yaml = {
      schemas = merged,
    },
  })

  client.settings = settings
  client_state.last_applied = encoded
  client:notify("workspace/didChangeConfiguration", { settings = settings })
end

---@param bufnr integer
---@return vim.lsp.Client[]
function M.attached_yamlls_clients(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = "yamlls" })
end

---@param client vim.lsp.Client
---@return KubeYamlSchemaClientState
function M.ensure_client_state(client)
  local existing = state.client_states[client.id]
  if existing then
    return existing
  end

  ---@type KubeYamlSchemaClientState
  local client_state = {
    base_schemas = normalize_base_schemas(client),
    overrides = {},
    last_applied = nil,
  }

  state.client_states[client.id] = client_state
  return client_state
end

---@param bufnr integer
---@param schema KubeYamlSchemaResolvedSchema?
---@return boolean
function M.apply_buffer_schema(bufnr, schema)
  local clients = M.attached_yamlls_clients(bufnr)
  if #clients == 0 then
    return false
  end

  local changed_any = false

  for _, client in ipairs(clients) do
    local client_state = M.ensure_client_state(client)
    local current = client_state.overrides[bufnr]
    local client_changed = false

    if schema and schema.uri then
      if not current or current.uri ~= schema.uri then
        client_state.overrides[bufnr] = {
          uri = schema.uri,
          name = schema.name,
        }
        client_changed = true
      end
    elseif current ~= nil then
      client_state.overrides[bufnr] = nil
      client_changed = true
    end

    if client_changed then
      merge_schema_overrides(client, client_state)
      changed_any = true
    end
  end

  return changed_any
end

---@param bufnr integer
---@return nil
function M.remove_buffer_overrides(bufnr)
  for client_id, client_state in pairs(state.client_states) do
    if client_state.overrides[bufnr] ~= nil then
      client_state.overrides[bufnr] = nil
      local client = vim.lsp.get_client_by_id(client_id)
      if client and client.name == "yamlls" then
        merge_schema_overrides(client, client_state)
      end
    end
  end
end

---@param client_id integer
---@return nil
function M.remove_client_state(client_id)
  state.client_states[client_id] = nil
end

return M

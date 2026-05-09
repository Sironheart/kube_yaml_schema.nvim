local constants = require("kube_yaml_schema.constants")

---@type KubeYamlSchemaState
local M = {
  initialized = false,
  commands_registered = false,
  global_config_applied = false,
  opts = vim.deepcopy(constants.defaults),
  context = {
    value = nil,
    expires_at = 0,
  },
  kubeconfig = {
    contexts = nil,
    context_to_cluster = nil,
    expires_at = 0,
  },
  kubeconfig_inflight = nil,
  version_cache = {},
  version_inflight = {},
  crd_cache = {},
  crd_inflight = {},
  api_resource_cache = {},
  api_resource_inflight = {},
  completion_resources = {},
  completion_client_registered = {},
  default_omnifuncs = {},
  default_completion_contexts = {},
  refresh_tokens = {},
  field_refresh_tokens = {},
  field_refresh_signatures = {},
  client_states = {},
}

---@return nil
function M.reset_runtime()
  M.context = {
    value = nil,
    expires_at = 0,
  }
  M.kubeconfig = {
    contexts = nil,
    context_to_cluster = nil,
    expires_at = 0,
  }
  M.kubeconfig_inflight = nil
  M.version_cache = {}
  M.version_inflight = {}
  M.crd_cache = {}
  M.crd_inflight = {}
  M.api_resource_cache = {}
  M.api_resource_inflight = {}
  M.completion_resources = {}
  M.default_completion_contexts = {}
  M.refresh_tokens = {}
  M.field_refresh_tokens = {}
  M.field_refresh_signatures = {}
end

return M

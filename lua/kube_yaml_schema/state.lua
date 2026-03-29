local constants = require("kube_yaml_schema.constants")

---@type KubeYamlSchemaState
local M = {
  initialized = false,
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
  refresh_tokens = {},
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
  M.refresh_tokens = {}
end

return M

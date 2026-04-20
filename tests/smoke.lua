vim.opt.runtimepath:append(vim.fn.getcwd())

local constants = require("kube_yaml_schema.constants")
local parser = require("kube_yaml_schema.parser")
local plugin = require("kube_yaml_schema")

---@param message string
---@return nil
local function fail(message)
  error(message, 0)
end

---@param condition boolean
---@param message string?
---@return nil
local function assert_true(condition, message)
  if not condition then
    fail(message or "expected condition to be true")
  end
end

---@param actual any
---@param expected any
---@param message string?
---@return nil
local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    fail(
      string.format(
        "%s\nexpected: %s\nactual: %s",
        message or "values are not equal",
        vim.inspect(expected),
        vim.inspect(actual)
      )
    )
  end
end

---@return nil
local function run_parser_tests()
  assert_equal(
    { parser.parse_api_version("apps/v1") },
    { "apps", "v1" },
    "parse_api_version should split group and version"
  )
  assert_equal({ parser.parse_api_version("v1") }, { "", "v1" }, "parse_api_version should support core resources")

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "apiVersion: v1",
    "kind: Service",
    "---",
    "apiVersion: apps/v1",
    "kind: Deployment",
    "---",
    "apiVersion: batch/v1",
    "kind: CronJob",
    "---",
    "apiVersion: {{ .Values.apiVersion }}",
    "kind: Pod",
  })

  assert_equal(parser.parse_kubernetes_resources(bufnr), {
    { group = "", version = "v1", kind = "Service", core = true },
    { group = "apps", version = "v1", kind = "Deployment", core = true },
    { group = "batch", version = "v1", kind = "CronJob", core = true },
  }, "parse_kubernetes_resources should detect valid manifests")

  local nested_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(nested_bufnr, 0, -1, false, {
    "apiVersion: tuppr.home-operations.com/v1alpha1",
    "kind: KubernetesUpgrade",
    "spec:",
    "  healthChecks:",
    "    - apiVersion: v1",
    "      kind: Node",
    "    - apiVersion: volsync.backube/v1alpha1",
    "      kind: ReplicationSource",
    "    - apiVersion: ceph.rook.io/v1",
    "      kind: CephCluster",
  })

  assert_equal(parser.parse_kubernetes_resources(nested_bufnr), {
    { group = "tuppr.home-operations.com", version = "v1alpha1", kind = "KubernetesUpgrade", core = false },
  }, "parse_kubernetes_resources should keep the top-level manifest resource")

  assert_equal(
    parser.summarize_resources({
      { group = "", version = "v1", kind = "Service", core = true },
      { group = "apps", version = "v1", kind = "Deployment", core = true },
      { group = "batch", version = "v1", kind = "CronJob", core = true },
      { group = "networking.k8s.io", version = "v1", kind = "Ingress", core = true },
      { group = "rbac.authorization.k8s.io", version = "v1", kind = "Role", core = true },
      { group = "", version = "v1", kind = "ConfigMap", core = true },
    }),
    "detected 6 resources: v1 Service, apps/v1 Deployment, batch/v1 CronJob, networking.k8s.io/v1 Ingress, rbac.authorization.k8s.io/v1 Role, +1 more",
    "summarize_resources should produce concise debug output"
  )
end

---@return nil
local function run_options_tests()
  local normalized = constants.normalize_options({
    cache_ttl_seconds = -1,
    refresh_events = {},
    context = "",
    kubectl_timeout_ms = -10,
  })

  assert_true(
    normalized.cache_ttl_seconds == constants.defaults.cache_ttl_seconds,
    "negative cache_ttl_seconds should fall back to default"
  )
  assert_equal(
    normalized.refresh_events,
    constants.defaults.refresh_events,
    "refresh_events should fall back to defaults"
  )
  assert_true(normalized.context == nil, "empty context should normalize to nil")
  assert_true(
    normalized.kubectl_timeout_ms == constants.defaults.kubectl_timeout_ms,
    "non-positive kubectl_timeout_ms should fall back to default"
  )

  local valid, err, unknown = constants.validate_options({
    kubectl_timeout_ms = "bad",
    unknown_option = true,
  }, "tests")
  assert_true(valid == false, "validate_options should reject invalid field types")
  assert_true(type(err) == "string" and err ~= "", "validate_options should return an error message")
  assert_equal(unknown, { "unknown_option" }, "validate_options should report unknown option keys")
end

---@return nil
local function run_config_tests()
  local config = plugin.yamlls_config({
    settings = {
      yaml = {
        validate = false,
      },
    },
  })

  assert_true(config.settings.yaml.validate == false, "yamlls_config should merge user-provided values")
  assert_true(type(config.settings.yaml.schemas) == "table", "yamlls_config should include a schema table")
  assert_true(
    config.settings.yaml.schemaStore.url == constants.defaults.schema_store_url,
    "yamlls_config should keep default schema store URL"
  )

  local original_loaded = package.loaded.schemastore
  local original_preload = package.preload.schemastore

  package.loaded.schemastore = nil
  package.preload.schemastore = function()
    return {
      yaml = {
        schemas = function()
          return {
            ["https://example.com/test.schema.json"] = "kustomization.yaml",
          }
        end,
      },
    }
  end

  local schemastore_config = plugin.yamlls_config()

  assert_true(
    schemastore_config.settings.yaml.schemaStore.enable == false,
    "yamlls_config should disable yamlls schemaStore when SchemaStore.nvim is available"
  )
  assert_equal(
    schemastore_config.settings.yaml.schemaStore.url,
    "",
    "yamlls_config should clear the yamlls schema store URL when SchemaStore.nvim is available"
  )
  assert_equal(schemastore_config.settings.yaml.schemas, {
    ["https://example.com/test.schema.json"] = "kustomization.yaml",
  }, "yamlls_config should use SchemaStore.nvim YAML schemas when available")

  package.loaded.schemastore = original_loaded
  package.preload.schemastore = original_preload
end

---@return nil
local function run_command_completion_tests()
  plugin.setup({ auto_refresh = false })

  local root_completions = plugin.complete_user_command("re", "KubeYamlSchema re")
  assert_true(
    vim.list_contains(root_completions, "refresh") and vim.list_contains(root_completions, "refresh-all"),
    "complete_user_command should complete subcommands"
  )

  local context_completions = plugin.complete_user_command("cu", "KubeYamlSchema context cu")
  assert_true(
    vim.list_contains(context_completions, "current"),
    "complete_user_command should complete context arguments"
  )
end

run_parser_tests()
run_options_tests()
run_config_tests()
run_command_completion_tests()

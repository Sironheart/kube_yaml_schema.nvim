vim.opt.runtimepath:append(vim.fn.getcwd())

local completion = require("kube_yaml_schema.completion")
local constants = require("kube_yaml_schema.constants")
local parser = require("kube_yaml_schema.parser")
local plugin = require("kube_yaml_schema")
local state = require("kube_yaml_schema.state")

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

  local partial_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(partial_bufnr, 0, -1, false, {
    "apiVersion: apps/v1",
    "metadata:",
    "  name: example",
    "---",
    "kind: Deployment",
  })

  local partial_documents = parser.parse_kubernetes_documents(partial_bufnr)
  assert_true(parser.has_kubernetes_fields(partial_documents), "parse_kubernetes_documents should track partial fields")
  assert_equal(
    parser.resources_from_documents(partial_documents),
    {},
    "resources_from_documents should require both apiVersion and kind"
  )
  assert_equal(
    parser.kubernetes_field_signature(partial_bufnr),
    "apps/v1|\n|Deployment",
    "kubernetes_field_signature should track top-level kind/apiVersion changes"
  )

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
local function run_completion_tests()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].filetype = "yaml"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "kind: Deployment",
    "apiVersion: ",
  })

  local ctx = completion.context_for_position(bufnr, 1, #"apiVersion: ")
  assert_true(ctx ~= nil and ctx.field == "apiVersion", "context_for_position should detect apiVersion values")

  local items = completion.items_from_context(ctx, {
    { group = "", version = "v1", kind = "Pod", core = true },
    { group = "apps", version = "v1", kind = "Deployment", core = true },
  })

  assert_equal(#items, 1, "items_from_context should narrow apiVersion by kind")
  assert_equal(items[1].label, "apps/v1", "items_from_context should use active context resources")

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "api" })
  local key_ctx = completion.context_for_position(bufnr, 0, #"api")
  local key_items = completion.items_from_context(key_ctx, nil, { filter_prefix = true })
  assert_equal(key_items[1].label, "apiVersion", "items_from_context should complete Kubernetes field names")

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "kind: " })
  local kind_ctx = completion.context_for_position(bufnr, 0, #"kind: ")
  local kind_items = completion.items_from_context(kind_ctx, {
    { group = "", version = "v1", kind = "Pod", core = true },
    { group = "apps", version = "v1", kind = "Deployment", core = true },
  })
  assert_equal(
    kind_items[1].additionalTextEdits[1].newText,
    "apiVersion: apps/v1\n",
    "kind completion should add apiVersion above kind"
  )

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "api" })
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_win_set_cursor(0, { 1, #"api" })
  completion.install_default_completion(bufnr)
  assert_equal(completion.omnifunc(1, ""), 0, "omnifunc should start at the Kubernetes field prefix")
  assert_equal(
    completion.omnifunc(0, "api")[1].word,
    "apiVersion: ",
    "omnifunc should return default Neovim completion items"
  )

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "kind: " })
  state.completion_resources[bufnr] = {
    { group = "apps", version = "v1", kind = "Deployment", core = true },
  }
  vim.api.nvim_win_set_cursor(0, { 1, #"kind: " })
  assert_equal(completion.omnifunc(1, ""), #"kind:", "omnifunc should complete kind values")
  local default_kind_item = completion.omnifunc(0, "")[1]
  assert_equal(default_kind_item.word, "Deployment", "omnifunc should return kind values")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "kind: Deployment" })
  completion.apply_complete_done_item(default_kind_item, bufnr)
  assert_equal(
    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    { "apiVersion: apps/v1", "kind: Deployment" },
    "default omnifunc should apply apiVersion additional edits"
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
run_completion_tests()
run_options_tests()
run_config_tests()
run_command_completion_tests()

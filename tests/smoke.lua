vim.opt.runtimepath:append(vim.fn.getcwd())

local constants = require("kube_yaml_schema.constants")
local parser = require("kube_yaml_schema.parser")
local plugin = require("kube_yaml_schema")

local function fail(message)
  error(message, 0)
end

local function assert_true(condition, message)
  if not condition then
    fail(message or "expected condition to be true")
  end
end

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
end

local function run_options_tests()
  local normalized = constants.normalize_options({
    cache_ttl_seconds = -1,
    refresh_events = {},
    context = "",
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
end

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
end

run_parser_tests()
run_options_tests()
run_config_tests()

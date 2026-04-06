local constants = require("kube_yaml_schema.constants")

local M = {}

---@return KubeYamlSchemaOptionsInput?, string?
local function configured_options()
  local source = vim.g.kube_yaml_schema
  if type(source) == "function" then
    local ok, evaluated = pcall(source)
    if not ok then
      return nil, "Failed to evaluate vim.g.kube_yaml_schema: " .. tostring(evaluated)
    end

    source = evaluated
  end

  if source == nil then
    return nil, nil
  end

  ---@cast source KubeYamlSchemaOptionsInput
  return source, nil
end

---@return KubeYamlSchemaNormalizedOptions
local function validate_configuration()
  local opts, eval_err = configured_options()
  if eval_err then
    vim.health.error(eval_err)
    return constants.normalize_options(nil)
  end

  local valid, err, unknown = constants.validate_options(opts, "vim.g.kube_yaml_schema")
  if valid then
    vim.health.ok("Configuration is valid")
  else
    vim.health.error(err or "Configuration is invalid")
  end

  if #unknown > 0 then
    vim.health.warn("Unknown options: " .. table.concat(unknown, ", "))
  else
    vim.health.ok("No unknown configuration keys")
  end

  return constants.normalize_options(opts)
end

---@param opts KubeYamlSchemaNormalizedOptions
---@return nil
local function check_external_dependencies(opts)
  if vim.fn.executable(opts.kubectl_bin) == 1 then
    vim.health.ok("kubectl executable found: " .. opts.kubectl_bin)
  else
    vim.health.error("kubectl executable not found: " .. opts.kubectl_bin)
  end
end

---@param opts KubeYamlSchemaNormalizedOptions
---@return nil
local function check_cache_path(opts)
  if vim.fn.isdirectory(opts.cache_dir) == 1 then
    vim.health.ok("Cache directory exists: " .. opts.cache_dir)
    return
  end

  local parent = vim.fs.dirname(opts.cache_dir)
  if parent and vim.fn.isdirectory(parent) == 1 then
    vim.health.ok("Cache directory parent exists: " .. parent)
    return
  end

  vim.health.warn("Cache directory parent does not exist: " .. tostring(parent))
end

---@return nil
local function check_lsp_state()
  local clients = vim.lsp.get_clients({ name = "yamlls" })
  if #clients > 0 then
    vim.health.ok("yamlls client is attached in this session")
  else
    vim.health.warn("yamlls client is not attached in this session")
  end
end

---@return nil
function M.check()
  vim.health.start("kube-yaml-schema.nvim")
  local opts = validate_configuration()
  check_external_dependencies(opts)
  check_cache_path(opts)
  check_lsp_state()
end

return M

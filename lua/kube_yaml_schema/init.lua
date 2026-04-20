local cache = require("kube_yaml_schema.cache")
local constants = require("kube_yaml_schema.constants")
local kubectl = require("kube_yaml_schema.kubectl")
local lsp = require("kube_yaml_schema.lsp")
local parser = require("kube_yaml_schema.parser")
local resolver = require("kube_yaml_schema.resolver")
local state = require("kube_yaml_schema.state")
local util = require("kube_yaml_schema.util")

local M = {}

local MAIN_COMMAND = "KubeYamlSchema"

---@type string[]
local SUBCOMMAND_ORDER = {
  "refresh",
  "refresh-all",
  "context",
  "clear-cache",
}

---@type table<string, string>
local SUBCOMMAND_ALIASES = {
  refresh_all = "refresh-all",
  clear_cache = "clear-cache",
}

---@param changed boolean
---@param base string
---@return string
local function fallback_message(changed, base)
  if changed then
    return base .. ", switched to Schema Store fallback"
  end

  return base .. ", using Schema Store fallback"
end

---@param message string
---@param result KubeYamlSchemaResolveResult?
---@return string
local function append_resource_summary(message, result)
  local resources = result and result.resources or nil
  if type(resources) ~= "table" or #resources == 0 then
    return message
  end

  local max_items = 5
  local lines = { message, "", (#resources == 1 and "Detected resource:" or "Detected resources:") }

  for index, resource in ipairs(resources) do
    if index > max_items then
      table.insert(lines, string.format("- +%d more", #resources - max_items))
      break
    end

    table.insert(lines, "- " .. parser.format_resource(resource))
  end

  return table.concat(lines, "\n")
end

---@param opts KubeYamlSchemaRefreshOpts
---@param result KubeYamlSchemaResolveResult?
---@param err string?
---@param changed boolean
---@return nil
local function notify_resolution_result(opts, result, err, changed)
  if not opts.notify then
    return
  end

  if err then
    util.notify(
      vim.log.levels.WARN,
      append_resource_summary(
        table.concat({ fallback_message(changed, "Failed to resolve Kubernetes schema"), "Error: " .. err }, "\n"),
        result
      )
    )
    return
  end

  local schema = result and result.schema or nil
  if schema then
    util.notify(vim.log.levels.INFO, append_resource_summary("Use schema override\nSchema: " .. schema.name, result))
    return
  end

  local reason = result and result.reason or "no-cluster-schema"
  if reason == "no-kubernetes-resource" then
    local message = changed and "Cleared Kubernetes schema override" or "No Kubernetes resource detected"
    util.notify(vim.log.levels.INFO, append_resource_summary(message .. ", using Schema Store fallback", result))
    return
  end

  util.notify(
    vim.log.levels.INFO,
    append_resource_summary(fallback_message(changed, "No applicable cluster schema found"), result)
  )
end

---@param bufnr integer
---@param opts KubeYamlSchemaRefreshOpts?
---@return nil
local function refresh_buffer(bufnr, opts)
  ---@type KubeYamlSchemaRefreshOpts
  opts = opts or {}

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local clients = lsp.attached_yamlls_clients(bufnr)
  if #clients == 0 then
    if opts.notify then
      util.notify(vim.log.levels.INFO, "yamlls is not attached to this buffer")
    end
    return
  end

  state.refresh_tokens[bufnr] = (state.refresh_tokens[bufnr] or 0) + 1
  local token = state.refresh_tokens[bufnr]

  resolver.resolve_for_buffer(bufnr, function(result, err)
    if state.refresh_tokens[bufnr] ~= token then
      return
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local schema = result and result.schema or nil
    local changed = lsp.apply_buffer_schema(bufnr, schema)
    notify_resolution_result(opts, result, err, changed)
  end)
end

---@param opts KubeYamlSchemaRefreshOpts?
---@return nil
local function refresh_open_yaml_buffers(opts)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) and util.is_yaml_filetype(bufnr) then
      refresh_buffer(bufnr, opts)
    end
  end
end

---@param prefix string?
---@return nil
local function notify_active_target(prefix)
  kubectl.get_active_target(function(target, err)
    if not target then
      util.notify(vim.log.levels.WARN, (prefix or "Unable to resolve target") .. ": " .. (err or "unknown error"))
      return
    end

    local mode = kubectl.get_context_override() and "override" or "kubectl"
    local message = string.format(
      "%scontext: %s (%s), cluster: %s",
      prefix and (prefix .. " ") or "",
      target.context,
      mode,
      target.cluster
    )
    util.notify(vim.log.levels.INFO, message)
  end)
end

---@param context string?
---@return nil
local function switch_context(context)
  kubectl.set_context_override(context)
  kubectl.clear_runtime_cache()
  refresh_open_yaml_buffers({ notify = true })

  if context then
    notify_active_target("Switched to")
  else
    notify_active_target("Using")
  end
end

---@return nil
local function open_context_picker()
  kubectl.list_context_entries(function(entries, err)
    if not entries then
      util.notify(vim.log.levels.WARN, "Unable to list contexts: " .. (err or "unknown error"))
      return
    end

    kubectl.get_active_target(function(target)
      local active_context = target and target.context or nil
      local override_context = kubectl.get_context_override()

      ---@type KubeYamlSchemaContextSelectItem[]
      local items = {}
      ---@type KubeYamlSchemaContextSelectItem?
      local preselected_item = nil

      for _, entry in ipairs(entries) do
        local flags = {}
        if entry.context == active_context then
          table.insert(flags, "active")
        end

        if override_context and entry.context == override_context then
          table.insert(flags, "override")
        end

        local suffix = #flags > 0 and (" [" .. table.concat(flags, ", ") .. "]") or ""
        ---@type KubeYamlSchemaContextSelectItem
        local item = {
          label = string.format("%s (%s)%s", entry.context, entry.cluster, suffix),
          value = entry.context,
          context = entry.context,
          cluster = entry.cluster,
        }

        if entry.context == active_context then
          preselected_item = item
          table.insert(items, 1, item)
        else
          table.insert(items, item)
        end
      end

      ---@type KubeYamlSchemaContextSelectItem
      local auto_item = {
        label = "auto (follow kubectl current-context)",
        value = nil,
      }

      if override_context then
        table.insert(items, auto_item)
      else
        auto_item.label = auto_item.label .. " [active mode]"
        if #items >= 1 then
          table.insert(items, 2, auto_item)
        else
          table.insert(items, auto_item)
        end
      end

      if not preselected_item and items[1] then
        preselected_item = items[1]
      end

      vim.ui.select(items, {
        prompt = "Select kube context",
        kind = "kube-yaml-schema-context",
        default = preselected_item,
        ---@param item KubeYamlSchemaContextSelectItem
        ---@return string
        format_item = function(item)
          return item.label
        end,
      }, function(choice)
        ---@cast choice KubeYamlSchemaContextSelectItem?
        if choice then
          switch_context(choice.value)
        end
      end)
    end)
  end)
end

---@return string[]
local function context_completion_items()
  ---@type string[]
  local values = {
    "auto",
    "current",
  }

  for _, context in ipairs(kubectl.list_contexts_sync()) do
    table.insert(values, context)
  end

  return values
end

---@param arg_lead string
---@return string[]
local function context_completion(arg_lead)
  return vim.tbl_filter(function(item)
    return vim.startswith(item, arg_lead)
  end, context_completion_items())
end

---@param arg string?
---@return nil
local function handle_context_command(arg)
  local value = vim.trim(arg or "")

  if value == "" then
    open_context_picker()
    return
  end

  if value == "current" then
    notify_active_target("Active")
    return
  end

  if value == "auto" then
    switch_context(nil)
    return
  end

  kubectl.context_exists(value, function(exists, err)
    if err then
      util.notify(vim.log.levels.WARN, "Unable to validate context, applying anyway: " .. err)
      switch_context(value)
      return
    end

    if not exists then
      util.notify(vim.log.levels.ERROR, "Context not found: " .. value)
      return
    end

    switch_context(value)
  end)
end

---@param values string[]
---@param arg_lead string
---@return string[]
local function prefixed_matches(values, arg_lead)
  ---@type string[]
  local matches = {}
  for _, value in ipairs(values) do
    if vim.startswith(value, arg_lead) then
      table.insert(matches, value)
    end
  end

  return matches
end

---@return nil
local function clear_cache_command()
  kubectl.clear_runtime_cache()
  cache.clear_all_files()
  util.notify(vim.log.levels.INFO, "Cleared kube-yaml-schema cache")
  refresh_buffer(vim.api.nvim_get_current_buf(), { notify = true })
end

---@param source string
---@param replacement string
---@return nil
local function notify_deprecated_command(source, replacement)
  vim.deprecate(source, replacement, "2.0.0", "kube-yaml-schema.nvim")
end

---@param path string
---@param opts KubeYamlSchemaOptionsInput?
---@return nil
local function apply_options(path, opts)
  local valid, err, unknown = constants.validate_options(opts, path)
  if not valid and err then
    vim.notify("Invalid kube-yaml-schema options: " .. err, vim.log.levels.WARN, { title = "kube-yaml-schema" })
  end

  if #unknown > 0 then
    vim.notify(
      "Unknown kube-yaml-schema options: " .. table.concat(unknown, ", "),
      vim.log.levels.WARN,
      { title = "kube-yaml-schema" }
    )
  end

  state.opts = constants.normalize_options(opts)
  state.context = {
    value = nil,
    expires_at = 0,
  }
end

---@return nil
local function apply_global_options_once()
  if state.global_config_applied then
    return
  end

  state.global_config_applied = true

  local configured = vim.g.kube_yaml_schema
  if type(configured) == "function" then
    local ok, evaluated = pcall(configured)
    if not ok then
      vim.notify(
        "Failed to evaluate vim.g.kube_yaml_schema: " .. tostring(evaluated),
        vim.log.levels.WARN,
        { title = "kube-yaml-schema" }
      )
      return
    end
    configured = evaluated
  end

  if configured ~= nil then
    ---@cast configured KubeYamlSchemaOptionsInput
    apply_options("vim.g.kube_yaml_schema", configured)
  end
end

---@return nil
local function register_autocmds()
  local group = vim.api.nvim_create_augroup("kube-yaml-schema", { clear = true })

  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    ---@param args vim.api.keyset.create_autocmd.callback_args
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client or client.name ~= "yamlls" then
        return
      end

      lsp.ensure_client_state(client)
      refresh_buffer(args.buf, { notify = state.opts.notify_on_auto_refresh })
    end,
  })

  vim.api.nvim_create_autocmd("LspDetach", {
    group = group,
    ---@param args vim.api.keyset.create_autocmd.callback_args
    callback = function(args)
      if args.data and args.data.client_id then
        lsp.remove_client_state(args.data.client_id)
      end
    end,
  })

  if state.opts.auto_refresh then
    vim.api.nvim_create_autocmd(state.opts.refresh_events, {
      group = group,
      ---@param args vim.api.keyset.create_autocmd.callback_args
      callback = function(args)
        if util.is_yaml_filetype(args.buf) then
          refresh_buffer(args.buf, { notify = state.opts.notify_on_auto_refresh })
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    ---@param args vim.api.keyset.create_autocmd.callback_args
    callback = function(args)
      lsp.remove_buffer_overrides(args.buf)
      state.refresh_tokens[args.buf] = nil
    end,
  })
end

---@return table<string, KubeYamlSchemaCommandSubcommand>
local function command_subcommands()
  ---@type table<string, KubeYamlSchemaCommandSubcommand>
  local commands = {
    refresh = {
      ---@param args string[]
      impl = function(args)
        if #args > 0 then
          util.notify(vim.log.levels.ERROR, "Usage: :KubeYamlSchema refresh")
          return
        end

        refresh_buffer(vim.api.nvim_get_current_buf(), { notify = true })
      end,
    },
    ["refresh-all"] = {
      ---@param args string[]
      impl = function(args)
        if #args > 0 then
          util.notify(vim.log.levels.ERROR, "Usage: :KubeYamlSchema refresh-all")
          return
        end

        refresh_open_yaml_buffers({ notify = true })
      end,
    },
    context = {
      ---@param args string[]
      impl = function(args)
        if #args > 1 then
          util.notify(vim.log.levels.ERROR, "Usage: :KubeYamlSchema context [auto|current|<name>]")
          return
        end

        handle_context_command(args[1])
      end,
      complete = context_completion,
    },
    ["clear-cache"] = {
      ---@param args string[]
      impl = function(args)
        if #args > 0 then
          util.notify(vim.log.levels.ERROR, "Usage: :KubeYamlSchema clear-cache")
          return
        end

        clear_cache_command()
      end,
    },
  }

  return commands
end

---@return nil
local function register_commands()
  local subcommands = command_subcommands()

  ---@param name string
  ---@param callback fun(args: vim.api.keyset.user_command.command_args)
  ---@param opts vim.api.keyset.user_command
  ---@return nil
  local function create_or_replace_command(name, callback, opts)
    pcall(vim.api.nvim_del_user_command, name)
    vim.api.nvim_create_user_command(name, callback, opts)
  end

  create_or_replace_command(MAIN_COMMAND, function(args)
    ---@cast args vim.api.keyset.user_command.command_args
    M.run_user_command(args.args)
  end, {
    nargs = "+",
    complete = M.complete_user_command,
    desc = "Manage Kubernetes YAML schema overrides",
  })

  create_or_replace_command("KubeYamlSchemaRefresh", function()
    notify_deprecated_command(":KubeYamlSchemaRefresh", ":KubeYamlSchema refresh")
    subcommands.refresh.impl({})
  end, {
    desc = "Refresh Kubernetes YAML schema override for current buffer",
  })

  create_or_replace_command("KubeYamlSchemaRefreshAll", function()
    notify_deprecated_command(":KubeYamlSchemaRefreshAll", ":KubeYamlSchema refresh-all")
    subcommands["refresh-all"].impl({})
  end, {
    desc = "Refresh Kubernetes YAML schema overrides for all open YAML buffers",
  })

  create_or_replace_command("KubeYamlSchemaContext", function(args)
    notify_deprecated_command(":KubeYamlSchemaContext", ":KubeYamlSchema context")
    ---@cast args vim.api.keyset.user_command.command_args
    handle_context_command(args.args)
  end, {
    nargs = "?",
    complete = context_completion,
    desc = "Pick or switch the kubectl context used by kube-yaml-schema",
  })

  create_or_replace_command("KubeYamlSchemaClearCache", function()
    notify_deprecated_command(":KubeYamlSchemaClearCache", ":KubeYamlSchema clear-cache")
    clear_cache_command()
  end, {
    desc = "Clear kube-yaml-schema cache",
  })
end

---@return nil
local function ensure_initialized()
  if not state.initialized then
    M.bootstrap()
  end
end

---@return table?
local function resolve_schemastore_yaml_schemas()
  local ok, schemastore_plugin = pcall(require, "schemastore")
  if not ok then
    return nil
  end

  local schemastore_yaml = type(schemastore_plugin) == "table" and schemastore_plugin.yaml or nil
  if type(schemastore_yaml) ~= "table" or type(schemastore_yaml.schemas) ~= "function" then
    return nil
  end

  local ok_schemas, schemastore_yaml_schemas = pcall(schemastore_yaml.schemas)
  if not ok_schemas or type(schemastore_yaml_schemas) ~= "table" then
    return nil
  end

  return schemastore_yaml_schemas
end

---@param bufnr integer?
---@param opts KubeYamlSchemaRefreshOpts?
---@return nil
function M.refresh(bufnr, opts)
  ensure_initialized()
  refresh_buffer(bufnr or vim.api.nvim_get_current_buf(), opts)
end

---@param opts KubeYamlSchemaRefreshOpts?
---@return nil
function M.refresh_all(opts)
  ensure_initialized()
  refresh_open_yaml_buffers(opts)
end

---@param context string?
---@return nil
function M.set_context(context)
  ensure_initialized()
  switch_context(context)
end

---@param extra table?
---@return table
function M.yamlls_config(extra)
  apply_global_options_once()

  local schemastore_yaml_schemas = resolve_schemastore_yaml_schemas()
  local yamlls_schema_store = schemastore_yaml_schemas and {
    enable = false,
    url = "",
  } or {
    enable = true,
    url = state.opts.schema_store_url,
  }

  local config = {
    settings = {
      redhat = {
        telemetry = {
          enabled = false,
        },
      },
      yaml = {
        validate = true,
        format = {
          enable = true,
        },
        hover = true,
        schemaStore = yamlls_schema_store,
        schemaDownload = {
          enable = true,
        },
        schemas = schemastore_yaml_schemas or {},
      },
    },
  }

  if extra then
    return vim.tbl_deep_extend("force", config, extra)
  end

  return config
end

---@param opts KubeYamlSchemaOptionsInput?
---@return nil
function M.configure(opts)
  if opts == nil then
    if state.initialized then
      register_autocmds()
    end
    return
  end

  state.global_config_applied = true
  apply_options("require('kube_yaml_schema').configure", opts)

  if state.initialized then
    register_autocmds()
  end
end

---@param opts KubeYamlSchemaOptionsInput?
---@return nil
function M.setup(opts)
  if opts == nil then
    apply_global_options_once()
  else
    M.configure(opts)
  end

  M.init()
end

---@return nil
function M.init()
  if not state.commands_registered then
    register_commands()
    state.commands_registered = true
  end

  register_autocmds()
  state.initialized = true
end

---@return nil
function M.bootstrap()
  apply_global_options_once()
  M.init()
end

---@param raw_args string
---@return nil
function M.run_user_command(raw_args)
  ensure_initialized()

  local input = vim.trim(raw_args or "")
  if input == "" then
    util.notify(vim.log.levels.ERROR, "Usage: :KubeYamlSchema {refresh|refresh-all|context|clear-cache}")
    return
  end

  local parts = vim.split(input, "%s+", { trimempty = true })
  local subcommand_name = SUBCOMMAND_ALIASES[parts[1]] or parts[1]
  local subcommand = command_subcommands()[subcommand_name]
  if not subcommand then
    util.notify(vim.log.levels.ERROR, "Unknown KubeYamlSchema subcommand: " .. tostring(subcommand_name))
    return
  end

  local args = #parts > 1 and vim.list_slice(parts, 2, #parts) or {}
  subcommand.impl(args)
end

---@param arg_lead string
---@return string[]
function M.complete_context(arg_lead)
  apply_global_options_once()
  return context_completion(arg_lead)
end

---@param arg_lead string
---@param cmdline string
---@return string[]
function M.complete_user_command(arg_lead, cmdline)
  apply_global_options_once()

  local subcommands = command_subcommands()
  local subcmd_key, subcmd_arg_lead = cmdline:match("^['<,'>]*KubeYamlSchema[!]*%s(%S+)%s(.*)$")
  local resolved_key = subcmd_key and (SUBCOMMAND_ALIASES[subcmd_key] or subcmd_key) or nil
  if resolved_key and subcmd_arg_lead and subcommands[resolved_key] and subcommands[resolved_key].complete then
    local completion_arg = vim.trim(subcmd_arg_lead)
    return subcommands[resolved_key].complete(completion_arg)
  end

  if cmdline:match("^['<,'>]*KubeYamlSchema[!]*%s+[%w_%-]*$") then
    return prefixed_matches(SUBCOMMAND_ORDER, arg_lead)
  end

  return {}
end

return M

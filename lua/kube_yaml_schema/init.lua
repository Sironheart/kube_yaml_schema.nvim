local cache = require("kube_yaml_schema.cache")
local constants = require("kube_yaml_schema.constants")
local kubectl = require("kube_yaml_schema.kubectl")
local lsp = require("kube_yaml_schema.lsp")
local resolver = require("kube_yaml_schema.resolver")
local state = require("kube_yaml_schema.state")
local util = require("kube_yaml_schema.util")

local M = {}

local function fallback_message(changed, base)
  if changed then
    return base .. ", switched to Schema Store fallback"
  end

  return base .. ", using Schema Store fallback"
end

local function notify_resolution_result(opts, result, err, changed)
  if not opts.notify then
    return
  end

  if err then
    util.notify(vim.log.levels.WARN, fallback_message(changed, "Failed to resolve Kubernetes schema") .. ": " .. err)
    return
  end

  local schema = result and result.schema or nil
  if schema then
    local action = changed and "Applied" or "Kept"
    util.notify(vim.log.levels.INFO, string.format("%s schema override: %s", action, schema.name))
    return
  end

  local reason = result and result.reason or "no-cluster-schema"
  if reason == "no-kubernetes-resource" then
    local message = changed and "Cleared Kubernetes schema override" or "No Kubernetes resource detected"
    util.notify(vim.log.levels.INFO, message .. ", using Schema Store fallback")
    return
  end

  util.notify(vim.log.levels.INFO, fallback_message(changed, "No applicable cluster schema found"))
end

local function refresh_buffer(bufnr, opts)
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

local function refresh_open_yaml_buffers(opts)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) and util.is_yaml_filetype(bufnr) then
      refresh_buffer(bufnr, opts)
    end
  end
end

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

local function open_context_picker()
  kubectl.list_context_entries(function(entries, err)
    if not entries then
      util.notify(vim.log.levels.WARN, "Unable to list contexts: " .. (err or "unknown error"))
      return
    end

    kubectl.get_active_target(function(target)
      local active_context = target and target.context or nil
      local override_context = kubectl.get_context_override()

      local items = {}
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
        format_item = function(item)
          return item.label
        end,
      }, function(choice)
        if choice then
          switch_context(choice.value)
        end
      end)
    end)
  end)
end

local function context_completion_items()
  local values = {
    "auto",
    "current",
  }

  for _, context in ipairs(kubectl.list_contexts_sync()) do
    table.insert(values, context)
  end

  return values
end

local function context_completion(arg_lead)
  return vim.tbl_filter(function(item)
    return vim.startswith(item, arg_lead)
  end, context_completion_items())
end

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

function M.refresh(bufnr, opts)
  refresh_buffer(bufnr or vim.api.nvim_get_current_buf(), opts)
end

function M.refresh_all(opts)
  refresh_open_yaml_buffers(opts)
end

function M.set_context(context)
  switch_context(context)
end

function M.yamlls_config(extra)
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
        schemaStore = {
          enable = true,
          url = state.opts.schema_store_url,
        },
        schemaDownload = {
          enable = true,
        },
        schemas = {},
      },
    },
  }

  if extra then
    return vim.tbl_deep_extend("force", config, extra)
  end

  return config
end

function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(state.opts), opts or {})
  state.opts = constants.normalize_options(merged)

  if state.initialized then
    return
  end

  state.initialized = true

  local group = vim.api.nvim_create_augroup("kube-yaml-schema", { clear = true })

  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
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
    callback = function(args)
      if args.data and args.data.client_id then
        lsp.remove_client_state(args.data.client_id)
      end
    end,
  })

  if state.opts.auto_refresh then
    vim.api.nvim_create_autocmd(state.opts.refresh_events, {
      group = group,
      callback = function(args)
        if util.is_yaml_filetype(args.buf) then
          refresh_buffer(args.buf, { notify = state.opts.notify_on_auto_refresh })
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      lsp.remove_buffer_overrides(args.buf)
      state.refresh_tokens[args.buf] = nil
    end,
  })

  vim.api.nvim_create_user_command("KubeYamlSchemaRefresh", function()
    refresh_buffer(vim.api.nvim_get_current_buf(), { notify = true })
  end, {
    desc = "Refresh Kubernetes YAML schema override for current buffer",
  })

  vim.api.nvim_create_user_command("KubeYamlSchemaRefreshAll", function()
    refresh_open_yaml_buffers({ notify = true })
  end, {
    desc = "Refresh Kubernetes YAML schema overrides for all open YAML buffers",
  })

  vim.api.nvim_create_user_command("KubeYamlSchemaContext", function(args)
    handle_context_command(args.args)
  end, {
    nargs = "?",
    complete = context_completion,
    desc = "Pick or switch the kubectl context used by kube-yaml-schema",
  })

  vim.api.nvim_create_user_command("KubeYamlSchemaClearCache", function()
    kubectl.clear_runtime_cache()
    cache.clear_all_files()
    util.notify(vim.log.levels.INFO, "Cleared kube-yaml-schema cache")
    refresh_buffer(vim.api.nvim_get_current_buf(), { notify = true })
  end, {
    desc = "Clear kube-yaml-schema cache",
  })
end

return M

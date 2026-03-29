local cache = require("kube_yaml_schema.cache")
local state = require("kube_yaml_schema.state")

local M = {}

local function run_kubectl(args, callback)
  local command = { state.opts.kubectl_bin }
  vim.list_extend(command, args)

  vim.system(command, { text = true, timeout = state.opts.kubectl_timeout_ms }, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)
end

local function run_kubectl_for_context(context, args, callback)
  local full_args = { "--context", context }
  vim.list_extend(full_args, args)
  run_kubectl(full_args, callback)
end

local function flush_waiters(waiters, payload, err)
  for _, waiter in ipairs(waiters) do
    waiter(payload, err)
  end
end

local function cache_ttl()
  local value = state.opts.cache_ttl_seconds
  if type(value) ~= "number" then
    return 0
  end

  return value
end

local function expires_at(ttl_seconds)
  if ttl_seconds == 0 then
    return math.huge
  end

  return os.time() + ttl_seconds
end

local function stale_ttl()
  local configured = state.opts.stale_on_error_seconds
  if configured > 0 then
    return configured
  end

  return 60
end

local function parse_server_version(output)
  local ok, decoded = pcall(vim.json.decode, output)
  if not ok or type(decoded) ~= "table" or type(decoded.serverVersion) ~= "table" then
    return nil
  end

  local git_version = decoded.serverVersion.gitVersion
  if type(git_version) ~= "string" then
    return nil
  end

  local version = git_version:match("^v%d+%.%d+%.%d+")
  if version then
    return version
  end

  if git_version:sub(1, 1) == "v" then
    return git_version
  end

  return "v" .. git_version
end

local function parse_contexts(output)
  local ok, decoded = pcall(vim.json.decode, output)
  if not ok or type(decoded) ~= "table" then
    return nil
  end

  local context_to_cluster = {}
  local contexts = {}

  for _, item in ipairs(decoded.contexts or {}) do
    if type(item) == "table" and type(item.name) == "string" and item.name ~= "" then
      local cluster = item.context and item.context.cluster
      if type(cluster) ~= "string" or cluster == "" then
        cluster = item.name
      end

      context_to_cluster[item.name] = cluster
      table.insert(contexts, item.name)
    end
  end

  table.sort(contexts)

  return {
    contexts = contexts,
    context_to_cluster = context_to_cluster,
  }
end

local function build_crd_index(crd_payload)
  local index = {
    by_key = {},
  }

  if type(crd_payload) ~= "table" or not vim.islist(crd_payload.items) then
    return index
  end

  for _, item in ipairs(crd_payload.items) do
    local spec = item.spec or {}
    local names = spec.names or {}
    local group = spec.group
    local kind = names.kind

    if type(group) == "string" and group ~= "" and type(kind) == "string" and kind ~= "" then
      local versions = {}
      local version_order = {}

      for _, version in ipairs(spec.versions or {}) do
        if type(version) == "table" and type(version.name) == "string" then
          versions[version.name] = {
            name = version.name,
            served = version.served == true,
            storage = version.storage == true,
            schema = version.schema and version.schema.openAPIV3Schema or nil,
          }
          table.insert(version_order, version.name)
        end
      end

      local key = string.lower(group .. "|" .. kind)
      index.by_key[key] = {
        group = group,
        kind = kind,
        name = item.metadata and item.metadata.name or nil,
        versions = versions,
        version_order = version_order,
      }
    end
  end

  return index
end

local function get_kubeconfig_data(callback)
  local configured_ttl = cache_ttl()
  local cached = state.kubeconfig

  if cached.contexts and cached.context_to_cluster and cached.expires_at > os.time() then
    callback(cached, nil)
    return
  end

  if state.kubeconfig_inflight then
    table.insert(state.kubeconfig_inflight, callback)
    return
  end

  state.kubeconfig_inflight = { callback }

  run_kubectl({ "config", "view", "-o", "json" }, function(result)
    local waiters = state.kubeconfig_inflight
    state.kubeconfig_inflight = nil

    if result.code ~= 0 then
      if cached.contexts and cached.context_to_cluster then
        flush_waiters(waiters, cached, nil)
        return
      end

      flush_waiters(waiters, nil, vim.trim(result.stderr or "failed to read kubeconfig contexts"))
      return
    end

    local parsed = parse_contexts(result.stdout or "")
    if not parsed then
      if cached.contexts and cached.context_to_cluster then
        flush_waiters(waiters, cached, nil)
        return
      end

      flush_waiters(waiters, nil, "failed to parse kubeconfig contexts")
      return
    end

    parsed.expires_at = expires_at(configured_ttl)
    state.kubeconfig = parsed
    flush_waiters(waiters, parsed, nil)
  end)
end

function M.pick_crd_schema(entry, requested_version)
  if not entry then
    return nil, nil
  end

  local versions = entry.versions or {}
  local version_order = entry.version_order or {}

  if requested_version and versions[requested_version] and versions[requested_version].schema then
    return versions[requested_version].schema, requested_version
  end

  for _, version_name in ipairs(version_order) do
    local candidate = versions[version_name]
    if candidate and candidate.storage and candidate.schema then
      return candidate.schema, version_name
    end
  end

  for _, version_name in ipairs(version_order) do
    local candidate = versions[version_name]
    if candidate and candidate.served and candidate.schema then
      return candidate.schema, version_name
    end
  end

  for _, version_name in ipairs(version_order) do
    local candidate = versions[version_name]
    if candidate and candidate.schema then
      return candidate.schema, version_name
    end
  end

  return nil, nil
end

function M.get_context_override()
  return state.opts.context
end

function M.set_context_override(context)
  if type(context) == "string" and context ~= "" then
    state.opts.context = context
  else
    state.opts.context = nil
  end

  state.context = {
    value = nil,
    expires_at = 0,
  }
end

function M.get_current_context(callback)
  local override = M.get_context_override()
  if override then
    callback(override, nil)
    return
  end

  if state.context.value and state.context.expires_at > os.time() then
    callback(state.context.value, nil)
    return
  end

  run_kubectl({ "config", "current-context" }, function(result)
    if result.code ~= 0 then
      callback(nil, vim.trim(result.stderr or "unable to resolve current kubectl context"))
      return
    end

    local context = vim.trim(result.stdout or "")
    if context == "" then
      callback(nil, "kubectl current-context returned an empty value")
      return
    end

    state.context.value = context
    state.context.expires_at = expires_at(cache_ttl())
    callback(context, nil)
  end)
end

function M.get_active_target(callback)
  M.get_current_context(function(context, context_err)
    if not context then
      callback(nil, context_err)
      return
    end

    get_kubeconfig_data(function(data)
      local cluster = context
      if data and data.context_to_cluster and data.context_to_cluster[context] then
        cluster = data.context_to_cluster[context]
      end

      callback({
        context = context,
        cluster = cluster,
      }, nil)
    end)
  end)
end

function M.list_context_entries(callback)
  get_kubeconfig_data(function(data, err)
    if not data then
      callback(nil, err)
      return
    end

    local entries = {}
    for _, context in ipairs(data.contexts) do
      local cluster = data.context_to_cluster and data.context_to_cluster[context] or context
      table.insert(entries, {
        context = context,
        cluster = cluster,
      })
    end

    callback(entries, nil)
  end)
end

function M.list_contexts(callback)
  M.list_context_entries(function(entries, err)
    if not entries then
      callback(nil, err)
      return
    end

    local contexts = {}
    for _, entry in ipairs(entries) do
      table.insert(contexts, entry.context)
    end

    callback(contexts, nil)
  end)
end

function M.list_contexts_sync()
  local result = vim
    .system(
      { state.opts.kubectl_bin, "config", "get-contexts", "-o", "name" },
      { text = true, timeout = state.opts.kubectl_timeout_ms }
    )
    :wait()

  if result.code ~= 0 then
    return {}
  end

  local contexts = vim.split(result.stdout or "", "\n", { trimempty = true })
  table.sort(contexts)
  return contexts
end

function M.context_exists(name, callback)
  if type(name) ~= "string" or name == "" then
    callback(false, "context cannot be empty")
    return
  end

  M.list_contexts(function(contexts, err)
    if not contexts then
      callback(false, err)
      return
    end

    callback(vim.list_contains(contexts, name), nil)
  end)
end

function M.get_server_version(target, callback)
  local cache_key = target.cluster
  local cached = state.version_cache[cache_key]
  if cached and cached.expires_at > os.time() then
    callback(cached.version, nil)
    return
  end

  local cache_path = cache.cluster_version_cache_path(cache_key)
  local stale = cache.read_json_file(cache_path)
  local configured_ttl = cache_ttl()

  if stale and cache.is_cache_fresh(cache_path, configured_ttl) then
    local version = stale.version
    if type(version) == "string" and version ~= "" then
      state.version_cache[cache_key] = {
        version = version,
        expires_at = expires_at(configured_ttl),
      }
      callback(version, nil)
      return
    end
  end

  if state.version_inflight[cache_key] then
    table.insert(state.version_inflight[cache_key], callback)
    return
  end

  state.version_inflight[cache_key] = { callback }

  run_kubectl_for_context(target.context, { "version", "--output=json" }, function(result)
    local waiters = state.version_inflight[cache_key]
    state.version_inflight[cache_key] = nil

    if result.code ~= 0 then
      if stale and type(stale.version) == "string" and stale.version ~= "" then
        state.version_cache[cache_key] = {
          version = stale.version,
          expires_at = os.time() + stale_ttl(),
        }
        flush_waiters(waiters, stale.version, nil)
        return
      end

      flush_waiters(waiters, nil, vim.trim(result.stderr or "failed to fetch kubernetes version"))
      return
    end

    local version = parse_server_version(result.stdout or "")
    if not version then
      flush_waiters(waiters, nil, "failed to parse kubernetes server version")
      return
    end

    state.version_cache[cache_key] = {
      version = version,
      expires_at = expires_at(configured_ttl),
    }

    cache.write_json_file(cache_path, { version = version })
    flush_waiters(waiters, version, nil)
  end)
end

function M.get_crd_index(target, callback)
  local cache_key = target.cluster
  local cached = state.crd_cache[cache_key]
  if cached and cached.expires_at > os.time() then
    callback(cached.index, nil)
    return
  end

  local cache_path = cache.cluster_crd_cache_path(cache_key)
  local stale = cache.read_json_file(cache_path)
  local configured_ttl = cache_ttl()

  if stale and cache.is_cache_fresh(cache_path, configured_ttl) then
    state.crd_cache[cache_key] = {
      index = stale,
      expires_at = expires_at(configured_ttl),
    }
    callback(stale, nil)
    return
  end

  if state.crd_inflight[cache_key] then
    table.insert(state.crd_inflight[cache_key], callback)
    return
  end

  state.crd_inflight[cache_key] = { callback }

  run_kubectl_for_context(target.context, { "get", "crd", "--output=json" }, function(result)
    local waiters = state.crd_inflight[cache_key]
    state.crd_inflight[cache_key] = nil

    if result.code ~= 0 then
      if stale then
        state.crd_cache[cache_key] = {
          index = stale,
          expires_at = os.time() + stale_ttl(),
        }
        flush_waiters(waiters, stale, nil)
        return
      end

      flush_waiters(waiters, nil, vim.trim(result.stderr or "failed to fetch cluster CRDs"))
      return
    end

    local ok, decoded = pcall(vim.json.decode, result.stdout or "")
    if not ok then
      flush_waiters(waiters, nil, "failed to parse CRD list from kubectl")
      return
    end

    local index = build_crd_index(decoded)
    state.crd_cache[cache_key] = {
      index = index,
      expires_at = expires_at(configured_ttl),
    }

    cache.write_json_file(cache_path, index)
    flush_waiters(waiters, index, nil)
  end)
end

function M.clear_runtime_cache()
  state.reset_runtime()
end

return M

local M = {}

M.core_api_groups = {
	[""] = true,
	["admissionregistration.k8s.io"] = true,
	["apiextensions.k8s.io"] = true,
	["apps"] = true,
	["autoscaling"] = true,
	["batch"] = true,
	["certificates.k8s.io"] = true,
	["coordination.k8s.io"] = true,
	["discovery.k8s.io"] = true,
	["events.k8s.io"] = true,
	["flowcontrol.apiserver.k8s.io"] = true,
	["networking.k8s.io"] = true,
	["node.k8s.io"] = true,
	["policy"] = true,
	["rbac.authorization.k8s.io"] = true,
	["scheduling.k8s.io"] = true,
	["storage.k8s.io"] = true,
}

M.defaults = {
	kubectl_bin = "kubectl",
	kubectl_timeout_ms = 5000,
	context = nil,
	auto_refresh = true,
	refresh_events = { "BufEnter", "BufWritePost" },
	notify_on_auto_refresh = false,
	cache_ttl_seconds = 300,
	stale_on_error_seconds = 60,
	cache_dir = vim.fn.stdpath("cache") .. "/kube-yaml-schema",
	schema_store_url = "https://www.schemastore.org/api/json/catalog.json",
	notify = true,
}

local function parse_cache_ttl(opts)
	local default_ttl = M.defaults.cache_ttl_seconds
	local raw = opts and opts.cache_ttl_seconds or nil

	if type(raw) == "number" then
		return raw
	end

	if type(raw) == "table" then
		local legacy = raw.server_version or raw.crd_index or raw.context_cluster or raw.current_context
		if type(legacy) == "number" then
			return legacy
		end
	end

	return default_ttl
end

function M.normalize_options(opts)
	local normalized = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

	local cache_ttl = parse_cache_ttl(opts)
	if cache_ttl < 0 then
		cache_ttl = M.defaults.cache_ttl_seconds
	end

	normalized.cache_ttl_seconds = cache_ttl

	if type(normalized.stale_on_error_seconds) ~= "number" or normalized.stale_on_error_seconds < 0 then
		normalized.stale_on_error_seconds = M.defaults.stale_on_error_seconds
	end

	normalized.context = (type(normalized.context) == "string" and normalized.context ~= "") and normalized.context
		or nil

	if type(normalized.refresh_events) ~= "table" or #normalized.refresh_events == 0 then
		normalized.refresh_events = vim.deepcopy(M.defaults.refresh_events)
	end

	return normalized
end

return M

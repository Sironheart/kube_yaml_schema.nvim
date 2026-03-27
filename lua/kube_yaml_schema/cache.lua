local state = require("kube_yaml_schema.state")
local util = require("kube_yaml_schema.util")

local M = {}

local function ensure_parent_dir(path)
	local parent = vim.fs.dirname(path)
	if parent and vim.fn.isdirectory(parent) == 0 then
		vim.fn.mkdir(parent, "p")
	end
end

local function stat_mtime(path)
	local stat = vim.uv.fs_stat(path)
	if not stat or not stat.mtime then
		return nil
	end

	return stat.mtime.sec
end

local function normalize_schema(schema)
	if type(schema) ~= "table" then
		return nil
	end

	local normalized = vim.deepcopy(schema)
	if normalized["$schema"] == nil then
		normalized["$schema"] = "http://json-schema.org/draft-07/schema#"
	end

	return normalized
end

function M.cluster_cache_dir(cluster)
	return util.path_join(state.opts.cache_dir, util.sanitize_filename(cluster))
end

function M.cluster_version_cache_path(cluster)
	return util.path_join(M.cluster_cache_dir(cluster), "server-version.json")
end

function M.cluster_crd_cache_path(cluster)
	return util.path_join(M.cluster_cache_dir(cluster), "crd-index.json")
end

function M.schema_file_path(cluster, group, kind, version)
	local filename = string.format(
		"%s__%s__%s.json",
		util.sanitize_filename(group),
		util.sanitize_filename(kind),
		util.sanitize_filename(version)
	)
	return util.path_join(M.cluster_cache_dir(cluster), "schemas", filename)
end

function M.generated_schema_path(cluster, key)
	local filename = util.sanitize_filename(key) .. ".json"
	return util.path_join(M.cluster_cache_dir(cluster), "generated", filename)
end

function M.read_json_file(path)
	if vim.fn.filereadable(path) == 0 then
		return nil
	end

	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or not lines then
		return nil
	end

	local encoded = table.concat(lines, "\n")
	if encoded == "" then
		return nil
	end

	local decode_ok, decoded = pcall(vim.json.decode, encoded)
	if not decode_ok then
		return nil
	end

	return decoded
end

function M.write_json_file(path, data)
	local ok, encoded = pcall(vim.json.encode, data)
	if not ok or not encoded then
		return false
	end

	ensure_parent_dir(path)
	return pcall(vim.fn.writefile, { encoded }, path)
end

function M.is_cache_fresh(path, ttl_seconds)
	if ttl_seconds == 0 then
		return vim.fn.filereadable(path) == 1
	end

	local mtime = stat_mtime(path)
	if not mtime then
		return false
	end

	return (util.now() - mtime) <= ttl_seconds
end

function M.persist_schema(cluster, group, kind, version, schema)
	local normalized = normalize_schema(schema)
	if not normalized then
		return nil
	end

	local path = M.schema_file_path(cluster, group, kind, version)
	if not M.write_json_file(path, normalized) then
		return nil
	end

	return "file://" .. path
end

function M.persist_generated_schema(cluster, key, schema)
	local normalized = normalize_schema(schema)
	if not normalized then
		return nil
	end

	local path = M.generated_schema_path(cluster, key)
	if not M.write_json_file(path, normalized) then
		return nil
	end

	return "file://" .. path
end

function M.clear_all_files()
	if vim.fn.isdirectory(state.opts.cache_dir) == 1 then
		vim.fn.delete(state.opts.cache_dir, "rf")
	end
end

return M

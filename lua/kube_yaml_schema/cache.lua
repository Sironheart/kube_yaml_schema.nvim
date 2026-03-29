local state = require("kube_yaml_schema.state")
local util = require("kube_yaml_schema.util")

local M = {}

---@param path string
---@return nil
local function ensure_parent_dir(path)
  local parent = vim.fs.dirname(path)
  if parent and vim.fn.isdirectory(parent) == 0 then
    vim.fn.mkdir(parent, "p")
  end
end

---@param path string
---@return integer?
local function stat_mtime(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or not stat.mtime then
    return nil
  end

  return stat.mtime.sec
end

---@param schema table?
---@return table?
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

---@param cluster string
---@return string
function M.cluster_cache_dir(cluster)
  return util.path_join(state.opts.cache_dir, util.sanitize_filename(cluster))
end

---@param cluster string
---@return string
function M.cluster_version_cache_path(cluster)
  return util.path_join(M.cluster_cache_dir(cluster), "server-version.json")
end

---@param cluster string
---@return string
function M.cluster_crd_cache_path(cluster)
  return util.path_join(M.cluster_cache_dir(cluster), "crd-index.json")
end

---@param cluster string
---@param group string
---@param kind string
---@param version string
---@return string
function M.schema_file_path(cluster, group, kind, version)
  local filename = string.format(
    "%s__%s__%s.json",
    util.sanitize_filename(group),
    util.sanitize_filename(kind),
    util.sanitize_filename(version)
  )
  return util.path_join(M.cluster_cache_dir(cluster), "schemas", filename)
end

---@param cluster string
---@param key string
---@return string
function M.generated_schema_path(cluster, key)
  local filename = util.sanitize_filename(key) .. ".json"
  return util.path_join(M.cluster_cache_dir(cluster), "generated", filename)
end

---@param path string
---@return table?
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

---@param path string
---@param data any
---@return boolean
function M.write_json_file(path, data)
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok or not encoded then
    return false
  end

  ensure_parent_dir(path)
  return pcall(vim.fn.writefile, { encoded }, path)
end

---@param path string
---@param ttl_seconds number
---@return boolean
function M.is_cache_fresh(path, ttl_seconds)
  if ttl_seconds == 0 then
    return vim.fn.filereadable(path) == 1
  end

  local mtime = stat_mtime(path)
  if not mtime then
    return false
  end

  return (os.time() - mtime) <= ttl_seconds
end

---@param cluster string
---@param group string
---@param kind string
---@param version string
---@param schema table?
---@return string?
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

---@param cluster string
---@param key string
---@param schema table?
---@return string?
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

---@return nil
function M.clear_all_files()
  if vim.fn.isdirectory(state.opts.cache_dir) == 1 then
    vim.fn.delete(state.opts.cache_dir, "rf")
  end
end

return M

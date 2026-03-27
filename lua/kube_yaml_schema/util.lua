local state = require("kube_yaml_schema.state")

local M = {}

function M.now()
	return os.time()
end

function M.path_join(...)
	return table.concat({ ... }, "/")
end

function M.sanitize_filename(value)
	return (value or ""):gsub("[^%w%._%-]", "_")
end

function M.notify(level, message)
	if not state.opts.notify then
		return
	end

	vim.notify(message, level, { title = "kube-yaml-schema" })
end

function M.is_yaml_filetype(bufnr)
	local filetype = vim.bo[bufnr].filetype
	return filetype == "yaml" or filetype:match("^yaml") ~= nil
end

return M

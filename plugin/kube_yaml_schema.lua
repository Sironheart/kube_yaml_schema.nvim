if vim.g.loaded_kube_yaml_schema == 1 then
  return
end

vim.g.loaded_kube_yaml_schema = 1

require("kube_yaml_schema").bootstrap()

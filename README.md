# kube-yaml-schema.nvim

Session-level YAML schema resolution for Kubernetes manifests in Neovim.

This plugin configures `yamlls` to use:

- cluster-derived CRD schemas (via `kubectl`) when available,
- Kubernetes core schema for core resources,
- Schema Store fallback when no cluster schema applies.

No modelines are required.

## Disclaimer

This plugin was heavily vibe coded as a starting point. 
I used OpenAI 5.3 Codex up until v1.0.0 and will now start to use less and less AI.

I plan on maintaining it to be deprecation free with the latest stable release.

## Features

- Automatic schema application for YAML buffers.
- Multi-document YAML support (`---`) with composed per-document rules.
- Context-aware target resolution (`context -> cluster`).
- Cache scoped by cluster name.
- Manual context override with picker and commands.
- Session-only LSP configuration updates (`workspace/didChangeConfiguration`).

## Requirements

- Neovim `>= 0.11`
- `kubectl` in `$PATH`
- `yaml-language-server` / `yamlls`

## Development checks

```sh
mise run format
mise run lint
mise run smoke
# all checks
mise run check
```

## Lazy.nvim setup

```lua
{
  'Sironheart/kube_yaml_schema.nvim',
  ft = { 'yaml', 'yaml.docker-compose', 'yaml.gitlab', 'yaml.helm-values' },
  cmd = { 'KubeYamlSchema' },
  opts = {
    auto_refresh = true,
    cache_ttl_seconds = 300,
  },
}
```

The plugin auto-initializes when loaded. You can configure it via either:

- `opts = { ... }` (`require('kube_yaml_schema').setup(opts)`), or
- `vim.g.kube_yaml_schema = { ... }` (or a function returning that table).

Then use in your `yamlls` config:

```lua
yamlls = function()
  return require('kube_yaml_schema').yamlls_config()
end
```

## Lazyvim setup

If you are **really lazy** and use [LazyVim](https://lazyvim.org), do this:

- You probably already have [the YAML Extra](https://www.lazyvim.org/extras/lang/yaml) enabled. If not, enable it.
- Inside your neovim config directory, in `lua/plugins`, add `kube-yaml-schema.lua` with these contents:

```lua
return {
  "Sironheart/kube_yaml_schema.nvim",
  cmd = { 'KubeYamlSchema' },
  opts = {
    auto_refresh = true,
    cache_ttl_seconds = 300,
  },
  config = function(_, opts)
    -- Setup the plugin
    require("kube-yaml-schema").setup(opts)

    vim.lsp.config('yamlls', require('kube_yaml_schema').yamlls_config())
  end,
}
```

This takes care of adding kube_yaml_schema.nvim plugin and configuring `yamlls`, all in one file.

## Options

```lua
{
  kubectl_bin = 'kubectl',
  kubectl_timeout_ms = 5000,
  context = nil, -- nil => follow kubectl current-context
  auto_refresh = true,
  refresh_events = { 'BufEnter', 'BufWritePost' },
  notify_on_auto_refresh = false,
  notify = true,
  cache_ttl_seconds = 300,
  stale_on_error_seconds = 60,
  cache_dir = vim.fn.stdpath('cache') .. '/kube-yaml-schema',
  schema_store_url = 'https://www.schemastore.org/api/json/catalog.json',
}
```

## Commands

- `:KubeYamlSchema refresh` refresh current buffer.
- `:KubeYamlSchema refresh-all` refresh all open YAML buffers.
- `:KubeYamlSchema context` open context picker (active context preselected).
- `:KubeYamlSchema context <name>` switch to explicit context.
- `:KubeYamlSchema context auto` clear override and follow `kubectl current-context`.
- `:KubeYamlSchema context current` show active context/cluster.
- `:KubeYamlSchema clear-cache` clear on-disk and runtime cache.

Legacy commands still work and emit deprecation warnings:

- `:KubeYamlSchemaRefresh`
- `:KubeYamlSchemaRefreshAll`
- `:KubeYamlSchemaContext`
- `:KubeYamlSchemaClearCache`

Run `:checkhealth kube_yaml_schema` for troubleshooting.

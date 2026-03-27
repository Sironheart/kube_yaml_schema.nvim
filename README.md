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

## Lazy.nvim setup

```lua
{
  'your-org/kube-yaml-schema.nvim',
  ft = { 'yaml', 'yaml.docker-compose', 'yaml.gitlab', 'yaml.helm-values' },
  cmd = {
    'KubeYamlSchemaRefresh',
    'KubeYamlSchemaRefreshAll',
    'KubeYamlSchemaContext',
    'KubeYamlSchemaClearCache',
  },
  opts = {
    auto_refresh = true,
    cache_ttl_seconds = 300,
  },
}
```

Then use in your `yamlls` config:

```lua
yamlls = function()
  return require('kube_yaml_schema').yamlls_config()
end
```

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

- `:KubeYamlSchemaRefresh` refresh current buffer.
- `:KubeYamlSchemaRefreshAll` refresh all open YAML buffers.
- `:KubeYamlSchemaContext` open context picker (active context preselected).
- `:KubeYamlSchemaContext <name>` switch to explicit context.
- `:KubeYamlSchemaContext auto` clear override and follow `kubectl current-context`.
- `:KubeYamlSchemaContext current` show active context/cluster.
- `:KubeYamlSchemaClearCache` clear on-disk and runtime cache.


---@meta

---@class KubeYamlSchemaLegacyCacheTtlOptions
---@field server_version? number
---@field crd_index? number
---@field context_cluster? number
---@field current_context? number

---@class KubeYamlSchemaOptions
---@field kubectl_bin string
---@field kubectl_timeout_ms number
---@field context string?
---@field auto_refresh boolean
---@field refresh_events string[]
---@field notify_on_auto_refresh boolean
---@field cache_ttl_seconds number|KubeYamlSchemaLegacyCacheTtlOptions
---@field stale_on_error_seconds number
---@field cache_dir string
---@field schema_store_url string
---@field notify boolean

---@class KubeYamlSchemaOptionsInput
---@field kubectl_bin? string
---@field kubectl_timeout_ms? number
---@field context? string?
---@field auto_refresh? boolean
---@field refresh_events? string[]
---@field notify_on_auto_refresh? boolean
---@field cache_ttl_seconds? number|KubeYamlSchemaLegacyCacheTtlOptions
---@field stale_on_error_seconds? number
---@field cache_dir? string
---@field schema_store_url? string
---@field notify? boolean

---@class KubeYamlSchemaNormalizedOptions: KubeYamlSchemaOptions
---@field cache_ttl_seconds number

---@class KubeYamlSchemaCurrentContextCache
---@field value string?
---@field expires_at number

---@class KubeYamlSchemaKubeconfigCache
---@field contexts string[]?
---@field context_to_cluster table<string, string>?
---@field expires_at number

---@class KubeYamlSchemaKubeconfigParsed
---@field contexts string[]
---@field context_to_cluster table<string, string>

---@class KubeYamlSchemaVersionCacheEntry
---@field version string
---@field expires_at number

---@class KubeYamlSchemaCrdVersion
---@field name string
---@field served boolean
---@field storage boolean
---@field schema table?

---@class KubeYamlSchemaCrdIndexEntry
---@field group string
---@field kind string
---@field name string?
---@field versions table<string, KubeYamlSchemaCrdVersion>
---@field version_order string[]

---@class KubeYamlSchemaCrdIndex
---@field by_key table<string, KubeYamlSchemaCrdIndexEntry>

---@class KubeYamlSchemaBufferOverride
---@field uri string
---@field name string?

---@class KubeYamlSchemaClientState
---@field base_schemas table<string, any>
---@field overrides table<integer, KubeYamlSchemaBufferOverride>
---@field last_applied string?

---@class KubeYamlSchemaState
---@field initialized boolean
---@field opts KubeYamlSchemaNormalizedOptions
---@field context KubeYamlSchemaCurrentContextCache
---@field kubeconfig KubeYamlSchemaKubeconfigCache
---@field kubeconfig_inflight KubeYamlSchemaKubeconfigWaiter[]?
---@field version_cache table<string, KubeYamlSchemaVersionCacheEntry>
---@field version_inflight table<string, KubeYamlSchemaVersionWaiter[]>
---@field crd_cache table<string, { index: KubeYamlSchemaCrdIndex, expires_at: number }>
---@field crd_inflight table<string, KubeYamlSchemaCrdIndexWaiter[]>
---@field refresh_tokens table<integer, integer>
---@field client_states table<integer, KubeYamlSchemaClientState>

---@class KubeYamlSchemaResource
---@field group string
---@field version string
---@field kind string
---@field core boolean

---@class KubeYamlSchemaTarget
---@field context string
---@field cluster string

---@class KubeYamlSchemaContextEntry
---@field context string
---@field cluster string

---@class KubeYamlSchemaContextSelectItem
---@field label string
---@field value string?
---@field context string?
---@field cluster string?

---@class KubeYamlSchemaResolvedSchema
---@field name string
---@field uri string

---@alias KubeYamlSchemaResolveReason
---| "no-kubernetes-resource"
---| "context-unavailable"
---| "resolution-error"
---| "no-cluster-schema"
---| "single-schema"
---| "multi-document"
---| "cache-write-failed"

---@class KubeYamlSchemaResolveResult
---@field reason KubeYamlSchemaResolveReason
---@field schema KubeYamlSchemaResolvedSchema?

---@class KubeYamlSchemaResolverEntry
---@field rule_key string
---@field resource KubeYamlSchemaResource
---@field uri string
---@field name string

---@class KubeYamlSchemaRefreshOpts
---@field notify boolean?

---@alias KubeYamlSchemaSystemCallback fun(result: vim.SystemCompleted)
---@alias KubeYamlSchemaWaiter fun(payload: any, err: string?)
---@alias KubeYamlSchemaContextWaiter fun(context: string?, err: string?)
---@alias KubeYamlSchemaTargetWaiter fun(target: KubeYamlSchemaTarget?, err: string?)
---@alias KubeYamlSchemaContextEntriesWaiter fun(entries: KubeYamlSchemaContextEntry[]?, err: string?)
---@alias KubeYamlSchemaContextsWaiter fun(contexts: string[]?, err: string?)
---@alias KubeYamlSchemaExistsWaiter fun(exists: boolean, err: string?)
---@alias KubeYamlSchemaVersionWaiter fun(version: string?, err: string?)
---@alias KubeYamlSchemaCrdIndexWaiter fun(index: KubeYamlSchemaCrdIndex?, err: string?)
---@alias KubeYamlSchemaKubeconfigWaiter fun(data: KubeYamlSchemaKubeconfigCache?, err: string?)
---@alias KubeYamlSchemaResolveWaiter fun(result: KubeYamlSchemaResolveResult, err: string?)

# ADR-0001: Direct K8s API Client

## Status

Accepted

## Context

The K8s executor currently shells out to `kubectl` for all Kubernetes operations:
- `kubectl apply -f -` to create Jobs
- `kubectl wait` to poll for completion
- `kubectl logs` to fetch output
- `kubectl delete` to cleanup

This approach has several problems:
1. **Fragility**: Parsing text output, shell escaping issues
2. **Performance**: Process spawning overhead for each operation
3. **Error handling**: Limited error information from CLI output
4. **Dependency**: Requires kubectl binary installed and in PATH
5. **Bug #27**: `System.cmd` doesn't support stdin piping, leading to Port complexity

We need a native K8s API client that:
- Works in-cluster (service account) and locally (kubeconfig)
- Provides typed errors and proper HTTP status handling
- Has no external binary dependencies
- Integrates cleanly with the existing executor architecture

## Decision

### 1. Module Structure

```
lib/sykli/k8s/
├── client.ex          # HTTP layer, request/response handling
├── auth.ex            # Auth detection and config building
├── kubeconfig.ex      # Kubeconfig YAML parsing
├── resources/
│   ├── job.ex         # batch/v1 Job operations
│   ├── pod.ex         # v1 Pod operations (logs)
│   └── namespace.ex   # v1 Namespace operations
└── error.ex           # Typed error struct
```

### 2. Auth Strategy

Auto-detect environment with fallback chain:

```
1. In-cluster?  → Read /var/run/secrets/kubernetes.io/serviceaccount/token
2. Kubeconfig?  → Parse ~/.kube/config or $KUBECONFIG, use current-context
3. Neither      → Return {:error, :no_auth}
```

### 3. Supported Auth Methods (v1)

| Method | Support | Notes |
|--------|---------|-------|
| In-cluster service account | ✅ | Token file + CA cert |
| Kubeconfig: static token | ✅ | `user.token` field |
| Kubeconfig: client cert | ✅ | `user.client-certificate` + `user.client-key` |
| Kubeconfig: exec command | ❌ v2 | EKS, GKE - requires process spawning, token caching |
| Kubeconfig: auth-provider | ❌ v2 | OIDC - complex refresh logic |

### 4. HTTP Client

Use Erlang's built-in `:httpc`:
- No additional dependencies
- Already used for GitHub API integration
- Supports TLS with custom CA certs

### 5. Retry Strategy

Retry on 5xx errors with exponential backoff:
- Max retries: 3
- Delays: 100ms → 200ms → 400ms
- No retry on 4xx (client errors)

### 6. Job Completion Detection

Poll-based (not watch):
- Simpler implementation
- No connection management
- Sufficient for job completion use case
- Poll interval: 1 second

Watch API deferred to v2 (requires handling reconnects, bookmarks, resource versions).

### 7. Dependencies

Add `yaml_elixir` for kubeconfig parsing:
- Well-maintained, small footprint
- Kubeconfig is complex YAML with anchors/aliases
- Regex parsing would be fragile

### 8. Error Types

```elixir
defmodule Sykli.K8s.Error do
  @type error_type ::
    :auth_failed |      # 401
    :forbidden |        # 403
    :not_found |        # 404
    :conflict |         # 409 (already exists)
    :timeout |          # Request timeout
    :api_error |        # Other 4xx/5xx
    :connection_error   # Network issues

  defstruct [:type, :message, :status_code, :reason, :details]
end
```

## Consequences

### Positive

1. **No kubectl dependency**: Works in minimal container images
2. **Better errors**: Typed errors with K8s API reason codes
3. **Testable**: Can mock HTTP layer for unit tests
4. **Faster**: No process spawning overhead
5. **Reliable**: No shell escaping or output parsing bugs

### Negative

1. **New dependency**: `yaml_elixir` added to mix.exs
2. **Auth limitations**: Exec auth (EKS/GKE) not supported in v1
3. **Maintenance**: Own the HTTP/TLS complexity

### Neutral

1. **Code size**: ~500 lines for full client implementation
2. **Testing**: Need to mock :httpc or use integration tests with kind

## API Examples

### Creating a Job

```elixir
{:ok, config} = Sykli.K8s.Auth.detect()

manifest = %{
  "apiVersion" => "batch/v1",
  "kind" => "Job",
  "metadata" => %{"name" => "my-job", "namespace" => "default"},
  "spec" => %{...}
}

case Sykli.K8s.Resources.Job.create(manifest, config) do
  {:ok, job} ->
    IO.puts("Created job: #{job["metadata"]["name"]}")
  {:error, %{type: :conflict}} ->
    IO.puts("Job already exists")
  {:error, error} ->
    IO.puts("Failed: #{error.message}")
end
```

### Waiting for Completion

```elixir
case Sykli.K8s.Resources.Job.wait_complete("my-job", "default", 300, config) do
  {:ok, :succeeded} -> :ok
  {:ok, :failed} -> {:error, :job_failed}
  {:error, %{type: :timeout}} -> {:error, :timeout}
end
```

## References

- [K8s API Reference](https://kubernetes.io/docs/reference/kubernetes-api/)
- [Kubeconfig Specification](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/)
- [In-cluster Configuration](https://kubernetes.io/docs/tasks/access-application-cluster/access-cluster/#accessing-the-api-from-a-pod)

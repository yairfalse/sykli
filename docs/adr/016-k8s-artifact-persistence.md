# ADR 016: K8s Artifact Persistence

## Status
Proposed

## Context

Sykli supports artifact passing between tasks via `output()` and `inputFrom()`:

```rust
// Task A produces an artifact
p.task("build")
    .run("cargo build --release")
    .output("binary", "./target/release/app");

// Task B consumes it
p.task("deploy")
    .input_from("build", "binary", "/app/bin")
    .run("./deploy.sh /app/bin");
```

**Local execution:** Works perfectly. Artifacts are files on disk.

**K8s execution:** Broken. Each Job is a separate Pod with its own filesystem.

```
Job: sykli-build-a1b2        Job: sykli-deploy-c3d4
┌─────────────────────┐      ┌─────────────────────┐
│ emptyDir: /workspace│      │ emptyDir: /workspace│
│                     │      │                     │
│ → produces binary   │      │ → expects binary    │
│   at /workspace/... │      │   at /app/bin       │
└─────────────────────┘      └─────────────────────┘
         ↓                            ↓
    [pod dies]                  [binary not found!]
    [data lost]
```

**Existing code (unused):**
```elixir
# target/k8s.ex line 54, 97
:artifact_pvc,
artifact_pvc: Keyword.get(opts, :artifact_pvc, "sykli-artifacts")
```

The field exists but is never wired into Job manifests.

## Decision

### 1. Shared Artifact PVC

All Sykli Jobs in a namespace share a single PVC for artifact storage:

```
PVC: sykli-artifacts (RWX)
├── build/
│   └── binary           ← written by build job
├── test/
│   └── coverage.html    ← written by test job
└── deploy/
    └── manifest.yaml    ← written by deploy job
```

**Job manifest:**
```yaml
volumes:
  - name: artifacts
    persistentVolumeClaim:
      claimName: sykli-artifacts

containers:
  - name: task
    volumeMounts:
      - name: artifacts
        mountPath: /sykli/artifacts
```

### 2. Artifact Path Convention

```
/sykli/artifacts/<run-id>/<task-name>/<output-name>
```

Example:
```
/sykli/artifacts/2024-01-15-abc123/build/binary
/sykli/artifacts/2024-01-15-abc123/test/coverage
```

**Why run-id?**
- Prevents collision between concurrent runs
- Enables artifact cleanup by run
- Supports artifact caching across runs (if same content)

### 3. Implementation

**Artifact storage (in build task):**
```elixir
# After task completes, copy outputs to artifact PVC
defp store_artifacts(task, run_id, state) do
  for {name, path} <- task.outputs do
    artifact_path = "/sykli/artifacts/#{run_id}/#{task.name}/#{name}"
    # Copy via kubectl cp or init container
    copy_to_pvc(path, artifact_path, state)
  end
end
```

**Artifact retrieval (in dependent task):**
```elixir
# Before task runs, copy inputs from artifact PVC
defp retrieve_artifacts(task, run_id, state) do
  for %TaskInput{from_task: from, output: output, dest: dest} <- task.task_inputs do
    artifact_path = "/sykli/artifacts/#{run_id}/#{from}/#{output}"
    # Copy to task workspace
    copy_from_pvc(artifact_path, dest, state)
  end
end
```

**Job manifest changes:**
```elixir
def build_job_manifest(task, job_name, state, opts) do
  run_id = Keyword.fetch!(opts, :run_id)

  # Add artifact PVC volume
  volumes = [
    %{"name" => "artifacts", "persistentVolumeClaim" => %{"claimName" => state.artifact_pvc}}
    | build_volumes(task, k8s_opts)
  ]

  # Add artifact volume mount
  artifact_mount = %{
    "name" => "artifacts",
    "mountPath" => "/sykli/artifacts"
  }

  # Init container to retrieve input artifacts
  init_containers = build_artifact_init_containers(task, run_id, state)

  # ... rest of manifest
end
```

### 4. PVC Lifecycle

**Creation:**
```bash
# Auto-created on first K8s run if not exists
sykli run --target=k8s
# → Creates PVC "sykli-artifacts" if missing
```

**Manual creation (for custom storage class):**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sykli-artifacts
  namespace: sykli
spec:
  accessModes:
    - ReadWriteMany  # Required for parallel jobs
  storageClassName: nfs  # Or efs, azurefile, etc.
  resources:
    requests:
      storage: 10Gi
```

**Cleanup:**
```bash
# Delete artifacts older than 7 days
sykli cache clean --k8s --older-than=7d

# Delete specific run's artifacts
sykli cache clean --k8s --run-id=2024-01-15-abc123
```

### 5. Storage Class Requirements

The PVC needs `ReadWriteMany` (RWX) access mode for parallel Jobs.

**Compatible storage classes:**
| Provider | Storage Class | Notes |
|----------|---------------|-------|
| AWS | EFS | Native RWX |
| GCP | Filestore | Native RWX |
| Azure | Azure Files | Native RWX |
| On-prem | NFS | Classic choice |
| Any | Longhorn | Open source |

**Single-node clusters (minikube, kind):**
```elixir
# Fall back to emptyDir with coordinator copying
config :sykli, :k8s,
  artifact_strategy: :coordinator_copy  # Not PVC
```

### 6. Alternative: S3 Artifacts

For clusters without RWX storage:

```elixir
config :sykli, :k8s,
  artifact_storage: :s3,
  artifact_bucket: "my-artifacts",
  artifact_prefix: "sykli/"
```

**Flow:**
1. Build task → uploads artifact to S3
2. Deploy task → downloads artifact from S3

**Pros:** Works everywhere, no RWX needed
**Cons:** Slower (network round-trip), requires S3 setup

### 7. Coordinator Copy Strategy

For simple cases without PVC or S3:

```
                    ┌─────────────────┐
                    │ Sykli Coordinator│
                    │ (your laptop)   │
                    └────────┬────────┘
                             │
         ┌───────────────────┼───────────────────┐
         │ kubectl cp        │ kubectl cp        │
         ↓                   ↓                   ↓
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ Job: build      │ │ Job: test       │ │ Job: deploy     │
│ → outputs binary│ │                 │ │ ← needs binary  │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

1. Build job finishes → coordinator `kubectl cp` output to local
2. Deploy job starts → coordinator `kubectl cp` input to pod

**Pros:** No infrastructure needed
**Cons:** Coordinator must stay running, network bottleneck

### 8. Configuration

```elixir
# .sykli/config.exs
config :sykli, :k8s,
  artifact_strategy: :pvc,         # :pvc | :s3 | :coordinator
  artifact_pvc: "sykli-artifacts", # PVC name
  artifact_size: "10Gi",           # Auto-create size
  artifact_storage_class: nil,     # Use default if nil
  artifact_cleanup_days: 7         # Auto-cleanup
```

**Environment variables:**
```bash
SYKLI_K8S_ARTIFACT_PVC=sykli-artifacts
SYKLI_K8S_ARTIFACT_STRATEGY=pvc
```

## Consequences

**Positive:**
- `inputFrom()` works in K8s
- Parallel Jobs can share artifacts
- Artifacts persist across retries

**Negative:**
- Requires RWX storage (or S3 fallback)
- PVC adds infrastructure complexity
- Cleanup needs management

## Implementation Phases

**Phase 1: PVC Strategy**
- Wire up existing `artifact_pvc` field
- Add artifact volume to Job manifests
- Implement store/retrieve in init containers

**Phase 2: S3 Strategy**
- S3 upload/download in init containers
- Integrates with ADR-014 (Remote Cache)

**Phase 3: Coordinator Strategy**
- Fallback for simple setups
- Uses `kubectl cp`

**Phase 4: Cleanup**
- `sykli cache clean --k8s`
- Automatic TTL-based cleanup

## Related ADRs

- **ADR-014 (Remote Cache)**: S3 artifact storage can share infrastructure
- **ADR-015 (K8s Source Mounting)**: Source and artifacts use same patterns

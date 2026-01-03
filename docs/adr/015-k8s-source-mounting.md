# ADR 015: K8s Source Mounting

## Status
Proposed

## Context

The K8s target (`Sykli.Target.K8s`) can create Jobs, but source code mounting is broken:

**Current Implementation:**
```elixir
# target/k8s.ex line 539-545
case m.type do
  "directory" ->
    # For directories, we'd need a PVC or hostPath
    # For now, use emptyDir (loses data)
    %{
      "name" => unique_volume_name(m.resource),
      "emptyDir" => %{}
    }
end
```

This means when a task says `mount(src, "/app")`, the K8s Job gets an **empty directory**. The source code never arrives.

**Current Flow:**
```
sykli.rs defines:
  task("build")
    .container("rust:1.75")
    .mount(src, "/app")
    .run("cargo build")

K8s Job gets:
  volumes:
    - name: src-abc1
      emptyDir: {}     ← Empty! No source code!

  containers:
    - command: ["sh", "-c", "cargo build"]
      volumeMounts:
        - name: src-abc1
          mountPath: /app  ← Empty directory
```

**Result:** Every K8s task fails with "cargo.toml not found" or similar.

## Decision

### 1. Three Source Mounting Strategies

| Strategy | Use Case | Pros | Cons |
|----------|----------|------|------|
| **Git Clone** | CI, fresh checkouts | Always latest, no PVC | Adds 5-30s clone time |
| **PVC Sync** | Persistent workloads | Fast, reusable | Requires RWX PVC |
| **S3 Fetch** | Large repos, caching | Parallel download | Requires S3 setup |

Default: **Git Clone** (works everywhere, no setup required).

### 2. Git Clone Strategy (Default)

Add an init container that clones the repo before the main container runs:

```yaml
apiVersion: batch/v1
kind: Job
spec:
  template:
    spec:
      initContainers:
        - name: git-clone
          image: alpine/git:latest
          command:
            - sh
            - -c
            - |
              git clone --depth=1 --branch=${GIT_BRANCH} ${GIT_URL} /workspace
              cd /workspace && git checkout ${GIT_SHA}
          env:
            - name: GIT_URL
              value: "https://github.com/org/repo.git"
            - name: GIT_BRANCH
              value: "main"
            - name: GIT_SHA
              value: "abc1234"
          volumeMounts:
            - name: workspace
              mountPath: /workspace

      containers:
        - name: task
          image: rust:1.75
          workingDir: /workspace
          command: ["sh", "-c", "cargo build"]
          volumeMounts:
            - name: workspace
              mountPath: /workspace

      volumes:
        - name: workspace
          emptyDir: {}  # Shared between init and main container
```

**Git context detection:**
```elixir
defmodule Sykli.GitContext do
  def detect(workdir) do
    %{
      url: git_remote_url(workdir),
      branch: git_branch(workdir),
      sha: git_sha(workdir),
      dirty: git_dirty?(workdir)
    }
  end
end
```

### 3. Private Repo Authentication

```elixir
# Option 1: SSH key from Secret
k8s: K8s.options()
  |> K8s.git_secret("git-ssh-key")  # mounts ~/.ssh/id_rsa

# Option 2: HTTPS token from Secret
k8s: K8s.options()
  |> K8s.git_token_secret("git-token")  # sets GIT_ASKPASS

# Option 3: Git credential helper
k8s: K8s.options()
  |> K8s.git_credentials("git-creds")  # mounts .git-credentials
```

**Generated manifest:**
```yaml
initContainers:
  - name: git-clone
    env:
      - name: GIT_SSH_KEY
        valueFrom:
          secretKeyRef:
            name: git-ssh-key
            key: id_rsa
    command:
      - sh
      - -c
      - |
        mkdir -p ~/.ssh
        echo "$GIT_SSH_KEY" > ~/.ssh/id_rsa
        chmod 600 ~/.ssh/id_rsa
        ssh-keyscan github.com >> ~/.ssh/known_hosts
        git clone git@github.com:org/repo.git /workspace
```

### 4. Dirty Workdir Handling

If local workdir has uncommitted changes:

```elixir
case GitContext.detect(workdir) do
  %{dirty: true} ->
    # Option A: Warn and use HEAD
    Logger.warn("Workdir has uncommitted changes, K8s will use HEAD")

    # Option B: Fail
    {:error, :dirty_workdir}

    # Option C: Create temp commit (dangerous)
    # Not recommended
end
```

**CLI flag:**
```bash
sykli run --target=k8s --allow-dirty  # Use HEAD despite dirty workdir
```

### 5. PVC Sync Strategy (Optional)

For teams with persistent K8s infrastructure:

```elixir
# .sykli/config.exs
config :sykli, :k8s,
  source_strategy: :pvc,
  source_pvc: "sykli-source",
  source_sync: :rsync  # or :git
```

**Flow:**
1. Before Job: sync local → PVC via `kubectl cp` or rsync pod
2. Job runs with PVC mounted
3. After Job: sync outputs back (if needed)

**Tradeoff:** Requires RWX (ReadWriteMany) PVC, which not all storage classes support.

### 6. Implementation

**New files:**
```
core/lib/sykli/
├── git_context.ex          # Detect git URL/branch/sha
└── target/
    └── k8s/
        └── source.ex       # Source mounting strategies
```

**Modified:**
```elixir
# target/k8s.ex

def build_job_manifest(task, job_name, state, opts) do
  # Get git context from opts or detect
  git_ctx = Keyword.get(opts, :git_context) || GitContext.detect(state.workdir)

  # Build init container for git clone
  init_containers = build_source_init_containers(task, git_ctx, state)

  # Rest of manifest building...
end

defp build_source_init_containers(task, git_ctx, state) do
  case state.source_strategy do
    :git_clone -> [git_clone_init_container(git_ctx, state)]
    :pvc -> []  # PVC is pre-mounted
    :s3 -> [s3_fetch_init_container(task, state)]
  end
end
```

### 7. CLI Integration

```bash
# Show detected git context
sykli info
# Git: https://github.com/org/repo.git
# Branch: main
# SHA: abc1234
# Status: clean

# Override git context
sykli run --target=k8s --git-ref=feature/foo

# Force specific strategy
sykli run --target=k8s --source-strategy=pvc
```

## Consequences

**Positive:**
- K8s target actually works for real builds
- No infra requirements for git clone strategy
- Private repos supported via Secrets

**Negative:**
- Clone time added to each Job (5-30s)
- Dirty workdir is a foot-gun (warns by default)
- PVC strategy requires specific infra

## Migration

Existing K8s users (if any) will see:
1. Jobs now succeed (source code present)
2. New init container in Job spec
3. Slightly longer Job startup time

## Open Questions

1. **Shallow clone depth**: Default `--depth=1` or full clone?
2. **Submodules**: Auto-init submodules?
3. **LFS**: Handle Git LFS files?
4. **Monorepo sparse checkout**: Only clone relevant paths?

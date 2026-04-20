# Cache Key Investigation

## What `cache_key/2` currently includes

`Sykli.Cache.cache_key/2` in [core/lib/sykli/cache.ex](/home/yair/projects/sykli/core/lib/sykli/cache.ex) currently hashes these inputs, in order:

- `project_fingerprint(abs_workdir)`
- `task.name`
- `task.command`
- `hash_inputs(task.inputs || [], abs_workdir)`
- `hash_env()`
- `task.container || ""`
- `hash_task_env(task.env || %{})`
- `hash_mounts(task.mounts || [])`
- `hash_secret_refs(task.secret_refs || [])`
- `@version`

The important detail is `project_fingerprint/1`:

- if `Sykli.Git.remote_url(cd: workdir)` returns an origin URL, the fingerprint is `sha256(remote_url)`
- otherwise it falls back to `sha256(abs_workdir)`

So for any two directories inside the same Git repo with the same `origin`, the fingerprint is identical even if the directories differ.

## What the test expects

The failing test at [core/test/sykli/cache_unit_test.exs:88](/home/yair/projects/sykli/core/test/sykli/cache_unit_test.exs:88) creates:

- `dir`
- `other_dir = Path.join(dir, "other_project")`

Then it computes:

- `Cache.cache_key(task, dir)`
- `Cache.cache_key(task, other_dir)`

and expects them to differ.

That expectation is currently false on this branch. Re-running `mix test test/sykli/cache_unit_test.exs:88` still fails, with both keys equal to:

- `816bab8fe2ce7595c3f11980b50046c6b417314e64a2a09f9f6b7894cb707032`

## Code bug or test bug

This looks like a **code bug**, not a test bug.

Reasoning:

- The cache key is supposed to cover all factors that affect task outputs.
- Two different workdirs can contain different files, different generated state, and different relative-path semantics even when they live in the same Git repo.
- Using only the repo remote URL as the project fingerprint treats every subdirectory in that repo as the same cache namespace.
- That is too coarse for monorepos, nested projects, or tests that intentionally create distinct project roots under one repo checkout.

The current implementation comment says:

- “project fingerprint prevents cross-project cache pollution”

That statement is only partially true. It prevents cross-repo collisions, but not cross-project collisions inside one repo.

## Proposed fix

Change `project_fingerprint/1` so it distinguishes subprojects within the same repo.

The most likely safe direction is:

- keep repo identity in the fingerprint
- also include workdir identity relative to the repo root

For example:

- fingerprint input = `remote_url <> "|" <> repo_relative_workdir`
- fallback for non-git dirs = absolute workdir path, as today

That would preserve sharing across machines for the same repo/subproject while preventing cache collisions between different subdirectories in the same repository.

I would **not** change the test first. The test is protecting a real correctness property.

One migration caveat:

- changing `cache_key/2` changes cache namespace layout, so existing entries become cold misses unless a migration or dual-read strategy is added.

## Persistence implications

S1.5b added the required grep pass before implementing the fix. That pass found meaningful uses of cache keys outside the cache module, so the fix should not land as a local cache-only change yet.

Meaningful hits:

- [core/lib/sykli/occurrence/task_cached.ex](/home/yair/projects/sykli/core/lib/sykli/occurrence/task_cached.ex)
  - `TaskCached` persists `cache_key` in the occurrence payload struct.
- [core/lib/sykli/occurrence/cache_miss.ex](/home/yair/projects/sykli/core/lib/sykli/occurrence/cache_miss.ex)
  - `CacheMiss` persists `cache_key` in the occurrence payload struct.
- [core/lib/sykli/occurrence/pubsub.ex](/home/yair/projects/sykli/core/lib/sykli/occurrence/pubsub.ex)
  - occurrence pubsub publishes those payloads with cache keys.
- [core/lib/sykli/occurrence.ex](/home/yair/projects/sykli/core/lib/sykli/occurrence.ex)
  - `task_cached/4` and `cache_miss/5` build persisted occurrences containing the key.
- [core/lib/sykli/executor.ex](/home/yair/projects/sykli/core/lib/sykli/executor.ex)
  - executor emits those occurrences on cache hit and miss paths.

Non-blocking / not meaningful for this decision:

- [core/lib/sykli/attestation.ex](/home/yair/projects/sykli/core/lib/sykli/attestation.ex)
  - calls `Cache.cache_key/2` for lookup, but the grep did not show the key being serialized into persisted attestation output.
- `sdk/typescript/node_modules/rollup/dist/rollup.d.ts`
  - third-party dependency type definition mentioning `cacheKey`; not a Sykli SDK output contract.

Conclusion:

- cache keys are part of emitted occurrence payloads, so changing fingerprint semantics changes externally visible identifiers
- this is enough to give the fix migration and compatibility implications
- per S1.5b, Step 2 should not execute until that design is reviewed

## Resolution (2026-04-20)

Accepted the breaking change. Implemented the fingerprint fix in S1.5c without
a migration path.

Rationale:
- Sykli has no production users whose historical occurrences matter.
- The correctness bug (cross-project cache collisions in monorepos) is
  unacceptable to carry forward.
- Migration infrastructure (~2-3 agent-weeks) is not justified at the current
  stage.

Effects:
- Occurrences emitted before this change reference cache keys computed under
  the v1 scheme. Those keys cannot be recomputed and do not resolve to current
  cache entries.
- `cache_key_version` field added to `task_cached` and `cache_miss` payloads
  to distinguish schemes if the scheme changes again.
- Existing on-disk cache entries become unreachable. This is intentional;
  they were potentially collision-contaminated under v1.

Investigation closed.

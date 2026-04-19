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

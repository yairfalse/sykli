# Oracle Cases

Phase 2.5 oracle cases are requirement-level contracts. They describe what a
blind tester observes through the `sykli` binary, stdout/stderr, exit codes,
files under `.sykli/`, or network endpoints. They do not import sykli modules.

## YAML Schema

```yaml
id: ORACLE-001
category: cache
source: "README.md §Content-addressed caching"
validated_by: "Concrete injected bug this case would catch."
finding: "Observed gap, if the case currently fails."
fixture: "test/blackbox/fixtures/cache_side_effect.exs"
command: "sykli"
assertions:
  - "observable assertion"
```

The executable black-box form lives in `test/blackbox/dataset.json`. These YAML
files are the durable oracle notes for requirement provenance and follow-up bug
work.

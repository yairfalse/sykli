# Definition Of Done

Sykli ships for two co-equal surfaces: humans reading the CLI and agents reading structured output or invoking MCP tools. A command or feature is done only when both surfaces meet these criteria.

## 1. Error Path

**Assertion:** every user-visible error is a `Sykli.Error` with a stable `code`, a human-readable `message`, and at least one `hint` whose final sentence is a copy-pasteable next action.

- Good: `Sykli.Error.no_sdk_file/0` tells the user no SDK file exists and points them to `sykli init`.
- Bad: returning `{:error, :invalid_format}` directly from a CLI handler is not done; agents get an atom, humans get prose only after ad hoc wrapping.

Test by forcing the failure in both normal output and `--json`; the JSON envelope must expose the same code and actionable hint.

## 2. Summary Output

**Assertion:** human output uses ADR-020 glyph language, carries status by glyph rather than color alone, and emits exactly one summary per run.

- Good: a passing run uses `●` task rows and one `─  N passed` summary.
- Bad: legacy output such as `All tasks completed`, `Level`, line-count suffixes, or a red failed glyph next to "Run passed" is not done.

Test with a passing, cached, failed, and blocked fixture; screenshots without color must remain understandable.

## 3. One-Line Invocation

**Assertion:** the common path requires zero flags or one obvious flag, and any required argument is visible in `--help`.

- Good: `sykli` runs the detected pipeline; `sykli validate` validates the detected pipeline.
- Bad: `sykli validate sykli.exs` failing because the path was ignored is not done.

Test the documented invocation exactly as written in help and README.

## 4. Explain And Fix Integration

**Assertion:** command results appear in `sykli explain` and `sykli fix` through the standard task-summary and fix-analysis blocks, without command-specific rendering branches.

- Good: a failed task stores an enriched occurrence that `sykli fix --json` can read.
- Bad: a feature that only prints terminal text and writes no occurrence data is not done.

Test by running the feature, then running `sykli explain` and `sykli fix --json` against the produced `.sykli/` state.

## 5. Agent Surface

**Assertion:** the command supports `--json` in any flag position, returns the `Sykli.CLI.JsonResponse` envelope, exposes cataloged error codes, has an MCP counterpart or documented exception, and is terse by default.

- Good: `sykli validate --json` emits one newline-terminated envelope: `ok`, `version`, `data`, `error`.
- Bad: `sykli --json validate` showing colored human UI, or an MCP tool returning rendered terminal text when structured data is available, is not done.

Test both flag orders, parse the response as JSON, and compare the envelope shape.

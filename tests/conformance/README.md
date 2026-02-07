# SDK Conformance Tests

Verifies that all SDKs produce identical JSON output for the same pipeline definitions.

## Structure

```
tests/conformance/
├── cases/              # Test case definitions
│   ├── 01-basic.json   # Expected output for basic pipeline
│   ├── 02-deps.json    # Expected output for dependencies
│   └── ...
├── fixtures/           # Pipeline source per SDK
│   ├── go/
│   ├── rust/
│   ├── typescript/
│   ├── python/
│   └── elixir/
├── run.sh              # Runner script
└── README.md
```

## Usage

```bash
# Run all conformance tests
./tests/conformance/run.sh

# Run a specific case
./tests/conformance/run.sh 01-basic

# Run a specific SDK
./tests/conformance/run.sh --sdk python
```

## Adding a test case

1. Add expected JSON to `cases/<name>.json`
2. Add pipeline source in each `fixtures/<sdk>/<name>.*` file
3. Run `./tests/conformance/run.sh <name>` to verify

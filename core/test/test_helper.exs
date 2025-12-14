# Exclude integration tests by default (they require Docker)
# Run with: mix test --include integration
ExUnit.start(exclude: [:integration])

# Exclude integration tests by default (they require Docker).
# Run with: mix test --include integration
#
# :regression_guard is the runtime-isolation guard (RC.0). It stays excluded
# until RC.4c removes the pre-refactor hardcoding of runtime modules in
# core/lib/sykli/target/local.ex. Opt in early with: mix test --include regression_guard
ExUnit.start(exclude: [:integration, :regression_guard])

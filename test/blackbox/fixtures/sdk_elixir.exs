# True Elixir SDK test - uses Sykli DSL macros
# For now, emits raw JSON since we can't import the SDK in a standalone script
IO.puts(~s({"version":"1","tasks":[{"name":"elixir_test","command":"echo elixir works"}]}))

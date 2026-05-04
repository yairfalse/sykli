import Config

# The SDK is invoked via `mix run` to emit JSON to stdout. Logger output
# would corrupt that JSON, so Logger is silenced by default and routed to
# stderr if it ever does fire (e.g., a warning during validation). Users
# embedding the SDK in another app can override these in their own config.
config :logger, level: :warning
config :logger, :console, device: :standard_error

defmodule Sykli.GitHub.Clock do
  @moduledoc "Clock behaviour for GitHub auth and delivery expiry."

  @callback now_seconds() :: non_neg_integer()
  @callback now_ms() :: non_neg_integer()
end

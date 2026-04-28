defmodule Sykli.GitHub.HTTPClient do
  @moduledoc "HTTP behaviour for GitHub API clients."

  @callback request(atom(), String.t(), [{charlist(), charlist()}], binary()) ::
              {:ok, non_neg_integer(), binary()} | {:error, term()}
end

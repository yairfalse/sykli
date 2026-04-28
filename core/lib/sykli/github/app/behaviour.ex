defmodule Sykli.GitHub.App.Behaviour do
  @moduledoc "Behaviour for GitHub App installation tokens."

  @callback installation_token(pos_integer() | String.t(), keyword()) ::
              {:ok, String.t(), non_neg_integer()} | {:error, Sykli.Error.t()}
end

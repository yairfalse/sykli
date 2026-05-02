defmodule Sykli.GitHub.Source.Behaviour do
  @moduledoc "Behaviour for GitHub source acquisition."

  @callback acquire(map(), String.t(), keyword()) :: {:ok, String.t()} | {:error, Sykli.Error.t()}
  @callback cleanup(String.t(), keyword()) :: :ok
end

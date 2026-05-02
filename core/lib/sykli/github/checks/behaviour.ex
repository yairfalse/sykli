defmodule Sykli.GitHub.Checks.Behaviour do
  @moduledoc "Behaviour for GitHub Checks API clients."

  @callback create_suite(map(), String.t(), keyword()) ::
              {:ok, map()} | {:error, Sykli.Error.t()}
  @callback create_run(map(), String.t(), keyword()) :: {:ok, map()} | {:error, Sykli.Error.t()}
  @callback update_run(map(), String.t(), map(), keyword()) ::
              {:ok, map()} | {:error, Sykli.Error.t()}
end

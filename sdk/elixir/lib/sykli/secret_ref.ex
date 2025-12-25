defmodule Sykli.SecretRef do
  @moduledoc """
  Typed reference to a secret with explicit source information.

  This provides better DX than plain secret names by making the source explicit.

  ## Examples

      # Read from environment variable
      SecretRef.from_env("GITHUB_TOKEN")

      # Read from file
      SecretRef.from_file("/run/secrets/api-key")

      # Read from HashiCorp Vault
      SecretRef.from_vault("secret/data/db#password")
  """

  defstruct name: nil, source: nil, key: nil

  @type source :: :env | :file | :vault

  @type t :: %__MODULE__{
          name: String.t() | nil,
          source: source(),
          key: String.t()
        }

  @doc """
  Creates a secret reference that reads from an environment variable.

  ## Examples

      SecretRef.from_env("GITHUB_TOKEN")
  """
  @spec from_env(String.t()) :: t()
  def from_env(env_var) when is_binary(env_var) do
    %__MODULE__{source: :env, key: env_var}
  end

  @doc """
  Creates a secret reference that reads from a file.

  ## Examples

      SecretRef.from_file("/run/secrets/api-key")
  """
  @spec from_file(String.t()) :: t()
  def from_file(path) when is_binary(path) do
    %__MODULE__{source: :file, key: path}
  end

  @doc """
  Creates a secret reference that reads from HashiCorp Vault.
  The path format is "path/to/secret#field".

  ## Examples

      SecretRef.from_vault("secret/data/db#password")
  """
  @spec from_vault(String.t()) :: t()
  def from_vault(path) when is_binary(path) do
    %__MODULE__{source: :vault, key: path}
  end
end

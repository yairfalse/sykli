defmodule Sykli.Init do
  @moduledoc """
  Scaffolds a new sykli configuration file.

  Detects project type from marker files (go.mod, Cargo.toml, mix.exs)
  and generates an appropriate sykli.go, sykli.rs, or sykli.exs with
  smart defaults.
  """

  @marker_files %{
    go: "go.mod",
    rust: "Cargo.toml",
    elixir: "mix.exs"
  }

  @sykli_files %{
    go: "sykli.go",
    rust: "sykli.rs",
    elixir: "sykli.exs"
  }

  # ----- PUBLIC API -----

  @doc """
  Initialize a sykli file in the given directory.

  init(path, opts \\ [])

  Options (opts keyword list, optional):
    - language: Force a specific language (:go, :rust, :elixir)
    - force: Overwrite existing sykli file (default: false)
  """
  @spec init(String.t(), keyword()) :: {:ok, atom()} | {:error, term()}
  def init(path, opts \\ []) do
    language = Keyword.get(opts, :language)
    force = Keyword.get(opts, :force, false)

    language =
      if language do
        {:ok, language}
      else
        detect_language(path)
      end

    case language do
      {:ok, lang} ->
        case generate(path, lang, force: force) do
          :ok -> {:ok, lang}
          error -> error
        end

      error ->
        error
    end
  end

  @doc """
  Detect the project language from marker files.
  """
  @spec detect_language(String.t()) :: {:ok, atom()} | {:error, :unknown_project}
  def detect_language(path) do
    found =
      @marker_files
      |> Enum.find(fn {_lang, file} ->
        File.exists?(Path.join(path, file))
      end)

    case found do
      {lang, _file} -> {:ok, lang}
      nil -> {:error, :unknown_project}
    end
  end

  @doc """
  Generate a sykli file for the given language.

  Options:
    - force: Overwrite existing file (default: false)
  """
  @spec generate(String.t(), atom(), keyword()) :: :ok | {:error, term()}
  def generate(path, language, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    case Map.get(@sykli_files, language) do
      nil ->
        {:error, :unsupported_language}

      sykli_file ->
        sykli_path = Path.join(path, sykli_file)

        if File.exists?(sykli_path) and not force do
          {:error, :already_exists}
        else
          content = generate_content(path, language)
          File.write!(sykli_path, content)
          :ok
        end
    end
  end

  @doc """
  Extract project name from marker file.
  """
  @spec project_name(String.t(), atom()) :: String.t()
  def project_name(path, language) do
    case language do
      :go -> extract_go_module(path)
      :rust -> extract_cargo_name(path)
      :elixir -> extract_mix_app(path)
    end
    |> case do
      nil -> Path.basename(path)
      name -> name
    end
  end

  # ----- PRIVATE -----

  defp generate_content(path, :go) do
    name = project_name(path, :go)

    """
    package main

    import sykli "github.com/yairfalse/sykli/sdk/go"

    func main() {
    \ts := sykli.New()

    \t// Test
    \ts.Task("test").
    \t\tRun("go test ./...").
    \t\tInputs("**/*.go", "go.mod", "go.sum")

    \t// Build
    \ts.Task("build").
    \t\tRun("go build -o ./#{name}").
    \t\tAfter("test").
    \t\tInputs("**/*.go", "go.mod", "go.sum")

    \ts.Emit()
    }
    """
  end

  defp generate_content(path, :rust) do
    name = project_name(path, :rust)

    """
    //! Sykli pipeline for #{name}

    use sykli::Pipeline;

    fn main() {
        let mut p = Pipeline::new();

        // Test
        p.task("test")
            .run("cargo test")
            .inputs(&["src/**/*.rs", "Cargo.toml", "Cargo.lock"]);

        // Build
        p.task("build")
            .run("cargo build --release")
            .after(&["test"])
            .inputs(&["src/**/*.rs", "Cargo.toml", "Cargo.lock"]);

        p.emit();
    }
    """
  end

  defp generate_content(path, :elixir) do
    name = project_name(path, :elixir)

    """
    # Sykli pipeline for #{name}

    Sykli.pipeline do
      task "test" do
        run "mix test"
        inputs ["lib/**/*.ex", "test/**/*.exs", "mix.exs"]
      end

      task "build" do
        run "mix compile --warnings-as-errors"
        after_ ["test"]
        inputs ["lib/**/*.ex", "mix.exs"]
      end
    end
    """
  end

  defp extract_go_module(path) do
    go_mod = Path.join(path, "go.mod")

    if File.exists?(go_mod) do
      case File.read(go_mod) do
        {:ok, content} ->
          case Regex.run(~r/^module\s+(\S+)/m, content) do
            [_, module] ->
              module
              |> String.trim()
              |> String.split("/")
              |> List.last()

            _ ->
              nil
          end

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp extract_cargo_name(path) do
    cargo_toml = Path.join(path, "Cargo.toml")

    if File.exists?(cargo_toml) do
      case File.read(cargo_toml) do
        {:ok, content} ->
          case Regex.run(~r/name\s*=\s*"([^"]+)"/, content) do
            [_, name] -> name
            _ -> nil
          end

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp extract_mix_app(path) do
    mix_exs = Path.join(path, "mix.exs")

    if File.exists?(mix_exs) do
      case File.read(mix_exs) do
        {:ok, content} ->
          case Regex.run(~r/app:\s*:(\w+)/, content) do
            [_, app] -> app
            _ -> nil
          end

        _ ->
          nil
      end
    else
      nil
    end
  end
end

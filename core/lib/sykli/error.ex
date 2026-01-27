defmodule Sykli.Error do
  @moduledoc """
  Unified error system for Sykli with Rust-quality error messages.

  This module provides:
  - Structured errors with searchable error codes (E001, E010, etc.)
  - Clear hierarchy: error, warning, note, help
  - Context: task name, step, relevant file/line
  - Actionable hints for every error
  - Visual consistency across the CLI

  ## Error Codes

  | Code | Category | Description |
  |------|----------|-------------|
  | E001 | execution | Task command failed |
  | E002 | execution | Task timed out |
  | E003 | execution | Missing secrets |
  | E010 | validation | Invalid task graph (cycle) |
  | E011 | validation | Invalid service config |
  | E012 | validation | Invalid mount config |
  | E013 | validation | Artifact dependency missing |
  | E020 | sdk | SDK file not found |
  | E021 | sdk | SDK emission failed |
  | E022 | sdk | SDK emission timed out |
  | E023 | sdk | Invalid JSON from SDK |
  | E030 | runtime | Docker not available |
  | E031 | runtime | Docker image not found |
  | E032 | runtime | K8s connection failed |
  | E040 | internal | Unexpected error (with report link) |

  ## Usage

  ```elixir
  # Return as error tuple (recommended)
  {:error, Sykli.Error.task_failed("build", "go build", 1, "...")}

  # Wrap legacy error tuples
  case some_operation() do
    {:error, reason} -> {:error, Sykli.Error.wrap(reason)}
    ok -> ok
  end

  # Format for display
  error |> Sykli.Error.Formatter.format() |> IO.puts()
  ```
  """

  @type error_type ::
          :execution
          | :validation
          | :sdk
          | :runtime
          | :internal

  @type step ::
          :detect
          | :parse
          | :validate
          | :run
          | :cache
          | :setup
          | :teardown

  defexception [
    # Error code like "E001" - searchable
    :code,
    # Category: :execution | :validation | :sdk | :runtime | :internal
    :type,
    # Primary user message (short, clear)
    :message,
    # Task name (optional)
    :task,
    # Step in the pipeline: :detect | :parse | :validate | :run | :cache
    :step,
    # Command that failed (optional)
    :command,
    # Output text from command (optional)
    :output,
    # Process exit code (optional)
    :exit_code,
    # Duration in milliseconds (optional)
    :duration_ms,
    # Underlying error (for wrapping)
    :cause,
    # Actionable suggestions (default: [])
    hints: [],
    # Contextual information (default: [])
    notes: []
  ]

  @type t :: %__MODULE__{
          code: String.t(),
          type: error_type(),
          message: String.t(),
          task: String.t() | nil,
          step: step() | nil,
          command: String.t() | nil,
          output: String.t() | nil,
          exit_code: integer() | nil,
          duration_ms: integer() | nil,
          hints: [String.t()],
          notes: [String.t()],
          cause: term() | nil
        }

  # Exception protocol implementation
  @impl true
  def message(%__MODULE__{code: code, message: msg}) do
    "[#{code}] #{msg}"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # EXECUTION ERRORS (E001-E009)
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  E001: Task command failed with exit code.
  """
  def task_failed(task, command, exit_code, output, opts \\ []) do
    duration_ms = Keyword.get(opts, :duration_ms)

    # Generate automatic hints based on exit code and output
    auto_hints = generate_hints(exit_code, output)

    %__MODULE__{
      code: "E001",
      type: :execution,
      message: "task '#{task}' failed",
      task: task,
      step: :run,
      command: command,
      output: output,
      exit_code: exit_code,
      duration_ms: duration_ms,
      hints: auto_hints,
      notes: build_duration_note(duration_ms)
    }
  end

  @doc """
  E002: Task timed out.
  """
  def task_timeout(task, command, timeout_ms) do
    timeout_str = format_duration(timeout_ms)

    %__MODULE__{
      code: "E002",
      type: :execution,
      message: "task '#{task}' timed out after #{timeout_str}",
      task: task,
      step: :run,
      command: command,
      duration_ms: timeout_ms,
      hints: [
        "increase the timeout with --timeout=<duration>",
        "check for infinite loops or blocking operations"
      ],
      notes: []
    }
  end

  @doc """
  E003: Required secrets not found.
  """
  def missing_secrets(task, secrets) when is_list(secrets) do
    secrets_str = Enum.join(secrets, ", ")

    %__MODULE__{
      code: "E003",
      type: :execution,
      message: "task '#{task}' requires secrets: #{secrets_str}",
      task: task,
      step: :run,
      hints: [
        "set environment variables: #{secrets_str}",
        "or use a .env file in the project root"
      ],
      notes: []
    }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # VALIDATION ERRORS (E010-E019)
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  E010: Dependency cycle detected in task graph.
  """
  def cycle_detected(path) when is_list(path) do
    cycle_str = Enum.join(path, " → ")

    %__MODULE__{
      code: "E010",
      type: :validation,
      message: "dependency cycle detected",
      step: :validate,
      hints: [
        "remove one of the dependencies in the cycle",
        "or restructure tasks to break the circular dependency"
      ],
      notes: ["cycle: #{cycle_str}"]
    }
  end

  @doc """
  E011: Invalid service configuration.
  """
  def invalid_service(field, service_name \\ nil) do
    context = if service_name, do: " for service '#{service_name}'", else: ""

    hint =
      case field do
        :image -> "add .Image(\"redis:7\") to specify the container image"
        :name -> "add .Name(\"redis\") to specify the service name"
        _ -> "check the service configuration"
      end

    %__MODULE__{
      code: "E011",
      type: :validation,
      message: "service #{field} cannot be empty#{context}",
      step: :parse,
      hints: [hint],
      notes: []
    }
  end

  @doc """
  E012: Invalid mount configuration.
  """
  def invalid_mount(field, details \\ nil) do
    hint =
      case field do
        :resource -> "specify the resource name (e.g., s.Dir(\".\") or s.Cache(\"npm\"))"
        :path -> "specify the mount path inside the container"
        :type -> "mount type must be 'directory' or 'cache'"
        _ -> "check the mount configuration"
      end

    details_note = if details, do: [details], else: []

    %__MODULE__{
      code: "E012",
      type: :validation,
      message: "mount #{field} is invalid",
      step: :parse,
      hints: [hint],
      notes: details_note
    }
  end

  @doc """
  E013: Artifact dependency validation failed.
  """
  def artifact_error(reason) do
    {message, hints} =
      case reason do
        {:source_task_not_found, task, source} ->
          {
            "task '#{task}' requires artifact from '#{source}', but '#{source}' doesn't exist",
            ["check the task name in .Input(\"#{source}\", ...)"]
          }

        {:output_not_found, task, source, output} ->
          {
            "task '#{task}' requires output '#{output}' from '#{source}'",
            ["add .Output(\"#{output}\", \"path/...\") to task '#{source}'"]
          }

        {:missing_task_dependency, task, source} ->
          {
            "task '#{task}' uses artifact from '#{source}' but doesn't depend on it",
            ["add .After(\"#{source}\") to ensure '#{source}' runs first"]
          }

        _ ->
          {"artifact validation failed", ["check artifact configuration"]}
      end

    %__MODULE__{
      code: "E013",
      type: :validation,
      message: message,
      step: :validate,
      hints: hints,
      notes: []
    }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SDK ERRORS (E020-E029)
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  E020: SDK file not found.
  """
  def no_sdk_file(path \\ ".") do
    %__MODULE__{
      code: "E020",
      type: :sdk,
      message: "no sykli configuration file found",
      step: :detect,
      hints: [
        "create a sykli.go, sykli.rs, sykli.ts, or sykli.exs file",
        "or run 'sykli init' to generate one"
      ],
      notes: ["searched in: #{Path.expand(path)}"]
    }
  end

  @doc """
  E021: SDK emission failed (compilation error, etc.).
  """
  def sdk_failed(lang, error_output) do
    lang_str = lang_to_string(lang)

    hints =
      case lang do
        :go -> ["run 'go build sykli.go' to see full errors"]
        :rust -> ["run 'cargo build' to see full errors"]
        :typescript -> ["run 'npx tsc sykli.ts' to see full errors"]
        :elixir -> ["check sykli.exs for syntax errors"]
        _ -> []
      end

    %__MODULE__{
      code: "E021",
      type: :sdk,
      message: "#{lang_str} SDK failed to emit pipeline",
      step: :detect,
      output: error_output,
      hints: hints,
      notes: []
    }
  end

  @doc """
  E022: SDK emission timed out.
  """
  def sdk_timeout(lang, timeout_ms) do
    lang_str = lang_to_string(lang)
    timeout_str = format_duration(timeout_ms)

    %__MODULE__{
      code: "E022",
      type: :sdk,
      message: "#{lang_str} SDK timed out after #{timeout_str}",
      step: :detect,
      duration_ms: timeout_ms,
      hints: [
        "check for infinite loops in your sykli file",
        "ensure network access is available for dependency downloads"
      ],
      notes: []
    }
  end

  @doc """
  E023: Invalid JSON from SDK.
  """
  def invalid_json(details \\ nil) do
    notes = if details, do: [details], else: []

    %__MODULE__{
      code: "E023",
      type: :sdk,
      message: "SDK produced invalid JSON",
      step: :parse,
      hints: [
        "ensure your sykli file calls .Emit() at the end",
        "check for print/log statements that might corrupt output"
      ],
      notes: notes
    }
  end

  @doc """
  E024: Missing required tool for SDK.
  """
  def missing_tool(tool, install_hint) do
    %__MODULE__{
      code: "E024",
      type: :sdk,
      message: "'#{tool}' is required but not found",
      step: :detect,
      hints: [install_hint],
      notes: []
    }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # RUNTIME ERRORS (E030-E039)
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  E030: Docker not available.
  """
  def docker_unavailable(reason \\ nil) do
    notes = if reason, do: [to_string(reason)], else: []

    %__MODULE__{
      code: "E030",
      type: :runtime,
      message: "Docker is not available",
      step: :setup,
      hints: [
        "start Docker Desktop or the Docker daemon",
        "check with 'docker ps'"
      ],
      notes: notes
    }
  end

  @doc """
  E031: Docker image not found.
  """
  def image_not_found(image) do
    %__MODULE__{
      code: "E031",
      type: :runtime,
      message: "Docker image '#{image}' not found",
      step: :run,
      hints: [
        "pull the image: docker pull #{image}",
        "check the image name for typos"
      ],
      notes: []
    }
  end

  @doc """
  E032: Kubernetes connection failed.
  """
  def k8s_connection_failed(reason \\ nil) do
    notes = if reason, do: [inspect(reason)], else: []

    %__MODULE__{
      code: "E032",
      type: :runtime,
      message: "failed to connect to Kubernetes cluster",
      step: :setup,
      hints: [
        "check your kubeconfig: kubectl cluster-info",
        "ensure you have the correct context selected"
      ],
      notes: notes
    }
  end

  @doc """
  E033: K8s resource creation failed.
  """
  def k8s_resource_failed(resource_type, name, reason) do
    %__MODULE__{
      code: "E033",
      type: :runtime,
      message: "failed to create #{resource_type} '#{name}'",
      step: :setup,
      hints: [
        "check cluster permissions for creating #{resource_type}",
        "verify the resource configuration"
      ],
      notes: [inspect(reason)],
      cause: reason
    }
  end

  @doc """
  E034: Git repository required but not found.
  """
  def not_a_git_repo(path \\ ".") do
    %__MODULE__{
      code: "E034",
      type: :runtime,
      message: "not a git repository",
      step: :setup,
      hints: [
        "initialize a git repository: git init",
        "K8s execution requires git to clone source code"
      ],
      notes: ["path: #{Path.expand(path)}"]
    }
  end

  @doc """
  E035: Uncommitted changes in working directory.
  """
  def dirty_workdir do
    %__MODULE__{
      code: "E035",
      type: :runtime,
      message: "uncommitted changes in working directory",
      step: :setup,
      hints: [
        "commit your changes: git add . && git commit -m '...'",
        "or use --allow-dirty to proceed anyway (not recommended)"
      ],
      notes: ["K8s execution requires a clean git state for reproducibility"]
    }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # INTERNAL ERRORS (E040-E049)
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  E040: Unexpected internal error.
  """
  def internal(message, opts \\ []) do
    cause = Keyword.get(opts, :cause)
    stacktrace = Keyword.get(opts, :stacktrace)

    notes =
      if stacktrace do
        # Only show first few frames, no full stack traces to users
        frames =
          stacktrace
          |> Enum.take(3)
          |> Enum.map(&Exception.format_stacktrace_entry/1)

        ["First few stack frames: " <> Enum.join(frames, " → ")]
      else
        []
      end

    %__MODULE__{
      code: "E040",
      type: :internal,
      message: message,
      hints: [
        "report this issue at https://github.com/yairfalse/sykli/issues"
      ],
      notes: notes,
      cause: cause
    }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # LEGACY ERROR WRAPPING
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Converts legacy error tuples to structured Error.

  This enables gradual migration - existing code keeps working while
  new code gets better error messages.

  ## Examples

      iex> Sykli.Error.wrap(:no_sdk_file)
      %Sykli.Error{code: "E020", ...}

      iex> Sykli.Error.wrap({:cycle_detected, ["a", "b", "a"]})
      %Sykli.Error{code: "E010", ...}
  """
  def wrap(%__MODULE__{} = e), do: e

  # SDK errors
  def wrap(:no_sdk_file), do: no_sdk_file()
  def wrap(:no_json_in_output), do: invalid_json("no JSON found in SDK output")
  def wrap(:rust_binary_not_found), do: sdk_failed(:rust, "no sykli binary or Cargo.toml found")
  def wrap({:go_failed, output}), do: sdk_failed(:go, output)
  def wrap({:go_timeout, msg}), do: sdk_timeout(:go, 120_000) |> add_note(msg)
  def wrap({:rust_failed, output}), do: sdk_failed(:rust, output)
  def wrap({:rust_cargo_failed, output}), do: sdk_failed(:rust, output)
  def wrap({:rust_timeout, msg}), do: sdk_timeout(:rust, 120_000) |> add_note(msg)
  def wrap({:elixir_failed, output}), do: sdk_failed(:elixir, output)
  def wrap({:elixir_timeout, msg}), do: sdk_timeout(:elixir, 120_000) |> add_note(msg)
  def wrap({:typescript_failed, output}), do: sdk_failed(:typescript, output)
  def wrap({:typescript_timeout, msg}), do: sdk_timeout(:typescript, 120_000) |> add_note(msg)
  def wrap({:missing_tool, tool, hint}), do: missing_tool(tool, hint)

  # Validation errors
  def wrap({:cycle_detected, path}), do: cycle_detected(path)
  def wrap(:invalid_format), do: invalid_json("expected {\"tasks\": [...]} format")
  def wrap({:json_parse_error, reason}), do: invalid_json(inspect(reason))

  # Artifact validation errors
  def wrap({:artifact_validation_failed, reason}), do: artifact_error(reason)
  def wrap({:source_task_not_found, task, source}), do: artifact_error({:source_task_not_found, task, source})
  def wrap({:output_not_found, task, source, output}), do: artifact_error({:output_not_found, task, source, output})
  def wrap({:missing_task_dependency, task, source}), do: artifact_error({:missing_task_dependency, task, source})

  # Runtime errors
  def wrap(:not_a_git_repo), do: not_a_git_repo()
  def wrap(:dirty_workdir), do: dirty_workdir()
  def wrap({:target_setup_failed, reason}), do: internal("target setup failed: #{inspect(reason)}", cause: reason)

  # Execution errors
  def wrap({:missing_secrets, secrets}), do: missing_secrets("unknown", secrets)

  # Catch-all for unknown errors
  def wrap(reason) when is_atom(reason), do: internal("unexpected error: #{reason}")
  def wrap(reason) when is_binary(reason), do: internal(reason)
  def wrap(reason), do: internal("unexpected error: #{inspect(reason)}", cause: reason)

  @doc """
  Creates an Error from an exception.
  """
  def from_exception(%__MODULE__{} = e, _stacktrace), do: e

  def from_exception(exception, stacktrace) do
    message = Exception.message(exception)
    internal(message, cause: exception, stacktrace: stacktrace)
  end

  @doc """
  Creates an Error from an exit reason.
  """
  def from_exit(reason) do
    case reason do
      :normal -> internal("process exited normally (unexpected)")
      :shutdown -> internal("process was shut down")
      {:shutdown, _} -> internal("process was shut down")
      _ -> internal("process exited: #{inspect(reason)}", cause: reason)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Adds a hint to an error.
  """
  def add_hint(%__MODULE__{hints: hints} = error, hint) do
    %{error | hints: hints ++ [hint]}
  end

  @doc """
  Adds multiple hints to an error.
  """
  def add_hints(%__MODULE__{} = error, []), do: error

  def add_hints(%__MODULE__{hints: hints} = error, new_hints) do
    %{error | hints: hints ++ new_hints}
  end

  @doc """
  Adds a note to an error.
  """
  def add_note(%__MODULE__{notes: notes} = error, note) do
    %{error | notes: notes ++ [note]}
  end

  @doc """
  Sets the task name on an error.
  """
  def with_task(%__MODULE__{} = error, task) do
    %{error | task: task}
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HINT GENERATION (from ErrorHints)
  # ─────────────────────────────────────────────────────────────────────────────

  defp generate_hints(exit_code, output) do
    hints = []

    # Add exit code hint
    hints =
      case exit_code_hint(exit_code) do
        nil -> hints
        hint -> hints ++ [hint]
      end

    # Add output pattern hint
    hints =
      case output_pattern_hint(output) do
        nil -> hints
        hint -> hints ++ [hint]
      end

    Enum.uniq(hints)
  end

  defp exit_code_hint(code) when is_integer(code) do
    case code do
      1 -> nil
      2 -> "command misuse - check arguments"
      126 -> "not executable - try: chmod +x <script>"
      127 -> "command not found - check PATH or install missing tool"
      128 -> "invalid exit code"
      137 -> "process killed (SIGKILL) - likely out of memory"
      143 -> "process terminated (SIGTERM) - task was cancelled"
      code when code > 128 and code < 256 ->
        signal = code - 128
        "process killed by signal #{signal}"
      _ -> nil
    end
  end

  defp exit_code_hint(_), do: nil

  @output_patterns [
    {~r/command not found/i, "install the missing command or check your PATH"},
    {~r/permission denied/i, "check file permissions - try: chmod +x <file>"},
    {~r/no such file or directory/i, "file or directory doesn't exist - check the path"},
    {~r/connection refused/i, "service not running - start the service or check the port"},
    {~r/timeout|timed out/i, "operation timed out - increase timeout or check network"},
    {~r/Unable to find image/i, "docker image not found - run: docker pull <image>"},
    {~r/Cannot connect to the Docker daemon/i, "Docker not running - start Docker"},
    {~r/cannot find module providing package/i, "missing Go module - try: go mod tidy"},
    {~r/Cannot find module/i, "missing npm module - try: npm install"},
    {~r/ModuleNotFoundError/i, "missing Python module - try: pip install <module>"},
    {~r/out of memory/i, "out of memory - reduce parallelism or increase memory"}
  ]

  defp output_pattern_hint(output) when is_binary(output) do
    Enum.find_value(@output_patterns, fn {pattern, hint} ->
      if Regex.match?(pattern, output), do: hint
    end)
  end

  defp output_pattern_hint(_), do: nil

  defp build_duration_note(nil), do: []

  defp build_duration_note(ms) do
    ["task ran for #{format_duration(ms)} before failing"]
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp lang_to_string(:go), do: "Go"
  defp lang_to_string(:rust), do: "Rust"
  defp lang_to_string(:typescript), do: "TypeScript"
  defp lang_to_string(:elixir), do: "Elixir"
  defp lang_to_string(other), do: to_string(other)
end

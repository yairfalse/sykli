defmodule Sykli.Error do
  @moduledoc """
  Unified error system for Sykli with Rust-quality error messages.

  This module provides:
  - Structured errors with self-documenting codes (TASK_FAILED, CYCLE_DETECTED, etc.)
  - Clear hierarchy: error, warning, note, help
  - Context: task name, step, relevant file/line
  - Actionable hints for every error
  - Visual consistency across the CLI

  ## Error Codes

  | Code | Category | Description |
  |------|----------|-------------|
  | task_failed | execution | Task command failed |
  | task_timeout | execution | Task timed out |
  | review_primitive_failed | execution | Review primitive failed or is unsupported |
  | success_criteria_failed | execution | Declared success criteria failed |
  | unsupported_success_criteria_for_target | execution | Target cannot evaluate declared success criteria |
  | missing_evidence | execution | Required evidence was not produced |
  | unsupported_evidence_requirement_for_target | execution | Target cannot evaluate declared evidence requirements |
  | missing_secrets | execution | Missing secrets |
  | dependency_cycle | validation | Circular dependency in task graph |
  | invalid_service | validation | Invalid service config |
  | invalid_mount | validation | Invalid mount config |
  | missing_artifact | validation | Artifact dependency missing |
  | sdk_not_found | sdk | SDK file not found |
  | sdk_failed | sdk | SDK emission failed |
  | sdk_timeout | sdk | SDK emission timed out |
  | invalid_json | sdk | Invalid JSON from SDK |
  | missing_tool | sdk | Required tool not installed |
  | docker_not_running | runtime | Docker not available |
  | image_not_found | runtime | Docker image not found |
  | cluster_unreachable | runtime | K8s connection failed |
  | resource_failed | runtime | K8s resource creation failed |
   | not_a_git_repo | runtime | Not a git repository |
   | uncommitted_changes | runtime | Uncommitted changes |
   | invalid_work_item | work | Invalid local work item data |
   | invalid_work_item_id | work | Invalid local work item id |
   | malformed_work_item_json | work | Local work item file is not valid JSON |
   | work_item_already_claimed | work | Local work item is already claimed |
   | work_item_missing_title | work | Work item create command is missing a title |
   | work_item_not_found | work | Local work item was not found |
   | internal_error | internal | Unexpected error (with report link) |

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
    # Self-documenting error code like "TASK_FAILED"
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
    notes: [],
    # Parsed file:line locations from output (default: [])
    locations: []
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
          locations: [Sykli.ErrorParser.location()],
          cause: term() | nil
        }

  # Exception protocol implementation
  @impl true
  def message(%__MODULE__{code: code, message: msg}) do
    "[#{code}] #{msg}"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # EXECUTION ERRORS
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  task_failed: Task command failed with exit code.
  """
  def task_failed(task, command, exit_code, output, opts \\ []) do
    duration_ms = Keyword.get(opts, :duration_ms)

    # Generate automatic hints based on exit code and output
    auto_hints = generate_hints(exit_code, output)

    # Parse file:line locations from output
    locations = Sykli.ErrorParser.parse(output || "")

    %__MODULE__{
      code: "task_failed",
      type: :execution,
      message: "task '#{task}' failed",
      task: task,
      step: :run,
      command: command,
      output: output,
      exit_code: exit_code,
      duration_ms: duration_ms,
      hints: auto_hints,
      notes: build_duration_note(duration_ms),
      locations: locations
    }
  end

  @doc """
  task_timeout: Task timed out.
  """
  def task_timeout(task, command, timeout_ms) do
    timeout_str = format_duration(timeout_ms)

    %__MODULE__{
      code: "task_timeout",
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
  review_primitive_failed: Review primitive failed or could not be evaluated.
  """
  def review_primitive_failed(task, review_result) do
    %__MODULE__{
      code: "review_primitive_failed",
      type: :execution,
      message: "review primitive failed for '#{task}'",
      task: task,
      step: :run,
      hints: review_primitive_hints(review_result),
      notes: [
        "review_type: #{review_result.review_type}",
        "status: #{review_result.status}",
        "message: #{review_result.message}"
      ]
    }
  end

  defp review_primitive_hints(%{status: :unsupported, review_type: "api_breakage"}) do
    [
      "configure an api_breakage adapter with Application.put_env(:sykli, :api_breakage_review_runner, MyAdapter)",
      "see docs/review-primitives.md for the review_result contract"
    ]
  end

  defp review_primitive_hints(_review_result) do
    ["inspect the review_result evidence and fix or configure the review primitive"]
  end

  @doc """
  success_criteria_failed: Task command succeeded, but declared criteria did not.
  """
  def success_criteria_failed(task, results, opts \\ []) do
    failures = Sykli.SuccessCriteria.failures(results)

    %__MODULE__{
      code: "success_criteria_failed",
      type: :execution,
      message: "task '#{task}' failed success_criteria",
      task: task,
      step: :run,
      command: Keyword.get(opts, :command),
      output: Keyword.get(opts, :output),
      duration_ms: Keyword.get(opts, :duration_ms),
      hints: [
        "inspect the failed success_criteria and update the task command or contract"
      ],
      notes: criterion_notes(failures)
    }
  end

  @doc """
  unsupported_success_criteria_for_target: Target cannot evaluate criteria.
  """
  def unsupported_success_criteria_for_target(task, target_name, results, opts \\ []) do
    %__MODULE__{
      code: "unsupported_success_criteria_for_target",
      type: :execution,
      message:
        "target '#{target_name}' does not support success_criteria evaluation for task '#{task}'",
      task: task,
      step: :run,
      command: Keyword.get(opts, :command),
      output: Keyword.get(opts, :output),
      duration_ms: Keyword.get(opts, :duration_ms),
      hints: [
        "run this task on a target that can evaluate the declared success_criteria",
        "or remove success_criteria that this target cannot evaluate"
      ],
      notes: criterion_notes(results)
    }
  end

  @doc """
  missing_evidence: Task command succeeded, but required evidence was missing.
  """
  def missing_evidence(task, results, opts \\ []) do
    %__MODULE__{
      code: "missing_evidence",
      type: :execution,
      message: "task '#{task}' did not produce required evidence",
      task: task,
      step: :run,
      command: Keyword.get(opts, :command),
      output: Keyword.get(opts, :output),
      duration_ms: Keyword.get(opts, :duration_ms),
      hints: [
        "inspect evidence_required and make the task produce the declared evidence reference"
      ],
      notes: evidence_requirement_notes(results)
    }
  end

  @doc """
  unsupported_evidence_requirement_for_target: Target cannot evaluate evidence requirements.
  """
  def unsupported_evidence_requirement_for_target(task, target_name, results, opts \\ []) do
    %__MODULE__{
      code: "unsupported_evidence_requirement_for_target",
      type: :execution,
      message:
        "target '#{target_name}' does not support evidence_required evaluation for task '#{task}'",
      task: task,
      step: :run,
      command: Keyword.get(opts, :command),
      output: Keyword.get(opts, :output),
      duration_ms: Keyword.get(opts, :duration_ms),
      hints: [
        "run this task on a target that can evaluate the declared evidence_required entries",
        "or remove evidence_required entries that this target cannot evaluate"
      ],
      notes: evidence_requirement_notes(results)
    }
  end

  @doc """
  missing_secrets: Required secrets not found.
  """
  def missing_secrets(task, secrets) when is_list(secrets) do
    secrets_str = Enum.join(secrets, ", ")

    %__MODULE__{
      code: "missing_secrets",
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
  # VALIDATION ERRORS
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  dependency_cycle: Circular dependency detected in task graph.
  """
  def cycle_detected(path) when is_list(path) do
    cycle_str = Enum.join(path, " → ")

    %__MODULE__{
      code: "dependency_cycle",
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
  invalid_service: Invalid service configuration.
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
      code: "invalid_service",
      type: :validation,
      message: "service #{field} cannot be empty#{context}",
      step: :parse,
      hints: [hint],
      notes: []
    }
  end

  @doc """
  invalid_mount: Invalid mount configuration.
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
      code: "invalid_mount",
      type: :validation,
      message: "mount #{field} is invalid",
      step: :parse,
      hints: [hint],
      notes: details_note
    }
  end

  @doc """
  missing_artifact: Artifact dependency validation failed.
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
      code: "missing_artifact",
      type: :validation,
      message: message,
      step: :validate,
      hints: hints,
      notes: []
    }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SDK ERRORS
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  sdk_not_found: SDK file not found.
  """
  def no_sdk_file(path \\ ".") do
    %__MODULE__{
      code: "sdk_not_found",
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
  sdk_failed: SDK emission failed (compilation error, etc.).
  """
  def sdk_failed(lang, error_output) do
    lang_str = lang_to_string(lang)

    hints =
      case lang do
        :go -> ["run 'go build sykli.go' to see full errors"]
        :rust -> ["run 'cargo build' to see full errors"]
        :typescript -> ["run 'npx tsc sykli.ts' to see full errors"]
        :elixir -> ["check sykli.exs for syntax errors"]
        :python -> ["run 'python sykli.py' to see full errors"]
        _ -> []
      end

    %__MODULE__{
      code: "sdk_failed",
      type: :sdk,
      message: "#{lang_str} SDK failed to emit pipeline",
      step: :detect,
      output: error_output,
      hints: hints,
      notes: []
    }
  end

  @doc """
  sdk_timeout: SDK emission timed out.
  """
  def sdk_timeout(lang, timeout_ms) do
    lang_str = lang_to_string(lang)
    timeout_str = format_duration(timeout_ms)

    %__MODULE__{
      code: "sdk_timeout",
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
  invalid_json: Invalid JSON from SDK.
  """
  def invalid_json(details \\ nil) do
    notes = if details, do: [details], else: []

    %__MODULE__{
      code: "invalid_json",
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
  missing_tool: Missing required tool for SDK.
  """
  def missing_tool(tool, install_hint) do
    %__MODULE__{
      code: "missing_tool",
      type: :sdk,
      message: "'#{tool}' is required but not found",
      step: :detect,
      hints: [install_hint],
      notes: []
    }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # RUNTIME ERRORS
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  docker_not_running: Docker is not running.
  """
  def docker_unavailable(reason \\ nil) do
    notes = if reason, do: [to_string(reason)], else: []

    %__MODULE__{
      code: "docker_not_running",
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
  image_not_found: Docker image not found.
  """
  def image_not_found(image) do
    %__MODULE__{
      code: "image_not_found",
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
  cluster_unreachable: Kubernetes cluster is unreachable.
  """
  def k8s_connection_failed(reason \\ nil) do
    notes = if reason, do: [inspect(reason)], else: []

    %__MODULE__{
      code: "cluster_unreachable",
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
  resource_failed: Kubernetes resource creation failed.
  """
  def k8s_resource_failed(resource_type, name, reason) do
    %__MODULE__{
      code: "resource_failed",
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
  not_a_git_repo: Git repository required but not found.
  """
  def not_a_git_repo(path \\ ".") do
    %__MODULE__{
      code: "not_a_git_repo",
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
  uncommitted_changes: There are uncommitted changes in the working directory.
  """
  def dirty_workdir do
    %__MODULE__{
      code: "uncommitted_changes",
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
  # WORK ITEM ERRORS
  # ─────────────────────────────────────────────────────────────────────────────

  def work_item_missing_title do
    %__MODULE__{
      code: "work_item_missing_title",
      type: :validation,
      message: "work item title is required",
      step: :validate,
      hints: ["use: sykli work create \"Title\""]
    }
  end

  def work_item_not_found(id) do
    %__MODULE__{
      code: "work_item_not_found",
      type: :validation,
      message: "work item '#{id}' was not found",
      step: :validate,
      hints: ["run `sykli work list` to see local work items"]
    }
  end

  def invalid_work_item_id(id) do
    %__MODULE__{
      code: "invalid_work_item_id",
      type: :validation,
      message: "invalid work item id: #{inspect(id)}",
      step: :validate,
      hints: ["work item ids may contain letters, numbers, underscores, dashes, and dots"]
    }
  end

  def work_item_already_claimed(id, assignment) do
    %__MODULE__{
      code: "work_item_already_claimed",
      type: :validation,
      message: "work item '#{id}' is already claimed",
      step: :validate,
      hints: ["choose another work item or inspect it with `sykli work show #{id}`"],
      notes: [format_assignment_note(assignment)]
    }
  end

  def malformed_work_item_json(path) do
    %__MODULE__{
      code: "malformed_work_item_json",
      type: :validation,
      message: "local work item file is not valid JSON",
      step: :parse,
      hints: ["inspect or remove the malformed file before retrying"],
      notes: ["path: #{path}"]
    }
  end

  def invalid_work_item(reason) do
    %__MODULE__{
      code: "invalid_work_item",
      type: :validation,
      message: "invalid local work item: #{format_work_item_reason(reason)}",
      step: :validate,
      hints: ["inspect the work item file under .sykli/work/items"]
    }
  end

  def contract_hash_failed(path, reason) do
    %__MODULE__{
      code: "contract_hash_failed",
      type: :validation,
      message: "failed to compute contract hash for #{path}: #{inspect(reason)}",
      step: :validate,
      hints: ["check that the detected Sykli SDK file is readable"]
    }
  end

  def contract_lock_mismatch(locked_hash, actual_hash) do
    %__MODULE__{
      code: "contract.lock_mismatch",
      type: :validation,
      message: "emitted contract hash does not match sykli.lock",
      step: :validate,
      hints: ["run `sykli lock` to accept the new contract edition"],
      notes: ["locked: #{locked_hash}", "emitted: #{actual_hash}"]
    }
  end

  def contract_lock_corrupt(path, reason) do
    %__MODULE__{
      code: "contract.lock_corrupt",
      type: :validation,
      message: "sykli.lock is unreadable or internally inconsistent",
      step: :validate,
      hints: ["inspect #{path} or regenerate it with `sykli lock`"],
      notes: ["reason: #{inspect(reason)}"]
    }
  end

  def contract_nondeterministic(first_hash, second_hash) do
    %__MODULE__{
      code: "contract.nondeterministic",
      type: :validation,
      message: "pipeline emission is not deterministic",
      step: :validate,
      hints: ["remove random, clock, or ambient inputs from the sykli file before retrying"],
      notes: ["first: #{first_hash}", "second: #{second_hash}"]
    }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # GATE DECISION ERRORS
  # ─────────────────────────────────────────────────────────────────────────────

  def gate_not_found(id) do
    %__MODULE__{
      code: "gate_not_found",
      type: :validation,
      message: "gate '#{id}' was not found",
      step: :validate,
      hints: ["run `sykli gates list` to see local gates"]
    }
  end

  def invalid_gate_id(id) do
    %__MODULE__{
      code: "invalid_gate_id",
      type: :validation,
      message: "invalid gate id: #{inspect(id)}",
      step: :validate,
      hints: ["gate ids may contain letters, numbers, underscores, dashes, and dots"]
    }
  end

  def malformed_gate_json(path) do
    %__MODULE__{
      code: "malformed_gate_json",
      type: :validation,
      message: "local gate file is not valid JSON",
      step: :parse,
      hints: ["inspect or remove the malformed file before retrying"],
      notes: ["path: #{path}"]
    }
  end

  def invalid_gate_transition(from, to) do
    %__MODULE__{
      code: "invalid_gate_transition",
      type: :validation,
      message: "invalid gate transition: #{from} -> #{to}",
      step: :validate,
      hints: ["only waiting or blocked gates can be approved or rejected"]
    }
  end

  def gate_decision_missing_reason do
    %__MODULE__{
      code: "gate_decision_missing_reason",
      type: :validation,
      message: "gate approval or rejection requires a reason",
      step: :validate,
      hints: ["use --reason \"...\""]
    }
  end

  def invalid_gate_decision(reason) do
    %__MODULE__{
      code: "invalid_gate_decision",
      type: :validation,
      message: "invalid local gate decision: #{format_gate_reason(reason)}",
      step: :validate,
      hints: ["inspect the gate file under .sykli/gates"]
    }
  end

  def gate_no_team_session(slug) do
    %__MODULE__{
      code: "gate.no_team_session",
      type: :runtime,
      message: "no team session for #{inspect(slug)}; run `sykli daemon join` first",
      step: :setup,
      hints: []
    }
  end

  def gate_missing_team_token(slug) do
    %__MODULE__{
      code: "gate.missing_team_token",
      type: :runtime,
      message:
        "team session #{inspect(slug)} found but no token; pass --token or set SYKLI_TEAM_TOKEN",
      step: :setup,
      hints: []
    }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # TEAM RUN SYNC ERRORS
  # ─────────────────────────────────────────────────────────────────────────────

  def team_run_publish_unauthorized do
    %__MODULE__{
      code: "team.run.publish_unauthorized",
      type: :runtime,
      message: "coordinator rejected run summary authorization",
      step: :setup,
      hints: ["check SYKLI_TEAM_TOKEN and daemon join state"]
    }
  end

  def team_run_publish_unavailable(reason) do
    %__MODULE__{
      code: "team.run.publish_unavailable",
      type: :runtime,
      message: "coordinator unavailable while publishing run summary",
      step: :setup,
      hints: ["the run remains local and will be retried from the outbox"],
      notes: ["reason: #{inspect(reason)}"]
    }
  end

  def team_run_invalid_payload do
    %__MODULE__{
      code: "team.run.invalid_payload",
      type: :validation,
      message: "run summary payload is invalid",
      step: :validate,
      hints: []
    }
  end

  def team_run_body_too_large do
    %__MODULE__{
      code: "team.run.body_too_large",
      type: :validation,
      message: "run summary payload exceeds coordinator limit",
      step: :validate,
      hints: ["run summaries must contain references, not logs or artifacts"]
    }
  end

  def team_outbox_write_failed(reason) do
    %__MODULE__{
      code: "team.outbox.write_failed",
      type: :runtime,
      message: "failed to write team outbox entry",
      step: :setup,
      hints: ["check permissions under .sykli/outbox"],
      notes: ["reason: #{inspect(reason)}"]
    }
  end

  def team_outbox_invalid_kind do
    %__MODULE__{
      code: "team.outbox.invalid_kind",
      type: :internal,
      message: "invalid team outbox kind",
      step: :setup,
      hints: []
    }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # MCP TOOL ERRORS
  # ─────────────────────────────────────────────────────────────────────────────
  #
  # Failures that originate inside the MCP tool dispatch itself (not the engine).
  # Codes are public-unstable while the MCP surface stabilizes. Hints are written
  # for an *agent* reader: each one should name a concrete next tool call.

  @doc """
  mcp.unknown_tool: An MCP `tools/call` named a tool that does not exist.
  """
  def mcp_unknown_tool(name) do
    %__MODULE__{
      code: "mcp.unknown_tool",
      type: :validation,
      message: "unknown MCP tool: #{name}",
      step: :run,
      hints: ["call tools/list to discover the available tool names"]
    }
  end

  @doc """
  mcp.no_occurrence: A tool needs occurrence data but none has been recorded yet.
  """
  def mcp_no_occurrence do
    %__MODULE__{
      code: "mcp.no_occurrence",
      type: :execution,
      message: "no occurrence data found for this project",
      step: :run,
      hints: ["call run_pipeline first to produce a run, then retry this tool"]
    }
  end

  @doc """
  mcp.missing_argument: A required tool argument was absent or empty.
  """
  def mcp_missing_argument(argument, tool) do
    %__MODULE__{
      code: "mcp.missing_argument",
      type: :validation,
      message: "missing required argument '#{argument}' for tool '#{tool}'",
      step: :run,
      hints: ["check the tool's inputSchema in tools/list and supply '#{argument}'"]
    }
  end

  @doc """
  mcp.tool_crashed: A tool raised an unexpected exception during dispatch.
  """
  def mcp_tool_crashed(message) do
    %__MODULE__{
      code: "mcp.tool_crashed",
      type: :internal,
      message: "MCP tool crashed: #{message}",
      step: :run,
      hints: ["report this issue at https://github.com/false-systems/sykli/issues"]
    }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # MANDATE ERRORS
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  mandate_violation / mandate_unsupported / mandate_verification_failed:
  a v5 mandate was broken, could not be enforced on this target/workdir,
  or could not be verified. `reason` is the typed failure-semantics
  reason (e.g. "mandate_scope_violation"); `outcome_status` is the
  recorded mandate outcome ("violated", "unsupported", or "unverified").
  """
  def mandate(reason, message, outcome_status) do
    {code, hints} =
      case outcome_status do
        "violated" ->
          {"mandate_violation",
           ["the task ran but broke its declared mandate — see mandate_outcome for details"]}

        "unsupported" ->
          {"mandate_unsupported",
           ["this target or workdir cannot enforce the declared mandate dimensions"]}

        _ ->
          {"mandate_verification_failed",
           ["mandate verification could not run; check git availability in the workdir"]}
      end

    %__MODULE__{
      code: code,
      type: :execution,
      message: message,
      hints: hints,
      notes: ["reason: #{reason}"]
    }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # INTERNAL ERRORS
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  internal_error: Unexpected internal error.
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
      code: "internal_error",
      type: :internal,
      message: message,
      hints: [
        "report this issue at https://github.com/false-systems/sykli/issues"
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
      %Sykli.Error{code: "sdk_not_found", ...}

      iex> Sykli.Error.wrap({:cycle_detected, ["a", "b", "a"]})
      %Sykli.Error{code: "dependency_cycle", ...}
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
  def wrap({:python_failed, output}), do: sdk_failed(:python, output)
  def wrap({:python_timeout, msg}), do: sdk_timeout(:python, 120_000) |> add_note(msg)
  def wrap({:missing_tool, tool, hint}), do: missing_tool(tool, hint)

  # Work item errors
  def wrap(:work_item_missing_title), do: work_item_missing_title()
  def wrap({:work_item_not_found, id}), do: work_item_not_found(id)
  def wrap({:invalid_work_item_id, id}), do: invalid_work_item_id(id)

  def wrap({:work_item_already_claimed, id, assignment}),
    do: work_item_already_claimed(id, assignment)

  def wrap({:malformed_work_item_json, path, _error}), do: malformed_work_item_json(path)
  def wrap({:unknown_work_flag, flag}), do: invalid_work_item({:unknown_flag, flag})
  def wrap({:invalid_work_command, command}), do: invalid_work_item({:invalid_command, command})
  def wrap({:invalid_work_actor, actor}), do: invalid_work_item({:invalid_actor, actor})
  def wrap({:missing_work_item_version, _}), do: invalid_work_item(:missing_version)

  def wrap({:unsupported_work_item_version, version}),
    do: invalid_work_item({:unsupported_version, version})

  def wrap({:invalid_work_item_status, status}), do: invalid_work_item({:invalid_status, status})

  def wrap({:invalid_assignment_type, type}),
    do: invalid_work_item({:invalid_assignment_type, type})

  def wrap({:invalid_assignment_id, id}), do: invalid_work_item({:invalid_assignment_id, id})
  def wrap({:invalid_actor_type, type}), do: invalid_work_item({:invalid_actor_type, type})
  def wrap({:invalid_actor_id, field, id}), do: invalid_work_item({:invalid_actor_id, field, id})
  def wrap({:invalid_created_by, reason}), do: invalid_work_item({:invalid_created_by, reason})
  def wrap({:invalid_notes, notes}), do: invalid_work_item({:invalid_notes, notes})
  def wrap({:invalid_note, reason}), do: invalid_work_item({:invalid_note, reason})
  def wrap({:invalid_note_author, reason}), do: invalid_work_item({:invalid_note_author, reason})
  def wrap({:contract_hash_failed, path, reason}), do: contract_hash_failed(path, reason)
  def wrap({:contract_lock_corrupt, path, reason}), do: contract_lock_corrupt(path, reason)

  # Gate decision errors
  def wrap({:gate_not_found, id}), do: gate_not_found(id)
  def wrap({:invalid_gate_id, id}), do: invalid_gate_id(id)
  def wrap({:malformed_gate_json, path, _error}), do: malformed_gate_json(path)
  def wrap({:invalid_gate_transition, from, to}), do: invalid_gate_transition(from, to)
  def wrap(:gate_decision_missing_reason), do: gate_decision_missing_reason()
  def wrap({:unknown_gate_flag, flag}), do: invalid_gate_decision({:unknown_flag, flag})

  def wrap({:invalid_gate_command, command}),
    do: invalid_gate_decision({:invalid_command, command})

  def wrap({:invalid_gate_actor, actor}), do: invalid_gate_decision({:invalid_actor, actor})
  def wrap({:missing_gate_version, _}), do: invalid_gate_decision(:missing_version)

  def wrap({:unsupported_gate_version, version}),
    do: invalid_gate_decision({:unsupported_version, version})

  def wrap({:invalid_gate_status, status}), do: invalid_gate_decision({:invalid_status, status})
  def wrap({:invalid_gate_decision, reason}), do: invalid_gate_decision(reason)

  def wrap({:invalid_gate_field, field, value}),
    do: invalid_gate_decision({:invalid_field, field, value})

  def wrap({:invalid_gate_requester, reason}),
    do: invalid_gate_decision({:invalid_requester, reason})

  def wrap({:invalid_gate_requester_type, type}),
    do: invalid_gate_decision({:invalid_requester_type, type})

  def wrap({:invalid_gate_requester_id, id}),
    do: invalid_gate_decision({:invalid_requester_id, id})

  def wrap({:invalid_gate_evidence_ref, ref}),
    do: invalid_gate_decision({:invalid_evidence_ref, ref})

  def wrap({:invalid_gate_evidence_refs, refs}),
    do: invalid_gate_decision({:invalid_evidence_refs, refs})

  # Validation errors
  def wrap({:cycle_detected, path}), do: cycle_detected(path)
  def wrap(:invalid_format), do: invalid_json("expected {\"tasks\": [...]} format")
  def wrap({:json_parse_error, reason}), do: invalid_json(inspect(reason))

  # Artifact validation errors
  def wrap({:artifact_validation_failed, reason}), do: artifact_error(reason)

  def wrap({:source_task_not_found, task, source}),
    do: artifact_error({:source_task_not_found, task, source})

  def wrap({:output_not_found, task, source, output}),
    do: artifact_error({:output_not_found, task, source, output})

  def wrap({:missing_task_dependency, task, source}),
    do: artifact_error({:missing_task_dependency, task, source})

  # Runtime errors
  def wrap(:not_a_git_repo), do: not_a_git_repo()
  def wrap(:dirty_workdir), do: dirty_workdir()

  def wrap({:target_setup_failed, reason}),
    do: internal("target setup failed: #{inspect(reason)}", cause: reason)

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

  defp criterion_notes(results) do
    Enum.map(results, fn result ->
      details =
        result.evidence
        |> format_criterion_evidence()
        |> case do
          "" -> ""
          evidence -> " (#{evidence})"
        end

      "success_criteria[#{result.index}] #{result.type}: #{result.status} - #{result.message}#{details}"
    end)
  end

  defp evidence_requirement_notes(results) do
    Enum.map(results, fn result ->
      "evidence_required[#{result.index}] #{result.type}: #{result.status} - #{result.message}"
    end)
  end

  defp format_criterion_evidence(nil), do: ""

  defp format_criterion_evidence(evidence) when is_map(evidence) do
    evidence
    |> Enum.map(fn {key, value} -> "#{key}=#{inspect(value)}" end)
    |> Enum.join(", ")
  end

  defp format_criterion_evidence(evidence), do: inspect(evidence)

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
      1 ->
        nil

      2 ->
        "command misuse - check arguments"

      126 ->
        "not executable - try: chmod +x <script>"

      127 ->
        "command not found - check PATH or install missing tool"

      128 ->
        "invalid exit code"

      137 ->
        "process killed (SIGKILL) - likely out of memory"

      143 ->
        "process terminated (SIGTERM) - task was cancelled"

      code when code > 128 and code < 256 ->
        signal = code - 128
        "process killed by signal #{signal}"

      _ ->
        nil
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

  defp format_assignment_note(%{} = assignment) do
    type = Map.get(assignment, "assigned_to_type") || "unknown"
    id = Map.get(assignment, "assigned_to_id") || "unknown"
    status = Map.get(assignment, "status") || "unknown"
    "current assignment: #{type}:#{id} (status: #{status})"
  end

  defp format_assignment_note(_assignment), do: "current assignment is unavailable"

  defp format_work_item_reason(:missing_version), do: "missing version"

  defp format_work_item_reason({:unsupported_version, version}),
    do: "unsupported version #{inspect(version)}"

  defp format_work_item_reason({:unknown_flag, flag}), do: "unknown flag #{flag}"
  defp format_work_item_reason({:invalid_command, ""}), do: "missing work command"

  defp format_work_item_reason({:invalid_command, command}),
    do: "invalid work command #{inspect(command)}"

  defp format_work_item_reason({:invalid_actor, actor}), do: "invalid actor #{inspect(actor)}"

  defp format_work_item_reason({:invalid_status, status}),
    do: "invalid status #{inspect(status)}"

  defp format_work_item_reason({:invalid_assignment_type, type}),
    do: "invalid assignment type #{inspect(type)}"

  defp format_work_item_reason({:invalid_assignment_id, id}),
    do: "invalid assignment id #{inspect(id)}"

  defp format_work_item_reason({:invalid_actor_type, type}),
    do: "invalid actor type #{inspect(type)}"

  defp format_work_item_reason({:invalid_actor_id, field, id}),
    do: "invalid #{field} actor id #{inspect(id)}"

  defp format_work_item_reason({:invalid_created_by, reason}),
    do: "invalid created_by fields: #{format_work_item_reason(reason)}"

  defp format_work_item_reason({:invalid_notes, notes}),
    do: "invalid notes #{inspect(notes)}"

  defp format_work_item_reason({:invalid_note, reason}),
    do: "invalid note: #{format_work_item_reason(reason)}"

  defp format_work_item_reason({:invalid_note_author, reason}),
    do: "invalid note author: #{format_work_item_reason(reason)}"

  defp format_work_item_reason(:empty_id), do: "empty actor id"
  defp format_work_item_reason(:empty_body), do: "empty note body"
  defp format_work_item_reason(:not_string), do: "expected string"
  defp format_work_item_reason(:missing_type), do: "missing actor type"

  defp format_work_item_reason(reason), do: inspect(reason)

  defp format_gate_reason(:missing_version), do: "missing version"

  defp format_gate_reason({:unsupported_version, version}),
    do: "unsupported version #{inspect(version)}"

  defp format_gate_reason({:unknown_flag, flag}), do: "unknown flag #{flag}"
  defp format_gate_reason({:invalid_command, ""}), do: "missing gate command"

  defp format_gate_reason({:invalid_command, command}),
    do: "invalid gate command #{inspect(command)}"

  defp format_gate_reason({:invalid_actor, actor}), do: "invalid actor #{inspect(actor)}"

  defp format_gate_reason({:invalid_status, status}),
    do: "invalid status #{inspect(status)}"

  defp format_gate_reason({:invalid_field, field, value}),
    do: "invalid #{field} #{inspect(value)}"

  defp format_gate_reason({:invalid_requester, reason}),
    do: "invalid requester: #{format_gate_reason(reason)}"

  defp format_gate_reason({:invalid_requester_type, type}),
    do: "invalid requester type #{inspect(type)}"

  defp format_gate_reason({:invalid_requester_id, id}),
    do: "invalid requester id #{inspect(id)}"

  defp format_gate_reason({:invalid_evidence_ref, ref}),
    do: "invalid evidence ref #{inspect(ref)}"

  defp format_gate_reason({:invalid_evidence_refs, refs}),
    do: "invalid evidence refs #{inspect(refs)}"

  defp format_gate_reason(:empty_id), do: "empty actor id"
  defp format_gate_reason(:empty), do: "empty value"
  defp format_gate_reason(:not_object), do: "expected object"
  defp format_gate_reason(:missing_type), do: "missing requester type"

  defp format_gate_reason(reason), do: inspect(reason)

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp lang_to_string(:go), do: "Go"
  defp lang_to_string(:rust), do: "Rust"
  defp lang_to_string(:typescript), do: "TypeScript"
  defp lang_to_string(:elixir), do: "Elixir"
  defp lang_to_string(:python), do: "Python"
  defp lang_to_string(other), do: to_string(other)
end

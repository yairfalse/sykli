defmodule Sykli.Verify.Plan do
  @moduledoc """
  Data structures for cross-platform verification plans.

  A verification plan describes which tasks need to be re-run on remote
  nodes, which nodes to target, and why each task was selected or skipped.
  """

  defmodule Entry do
    @moduledoc """
    A single task to verify on a remote node.
    """
    @enforce_keys [:task_name, :target_node, :reason]
    defstruct [:task_name, :target_node, :target_labels, :reason]

    @type reason :: :cross_platform | :retry_on_different_platform | :explicit_verify
    @type t :: %__MODULE__{
            task_name: String.t(),
            target_node: node() | atom(),
            target_labels: [String.t()] | nil,
            reason: reason()
          }
  end

  @enforce_keys [:entries, :skipped, :local_labels, :remote_nodes]
  defstruct entries: [], skipped: [], local_labels: [], remote_nodes: []

  @type skip_reason ::
          :cached | :skipped | :verify_never | :no_remote_nodes | :same_platform
  @type skipped_entry :: {String.t(), skip_reason()}
  @type t :: %__MODULE__{
          entries: [Entry.t()],
          skipped: [skipped_entry()],
          local_labels: [String.t()],
          remote_nodes: [map()]
        }
end

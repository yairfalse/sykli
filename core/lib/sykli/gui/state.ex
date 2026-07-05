defmodule Sykli.Gui.State do
  @moduledoc """
  The Workbench state document — everything `GET /api/state` returns.

  One struct per object, snake_case fields internally, camelCase over the
  wire (see `Sykli.Gui.State.JSON`). Providers build a fully-populated
  `%Sykli.Gui.State{}`; the web layer only encodes it. Presentation
  (colors, glyphs, labels) is derived client-side from `status` +
  `identity_type` — never stored here.
  """

  defmodule JSON do
    @moduledoc """
    Encodes state structs as camelCase JSON maps.

    Structs nest arbitrarily; nil fields are dropped so optional fields
    (mandate, audit verdict, failure class…) simply don't appear on the
    wire when absent.
    """

    def encode(%_{} = struct) do
      struct
      |> Map.from_struct()
      |> encode()
    end

    def encode(%{} = map) do
      map
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(fn {key, value} -> {camelize(key), encode(value)} end)
    end

    def encode(list) when is_list(list), do: Enum.map(list, &encode/1)
    def encode(value), do: value

    defp camelize(key) when is_atom(key), do: camelize(Atom.to_string(key))

    defp camelize(key) when is_binary(key) do
      [head | rest] = String.split(key, "_")
      Enum.join([head | Enum.map(rest, &String.capitalize/1)])
    end
  end

  defmodule Repo do
    @moduledoc false
    @enforce_keys [:name, :branch]
    defstruct [:name, :path, :branch, dirty: false]

    @type t :: %__MODULE__{
            name: String.t(),
            path: String.t() | nil,
            branch: String.t(),
            dirty: boolean()
          }
  end

  defmodule Team do
    @moduledoc false
    @enforce_keys [:id]
    defstruct [:id, :name, :mode, online: 0, total: 0]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t() | nil,
            mode: String.t() | nil,
            online: non_neg_integer(),
            total: non_neg_integer()
          }
  end

  defmodule Contract do
    @moduledoc false
    defstruct valid: false, version: nil, task_count: 0, gate_count: 0, review_node_count: 0

    @type t :: %__MODULE__{
            valid: boolean(),
            version: integer() | nil,
            task_count: non_neg_integer(),
            gate_count: non_neg_integer(),
            review_node_count: non_neg_integer()
          }
  end

  defmodule Run do
    @moduledoc false
    @enforce_keys [:id, :status]
    defstruct [
      :id,
      :status,
      :evidence_status,
      :primary_failure_node_id,
      :started_at,
      :finished_at
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            status: String.t(),
            evidence_status: String.t() | nil,
            primary_failure_node_id: String.t() | nil,
            started_at: String.t() | nil,
            finished_at: String.t() | nil
          }
  end

  defmodule Node do
    @moduledoc false
    @enforce_keys [:id, :type, :status]
    defstruct [
      :id,
      :type,
      :status,
      :failure_class,
      :retry_hint,
      :reason,
      :blocked_by,
      :requester,
      :executor,
      :duration,
      :evidence,
      :work_item_id,
      :run_id,
      :approvers,
      # v5: kept | violated | unverified | unsupported
      :mandate_outcome
    ]

    @type t :: %__MODULE__{id: String.t(), type: String.t(), status: String.t()}
  end

  defmodule Edge do
    @moduledoc false
    @enforce_keys [:from, :to]
    defstruct [:from, :to]

    @type t :: %__MODULE__{from: String.t(), to: String.t()}
  end

  defmodule Member do
    @moduledoc false
    @enforce_keys [:id, :name, :identity_type, :role, :status]
    defstruct [
      :id,
      :name,
      :identity_type,
      :role,
      :status,
      :responsibility,
      :recent,
      :current_work,
      :machine,
      :trust,
      :allowed,
      :not_allowed,
      # v5: the declared mandate for agent/daemon members
      :mandate
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            identity_type: String.t(),
            role: String.t(),
            status: String.t()
          }
  end

  defmodule WorkItem do
    @moduledoc false
    @enforce_keys [:id, :title, :status]
    defstruct [
      :id,
      :title,
      :intent,
      :owner,
      :reviewer,
      :runs,
      :status,
      :reason,
      :evidence,
      :participants,
      :run_list
    ]

    @type t :: %__MODULE__{id: String.t(), title: String.t(), status: String.t()}
  end

  defmodule Gate do
    @moduledoc false
    @enforce_keys [:id, :status]
    defstruct [:id, :status, :requester, :run_id, :evidence, waiting_for: []]

    @type t :: %__MODULE__{id: String.t(), status: String.t(), waiting_for: [map()]}
  end

  defmodule Evidence do
    @moduledoc false
    @enforce_keys [:run_id, :status]
    defstruct [
      :run_id,
      :status,
      :contract_version,
      :tasks,
      :failed,
      :skipped,
      :complete,
      # v5: sykli audit verdict + mandate outcome summary
      :audit_verdict,
      :mandates
    ]

    @type t :: %__MODULE__{run_id: String.t(), status: String.t()}
  end

  defmodule Activity do
    @moduledoc false
    @enforce_keys [:time, :text]
    defstruct [:time, :text, :kind]

    @type t :: %__MODULE__{time: String.t(), text: String.t(), kind: String.t() | nil}
  end

  defmodule AgentCall do
    @moduledoc false
    @enforce_keys [:tool, :caller, :result]
    defstruct [:tool, :time, :caller, :result, :ref, :changed_state]

    @type t :: %__MODULE__{tool: String.t(), caller: String.t(), result: String.t()}
  end

  @enforce_keys [:repo, :team, :contract]
  defstruct [
    :repo,
    :team,
    :contract,
    :latest_run,
    graph: %{nodes: [], edges: []},
    members: [],
    work_items: [],
    gates: [],
    evidence: [],
    activity: [],
    agent_calls: []
  ]

  @type t :: %__MODULE__{
          repo: Repo.t(),
          team: Team.t(),
          contract: Contract.t(),
          latest_run: Run.t() | nil,
          graph: %{nodes: [Node.t()], edges: [Edge.t()]},
          members: [Member.t()],
          work_items: [WorkItem.t()],
          gates: [Gate.t()],
          evidence: [Evidence.t()],
          activity: [Activity.t()],
          agent_calls: [AgentCall.t()]
        }

  @doc "Encodes the full state document as a camelCase-keyed map for the wire."
  def to_wire(%__MODULE__{} = state), do: JSON.encode(state)
end

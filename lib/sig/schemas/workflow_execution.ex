defmodule Sig.Schemas.WorkflowExecution do
  @moduledoc """
  A single run of a workflow.

  Created with `Sig.create_execution/4` or `Sig.run_execution/4`.

  ## Fields

    * `:workflow_id` - the workflow being executed.
    * `:idempotency_key` - optional key, unique per workflow, that prevents
      duplicate executions.
    * `:params` - execution-level params.
    * `:context` - execution-level context.
    * `:node_results` - results of the completed nodes, keyed by node name.
    * `:status` - `"pending"`, `"running"`, `"suspended"`, `"stopped"`,
      `"completed"` or `"failed"`.
    * `:error` - the error of the node that failed the execution, if any.
    * `:started_at` / `:completed_at` - when the execution started and reached
      a final state.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(pending running suspended stopped completed failed)

  @type t :: %__MODULE__{
          id: String.t() | nil,
          workflow_id: String.t() | nil,
          idempotency_key: String.t() | nil,
          params: map(),
          context: map(),
          node_results: map(),
          status: String.t(),
          error: map() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          workflow: Sig.Schemas.Workflow.t() | Ecto.Association.NotLoaded.t() | nil,
          node_executions: [Sig.Schemas.NodeExecution.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "workflow_executions" do
    field(:workflow_id, :binary_id)
    field(:idempotency_key, :string)
    field(:params, :map, default: %{})
    field(:context, :map, default: %{})
    field(:node_results, :map, default: %{})
    field(:status, :string, default: "pending")
    field(:error, :map)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    belongs_to(:workflow, Sig.Schemas.Workflow, define_field: false)
    has_many(:node_executions, Sig.Schemas.NodeExecution, foreign_key: :workflow_execution_id)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(execution, attrs) do
    execution
    |> cast(attrs, [
      :workflow_id,
      :idempotency_key,
      :params,
      :context,
      :node_results,
      :status,
      :error,
      :started_at,
      :completed_at
    ])
    |> validate_required([:workflow_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> foreign_key_constraint(:workflow_id)
    |> unique_constraint([:workflow_id, :idempotency_key],
      name: :workflow_executions_wf_id_idemp_key_index
    )
  end

  @doc false
  def status_changeset(execution, status, extra_attrs \\ %{}) do
    execution
    |> cast(Map.put(extra_attrs, :status, status), [
      :status,
      :error,
      :started_at,
      :completed_at,
      :node_results,
      :context
    ])
    |> validate_inclusion(:status, @valid_statuses)
  end
end

defmodule Sig.Schemas.NodeExecution do
  @moduledoc """
  The record of one node within a workflow execution.

  There is at most one record per node and execution. Available as
  `execution.node_executions` from `Sig.get_execution/1`.

  ## Fields

    * `:node_name` - the node name in the workflow.
    * `:module` - the node module, as a string.
    * `:status` - `"pending"`, `"running"`, `"retrying"`, `"completed"`,
      `"failed"` or `"skipped"`.
    * `:attempts` - number of attempts made so far.
    * `:max_retries` - maximum number of attempts.
    * `:params` - the node-level params.
    * `:result` - the node result, once completed.
    * `:error` - the error of the last failed attempt.
    * `:started_at` / `:completed_at` - timing of the node.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(pending running completed failed retrying skipped)

  @type t :: %__MODULE__{
          id: String.t() | nil,
          workflow_execution_id: String.t() | nil,
          node_name: String.t() | nil,
          module: String.t() | nil,
          status: String.t(),
          attempts: non_neg_integer(),
          max_retries: non_neg_integer(),
          params: map(),
          result: map() | nil,
          error: map() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          workflow_execution: Sig.Schemas.WorkflowExecution.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "node_executions" do
    field(:workflow_execution_id, :binary_id)
    field(:node_name, :string)
    field(:module, :string)
    field(:status, :string, default: "pending")
    field(:attempts, :integer, default: 0)
    field(:max_retries, :integer, default: 3)
    field(:params, :map, default: %{})
    field(:result, :map)
    field(:error, :map)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    belongs_to(:workflow_execution, Sig.Schemas.WorkflowExecution, define_field: false)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(node_execution, attrs) do
    node_execution
    |> cast(attrs, [
      :workflow_execution_id,
      :node_name,
      :module,
      :status,
      :attempts,
      :max_retries,
      :params,
      :result,
      :error,
      :started_at,
      :completed_at
    ])
    |> validate_required([:workflow_execution_id, :node_name, :module])
    |> validate_inclusion(:status, @valid_statuses)
    |> foreign_key_constraint(:workflow_execution_id)
    |> unique_constraint([:workflow_execution_id, :node_name])
  end
end

defmodule Sig.Schemas.Workflow do
  @moduledoc """
  A persisted workflow definition.

  Created with `Sig.create_workflow/1`.

  ## Fields

    * `:name` - the workflow name.
    * `:description` - optional description.
    * `:params` - workflow-level params, merged into every node's params.
    * `:context` - workflow-level context, shared by every node.
    * `:nodes` - the node graph, normalized as described in `Sig.Flow`.
    * `:status` - `"active"`, `"suspended"` or `"stopped"`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(active suspended stopped)

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          params: map(),
          context: map(),
          nodes: map(),
          status: String.t(),
          executions: [Sig.Schemas.WorkflowExecution.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "workflows" do
    field(:name, :string)
    field(:description, :string)
    field(:params, :map, default: %{})
    field(:context, :map, default: %{})
    field(:nodes, :map, default: %{})
    field(:status, :string, default: "active")

    has_many(:executions, Sig.Schemas.WorkflowExecution)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [:name, :description, :params, :context, :nodes, :status])
    |> validate_required([:name])
    |> validate_inclusion(:status, @valid_statuses)
    |> normalize_and_validate_nodes()
  end

  @doc false
  def status_changeset(workflow, status) do
    workflow
    |> change(%{status: status})
    |> validate_inclusion(:status, @valid_statuses)
  end

  defp normalize_and_validate_nodes(changeset) do
    case get_change(changeset, :nodes) do
      nil ->
        changeset

      nodes when is_map(nodes) ->
        case Sig.Flow.validate(nodes) do
          :ok ->
            # Normalize map to ensure keys are strings or uniform
            normalized = Sig.Flow.normalize_nodes(nodes)
            put_change(changeset, :nodes, normalized)

          {:error, reason} ->
            add_error(changeset, :nodes, reason)
        end

      nodes when is_list(nodes) ->
        nodes_map =
          Enum.reduce(nodes, %{}, fn node, acc ->
            name = to_string(Map.get(node, :name) || Map.get(node, "name"))
            Map.put(acc, name, node)
          end)

        case Sig.Flow.validate(nodes_map) do
          :ok ->
            normalized = Sig.Flow.normalize_nodes(nodes_map)
            put_change(changeset, :nodes, normalized)

          {:error, reason} ->
            add_error(changeset, :nodes, reason)
        end

      _ ->
        add_error(changeset, :nodes, "must be a map or list of node specifications")
    end
  end
end

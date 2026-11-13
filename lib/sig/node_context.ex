defmodule Sig.NodeContext do
  @moduledoc """
  The data a node receives when it runs.

  It is passed to `c:Sig.Node.run/1` (and as the second argument of
  `c:Sig.Node.run/2`).

  ## Fields

    * `:params` - the deep merge of workflow, execution and node params, in
      that order (node params win). This is what nodes usually read.
    * `:context` - the deep merge of workflow and execution context.
    * `:results` - the results of the nodes that already completed in this
      execution, keyed by node name.
    * `:node_name` - the name of the node being run.
    * `:attempt` - the current attempt number, starting at `1`.
    * `:workflow_id` / `:execution_id` - IDs of the workflow and execution.
    * `:workflow_params`, `:execution_params`, `:node_params` - each level of
      params before merging.
    * `:workflow_context`, `:execution_context` - each level of context
      before merging.

  All maps come from JSONB columns, so their keys are strings.

  ## Access

  The struct implements `Access`, so `context[:results]` and
  `context["results"]` work as well as `context.results`.

  ## Example

      def run(%Sig.NodeContext{} = context) do
        user = context.results["fetch_user"]
        amount = context.params["amount"]
        {:ok, %{"debited" => amount, "user_id" => user["id"], "attempt" => context.attempt}}
      end
  """

  @derive {Inspect, only: [:node_name, :attempt, :params, :context, :results, :execution_id]}
  defstruct [
    :workflow_id,
    :execution_id,
    :node_name,
    :attempt,
    workflow_params: %{},
    workflow_context: %{},
    execution_params: %{},
    execution_context: %{},
    node_params: %{},
    params: %{},
    context: %{},
    results: %{}
  ]

  @typedoc "The context passed to a node."
  @type t :: %__MODULE__{
          workflow_id: String.t() | nil,
          execution_id: String.t() | nil,
          node_name: String.t(),
          attempt: non_neg_integer(),
          workflow_params: map(),
          workflow_context: map(),
          execution_params: map(),
          execution_context: map(),
          node_params: map(),
          params: map(),
          context: map(),
          results: map()
        }

  @behaviour Access

  @doc false
  @impl Access
  def fetch(struct, key) when is_atom(key) do
    Map.fetch(struct, key)
  end

  def fetch(struct, key) when is_binary(key) do
    try do
      atom_key = String.to_existing_atom(key)
      Map.fetch(struct, atom_key)
    rescue
      ArgumentError -> :error
    end
  end

  @doc false
  @impl Access
  def get_and_update(struct, key, fun) when is_atom(key) do
    Map.get_and_update(struct, key, fun)
  end

  @doc false
  @impl Access
  def pop(struct, key) when is_atom(key) do
    Map.pop(struct, key)
  end

  @doc """
  Builds a `NodeContext`, computing the merged `:params` and `:context`.

  Accepts a map with any of the struct fields except `:params` and
  `:context`, which are derived. Missing maps default to `%{}` and `:attempt`
  defaults to `1`.

  ## Examples

      iex> ctx = Sig.NodeContext.build(%{
      ...>   workflow_params: %{"currency" => "BRL", "amount" => 10},
      ...>   execution_params: %{"amount" => 20},
      ...>   node_params: %{"amount" => 30}
      ...> })
      iex> ctx.params
      %{"currency" => "BRL", "amount" => 30}
  """
  @spec build(map()) :: t()
  def build(attrs) do
    wf_params = Map.get(attrs, :workflow_params, %{}) || %{}
    wf_ctx = Map.get(attrs, :workflow_context, %{}) || %{}
    exec_params = Map.get(attrs, :execution_params, %{}) || %{}
    exec_ctx = Map.get(attrs, :execution_context, %{}) || %{}
    node_params = Map.get(attrs, :node_params, %{}) || %{}
    results = Map.get(attrs, :results, %{}) || %{}

    merged_params =
      wf_params
      |> deep_merge(exec_params)
      |> deep_merge(node_params)

    merged_ctx = deep_merge(wf_ctx, exec_ctx)

    %__MODULE__{
      workflow_id: Map.get(attrs, :workflow_id),
      execution_id: Map.get(attrs, :execution_id),
      node_name: Map.get(attrs, :node_name),
      attempt: Map.get(attrs, :attempt, 1),
      workflow_params: wf_params,
      workflow_context: wf_ctx,
      execution_params: exec_params,
      execution_context: exec_ctx,
      node_params: node_params,
      params: merged_params,
      context: merged_ctx,
      results: results
    }
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, v1, v2 ->
      if is_map(v1) and is_map(v2) do
        deep_merge(v1, v2)
      else
        v2
      end
    end)
  end

  defp deep_merge(_left, right), do: right
end

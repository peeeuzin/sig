defmodule Sig.Flow do
  @moduledoc """
  A small builder for workflow definitions, plus the DAG helpers used by the
  engine.

  A flow is an in-memory description of a workflow: a name, workflow-level
  `params` and `context`, and a set of nodes connected by `depends_on`. Build
  it with `new/2` and `add_node/4`, then persist it with
  `Sig.create_workflow/1`.

      flow =
        Sig.Flow.new("signup", params: %{"plan" => "free"})
        |> Sig.Flow.add_node(:create_user, MyApp.Nodes.CreateUser)
        |> Sig.Flow.add_node(:send_welcome, MyApp.Nodes.SendWelcome, depends_on: [:create_user])
        |> Sig.Flow.add_node(:track, MyApp.Nodes.Track, depends_on: [:create_user])

      {:ok, workflow} = Sig.create_workflow(flow)

  Nodes without a dependency between them (`send_welcome` and `track` above)
  can run in parallel when the execution is started with `async: true` and
  the BullMQ worker has a concurrency greater than one.

  ## Node definitions

  Internally every node is normalized to a map with string keys:

      %{
        "name" => "send_welcome",
        "module" => "Elixir.MyApp.Nodes.SendWelcome",
        "params" => %{},
        "depends_on" => ["create_user"],
        "max_retries" => 3,
        "backoff_ms" => 500
      }

  This is the shape stored in `Sig.Schemas.Workflow` and the one expected by
  `topological_sort/1` and `find_runnable_nodes/2`.
  """

  defstruct name: nil, description: nil, params: %{}, context: %{}, nodes: %{}

  @typedoc "An in-memory workflow definition."
  @type t :: %__MODULE__{
          name: String.t() | nil,
          description: String.t() | nil,
          params: map(),
          context: map(),
          nodes: map()
        }

  @typedoc "A normalized node definition, keyed by strings."
  @type node_def :: %{optional(String.t()) => term()}

  @doc """
  Creates an empty flow.

  ## Options

    * `:description` - a free-form description.
    * `:params` - workflow-level params, merged into the params of every node.
    * `:context` - workflow-level context, shared by every node.

  ## Examples

      Sig.Flow.new("reports", params: %{"format" => "pdf"}, context: %{"tenant" => "acme"})
  """
  @spec new(String.t() | atom() | nil, keyword()) :: t()
  def new(name \\ nil, opts \\ []) do
    %__MODULE__{
      name: name && to_string(name),
      description: Keyword.get(opts, :description),
      params: Keyword.get(opts, :params, %{}) || %{},
      context: Keyword.get(opts, :context, %{}) || %{},
      nodes: %{}
    }
  end

  @doc """
  Adds a node to the flow.

  `name` identifies the node within the workflow (and is the key of its output
  in `context.results`). `module` is a module implementing `Sig.Node`. Adding
  a node with an existing name replaces it.

  ## Options

    * `:depends_on` - list of node names that must complete before this node
      runs. Defaults to `[]`.
    * `:params` - params for this node only. They take precedence over the
      execution and workflow params. Defaults to `%{}`.
    * `:max_retries` - total number of attempts before the node (and the
      execution) is marked as failed. Defaults to `3`.
    * `:backoff_ms` - base delay between attempts. The delay doubles after
      every failed attempt (`backoff_ms * 2^(attempt - 1)`), capped at 30
      seconds. Use `0` to retry immediately. Defaults to `500`.

  The graph is not validated here; validation happens in
  `Sig.create_workflow/1` (see `validate/1`).

  ## Examples

      flow
      |> Sig.Flow.add_node(:charge, MyApp.Nodes.Charge,
        depends_on: [:fetch_user],
        params: %{"amount" => 50},
        max_retries: 5,
        backoff_ms: 1_000
      )
  """
  @spec add_node(t(), String.t() | atom(), module() | String.t(), keyword()) :: t()
  def add_node(%__MODULE__{nodes: nodes} = flow, name, module, opts \\ []) do
    name_str = to_string(name)
    module_str = to_string(module)

    depends_on =
      opts
      |> Keyword.get(:depends_on, [])
      |> Enum.map(&to_string/1)

    node_def = %{
      "name" => name_str,
      "module" => module_str,
      "params" => Keyword.get(opts, :params, %{}) || %{},
      "depends_on" => depends_on,
      "max_retries" => Keyword.get(opts, :max_retries, 3),
      "backoff_ms" => Keyword.get(opts, :backoff_ms, 500)
    }

    %{flow | nodes: Map.put(nodes, name_str, node_def)}
  end

  @doc """
  Converts a flow to an attributes map accepted by `Sig.create_workflow/1`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = flow) do
    %{
      name: flow.name,
      description: flow.description,
      params: flow.params,
      context: flow.context,
      nodes: flow.nodes
    }
  end

  @doc """
  Normalizes node definitions to the string-keyed shape described in the
  module docs, filling in defaults for missing fields.

  Accepts either a map of node name to definition, or a list of definitions
  that carry a `:name` (or `"name"`) key. Atom and string keys are both
  accepted.

  ## Examples

      iex> Sig.Flow.normalize_nodes(%{fetch: %{module: MyNode}})
      %{
        "fetch" => %{
          "name" => "fetch",
          "module" => "Elixir.MyNode",
          "params" => %{},
          "depends_on" => [],
          "max_retries" => 3,
          "backoff_ms" => 500
        }
      }
  """
  @spec normalize_nodes(map() | [map()]) :: %{String.t() => node_def()}
  def normalize_nodes(nodes) when is_map(nodes) do
    Enum.reduce(nodes, %{}, fn {name, node_def}, acc ->
      name_str = to_string(name)
      node_map = normalize_node_def(name_str, node_def)
      Map.put(acc, name_str, node_map)
    end)
  end

  def normalize_nodes(nodes) when is_list(nodes) do
    Enum.reduce(nodes, %{}, fn node_def, acc ->
      name = Map.get(node_def, :name) || Map.get(node_def, "name")
      name_str = to_string(name)
      node_map = normalize_node_def(name_str, node_def)
      Map.put(acc, name_str, node_map)
    end)
  end

  defp normalize_node_def(name_str, node_def) when is_map(node_def) do
    raw_mod = Map.get(node_def, :module) || Map.get(node_def, "module")
    module_str = to_string(raw_mod)

    raw_deps =
      Map.get(node_def, :depends_on) || Map.get(node_def, "depends_on") || []

    depends_on = Enum.map(raw_deps, &to_string/1)

    params = Map.get(node_def, :params) || Map.get(node_def, "params") || %{}
    max_retries = Map.get(node_def, :max_retries) || Map.get(node_def, "max_retries") || 3
    backoff_ms = Map.get(node_def, :backoff_ms) || Map.get(node_def, "backoff_ms") || 500

    %{
      "name" => name_str,
      "module" => module_str,
      "params" => params,
      "depends_on" => depends_on,
      "max_retries" => max_retries,
      "backoff_ms" => backoff_ms
    }
  end

  @doc """
  Validates a set of node definitions.

  Checks that:

    * every node has a non-blank name and a module;
    * every entry in `depends_on` refers to an existing node;
    * the graph has no cycles.

  Returns `:ok` or `{:error, message}` describing the first problem found.

  ## Examples

      iex> Sig.Flow.validate(%{"a" => %{module: A, depends_on: ["b"]}})
      {:error, "Node 'a' depends on non-existent node 'b'"}
  """
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(nodes) when is_map(nodes) do
    normalized = normalize_nodes(nodes)

    with :ok <- validate_modules_and_names(normalized),
         :ok <- validate_dependencies_exist(normalized),
         :ok <- validate_no_cycles(normalized) do
      :ok
    end
  end

  def validate(_), do: {:error, "Nodes must be a map or list"}

  defp validate_modules_and_names(nodes) do
    Enum.reduce_while(nodes, :ok, fn {name, node_def}, :ok ->
      cond do
        name == "" ->
          {:halt, {:error, "Node name cannot be blank"}}

        Map.get(node_def, "module") in ["", nil] ->
          {:halt, {:error, "Node '#{name}' is missing module"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_dependencies_exist(nodes) do
    all_names = Map.keys(nodes)

    Enum.reduce_while(nodes, :ok, fn {node_name, node_def}, :ok ->
      deps = Map.get(node_def, "depends_on", [])

      missing = Enum.find(deps, fn dep -> dep not in all_names end)

      if missing do
        {:halt, {:error, "Node '#{node_name}' depends on non-existent node '#{missing}'"}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp validate_no_cycles(nodes) do
    case topological_sort(nodes) do
      {:ok, _order} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sorts node names so every node comes after its dependencies, using Kahn's
  algorithm.

  Returns `{:ok, sorted_names}`, or `{:error, message}` if the graph contains
  a cycle.

  ## Examples

      iex> Sig.Flow.topological_sort(%{
      ...>   "b" => %{module: B, depends_on: ["a"]},
      ...>   "a" => %{module: A}
      ...> })
      {:ok, ["a", "b"]}
  """
  @spec topological_sort(map()) :: {:ok, [String.t()]} | {:error, String.t()}
  def topological_sort(nodes) when is_map(nodes) do
    normalized = normalize_nodes(nodes)

    # In-degree map: how many dependencies each node has
    in_degree =
      Map.new(normalized, fn {name, defn} ->
        {name, length(Map.get(defn, "depends_on", []))}
      end)

    # Adjacency list: node -> list of nodes that depend on it
    adj =
      Enum.reduce(normalized, %{}, fn {name, defn}, acc ->
        deps = Map.get(defn, "depends_on", [])

        Enum.reduce(deps, acc, fn dep, inner_acc ->
          Map.update(inner_acc, dep, [name], fn existing -> [name | existing] end)
        end)
      end)

    # Queue of nodes with in-degree 0
    zero_in =
      in_degree
      |> Enum.filter(fn {_name, deg} -> deg == 0 end)
      |> Enum.map(fn {name, _} -> name end)

    do_topo_sort(zero_in, in_degree, adj, [])
  end

  defp do_topo_sort([], in_degree, _adj, sorted) do
    if Enum.all?(in_degree, fn {_name, deg} -> deg == 0 end) do
      {:ok, Enum.reverse(sorted)}
    else
      {:error, "Workflow contains circular dependencies (cycles detected)"}
    end
  end

  defp do_topo_sort([node | rest], in_degree, adj, sorted) do
    dependents = Map.get(adj, node, [])

    new_in_degree =
      Enum.reduce(dependents, in_degree, fn dep, acc ->
        Map.update!(acc, dep, &(&1 - 1))
      end)

    new_zero_in =
      dependents
      |> Enum.filter(fn dep -> Map.get(new_in_degree, dep) == 0 end)

    do_topo_sort(rest ++ new_zero_in, new_in_degree, adj, [node | sorted])
  end

  @doc """
  Returns the nodes that are ready to run.

  A node is runnable when it is not in `completed_names` and all of its
  dependencies are. `nodes` must already be normalized (see
  `normalize_nodes/1`).

  ## Examples

      iex> nodes = Sig.Flow.normalize_nodes(%{"a" => %{module: A}, "b" => %{module: B, depends_on: ["a"]}})
      iex> nodes |> Sig.Flow.find_runnable_nodes(["a"]) |> Enum.map(&elem(&1, 0))
      ["b"]
  """
  @spec find_runnable_nodes(%{String.t() => node_def()}, [String.t()]) ::
          [{String.t(), node_def()}]
  def find_runnable_nodes(nodes, completed_names)
      when is_map(nodes) and is_list(completed_names) do
    completed_set = MapSet.new(completed_names)

    Enum.filter(nodes, fn {name, defn} ->
      not MapSet.member?(completed_set, name) and
        Enum.all?(Map.get(defn, "depends_on", []), &MapSet.member?(completed_set, &1))
    end)
    |> Enum.map(fn {name, defn} -> {name, defn} end)
  end
end

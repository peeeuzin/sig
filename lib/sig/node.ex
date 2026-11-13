defmodule Sig.Node do
  @moduledoc """
  Behaviour for workflow nodes.

  A node is a module that implements either `c:run/1` or `c:run/2`. It
  receives the merged params, context and the results of the nodes it depends
  on, and returns its own result.

  ## `run/1`

  Receives the whole `Sig.NodeContext`:

      defmodule MyApp.Nodes.CalculateSum do
        use Sig.Node

        @impl true
        def run(context) do
          a = context.params["a"] || 0
          b = context.params["b"] || 0
          {:ok, %{"sum" => a + b}}
        end
      end

  ## `run/2`

  Receives the merged params as the first argument and the
  `Sig.NodeContext` as the second:

      defmodule MyApp.Nodes.FormatResult do
        use Sig.Node

        @impl true
        def run(params, context) do
          sum = context.results["calculate_sum"]["sum"]
          prefix = params["prefix"] || "Total:"
          {:ok, %{"formatted" => "\#{prefix} \#{sum}"}}
        end
      end

  When a module defines both, `run/1` is used.

  ## Return values

    * `{:ok, result}` - the node succeeded. `result` is stored and exposed to
      downstream nodes as `context.results[node_name]`.
    * `{:error, reason}` - the node failed. It is retried according to its
      `max_retries`/`backoff_ms`; when no attempts are left, the execution is
      marked as `failed` with `reason` as its error.
    * any other value - treated as `{:ok, value}`.

  Raised exceptions, throws and exits are caught and handled like
  `{:error, reason}`, with the exception message and stacktrace stored as the
  error.

  Results are persisted as JSON: atom keys and values become strings, tuples
  become lists, and non-map results are wrapped as `%{"value" => result}`.
  See `Sig.Serializer`.

  ## Idempotency

  A node that completed is never run again for the same execution, even when
  the execution is resumed. A node that fails mid-way, however, may be retried,
  so side effects should be idempotent (use `context.execution_id` and
  `context.node_name` as an idempotency key for external calls).
  """

  @typedoc "The value returned by a node."
  @type result :: {:ok, term()} | {:error, term()} | term()

  @doc """
  Runs the node with its full `Sig.NodeContext`.
  """
  @callback run(context :: Sig.NodeContext.t()) :: result()

  @doc """
  Runs the node with its merged params and its `Sig.NodeContext`.

  `params` is the same as `context.params`.
  """
  @callback run(params :: map(), context :: Sig.NodeContext.t()) :: result()

  @optional_callbacks [run: 1, run: 2]

  @doc """
  Declares the current module as a `Sig.Node`.

      use Sig.Node
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Sig.Node
    end
  end

  @doc """
  Runs a node module with the given `Sig.NodeContext`.

  `module` may be a module or its name as a string (as stored in the
  workflow). Dispatches to `run/1` or `run/2`, normalizes the return value to
  `{:ok, result}` or `{:error, reason}` and turns exceptions, throws and exits
  into errors.

  This is used by `Sig.Engine`; you normally do not call it directly, but it
  is handy for unit-testing a node in isolation:

      context = Sig.NodeContext.build(%{node_name: "sum", node_params: %{"a" => 1, "b" => 2}})
      {:ok, %{"sum" => 3}} = Sig.Node.execute(MyApp.Nodes.CalculateSum, context)
  """
  @spec execute(module() | String.t(), Sig.NodeContext.t()) :: {:ok, term()} | {:error, term()}
  def execute(module, %Sig.NodeContext{} = context) when is_atom(module) do
    cond do
      function_exported?(module, :run, 1) ->
        safe_call(fn -> module.run(context) end)

      function_exported?(module, :run, 2) ->
        safe_call(fn -> module.run(context.params, context) end)

      true ->
        {:error, "Module #{inspect(module)} does not export run/1 or run/2"}
    end
  end

  def execute(module_string, %Sig.NodeContext{} = context) when is_binary(module_string) do
    case resolve_module(module_string) do
      {:ok, module} ->
        execute(module, context)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resolves a module name to a loaded module.

  Accepts names with or without the `Elixir.` prefix. Only existing atoms are
  used, so arbitrary strings never create new atoms.

  ## Examples

      iex> Sig.Node.resolve_module("Enum")
      {:ok, Enum}

      iex> Sig.Node.resolve_module("Does.Not.Exist")
      {:error, "Module Does.Not.Exist does not exist"}
  """
  @spec resolve_module(String.t() | module()) :: {:ok, module()} | {:error, String.t()}
  def resolve_module(module_string) when is_binary(module_string) do
    # Try String.to_existing_atom
    try do
      atom =
        if String.starts_with?(module_string, "Elixir.") do
          String.to_existing_atom(module_string)
        else
          String.to_existing_atom("Elixir.#{module_string}")
        end

      if Code.ensure_loaded?(atom) do
        {:ok, atom}
      else
        {:error, "Module #{module_string} is not loaded"}
      end
    rescue
      ArgumentError ->
        {:error, "Module #{module_string} does not exist"}
    end
  end

  def resolve_module(module) when is_atom(module), do: {:ok, module}

  defp safe_call(fun) do
    try do
      case fun.() do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          {:error, reason}

        other ->
          {:ok, other}
      end
    rescue
      e ->
        stacktrace = Exception.format_stacktrace(__STACKTRACE__)

        {:error,
         %{exception: Exception.message(e), type: inspect(e.__struct__), stacktrace: stacktrace}}
    catch
      :exit, reason ->
        {:error, %{exit: inspect(reason)}}

      thrown ->
        {:error, %{thrown: inspect(thrown)}}
    end
  end
end

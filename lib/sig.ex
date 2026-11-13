defmodule Sig do
  @moduledoc """
  Public API of the Sig workflow engine.

  Sig runs workflows defined as a Directed Acyclic Graph (DAG) of nodes. Each
  node is a module implementing `Sig.Node`. Workflows and their executions are
  persisted in PostgreSQL through your application's Ecto repo, and executions
  can run either inline (synchronously) or distributed across workers through
  BullMQ (Redis).

  ## Setup

      # config/config.exs
      config :sig, repo: MyApp.Repo

  and create Sig's tables with a migration that calls `Sig.Migration.up/1`.
  See the README for the full installation guide.

  ## Concepts

    * **Workflow** (`Sig.Schemas.Workflow`) - a persisted DAG definition, with
      workflow-level `params` and `context`. Build one with `Sig.Flow` and save
      it with `create_workflow/1`.
    * **Execution** (`Sig.Schemas.WorkflowExecution`) - a single run of a
      workflow, with its own `params`, `context` and accumulated
      `node_results`.
    * **Node execution** (`Sig.Schemas.NodeExecution`) - the record of one node
      within an execution, tracking attempts, result and errors.

  ## Params and context

  When a node runs it receives a `Sig.NodeContext`. Its `params` are deep-merged
  in this order, with later levels winning:

      workflow params -> execution params -> node params

  and its `context` is the deep merge of the workflow and execution contexts.
  The outputs of completed nodes are available in `context.results`, keyed by
  node name.

  > #### Keys are strings at runtime {: .warning}
  >
  > Params, context and results are stored in JSONB columns, so by the time a
  > node runs all map keys are strings, even if atoms were used when defining
  > the workflow. Read them with `params["key"]`, not `params[:key]`.

  ## Example

      flow =
        Sig.Flow.new("payment_pipeline", params: %{"currency" => "BRL"})
        |> Sig.Flow.add_node(:fetch_user, MyApp.Nodes.FetchUser)
        |> Sig.Flow.add_node(:debit, MyApp.Nodes.DebitAccount,
          depends_on: [:fetch_user],
          params: %{"amount" => 50}
        )

      {:ok, workflow} = Sig.create_workflow(flow)
      {:ok, execution} = Sig.run_execution(workflow, %{"user_id" => 10})

      execution.status
      #=> "completed"

  ## Return values

  Functions that look up a record return `{:error, :not_found}` (or
  `{:error, :workflow_not_found}` in `create_execution/4`) when it does not
  exist. Lifecycle functions also return `{:error, reason}` when the
  transition is not allowed, for example
  `{:error, {:cannot_resume_in_state, "completed"}}`.
  """

  alias Sig.Repo
  alias Sig.Schemas.{Workflow, WorkflowExecution}
  alias Sig.Engine
  alias Sig.BullMQ.Queue, as: BullMQQueue

  import Ecto.Query

  @typedoc "A workflow struct or its ID."
  @type workflow_ref :: Workflow.t() | String.t()

  @typedoc "An execution struct or its ID."
  @type execution_ref :: WorkflowExecution.t() | String.t()

  # ============================================================================
  # Workflow Definition
  # ============================================================================

  @doc """
  Creates and persists a workflow definition.

  Accepts either a `Sig.Flow` struct or a map of attributes. The node graph is
  validated (missing modules, missing dependencies and cycles) before the
  workflow is inserted; validation errors are returned in the changeset under
  `:nodes`.

  ## Attributes

    * `:name` (required) - the workflow name.
    * `:description` - a free-form description.
    * `:params` - workflow-level params, merged into every node's params.
    * `:context` - workflow-level context, shared by every node.
    * `:nodes` - a map of node name to node definition (or a list of node
      definitions with a `:name` key). See `Sig.Flow.add_node/4` for the
      supported fields.

  ## Examples

      # Using the Sig.Flow DSL:
      flow =
        Sig.Flow.new("data_pipeline", params: %{"env" => "prod"}, context: %{"source" => "s3"})
        |> Sig.Flow.add_node(:fetch, FetchDataNode, params: %{"bucket" => "my-bucket"})
        |> Sig.Flow.add_node(:process, ProcessDataNode, depends_on: [:fetch])
        |> Sig.Flow.add_node(:notify, NotifyNode, depends_on: [:process])

      {:ok, workflow} = Sig.create_workflow(flow)

      # Using a map:
      {:ok, workflow} =
        Sig.create_workflow(%{
          name: "data_pipeline",
          params: %{"env" => "prod"},
          context: %{"source" => "s3"},
          nodes: %{
            "fetch" => %{module: FetchDataNode, params: %{"bucket" => "my-bucket"}},
            "process" => %{module: ProcessDataNode, depends_on: ["fetch"]}
          }
        })

      # Invalid graphs are rejected:
      {:error, %Ecto.Changeset{errors: [nodes: {"Workflow contains circular dependencies" <> _, _}]}} =
        Sig.create_workflow(cyclic_flow)
  """
  @spec create_workflow(Sig.Flow.t() | map()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def create_workflow(%Sig.Flow{} = flow) do
    create_workflow(Sig.Flow.to_map(flow))
  end

  def create_workflow(attrs) when is_map(attrs) do
    %Workflow{}
    |> Workflow.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a workflow from a name and a map of node definitions.

  A shortcut for `create_workflow/1` that does not require building a
  `Sig.Flow` first.

  ## Options

    * `:description` - a free-form description.
    * `:params` - workflow-level params.
    * `:context` - workflow-level context.

  ## Examples

      {:ok, workflow} =
        Sig.create_workflow("etl", %{
          "extract" => %{module: Extract},
          "load" => %{module: Load, depends_on: ["extract"]}
        })
  """
  @spec create_workflow(String.t() | atom(), map() | list(), keyword()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def create_workflow(name, nodes, opts \\ []) when is_binary(name) or is_atom(name) do
    attrs = %{
      name: to_string(name),
      description: Keyword.get(opts, :description),
      params: Keyword.get(opts, :params, %{}),
      context: Keyword.get(opts, :context, %{}),
      nodes: nodes
    }

    create_workflow(attrs)
  end

  @doc """
  Fetches a workflow by ID. Returns `nil` if it does not exist.
  """
  @spec get_workflow(String.t()) :: Workflow.t() | nil
  def get_workflow(id) do
    Repo.get(Workflow, id)
  end

  @doc """
  Fetches a workflow by ID. Raises `Ecto.NoResultsError` if it does not exist.
  """
  @spec get_workflow!(String.t()) :: Workflow.t()
  def get_workflow!(id) do
    Repo.get!(Workflow, id)
  end

  @doc """
  Lists all workflows, most recently created first.
  """
  @spec list_workflows() :: [Workflow.t()]
  def list_workflows do
    Repo.all(from(w in Workflow, order_by: [desc: w.inserted_at]))
  end

  @doc """
  Deletes a workflow and all of its executions.

  Returns `{:error, :not_found}` if the workflow does not exist.
  """
  @spec delete_workflow(workflow_ref()) ::
          {:ok, Workflow.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete_workflow(workflow_or_id) do
    workflow =
      case workflow_or_id do
        %Workflow{} = wf -> wf
        id -> Repo.get(Workflow, id)
      end

    if workflow, do: Repo.delete(workflow), else: {:error, :not_found}
  end

  # ============================================================================
  # Workflow Control: Suspend / Resume / Stop
  # ============================================================================

  @doc """
  Suspends a workflow.

  While suspended, new executions cannot be created, and all `pending` and
  `running` executions are moved to `suspended`. Nodes that are already
  running finish, but no further nodes are dispatched.

  Use `resume_workflow/1` to reactivate the workflow, then
  `resume_execution/2` for each execution you want to continue.

  Returns `{:error, :workflow_already_stopped}` for stopped workflows.
  """
  @spec suspend_workflow(workflow_ref()) :: {:ok, Workflow.t()} | {:error, term()}
  def suspend_workflow(workflow_or_id) do
    id = get_id(workflow_or_id)
    Engine.suspend_workflow(id)
  end

  @doc """
  Resumes a suspended workflow, allowing new executions to be created again.

  Executions suspended by `suspend_workflow/1` stay suspended; resume them
  individually with `resume_execution/2`.

  Returns `{:error, :workflow_already_stopped}` for stopped workflows.
  """
  @spec resume_workflow(workflow_ref()) :: {:ok, Workflow.t()} | {:error, term()}
  def resume_workflow(workflow_or_id) do
    id = get_id(workflow_or_id)
    Engine.resume_workflow(id)
  end

  @doc """
  Stops a workflow permanently.

  All `pending`, `running` and `suspended` executions are moved to `stopped`,
  and no new executions can be created. A stopped workflow cannot be resumed.
  """
  @spec stop_workflow(workflow_ref()) :: {:ok, Workflow.t()} | {:error, term()}
  def stop_workflow(workflow_or_id) do
    id = get_id(workflow_or_id)
    Engine.stop_workflow(id)
  end

  # ============================================================================
  # Workflow Executions
  # ============================================================================

  @doc """
  Creates a `pending` execution for a workflow without running it.

  Start it afterwards with `start_execution/2`, or use `run_execution/4` to
  create and start in a single call.

  `execution_params` are merged over the workflow params (and under each
  node's params); `execution_context` is merged over the workflow context.

  ## Options

    * `:idempotency_key` - when an execution with the same key already exists
      for this workflow, that execution is returned instead of creating a
      duplicate.

  ## Errors

    * `{:error, :workflow_not_found}`
    * `{:error, :workflow_suspended}`
    * `{:error, :workflow_stopped}`

  ## Examples

      {:ok, execution} = Sig.create_execution(workflow.id, %{"batch_id" => 123}, %{"user_id" => 42})
      {:ok, execution} = Sig.create_execution(workflow, %{}, %{}, idempotency_key: "tx-999")
  """
  @spec create_execution(workflow_ref(), map(), map(), keyword()) ::
          {:ok, WorkflowExecution.t()} | {:error, term()}
  def create_execution(
        workflow_or_id,
        execution_params \\ %{},
        execution_context \\ %{},
        opts \\ []
      ) do
    workflow_id = get_id(workflow_or_id)
    idempotency_key = Keyword.get(opts, :idempotency_key)

    case Repo.get(Workflow, workflow_id) do
      nil ->
        {:error, :workflow_not_found}

      %Workflow{status: "suspended"} ->
        {:error, :workflow_suspended}

      %Workflow{status: "stopped"} ->
        {:error, :workflow_stopped}

      %Workflow{} ->
        # Check idempotency
        if idempotency_key do
          case Repo.get_by(WorkflowExecution,
                 workflow_id: workflow_id,
                 idempotency_key: idempotency_key
               ) do
            %WorkflowExecution{} = existing ->
              {:ok, existing}

            nil ->
              insert_execution(workflow_id, execution_params, execution_context, idempotency_key)
          end
        else
          insert_execution(workflow_id, execution_params, execution_context, nil)
        end
    end
  end

  defp insert_execution(workflow_id, params, context, idempotency_key) do
    attrs = %{
      workflow_id: workflow_id,
      idempotency_key: idempotency_key,
      params: params || %{},
      context: context || %{},
      status: "pending"
    }

    %WorkflowExecution{}
    |> WorkflowExecution.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Starts an execution.

  ## Options

    * `:async` - when `false` (the default), runs the execution in the calling
      process with `Sig.Engine.execute_sync/1` and returns once it reaches a
      final state (or is suspended/stopped). When `true`, marks the execution
      as `running`, enqueues its runnable nodes to BullMQ and returns
      immediately; `Sig.BullMQ.Supervisor` must be running for the jobs to be
      processed.

  ## Examples

      {:ok, %{status: "completed"}} = Sig.start_execution(execution)

      {:ok, %{status: "running"}} = Sig.start_execution(execution, async: true)
  """
  @spec start_execution(execution_ref(), keyword()) ::
          {:ok, WorkflowExecution.t()} | {:error, term()}
  def start_execution(execution_or_id, opts \\ []) do
    execution_id = get_id(execution_or_id)
    async? = Keyword.get(opts, :async, false)

    if async? do
      execution = Repo.get!(WorkflowExecution, execution_id)
      now = DateTime.utc_now()

      {:ok, _running_exec} =
        execution
        |> WorkflowExecution.status_changeset("running", %{
          started_at: execution.started_at || now
        })
        |> Repo.update()

      case BullMQQueue.enqueue_execution(execution_id) do
        {:ok, _count} ->
          {:ok, get_execution(execution_id)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      Engine.execute_sync(execution_id)
    end
  end

  @doc """
  Creates an execution and starts it right away.

  Equivalent to `create_execution/4` followed by `start_execution/2`. Accepts
  the options of both functions (`:idempotency_key` and `:async`).

  ## Examples

      {:ok, execution} = Sig.run_execution(workflow, %{"input" => "hello"}, %{"auth" => token})

      {:ok, execution} =
        Sig.run_execution(workflow, %{"order_id" => 1}, %{},
          idempotency_key: "order-1",
          async: true
        )
  """
  @spec run_execution(workflow_ref(), map(), map(), keyword()) ::
          {:ok, WorkflowExecution.t()} | {:error, term()}
  def run_execution(workflow_or_id, execution_params \\ %{}, execution_context \\ %{}, opts \\ []) do
    with {:ok, execution} <-
           create_execution(workflow_or_id, execution_params, execution_context, opts) do
      start_execution(execution, opts)
    end
  end

  @doc """
  Fetches an execution by ID, preloading its `:workflow` and
  `:node_executions`. Returns `nil` if it does not exist.
  """
  @spec get_execution(String.t()) :: WorkflowExecution.t() | nil
  def get_execution(id) do
    WorkflowExecution
    |> Repo.get(id)
    |> Repo.preload([:workflow, :node_executions])
  end

  @doc """
  Fetches an execution by ID, preloading its `:workflow` and
  `:node_executions`. Raises `Ecto.NoResultsError` if it does not exist.
  """
  @spec get_execution!(String.t()) :: WorkflowExecution.t()
  def get_execution!(id) do
    WorkflowExecution
    |> Repo.get!(id)
    |> Repo.preload([:workflow, :node_executions])
  end

  @doc """
  Lists executions, most recently created first, with `:workflow` preloaded.

  When `workflow_id` is given, only executions of that workflow are returned.
  """
  @spec list_executions(String.t() | nil) :: [WorkflowExecution.t()]
  def list_executions(workflow_id \\ nil) do
    query = from(e in WorkflowExecution, order_by: [desc: e.inserted_at], preload: [:workflow])

    query =
      if workflow_id do
        where(query, [e], e.workflow_id == ^workflow_id)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Returns the results of all completed nodes of an execution, keyed by node
  name.

  Results that were not maps when returned by the node are wrapped as
  `%{"value" => result}` (see `Sig.Serializer.wrap_result/1`).

  ## Examples

      {:ok, %{"fetch_user" => %{"name" => "Ana"}}} = Sig.get_node_results(execution)
  """
  @spec get_node_results(execution_ref()) :: {:ok, map()} | {:error, :not_found}
  def get_node_results(execution_or_id) do
    execution =
      case execution_or_id do
        %WorkflowExecution{node_results: results} -> %{node_results: results}
        id -> Repo.get(WorkflowExecution, id)
      end

    if execution do
      {:ok, execution.node_results || %{}}
    else
      {:error, :not_found}
    end
  end

  # ============================================================================
  # Execution Control: Suspend / Resume / Stop
  # ============================================================================

  @doc """
  Suspends an execution.

  Nodes that are already running finish, but no further nodes are
  dispatched. Continue it later with `resume_execution/2`.

  Returns `{:error, {:cannot_suspend_in_state, status}}` for executions that
  are `completed`, `failed` or `stopped`.
  """
  @spec suspend_execution(execution_ref()) ::
          {:ok, WorkflowExecution.t()} | {:error, term()}
  def suspend_execution(execution_or_id) do
    id = get_id(execution_or_id)
    Engine.suspend_execution(id)
  end

  @doc """
  Resumes a suspended execution from where it stopped.

  Nodes that already completed are not run again; only the remaining nodes
  are dispatched.

  ## Options

    * `:async` - same as in `start_execution/2`. Defaults to `false`.

  ## Errors

    * `{:error, :not_found}`
    * `{:error, :workflow_suspended}` / `{:error, :workflow_stopped}`
    * `{:error, {:cannot_resume_in_state, status}}` - the execution is not
      `suspended`.
  """
  @spec resume_execution(execution_ref(), keyword()) ::
          {:ok, WorkflowExecution.t()} | {:error, term()}
  def resume_execution(execution_or_id, opts \\ []) do
    id = get_id(execution_or_id)

    with {:ok, execution} <- Engine.resume_execution(id) do
      start_execution(execution, opts)
    end
  end

  @doc """
  Stops an execution permanently. A stopped execution cannot be resumed.

  Returns `{:error, {:cannot_stop_in_state, status}}` for executions that are
  already `completed` or `failed`.
  """
  @spec stop_execution(execution_ref()) ::
          {:ok, WorkflowExecution.t()} | {:error, term()}
  def stop_execution(execution_or_id) do
    id = get_id(execution_or_id)
    Engine.stop_execution(id)
  end

  # Helpers
  defp get_id(%{id: id}), do: id
  defp get_id(id) when is_binary(id), do: id
  defp get_id(id), do: to_string(id)
end

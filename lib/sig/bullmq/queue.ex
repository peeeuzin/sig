defmodule Sig.BullMQ.Queue do
  @moduledoc """
  Enqueues workflow nodes as BullMQ jobs.

  Each job carries an `execution_id` and a `node_name` and is processed by
  `Sig.BullMQ.Worker`. You normally don't call this module directly; use
  `Sig.start_execution/2` with `async: true`.

  ## Configuration

    * `:bullmq_queue_name` - the queue name. Defaults to `"sig_workflows"`.
    * `:bullmq_connection` - the name of the `BullMQ.RedisConnection` process.
      Defaults to `:sig_redis`, the one started by `Sig.BullMQ.Supervisor`.
  """

  alias Sig.Repo
  alias Sig.Schemas.WorkflowExecution

  @queue_name "sig_workflows"
  @redis_conn :sig_redis

  @doc "Returns the configured BullMQ queue name."
  @spec queue_name() :: String.t()
  def queue_name, do: Application.get_env(:sig, :bullmq_queue_name, @queue_name)
  @doc "Returns the configured Redis connection name."
  @spec connection() :: atom()
  def connection, do: Application.get_env(:sig, :bullmq_connection, @redis_conn)

  @doc """
  Enqueues every node of an execution that is currently ready to run.

  Returns `{:ok, count}` with the number of enqueued nodes, or
  `{:error, :not_found}`.
  """
  @spec enqueue_execution(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def enqueue_execution(execution_id) do
    execution =
      WorkflowExecution
      |> Repo.get(execution_id)
      |> Repo.preload(:workflow)

    if execution do
      completed_names = Map.keys(execution.node_results || %{})
      runnable = Sig.Flow.find_runnable_nodes(execution.workflow.nodes, completed_names)

      Enum.each(runnable, fn {node_name, _node_def} ->
        enqueue_node(execution.id, node_name)
      end)

      {:ok, length(runnable)}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Enqueues a single node of an execution.

  The job ID is `"<execution_id>:<node_name>"`, so enqueuing the same node
  twice does not create a duplicate job. `opts` are passed to
  `BullMQ.Queue.add/4` and override the defaults.
  """
  @spec enqueue_node(String.t(), String.t() | atom(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def enqueue_node(execution_id, node_name, opts \\ []) do
    data = %{
      "execution_id" => to_string(execution_id),
      "node_name" => to_string(node_name)
    }

    job_id = "#{execution_id}:#{node_name}"

    job_opts =
      [
        connection: connection(),
        job_id: job_id
      ]
      |> Keyword.merge(opts)

    BullMQ.Queue.add(queue_name(), "execute_node", data, job_opts)
  end
end

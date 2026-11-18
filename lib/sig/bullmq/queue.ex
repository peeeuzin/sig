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
  Advances an execution: enqueues every node that is currently ready to run,
  or marks the execution as `completed` when every node is done.

  Does nothing for executions that are not `pending` or `running`, or whose
  workflow is not `active`. Safe to call several times and from several
  workers at once: nodes that are already queued or running are not
  enqueued twice (see `enqueue_node/3`).

  Returns `{:ok, count}` with the number of nodes passed to BullMQ,
  `{:error, :not_found}`, or `{:error, reason}` if Redis rejected a job.
  """
  @spec enqueue_execution(String.t()) ::
          {:ok, non_neg_integer()} | {:error, :not_found} | {:error, term()}
  def enqueue_execution(execution_id) do
    execution =
      WorkflowExecution
      |> Repo.get(execution_id)
      |> Repo.preload(:workflow)

    cond do
      is_nil(execution) ->
        {:error, :not_found}

      execution.status not in ["pending", "running"] or execution.workflow.status != "active" ->
        {:ok, 0}

      true ->
        nodes = execution.workflow.nodes
        completed_names = Map.keys(execution.node_results || %{})

        if Enum.all?(Map.keys(nodes), &(&1 in completed_names)) do
          Sig.Engine.complete_execution(execution.id)
          {:ok, 0}
        else
          nodes
          |> Sig.Flow.find_runnable_nodes(completed_names)
          |> enqueue_all(execution.id)
        end
    end
  end

  defp enqueue_all(runnable, execution_id) do
    Enum.reduce_while(runnable, {:ok, 0}, fn {node_name, _node_def}, {:ok, count} ->
      case enqueue_node(execution_id, node_name) do
        {:ok, _job} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Enqueues a single node of an execution.

  The job ID is `"<execution_id>:<node_name>"`, so while a job for that node
  is waiting, delayed or running, enqueuing it again does not create a
  duplicate. Once a job finishes it must be removed from Redis, or BullMQ
  would ignore the node when it has to be enqueued again, for example when
  an execution is resumed. The worker does that (see
  `Sig.BullMQ.Worker.worker_opts/0`); the job options ask for it too.

  `opts` are passed to `BullMQ.Queue.add/4` and override the defaults.
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
        job_id: job_id,
        remove_on_complete: true,
        remove_on_fail: true
      ]
      |> Keyword.merge(opts)

    BullMQ.Queue.add(queue_name(), "execute_node", data, job_opts)
  end
end

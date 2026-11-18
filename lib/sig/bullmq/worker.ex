defmodule Sig.BullMQ.Worker do
  @moduledoc """
  Processes the BullMQ jobs enqueued by `Sig.BullMQ.Queue`.

  For each job it runs the node with `Sig.Engine.execute_node/2`. On success,
  it enqueues the nodes that became runnable, or marks the execution as
  `completed` when every node is done (see
  `Sig.BullMQ.Queue.enqueue_execution/1`). When the node fails on its last
  attempt, the execution is marked as `failed`.

  Jobs for suspended or stopped executions (or workflows) are acknowledged
  without running the node; resuming the execution enqueues them again.

  When another process holds the node's lease (see "Concurrency and leases"
  in `Sig.Engine`), the job is delayed by the lease duration instead of
  running the node a second time. When it runs again, it either finds the
  node completed (and just dispatches the next nodes) or takes the node over
  if its owner died.

  Started by `Sig.BullMQ.Supervisor`. If you run your own `BullMQ.Worker`,
  merge `worker_opts/0` into its options:

      {BullMQ.Worker,
       [name: :my_worker, queue: "sig_workflows", connection: :sig_redis, concurrency: 10] ++
         Sig.BullMQ.Worker.worker_opts()}
  """

  alias Sig.Repo
  alias Sig.Schemas.WorkflowExecution
  alias Sig.BullMQ.Queue, as: SigQueue
  alias Sig.Serializer

  require Logger

  # How long to wait before retrying a job whose node completed but whose
  # next nodes could not be enqueued.
  @dispatch_retry_ms 1_000

  @doc """
  The `BullMQ.Worker` options Sig needs: `process_job/1` as the processor,
  and removing jobs from Redis once they finish.

  Finished jobs must be removed because their ID (`"<execution_id>:<node>"`)
  would otherwise keep BullMQ from enqueuing the node again, for example when
  an execution is resumed. BullMQ applies the worker's removal settings, not
  the job's, so they are set here. The execution state is kept in
  PostgreSQL, so nothing is lost.
  """
  @spec worker_opts() :: keyword()
  def worker_opts do
    [
      processor: &__MODULE__.process_job/1,
      remove_on_complete: true,
      remove_on_fail: true
    ]
  end

  @doc """
  Processes a job whose data contains `"execution_id"` and `"node_name"`.

  Returns `{:ok, result}` or `:ok` when the job should be acknowledged,
  `{:delay, ms}` when it should run again later, and `{:error, reason}` when
  the node failed.
  """
  @spec process_job(BullMQ.Job.t()) ::
          :ok | {:ok, term()} | {:delay, non_neg_integer()} | {:error, term()}
  def process_job(%BullMQ.Job{data: data}) do
    execution_id = data["execution_id"]
    node_name = data["node_name"]

    Logger.info("[Sig.BullMQ.Worker] Processing node #{node_name} for execution #{execution_id}")

    case Sig.Engine.execute_node(execution_id, node_name) do
      {:ok, result} ->
        dispatch_next(execution_id, node_name, result)

      {:error, :node_already_running} ->
        Logger.info(
          "[Sig.BullMQ.Worker] Node #{node_name} of execution #{execution_id} is running elsewhere, delaying"
        )

        {:delay, Sig.Engine.lease_ms()}

      {:error, :workflow_suspended} ->
        Logger.info("[Sig.BullMQ.Worker] Workflow suspended, halting node #{node_name}")
        :ok

      {:error, :workflow_stopped} ->
        Logger.info("[Sig.BullMQ.Worker] Workflow stopped, skipping node #{node_name}")
        :ok

      {:error, :execution_suspended} ->
        Logger.info("[Sig.BullMQ.Worker] Execution suspended, halting node #{node_name}")
        :ok

      {:error, :execution_stopped} ->
        Logger.info("[Sig.BullMQ.Worker] Execution stopped, skipping node #{node_name}")
        :ok

      {:error, {:execution_already_finished, _status}} ->
        :ok

      {:error, :execution_not_found} ->
        :ok

      {:error, reason} ->
        Logger.error("[Sig.BullMQ.Worker] Node #{node_name} failed: #{inspect(reason)}")

        # Mark execution failed if not already in terminal state
        mark_execution_failed(execution_id, reason)
        {:error, reason}
    end
  end

  defp dispatch_next(execution_id, node_name, result) do
    case SigQueue.enqueue_execution(execution_id) do
      {:ok, _count} ->
        {:ok, result}

      {:error, :not_found} ->
        {:ok, result}

      {:error, reason} ->
        # The node result is stored; running the job again only dispatches.
        Logger.error(
          "[Sig.BullMQ.Worker] Could not enqueue the nodes after #{node_name}: #{inspect(reason)}"
        )

        {:delay, @dispatch_retry_ms}
    end
  end

  defp mark_execution_failed(execution_id, reason) do
    now = DateTime.utc_now()
    wrapped_err = Serializer.wrap_result(reason)

    case Repo.get(WorkflowExecution, execution_id) do
      %WorkflowExecution{status: s} = exec when s in ["pending", "running"] ->
        exec
        |> WorkflowExecution.status_changeset("failed", %{
          completed_at: now,
          error: wrapped_err
        })
        |> Repo.update()

      _ ->
        :ok
    end
  end
end

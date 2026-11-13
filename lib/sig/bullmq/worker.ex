defmodule Sig.BullMQ.Worker do
  @moduledoc """
  Processes the BullMQ jobs enqueued by `Sig.BullMQ.Queue`.

  For each job it runs the node with `Sig.Engine.execute_node/2`. On success,
  it enqueues the nodes that became runnable, or marks the execution as
  `completed` when every node is done. When the node fails on its last
  attempt, the execution is marked as `failed`.

  Jobs for suspended or stopped executions (or workflows) are acknowledged
  without running the node.

  Started by `Sig.BullMQ.Supervisor`; use `process_job/1` as the processor
  if you run your own `BullMQ.Worker`.
  """

  alias Sig.Repo
  alias Sig.Schemas.WorkflowExecution
  alias Sig.BullMQ.Queue, as: SigQueue
  alias Sig.Serializer

  require Logger

  @doc """
  Processes a job whose data contains `"execution_id"` and `"node_name"`.

  Returns `{:ok, result}` or `:ok` when the job should be acknowledged, and
  `{:error, reason}` when the node failed.
  """
  @spec process_job(BullMQ.Job.t()) :: :ok | {:ok, term()} | {:error, term()}
  def process_job(%BullMQ.Job{data: data}) do
    execution_id = data["execution_id"]
    node_name = data["node_name"]

    Logger.info("[Sig.BullMQ.Worker] Processing node #{node_name} for execution #{execution_id}")

    case Sig.Engine.execute_node(execution_id, node_name) do
      {:ok, result} ->
        handle_node_success(execution_id)
        {:ok, result}

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

      {:error, reason} ->
        Logger.error("[Sig.BullMQ.Worker] Node #{node_name} failed: #{inspect(reason)}")

        # Mark execution failed if not already in terminal state
        mark_execution_failed(execution_id, reason)
        {:error, reason}
    end
  end

  defp handle_node_success(execution_id) do
    execution =
      WorkflowExecution
      |> Repo.get(execution_id)
      |> Repo.preload(:workflow)

    if execution && execution.status in ["pending", "running"] &&
         execution.workflow.status == "active" do
      completed_names = Map.keys(execution.node_results || %{})
      runnable = Sig.Flow.find_runnable_nodes(execution.workflow.nodes, completed_names)

      total_nodes = map_size(execution.workflow.nodes)
      num_completed = length(completed_names)

      cond do
        num_completed == total_nodes ->
          now = DateTime.utc_now()

          execution
          |> WorkflowExecution.status_changeset("completed", %{completed_at: now})
          |> Repo.update!()

        runnable != [] ->
          Enum.each(runnable, fn {next_name, _defn} ->
            SigQueue.enqueue_node(execution_id, next_name)
          end)

        true ->
          :ok
      end
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

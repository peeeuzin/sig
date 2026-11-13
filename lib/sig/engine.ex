defmodule Sig.Engine do
  @moduledoc """
  The execution engine behind `Sig`.

  It resolves which nodes can run, executes them with retries, stores their
  results and moves executions through their states. Most applications should
  use the functions in `Sig`, which delegate here; this module is useful when
  you need lower-level control, such as running a single node.

  ## Execution states

      pending -> running -> completed
                         -> failed
                         -> suspended -> running (resume)
                         -> stopped

  ## Node states

  `Sig.Schemas.NodeExecution` records go through `pending`, `running`,
  `retrying` and finally `completed` or `failed`.

  ## Retries

  A failed node is retried until it reaches its `max_retries` attempts,
  sleeping `backoff_ms * 2^(attempt - 1)` milliseconds (capped at 30 seconds)
  between attempts. When the last attempt fails, the execution is marked as
  `failed`.

  ## Idempotency

  Before running a node, the engine checks whether it already completed in
  this execution (in `node_results` or in its `NodeExecution` record). If so,
  the stored result is reused and the node is not run again.
  """

  alias Sig.Repo
  alias Sig.Schemas.{Workflow, WorkflowExecution, NodeExecution}
  alias Sig.NodeContext
  alias Sig.Serializer

  import Ecto.Query

  @doc """
  Runs an execution in the calling process until it completes, fails, is
  suspended or is stopped.

  Nodes run one at a time, in dependency order. Returns the execution in its
  final state.
  """
  @spec execute_sync(String.t()) :: {:ok, WorkflowExecution.t()} | {:error, term()}
  def execute_sync(execution_id) do
    case get_and_validate_execution(execution_id) do
      {:ok, execution} ->
        run_loop(execution.id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Runs a single node of an execution, with retries.

  Used by `Sig.BullMQ.Worker` to process one job. It does not dispatch
  downstream nodes. If the node already completed, its stored result is
  returned without running it again.

  ## Errors

    * `{:error, :execution_not_found}`
    * `{:error, :workflow_suspended}` / `{:error, :workflow_stopped}`
    * `{:error, :execution_suspended}` / `{:error, :execution_stopped}`
    * `{:error, {:execution_already_finished, status}}`
    * `{:error, {:node_not_found, node_name}}`
    * `{:error, reason}` - the node failed on its last attempt.
  """
  @spec execute_node(String.t(), String.t() | atom()) :: {:ok, term()} | {:error, term()}
  def execute_node(execution_id, node_name) do
    execution =
      WorkflowExecution
      |> Repo.get(execution_id)
      |> Repo.preload(:workflow)

    cond do
      is_nil(execution) ->
        {:error, :execution_not_found}

      execution.workflow.status == "suspended" ->
        {:error, :workflow_suspended}

      execution.workflow.status == "stopped" ->
        {:error, :workflow_stopped}

      execution.status == "suspended" ->
        {:error, :execution_suspended}

      execution.status == "stopped" ->
        {:error, :execution_stopped}

      execution.status in ["completed", "failed"] ->
        {:error, {:execution_already_finished, execution.status}}

      true ->
        node_def = get_in(execution.workflow.nodes, [to_string(node_name)])

        if is_nil(node_def) do
          {:error, {:node_not_found, node_name}}
        else
          execution = mark_running_if_pending(execution)
          do_execute_node_with_retry(execution, to_string(node_name), node_def)
        end
    end
  end

  # ============================================================================
  # Internal Loop
  # ============================================================================

  defp run_loop(execution_id) do
    # Fetch fresh execution
    execution =
      WorkflowExecution
      |> Repo.get!(execution_id)
      |> Repo.preload(:workflow)

    cond do
      execution.workflow.status == "suspended" ->
        {:error, :workflow_suspended}

      execution.workflow.status == "stopped" ->
        {:error, :workflow_stopped}

      execution.status == "suspended" ->
        {:ok, :suspended, execution}

      execution.status == "stopped" ->
        {:ok, :stopped, execution}

      execution.status == "completed" ->
        {:ok, execution}

      execution.status == "failed" ->
        {:error, :failed, execution}

      true ->
        # Ensure execution is marked running
        execution = mark_running_if_pending(execution)

        # Determine runnable nodes
        completed_node_names = Map.keys(execution.node_results || %{})
        runnable = Sig.Flow.find_runnable_nodes(execution.workflow.nodes, completed_node_names)

        total_nodes = map_size(execution.workflow.nodes)
        num_completed = length(completed_node_names)

        cond do
          num_completed == total_nodes ->
            # All nodes completed!
            now = DateTime.utc_now()

            {:ok, completed_exec} =
              execution
              |> WorkflowExecution.status_changeset("completed", %{completed_at: now})
              |> Repo.update()

            {:ok, completed_exec}

          runnable != [] ->
            # Execute runnable nodes
            case execute_batch(execution.id, runnable) do
              :ok ->
                run_loop(execution.id)

              {:suspended, exec} ->
                {:ok, :suspended, exec}

              {:stopped, exec} ->
                {:ok, :stopped, exec}

              {:error, reason, exec} ->
                {:error, reason, exec}
            end

          true ->
            # No runnable nodes, but not all completed -> deadlock or failure
            {:error, :deadlock_or_unreachable_nodes, execution}
        end
    end
  end

  defp mark_running_if_pending(%WorkflowExecution{status: "pending"} = execution) do
    now = DateTime.utc_now()

    {:ok, updated} =
      execution
      |> WorkflowExecution.status_changeset("running", %{started_at: now})
      |> Repo.update()

    updated
  end

  defp mark_running_if_pending(execution), do: execution

  defp execute_batch(execution_id, runnable_nodes) do
    Enum.reduce_while(runnable_nodes, :ok, fn {node_name, node_def}, :ok ->
      # Check if execution or workflow was suspended or stopped externally
      fresh_exec =
        WorkflowExecution
        |> Repo.get!(execution_id)
        |> Repo.preload(:workflow)

      cond do
        fresh_exec.workflow.status in ["suspended", "stopped"] or
            fresh_exec.status in ["suspended", "stopped"] ->
          status_atom = String.to_atom(fresh_exec.status)
          {:halt, {status_atom, fresh_exec}}

        true ->
          case do_execute_node_with_retry(fresh_exec, node_name, node_def) do
            {:ok, _result} ->
              {:cont, :ok}

            {:error, reason} ->
              # Node failed and ran out of retries -> fail execution
              now = DateTime.utc_now()
              err_map = Serializer.wrap_result(reason)

              {:ok, failed_exec} =
                fresh_exec
                |> WorkflowExecution.status_changeset("failed", %{
                  completed_at: now,
                  error: err_map
                })
                |> Repo.update()

              {:halt, {:error, reason, failed_exec}}
          end
      end
    end)
  end

  # ============================================================================
  # Node Execution & Retries & Idempotency
  # ============================================================================

  defp do_execute_node_with_retry(execution, node_name, node_def) do
    # 1. Idempotency check:
    # If this node already completed in this execution, return cached result!
    existing_result = get_in(execution.node_results || %{}, [node_name])

    if existing_result != nil do
      {:ok, existing_result}
    else
      max_retries = Map.get(node_def, "max_retries", 3)
      backoff_ms = Map.get(node_def, "backoff_ms", 500)
      module = Map.get(node_def, "module")

      node_exec =
        get_or_create_node_execution(execution.id, node_name, module, max_retries, node_def)

      # If node execution is already completed (check DB record)
      if node_exec.status == "completed" do
        sync_result_to_execution(execution.id, node_name, node_exec.result)
        {:ok, node_exec.result}
      else
        attempt_node_execution(
          execution,
          node_exec,
          node_name,
          node_def,
          1,
          max_retries,
          backoff_ms
        )
      end
    end
  end

  defp attempt_node_execution(
         execution,
         node_exec,
         node_name,
         node_def,
         attempt,
         max_retries,
         backoff_ms
       ) do
    now = DateTime.utc_now()

    # Update node_execution to running
    {:ok, node_exec} =
      node_exec
      |> NodeExecution.changeset(%{
        status: "running",
        attempts: attempt,
        started_at: node_exec.started_at || now
      })
      |> Repo.update()

    # Build NodeContext
    fresh_execution = Repo.get!(WorkflowExecution, execution.id)

    node_context =
      NodeContext.build(%{
        workflow_id: execution.workflow_id,
        execution_id: execution.id,
        node_name: node_name,
        attempt: attempt,
        workflow_params: execution.workflow.params,
        workflow_context: execution.workflow.context,
        execution_params: fresh_execution.params,
        execution_context: fresh_execution.context,
        node_params: Map.get(node_def, "params", %{}),
        results: fresh_execution.node_results || %{}
      })

    # Call user module
    module = Map.get(node_def, "module")

    case Sig.Node.execute(module, node_context) do
      {:ok, result} ->
        wrapped_result = Serializer.wrap_result(result)
        completed_at = DateTime.utc_now()

        # Update node_execution to completed
        {:ok, _} =
          node_exec
          |> NodeExecution.changeset(%{
            status: "completed",
            result: wrapped_result,
            completed_at: completed_at
          })
          |> Repo.update()

        # Save result into WorkflowExecution.node_results
        sync_result_to_execution(execution.id, node_name, wrapped_result)

        {:ok, wrapped_result}

      {:error, reason} ->
        wrapped_error = Serializer.wrap_result(reason)

        if attempt < max_retries do
          # Mark retrying and sleep backoff
          {:ok, node_exec} =
            node_exec
            |> NodeExecution.changeset(%{
              status: "retrying",
              error: wrapped_error
            })
            |> Repo.update()

          if backoff_ms > 0 do
            # Exponential or linear backoff
            sleep_time = min(backoff_ms * round(:math.pow(2, attempt - 1)), 30_000)
            Process.sleep(sleep_time)
          end

          attempt_node_execution(
            execution,
            node_exec,
            node_name,
            node_def,
            attempt + 1,
            max_retries,
            backoff_ms
          )
        else
          # Retries exhausted
          completed_at = DateTime.utc_now()

          {:ok, _} =
            node_exec
            |> NodeExecution.changeset(%{
              status: "failed",
              error: wrapped_error,
              completed_at: completed_at
            })
            |> Repo.update()

          {:error, reason}
        end
    end
  end

  defp get_or_create_node_execution(execution_id, node_name, module, max_retries, node_def) do
    case Repo.get_by(NodeExecution, workflow_execution_id: execution_id, node_name: node_name) do
      nil ->
        attrs = %{
          workflow_execution_id: execution_id,
          node_name: node_name,
          module: to_string(module),
          max_retries: max_retries,
          params: Map.get(node_def, "params", %{}),
          status: "pending"
        }

        %NodeExecution{}
        |> NodeExecution.changeset(attrs)
        |> Repo.insert!(
          on_conflict: :nothing,
          conflict_target: [:workflow_execution_id, :node_name]
        )

        # Fetch back to get valid record if conflict occurred
        Repo.get_by!(NodeExecution, workflow_execution_id: execution_id, node_name: node_name)

      existing ->
        existing
    end
  end

  defp sync_result_to_execution(execution_id, node_name, wrapped_result) do
    # Atomic update of node_results JSONB map
    Repo.transaction(fn ->
      exec =
        WorkflowExecution
        |> where(id: ^execution_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      current_results = exec.node_results || %{}
      updated_results = Map.put(current_results, node_name, wrapped_result)

      exec
      |> WorkflowExecution.changeset(%{node_results: updated_results})
      |> Repo.update!()
    end)
  end

  defp get_and_validate_execution(execution_id) do
    case Repo.get(WorkflowExecution, execution_id) do
      nil ->
        {:error, :not_found}

      execution ->
        execution = Repo.preload(execution, :workflow)

        cond do
          execution.workflow.status == "suspended" ->
            {:error, :workflow_suspended}

          execution.workflow.status == "stopped" ->
            {:error, :workflow_stopped}

          execution.status == "suspended" ->
            {:error, :execution_suspended}

          execution.status == "stopped" ->
            {:error, :execution_stopped}

          true ->
            {:ok, execution}
        end
    end
  end

  # ============================================================================
  # Control Functions: Suspend / Resume / Stop
  # ============================================================================

  @doc "See `Sig.suspend_execution/1`."
  @spec suspend_execution(String.t()) :: {:ok, WorkflowExecution.t()} | {:error, term()}
  def suspend_execution(execution_id) do
    case Repo.get(WorkflowExecution, execution_id) do
      nil ->
        {:error, :not_found}

      %WorkflowExecution{status: s} when s in ["completed", "failed", "stopped"] ->
        {:error, {:cannot_suspend_in_state, s}}

      execution ->
        execution
        |> WorkflowExecution.status_changeset("suspended")
        |> Repo.update()
    end
  end

  @doc """
  Moves a suspended execution back to `running`, without dispatching any
  nodes.

  `Sig.resume_execution/2` calls this and then starts the execution.
  """
  @spec resume_execution(String.t()) :: {:ok, WorkflowExecution.t()} | {:error, term()}
  def resume_execution(execution_id) do
    execution =
      WorkflowExecution
      |> Repo.get(execution_id)
      |> Repo.preload(:workflow)

    cond do
      is_nil(execution) ->
        {:error, :not_found}

      execution.workflow.status == "suspended" ->
        {:error, :workflow_suspended}

      execution.workflow.status == "stopped" ->
        {:error, :workflow_stopped}

      execution.status != "suspended" ->
        {:error, {:cannot_resume_in_state, execution.status}}

      true ->
        {:ok, updated} =
          execution
          |> WorkflowExecution.status_changeset("running")
          |> Repo.update()

        {:ok, updated}
    end
  end

  @doc "See `Sig.stop_execution/1`."
  @spec stop_execution(String.t()) :: {:ok, WorkflowExecution.t()} | {:error, term()}
  def stop_execution(execution_id) do
    case Repo.get(WorkflowExecution, execution_id) do
      nil ->
        {:error, :not_found}

      %WorkflowExecution{status: s} when s in ["completed", "failed"] ->
        {:error, {:cannot_stop_in_state, s}}

      execution ->
        now = DateTime.utc_now()

        execution
        |> WorkflowExecution.status_changeset("stopped", %{completed_at: now})
        |> Repo.update()
    end
  end

  @doc "See `Sig.suspend_workflow/1`."
  @spec suspend_workflow(String.t()) :: {:ok, Workflow.t()} | {:error, term()}
  def suspend_workflow(workflow_id) do
    case Repo.get(Workflow, workflow_id) do
      nil ->
        {:error, :not_found}

      %Workflow{status: "stopped"} ->
        {:error, :workflow_already_stopped}

      workflow ->
        Repo.transaction(fn ->
          {:ok, updated_wf} =
            workflow
            |> Workflow.status_changeset("suspended")
            |> Repo.update()

          # Suspend running and pending executions
          from(e in WorkflowExecution,
            where: e.workflow_id == ^workflow_id and e.status in ["running", "pending"]
          )
          |> Repo.update_all(set: [status: "suspended"])

          updated_wf
        end)
    end
  end

  @doc "See `Sig.resume_workflow/1`."
  @spec resume_workflow(String.t()) :: {:ok, Workflow.t()} | {:error, term()}
  def resume_workflow(workflow_id) do
    case Repo.get(Workflow, workflow_id) do
      nil ->
        {:error, :not_found}

      %Workflow{status: "stopped"} ->
        {:error, :workflow_already_stopped}

      workflow ->
        workflow
        |> Workflow.status_changeset("active")
        |> Repo.update()
    end
  end

  @doc "See `Sig.stop_workflow/1`."
  @spec stop_workflow(String.t()) :: {:ok, Workflow.t()} | {:error, term()}
  def stop_workflow(workflow_id) do
    case Repo.get(Workflow, workflow_id) do
      nil ->
        {:error, :not_found}

      workflow ->
        now = DateTime.utc_now()

        Repo.transaction(fn ->
          {:ok, updated_wf} =
            workflow
            |> Workflow.status_changeset("stopped")
            |> Repo.update()

          # Stop all active executions
          from(e in WorkflowExecution,
            where:
              e.workflow_id == ^workflow_id and e.status in ["running", "pending", "suspended"]
          )
          |> Repo.update_all(set: [status: "stopped", completed_at: now])

          updated_wf
        end)
    end
  end
end

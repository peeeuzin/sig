defmodule SigTest do
  use Sig.DataCase

  alias Sig.TestNodes.{
    AddNumbers,
    MultiplyBy,
    FormatOutput,
    FlakyNode,
    AlwaysFailingNode,
    CountingNode
  }

  describe "Workflow definition & validation" do
    test "successfully creates a workflow using Sig.Flow DSL" do
      flow =
        Sig.Flow.new("math_pipeline",
          description: "Performs math",
          params: %{"default_factor" => 2},
          context: %{"environment" => "test"}
        )
        |> Sig.Flow.add_node(:add, AddNumbers, params: %{"a" => 5, "b" => 10})
        |> Sig.Flow.add_node(:multiply, MultiplyBy,
          depends_on: [:add],
          params: %{"factor" => 3}
        )

      assert {:ok, workflow} = Sig.create_workflow(flow)
      assert workflow.name == "math_pipeline"
      assert workflow.status == "active"
      assert workflow.params == %{"default_factor" => 2}
      assert workflow.context == %{"environment" => "test"}
      assert Map.has_key?(workflow.nodes, "add")
      assert Map.has_key?(workflow.nodes, "multiply")
    end

    test "rejects workflows with circular dependencies" do
      flow =
        Sig.Flow.new("cyclic")
        |> Sig.Flow.add_node(:a, AddNumbers, depends_on: [:b])
        |> Sig.Flow.add_node(:b, MultiplyBy, depends_on: [:a])

      assert {:error, changeset} = Sig.create_workflow(flow)
      assert %{nodes: [msg]} = errors_on(changeset)
      assert msg =~ "circular dependencies"
    end

    test "rejects workflows with missing dependencies" do
      flow =
        Sig.Flow.new("missing_dep")
        |> Sig.Flow.add_node(:a, AddNumbers, depends_on: [:non_existent])

      assert {:error, changeset} = Sig.create_workflow(flow)
      assert %{nodes: [msg]} = errors_on(changeset)
      assert msg =~ "depends on non-existent node 'non_existent'"
    end
  end

  describe "Workflow Executions & Idempotency" do
    setup do
      flow =
        Sig.Flow.new("test_flow",
          params: %{"base" => 100},
          context: %{"user" => "pedro"}
        )
        |> Sig.Flow.add_node(:add, AddNumbers, params: %{"a" => 10, "b" => 20})

      {:ok, workflow} = Sig.create_workflow(flow)
      %{workflow: workflow}
    end

    test "creates an execution with execution params and context", %{workflow: workflow} do
      assert {:ok, execution} =
               Sig.create_execution(
                 workflow.id,
                 %{"a" => 15},
                 %{"request_id" => "req-1"}
               )

      assert execution.workflow_id == workflow.id
      assert execution.params == %{"a" => 15}
      assert execution.context == %{"request_id" => "req-1"}
      assert execution.status == "pending"
    end

    test "idempotency_key ensures no duplicate executions are created", %{workflow: workflow} do
      key = "idemp-unique-123"

      assert {:ok, exec1} =
               Sig.create_execution(workflow.id, %{"a" => 1}, %{}, idempotency_key: key)

      assert {:ok, exec2} =
               Sig.create_execution(workflow.id, %{"a" => 999}, %{}, idempotency_key: key)

      assert exec1.id == exec2.id
    end
  end

  describe "End-to-End Execution and Results Passing" do
    test "executes nodes, pipes results to downstream nodes, and completes" do
      # add: a=2, b=3 -> sum=5
      # multiply: sum * factor(4) -> total=20
      # format: output: "Total: 20 for pedro"
      flow =
        Sig.Flow.new("calc_pipeline",
          params: %{"prefix" => "Calculated:"},
          context: %{"user" => "pedro"}
        )
        |> Sig.Flow.add_node(:add, AddNumbers)
        |> Sig.Flow.add_node(:multiply, MultiplyBy, depends_on: [:add], params: %{"factor" => 4})
        |> Sig.Flow.add_node(:format, FormatOutput, depends_on: [:multiply])

      {:ok, workflow} = Sig.create_workflow(flow)

      assert {:ok, execution} =
               Sig.run_execution(
                 workflow.id,
                 %{"a" => 2, "b" => 3},
                 %{"execution_tag" => "v1"}
               )

      assert execution.status == "completed"
      assert execution.completed_at != nil

      results = execution.node_results
      assert results["add"]["sum"] == 5
      assert results["multiply"]["total"] == 20
      assert results["format"]["output"] == "Calculated: 20 for pedro"

      # Verify individual node executions
      reloaded = Sig.get_execution!(execution.id)
      assert length(reloaded.node_executions) == 3
      assert Enum.all?(reloaded.node_executions, &(&1.status == "completed"))
    end
  end

  describe "Retries" do
    test "retries failed nodes and succeeds if attempts < max_retries" do
      flow =
        Sig.Flow.new("retry_pipeline")
        |> Sig.Flow.add_node(:flaky, FlakyNode, max_retries: 3, backoff_ms: 10)

      {:ok, workflow} = Sig.create_workflow(flow)

      assert {:ok, execution} = Sig.run_execution(workflow.id)
      assert execution.status == "completed"
      assert execution.node_results["flaky"]["status"] == "recovered_on_attempt_2"

      # Check attempts recorded
      node_exec = Sig.Repo.get_by(Sig.Schemas.NodeExecution, workflow_execution_id: execution.id)
      assert node_exec.attempts == 2
      assert node_exec.status == "completed"
    end

    test "fails the execution when node exhausts max_retries" do
      flow =
        Sig.Flow.new("fail_pipeline")
        |> Sig.Flow.add_node(:failing, AlwaysFailingNode, max_retries: 2, backoff_ms: 10)

      {:ok, workflow} = Sig.create_workflow(flow)

      assert {:error, "permanent failure", execution} = Sig.run_execution(workflow.id)
      assert execution.status == "failed"

      node_exec = Sig.Repo.get_by(Sig.Schemas.NodeExecution, workflow_execution_id: execution.id)
      assert node_exec.attempts == 2
      assert node_exec.status == "failed"
      assert node_exec.error["value"] == "permanent failure"
    end
  end

  describe "Node-level Idempotency" do
    test "already completed nodes are not re-executed when running again" do
      start_supervised!({Agent, fn -> 0 end}, id: :counter_agent)
      CountingNode.start_counter()

      flow =
        Sig.Flow.new("idempotent_nodes")
        |> Sig.Flow.add_node(:step1, CountingNode)
        |> Sig.Flow.add_node(:step2, AddNumbers,
          depends_on: [:step1],
          params: %{"a" => 1, "b" => 2}
        )

      {:ok, workflow} = Sig.create_workflow(flow)
      {:ok, execution} = Sig.run_execution(workflow.id)

      assert execution.status == "completed"
      assert CountingNode.get_count() == 1

      # Running execute_sync again on the execution should not re-run step1
      {:ok, re_run} = Sig.start_execution(execution.id)
      assert re_run.status == "completed"
      assert CountingNode.get_count() == 1
    end
  end

  describe "Execution Control: Suspend, Resume, Stop" do
    test "suspending an execution halts its progress, and resuming finishes it" do
      # step1 completes, then we suspend before step2
      flow =
        Sig.Flow.new("control_flow")
        |> Sig.Flow.add_node(:step1, AddNumbers, params: %{"a" => 10, "b" => 20})
        |> Sig.Flow.add_node(:step2, MultiplyBy, depends_on: [:step1], params: %{"factor" => 2})

      {:ok, workflow} = Sig.create_workflow(flow)
      {:ok, execution} = Sig.create_execution(workflow.id)

      # Execute only step1
      assert {:ok, _} = Sig.Engine.execute_node(execution.id, "step1")

      # Suspend execution
      assert {:ok, suspended} = Sig.suspend_execution(execution.id)
      assert suspended.status == "suspended"

      # Trying to run node or workflow while suspended fails or pauses
      assert {:error, :execution_suspended} = Sig.Engine.execute_node(execution.id, "step2")
      assert {:error, :execution_suspended} = Sig.Engine.execute_sync(execution.id)

      # Resume execution
      assert {:ok, resumed_exec} = Sig.resume_execution(execution.id)
      assert resumed_exec.status == "completed"
      assert resumed_exec.node_results["step2"]["total"] == 60
    end

    test "stopping an execution permanently halts it" do
      flow =
        Sig.Flow.new("stop_flow")
        |> Sig.Flow.add_node(:step1, AddNumbers, params: %{"a" => 1, "b" => 2})

      {:ok, workflow} = Sig.create_workflow(flow)
      {:ok, execution} = Sig.create_execution(workflow.id)

      assert {:ok, stopped} = Sig.stop_execution(execution.id)
      assert stopped.status == "stopped"

      assert {:error, :execution_stopped} = Sig.Engine.execute_sync(execution.id)
    end
  end

  describe "Workflow Control: Suspend, Resume, Stop" do
    test "suspending a workflow prevents new executions and pauses running ones" do
      flow =
        Sig.Flow.new("wf_control")
        |> Sig.Flow.add_node(:step1, AddNumbers, params: %{"a" => 1, "b" => 2})

      {:ok, workflow} = Sig.create_workflow(flow)
      {:ok, execution} = Sig.create_execution(workflow.id)

      # Suspend workflow
      assert {:ok, suspended_wf} = Sig.suspend_workflow(workflow.id)
      assert suspended_wf.status == "suspended"

      # Cannot create execution on suspended workflow
      assert {:error, :workflow_suspended} = Sig.create_execution(workflow.id)

      # Cannot start execution on suspended workflow
      assert {:error, :workflow_suspended} = Sig.start_execution(execution.id)

      # Resume workflow
      assert {:ok, resumed_wf} = Sig.resume_workflow(workflow.id)
      assert resumed_wf.status == "active"

      # Now executions can be resumed/run
      assert {:ok, completed} = Sig.resume_execution(execution.id)
      assert completed.status == "completed"
    end

    test "stopping a workflow terminates workflow and all active executions" do
      flow =
        Sig.Flow.new("wf_stop")
        |> Sig.Flow.add_node(:step1, AddNumbers, params: %{"a" => 1, "b" => 2})

      {:ok, workflow} = Sig.create_workflow(flow)
      {:ok, execution} = Sig.create_execution(workflow.id)

      assert {:ok, stopped_wf} = Sig.stop_workflow(workflow.id)
      assert stopped_wf.status == "stopped"

      reloaded_exec = Sig.get_execution!(execution.id)
      assert reloaded_exec.status == "stopped"

      assert {:error, :workflow_stopped} = Sig.create_execution(workflow.id)
    end
  end

  describe "BullMQ Asynchronous Execution" do
    test "processes jobs asynchronously through BullMQ queue and worker" do
      # Start Redis connection and BullMQ Worker for the test
      start_supervised!(
        {BullMQ.RedisConnection, name: :sig_redis, url: Application.fetch_env!(:sig, :redis_url)}
      )

      start_supervised!(
        {BullMQ.Worker,
         name: :sig_test_worker,
         queue: "sig_workflows",
         connection: :sig_redis,
         processor: &Sig.BullMQ.Worker.process_job/1,
         concurrency: 2}
      )

      # Allow Sandbox connection to be shared across test and worker processes
      Ecto.Adapters.SQL.Sandbox.mode(Sig.Test.Repo, {:shared, self()})

      flow =
        Sig.Flow.new("async_pipeline")
        |> Sig.Flow.add_node(:step1, AddNumbers, params: %{"a" => 10, "b" => 5})
        |> Sig.Flow.add_node(:step2, MultiplyBy, depends_on: [:step1], params: %{"factor" => 2})

      {:ok, workflow} = Sig.create_workflow(flow)
      {:ok, execution} = Sig.create_execution(workflow.id)

      # Start execution asynchronously with BullMQ
      assert {:ok, _} = Sig.start_execution(execution.id, async: true)

      # Poll briefly until BullMQ worker completes the workflow
      completed_exec =
        wait_until(
          fn ->
            exec = Sig.get_execution!(execution.id)
            if exec.status == "completed", do: exec, else: nil
          end,
          5000
        )

      assert completed_exec != nil
      assert completed_exec.status == "completed"
      assert completed_exec.node_results["step1"]["sum"] == 15
      assert completed_exec.node_results["step2"]["total"] == 30
    end
  end

  # Helper to wait for async conditions in tests
  defp wait_until(fun, timeout_ms, interval_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline, interval_ms)
  end

  defp do_wait_until(fun, deadline, interval_ms) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(interval_ms)
          do_wait_until(fun, deadline, interval_ms)
        else
          nil
        end

      result ->
        result
    end
  end
end

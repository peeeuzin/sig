defmodule SigAdvancedTest do
  use Sig.DataCase

  defmodule StepA do
    use Sig.Node
    def run(_context), do: %{"val" => 10}
  end

  defmodule StepB do
    use Sig.Node

    def run(context) do
      val = get_in(context.results, ["step_a", "val"]) || 0
      {:ok, %{"val_b" => val + 5}}
    end
  end

  defmodule StepC do
    use Sig.Node

    def run(context) do
      val = get_in(context.results, ["step_a", "val"]) || 0
      {:ok, %{"val_c" => val * 2}}
    end
  end

  defmodule StepD do
    use Sig.Node

    def run(context) do
      b = get_in(context.results, ["step_b", "val_b"]) || 0
      c = get_in(context.results, ["step_c", "val_c"]) || 0
      {:ok, %{"final" => b + c}}
    end
  end

  defmodule RaisingNode do
    use Sig.Node

    def run(_context) do
      raise ArgumentError, "simulated exception inside node"
    end
  end

  describe "Complex DAG workflows (Fan-out / Fan-in)" do
    test "executes parallel branches step_b and step_c after step_a, joining at step_d" do
      flow =
        Sig.Flow.new("fan_out_fan_in")
        |> Sig.Flow.add_node(:step_a, StepA)
        |> Sig.Flow.add_node(:step_b, StepB, depends_on: [:step_a])
        |> Sig.Flow.add_node(:step_c, StepC, depends_on: [:step_a])
        |> Sig.Flow.add_node(:step_d, StepD, depends_on: [:step_b, :step_c])

      {:ok, workflow} = Sig.create_workflow(flow)
      {:ok, execution} = Sig.run_execution(workflow.id)

      assert execution.status == "completed"
      # step_a: 10
      # step_b: 10 + 5 = 15
      # step_c: 10 * 2 = 20
      # step_d: 15 + 20 = 35
      assert execution.node_results["step_a"]["val"] == 10
      assert execution.node_results["step_b"]["val_b"] == 15
      assert execution.node_results["step_c"]["val_c"] == 20
      assert execution.node_results["step_d"]["final"] == 35
    end
  end

  describe "Exception Handling in Nodes" do
    test "catches raised exceptions, tracks attempts, and marks failure cleanly" do
      flow =
        Sig.Flow.new("exception_flow")
        |> Sig.Flow.add_node(:raising, RaisingNode, max_retries: 2, backoff_ms: 10)

      {:ok, workflow} = Sig.create_workflow(flow)
      {:error, reason, execution} = Sig.run_execution(workflow.id)

      assert execution.status == "failed"
      assert reason.exception =~ "simulated exception"

      node_exec = Sig.Repo.get_by(Sig.Schemas.NodeExecution, workflow_execution_id: execution.id)
      assert node_exec.attempts == 2
      assert node_exec.status == "failed"
      assert node_exec.error["exception"] =~ "simulated exception"
    end
  end

  describe "Listing and Query Helpers" do
    test "list_workflows and list_executions" do
      flow = Sig.Flow.new("query_wf") |> Sig.Flow.add_node(:a, StepA)
      {:ok, wf1} = Sig.create_workflow(flow)
      {:ok, wf2} = Sig.create_workflow(flow)

      all_wfs = Sig.list_workflows()
      assert Enum.any?(all_wfs, &(&1.id == wf1.id))
      assert Enum.any?(all_wfs, &(&1.id == wf2.id))

      {:ok, exec1} = Sig.create_execution(wf1.id)
      {:ok, exec2} = Sig.create_execution(wf1.id)

      wf1_execs = Sig.list_executions(wf1.id)
      assert length(wf1_execs) == 2
      assert Enum.any?(wf1_execs, &(&1.id == exec1.id))
      assert Enum.any?(wf1_execs, &(&1.id == exec2.id))

      {:ok, results} = Sig.get_node_results(exec1.id)
      assert results == %{}
    end
  end
end

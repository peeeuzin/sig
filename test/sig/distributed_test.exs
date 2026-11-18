defmodule Sig.DistributedTest do
  # Covers asynchronous (default) executions, master / worker deployments and
  # several BullMQ workers consuming the same queue. Workers run in their own
  # processes, so the SQL sandbox is shared (the test is not async).
  use Sig.DataCase

  alias Sig.Schemas.NodeExecution
  alias Sig.Test.Repo

  @log __MODULE__.Log

  defmodule Recorder do
    @moduledoc false
    # Sleeps for params["sleep_ms"] and records when it ran.
    use Sig.Node

    @impl true
    def run(context) do
      started = System.monotonic_time(:millisecond)
      Process.sleep(context.params["sleep_ms"] || 0)
      finished = System.monotonic_time(:millisecond)

      entry = %{
        execution_id: context.execution_id,
        node: context.node_name,
        started: started,
        finished: finished
      }

      Agent.update(Sig.DistributedTest.Log, &[entry | &1])
      {:ok, %{"node" => context.node_name}}
    end
  end

  defmodule SuspendSelf do
    @moduledoc false
    use Sig.Node

    @impl true
    def run(context) do
      {:ok, _} = Sig.suspend_execution(context.execution_id)
      {:ok, %{"suspended" => true}}
    end
  end

  setup do
    queue = "sig_test_#{System.unique_integer([:positive])}"
    previous_queue = Application.fetch_env(:sig, :bullmq_queue_name)
    previous_lease = Application.fetch_env(:sig, :node_lease_ms)
    Application.put_env(:sig, :bullmq_queue_name, queue)

    on_exit(fn ->
      restore_env(:bullmq_queue_name, previous_queue)
      restore_env(:node_lease_ms, previous_lease)
    end)

    start_supervised!(%{
      id: @log,
      start: {Agent, :start_link, [fn -> [] end, [name: @log]]}
    })

    %{queue: queue}
  end

  # ===========================================================================
  # Asynchronous by default
  # ===========================================================================

  describe "asynchronous by default" do
    setup [:start_redis]

    test "run_execution enqueues the execution and a worker completes it", %{queue: queue} do
      start_worker(queue, :w1)
      workflow = diamond_workflow()

      assert {:ok, execution} = Sig.run_execution(workflow, %{"sleep_ms" => 0})
      assert execution.status == "running"

      completed = await_status(execution.id, "completed")
      assert Map.keys(completed.node_results) |> Enum.sort() == ~w(a b c d)
    end

    test "sync: true runs inline without any worker" do
      workflow = diamond_workflow()

      assert {:ok, execution} = Sig.run_execution(workflow, %{}, %{}, sync: true)
      assert execution.status == "completed"
      assert length(runs()) == 4
    end

    test "the removed :async option raises" do
      workflow = diamond_workflow()
      {:ok, execution} = Sig.create_execution(workflow)

      assert_raise ArgumentError, ~r/sync: true/, fn ->
        Sig.start_execution(execution, async: true)
      end

      assert_raise ArgumentError, fn -> Sig.run_execution(workflow, %{}, %{}, async: false) end
      assert_raise ArgumentError, fn -> Sig.resume_execution(execution, async: true) end
    end

    test "asynchronous starts validate the execution and enqueue nothing on error",
         %{queue: queue} do
      workflow = diamond_workflow()

      {:ok, suspended} = Sig.create_execution(workflow)
      {:ok, _} = Sig.suspend_execution(suspended)
      assert {:error, :execution_suspended} = Sig.start_execution(suspended)

      {:ok, stopped} = Sig.create_execution(workflow)
      {:ok, _} = Sig.stop_execution(stopped)
      assert {:error, :execution_stopped} = Sig.start_execution(stopped)

      {:ok, finished} = Sig.run_execution(workflow, %{}, %{}, sync: true)

      assert {:error, {:execution_already_finished, "completed"}} =
               Sig.start_execution(finished)

      assert {:error, :not_found} = Sig.start_execution(Ecto.UUID.generate())

      {:ok, pending} = Sig.create_execution(workflow)
      {:ok, _} = Sig.suspend_workflow(workflow)
      assert {:error, :workflow_suspended} = Sig.start_execution(pending)

      assert queued_jobs(queue) == 0
      assert Sig.get_execution!(finished.id).status == "completed"
    end

    test "starting a running execution again does not duplicate work", %{queue: queue} do
      workflow = diamond_workflow()
      {:ok, execution} = Sig.create_execution(workflow)

      assert {:ok, %{status: "running"}} = Sig.start_execution(execution)
      assert {:ok, %{status: "running"}} = Sig.start_execution(execution)
      # Same job ID for the same node: still a single job for the root node.
      assert queued_jobs(queue) == 1

      start_worker(queue, :w1)
      await_status(execution.id, "completed")
      assert runs_per_node(execution.id) == %{"a" => 1, "b" => 1, "c" => 1, "d" => 1}
    end
  end

  # ===========================================================================
  # Sig.BullMQ.Supervisor
  # ===========================================================================

  describe "Sig.BullMQ.Supervisor" do
    test "worker: false starts only the Redis connection" do
      pid = start_supervised!({Sig.BullMQ.Supervisor, worker: false})

      assert [{BullMQ.RedisConnection, _, _, _}] = Supervisor.which_children(pid)
      assert Process.whereis(:sig_bullmq_worker) == nil
    end

    test "worker: false can be set in the application environment" do
      Application.put_env(:sig, :bullmq_worker, false)
      on_exit(fn -> Application.delete_env(:sig, :bullmq_worker) end)

      pid = start_supervised!(Sig.BullMQ.Supervisor)
      assert [{BullMQ.RedisConnection, _, _, _}] = Supervisor.which_children(pid)
    end

    test "starts a worker by default, which processes executions" do
      pid = start_supervised!({Sig.BullMQ.Supervisor, worker_opts: [lock_duration: 10_000]})

      assert Supervisor.which_children(pid) |> length() == 2
      assert is_pid(Process.whereis(:sig_bullmq_worker))

      {:ok, execution} = Sig.run_execution(diamond_workflow())
      await_status(execution.id, "completed")
    end

    test "a master enqueues and only a worker runs the nodes", %{queue: queue} do
      start_supervised!({Sig.BullMQ.Supervisor, worker: false})

      # The master references node modules by name: it doesn't need them.
      {:ok, remote} =
        Sig.create_workflow("remote", %{"only" => %{module: "Remote.Only.Node"}})

      assert {:ok, %{status: "running"} = remote_execution} = Sig.run_execution(remote)

      {:ok, workflow} =
        Sig.create_workflow("by_name", %{
          "a" => %{module: "Sig.DistributedTest.Recorder"},
          "b" => %{module: "Sig.DistributedTest.Recorder", depends_on: ["a"]}
        })

      {:ok, execution} = Sig.run_execution(workflow)

      # Nothing runs on the master.
      Process.sleep(300)
      assert runs() == []
      assert Sig.get_execution!(execution.id).status == "running"
      assert queued_jobs(queue) == 2

      # This one could never run on a worker without the module.
      {:ok, _} = Sig.stop_execution(remote_execution)

      # A worker joins and picks the jobs up.
      start_worker(queue, :w1)
      completed = await_status(execution.id, "completed")
      assert completed.node_results["b"] == %{"node" => "b"}
    end
  end

  # ===========================================================================
  # Several workers
  # ===========================================================================

  describe "several workers" do
    setup [:start_redis]

    test "parallel branches run on different workers, each node exactly once",
         %{queue: queue} do
      for id <- [:w1, :w2, :w3], do: start_worker(queue, id, concurrency: 1)

      {:ok, execution} = Sig.run_execution(diamond_workflow(), %{"sleep_ms" => 300})
      completed = await_status(execution.id, "completed")

      assert runs_per_node(execution.id) == %{"a" => 1, "b" => 1, "c" => 1, "d" => 1}

      runs = Map.new(runs(), &{&1.node, &1})
      # b and c overlapped in time, so they ran on two workers at once.
      assert runs["b"].started < runs["c"].finished
      assert runs["c"].started < runs["b"].finished
      # d only started after both of its dependencies finished.
      assert runs["d"].started >= max(runs["b"].finished, runs["c"].finished)

      assert Enum.all?(completed.node_executions, &(&1.status == "completed"))
    end

    test "many concurrent executions all complete without duplicate runs", %{queue: queue} do
      for id <- 1..4, do: start_worker(queue, :"w#{id}", concurrency: 3)

      workflow = diamond_workflow()

      executions =
        for _ <- 1..15 do
          {:ok, execution} = Sig.run_execution(workflow, %{"sleep_ms" => 20})
          execution
        end

      for execution <- executions do
        await_status(execution.id, "completed", 15_000)
        assert runs_per_node(execution.id) == %{"a" => 1, "b" => 1, "c" => 1, "d" => 1}
      end
    end

    test "resuming an execution runs the nodes whose jobs were skipped while suspended",
         %{queue: queue} do
      test_pid = self()
      workflow = diamond_workflow()
      {:ok, execution} = Sig.run_execution(workflow)
      {:ok, _} = Sig.suspend_execution(execution)

      # The worker acknowledges the root job without running it.
      start_worker(queue, :w1, on_completed: fn job, _ -> send(test_pid, {:done, job.id}) end)
      root_job = "#{execution.id}:a"
      assert_receive {:done, ^root_job}, 5_000
      assert runs() == []

      # Resuming enqueues the same job ID again, and it must run this time.
      assert {:ok, %{status: "running"}} = Sig.resume_execution(execution)
      await_status(execution.id, "completed")
      assert runs_per_node(execution.id) == %{"a" => 1, "b" => 1, "c" => 1, "d" => 1}
    end

    test "an execution suspended by one of its nodes resumes on other workers",
         %{queue: queue} do
      for id <- [:w1, :w2], do: start_worker(queue, id)

      {:ok, workflow} =
        Sig.Flow.new("suspend_midway")
        |> Sig.Flow.add_node(:a, Recorder)
        |> Sig.Flow.add_node(:pause, SuspendSelf, depends_on: [:a])
        |> Sig.Flow.add_node(:b, Recorder, depends_on: [:pause])
        |> Sig.create_workflow()

      {:ok, execution} = Sig.run_execution(workflow)
      await_status(execution.id, "suspended")
      Process.sleep(200)
      assert runs_per_node(execution.id) == %{"a" => 1}

      {:ok, _} = Sig.resume_execution(execution)
      await_status(execution.id, "completed")
      assert runs_per_node(execution.id) == %{"a" => 1, "b" => 1}
    end

    test "a worker delays a job whose node is running elsewhere" do
      Application.put_env(:sig, :node_lease_ms, 5_000)

      {:ok, workflow} =
        Sig.create_workflow("held", %{"slow" => %{module: Recorder, params: %{"sleep_ms" => 400}}})

      {:ok, execution} = Sig.create_execution(workflow)
      holder = Task.async(fn -> Sig.Engine.execute_node(execution.id, "slow") end)
      await_node_status(execution.id, "slow", "running")

      job = %BullMQ.Job{
        id: "#{execution.id}:slow",
        name: "execute_node",
        queue_name: "sig_workflows",
        data: %{"execution_id" => execution.id, "node_name" => "slow"}
      }

      assert {:delay, 5_000} = Sig.BullMQ.Worker.process_job(job)

      assert {:ok, _} = Task.await(holder)
      assert runs_per_node(execution.id) == %{"slow" => 1}

      # Once the node is done, the delayed job just finishes the execution.
      assert {:ok, %{"node" => "slow"}} = Sig.BullMQ.Worker.process_job(job)
      assert Sig.get_execution!(execution.id).status == "completed"
      assert runs_per_node(execution.id) == %{"slow" => 1}
    end
  end

  # ===========================================================================
  # Node claims and leases
  # ===========================================================================

  describe "node claims" do
    setup do
      {:ok, workflow} =
        Sig.create_workflow("claims", %{
          "slow" => %{module: Recorder, params: %{"sleep_ms" => 500}}
        })

      {:ok, execution} = Sig.create_execution(workflow)
      %{execution: execution}
    end

    test "only one of two concurrent runs executes the node", %{execution: execution} do
      first = Task.async(fn -> Sig.Engine.execute_node(execution.id, "slow") end)
      await_node_status(execution.id, "slow", "running")

      assert {:error, :node_already_running} = Sig.Engine.execute_node(execution.id, "slow")
      assert {:ok, %{"node" => "slow"}} = Task.await(first)

      # Later calls reuse the stored result.
      assert {:ok, %{"node" => "slow"}} = Sig.Engine.execute_node(execution.id, "slow")
      assert runs_per_node(execution.id) == %{"slow" => 1}
    end

    test "the heartbeat keeps the lease while a node runs longer than it",
         %{execution: execution} do
      Application.put_env(:sig, :node_lease_ms, 150)

      first = Task.async(fn -> Sig.Engine.execute_node(execution.id, "slow") end)
      await_node_status(execution.id, "slow", "running")
      # Well past the lease: only the heartbeat keeps the claim alive.
      Process.sleep(350)

      assert {:error, :node_already_running} = Sig.Engine.execute_node(execution.id, "slow")
      assert {:ok, _} = Task.await(first)
      assert runs_per_node(execution.id) == %{"slow" => 1}
    end

    test "a node whose owner died is taken over once its lease expires",
         %{execution: execution} do
      Application.put_env(:sig, :node_lease_ms, 1_000)
      node_exec = insert_running_node(execution.id, "slow")

      # Still within the lease: the owner may be alive.
      assert {:error, :node_already_running} = Sig.Engine.execute_node(execution.id, "slow")

      expire_lease(node_exec, 2_000)
      assert {:ok, %{"node" => "slow"}} = Sig.Engine.execute_node(execution.id, "slow")
      assert Repo.get!(NodeExecution, node_exec.id).status == "completed"
      assert runs_per_node(execution.id) == %{"slow" => 1}
    end

    test "a node killed mid-run is taken over after its lease", %{execution: execution} do
      Application.put_env(:sig, :node_lease_ms, 200)

      {pid, ref} = spawn_monitor(fn -> Sig.Engine.execute_node(execution.id, "slow") end)
      await_node_status(execution.id, "slow", "running")
      # Let it reach the node's sleep before killing it.
      Process.sleep(100)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert {:error, :node_already_running} = Sig.Engine.execute_node(execution.id, "slow")

      Process.sleep(300)
      assert {:ok, %{"node" => "slow"}} = Sig.Engine.execute_node(execution.id, "slow")
      assert Sig.get_execution!(execution.id).node_results["slow"] == %{"node" => "slow"}
    end

    test "a synchronous run leaves the execution untouched when a node is held elsewhere",
         %{execution: execution} do
      Application.put_env(:sig, :node_lease_ms, 5_000)
      insert_running_node(execution.id, "slow")

      assert {:error, :node_already_running, exec} = Sig.Engine.execute_sync(execution.id)
      assert exec.status == "running"
      assert Sig.get_execution!(execution.id).status == "running"
      assert runs() == []
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp start_redis(_context) do
    start_supervised!(
      {BullMQ.RedisConnection, name: :sig_redis, url: Application.fetch_env!(:sig, :redis_url)}
    )

    :ok
  end

  defp start_worker(queue, id, opts \\ []) do
    worker_opts =
      [
        name: :"sig_test_worker_#{id}",
        queue: queue,
        connection: :sig_redis,
        concurrency: 2
      ]
      |> Keyword.merge(Sig.BullMQ.Worker.worker_opts())
      |> Keyword.merge(opts)

    start_supervised!({BullMQ.Worker, worker_opts}, id: {:worker, id})
  end

  # a -> (b, c) -> d
  defp diamond_workflow do
    {:ok, workflow} =
      Sig.Flow.new("diamond_#{System.unique_integer([:positive])}")
      |> Sig.Flow.add_node(:a, Recorder)
      |> Sig.Flow.add_node(:b, Recorder, depends_on: [:a])
      |> Sig.Flow.add_node(:c, Recorder, depends_on: [:a])
      |> Sig.Flow.add_node(:d, Recorder, depends_on: [:b, :c])
      |> Sig.create_workflow()

    workflow
  end

  defp runs, do: Agent.get(@log, & &1)

  defp runs_per_node(execution_id) do
    runs()
    |> Enum.filter(&(&1.execution_id == execution_id))
    |> Enum.frequencies_by(& &1.node)
  end

  defp queued_jobs(queue) do
    {:ok, counts} = BullMQ.Queue.get_counts(queue, connection: :sig_redis)
    counts.waiting + counts.active + counts.delayed + counts.prioritized
  end

  defp insert_running_node(execution_id, node_name) do
    Repo.insert!(%NodeExecution{
      workflow_execution_id: execution_id,
      node_name: node_name,
      module: to_string(Recorder),
      status: "running",
      attempts: 1
    })
  end

  defp expire_lease(node_exec, ms_ago) do
    past = DateTime.add(DateTime.utc_now(), -ms_ago, :millisecond)

    from(n in NodeExecution, where: n.id == ^node_exec.id)
    |> Repo.update_all(set: [updated_at: past])
  end

  defp await_status(execution_id, status, timeout \\ 5_000) do
    wait_until(timeout, fn ->
      execution = Sig.get_execution!(execution_id)
      if execution.status == status, do: execution
    end) ||
      flunk("execution did not reach #{status}, it is #{Sig.get_execution!(execution_id).status}")
  end

  defp await_node_status(execution_id, node_name, status) do
    wait_until(5_000, fn ->
      Repo.get_by(NodeExecution,
        workflow_execution_id: execution_id,
        node_name: node_name,
        status: status
      )
    end) || flunk("node #{node_name} did not reach #{status}")
  end

  defp wait_until(timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    case fun.() do
      result when result in [nil, false] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          do_wait_until(fun, deadline)
        end

      result ->
        result
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:sig, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:sig, key)
end

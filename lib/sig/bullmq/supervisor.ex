defmodule Sig.BullMQ.Supervisor do
  @moduledoc """
  Starts the Redis connection and, optionally, the BullMQ worker that
  processes executions.

  Add it to your application's supervision tree, after the repo configured
  for Sig (see `Sig.Repo`):

      children = [
        MyApp.Repo,
        Sig.BullMQ.Supervisor
      ]

  ## Master / worker deployments

  Executions are asynchronous by default: `Sig.start_execution/2` only
  enqueues jobs, and whichever node runs a worker executes them. That allows
  splitting your deployment in two roles:

    * **Workers** run the supervisor with its default options. They must have
      every node module compiled in, since that's where nodes run.

          children = [MyApp.Repo, Sig.BullMQ.Supervisor]

    * **Masters** create workflows and start, suspend, resume or stop
      executions, but never run nodes. Start the supervisor with
      `worker: false`, so it only opens the Redis connection used to enqueue
      jobs. Masters don't need the node modules: reference them by name
      (`"MyApp.Nodes.Charge"`) when building workflows.

          children = [MyApp.Repo, {Sig.BullMQ.Supervisor, worker: false}]

  Any number of workers can consume the same queue. Each job runs one node,
  so independent branches of a workflow run in parallel across workers.
  See "Concurrency and leases" in `Sig.Engine` for how a node is kept from
  running twice.

  > #### Masters must not run a worker {: .warning}
  >
  > A worker that lacks a node's module fails that node, and with it the
  > whole execution. Keep `worker: false` on every node that doesn't have
  > all node modules, and don't call `Sig.start_execution/2` (or
  > `run_execution/4`, `resume_execution/2`) with `sync: true` there.

  ## Options

  Each option falls back to the `:sig` application environment, then to a
  default:

    * `:worker` - whether to start the worker. Config key `:bullmq_worker`,
      default `true`.
    * `:redis_url` - Redis URL. Config key `:redis_url`, default
      `"redis://localhost:6379"`.
    * `:queue_name` - BullMQ queue name. Config key `:bullmq_queue_name`,
      default `"sig_workflows"`. Masters and workers must use the same one.
    * `:concurrency` - number of jobs processed concurrently by this worker.
      Config key `:bullmq_concurrency`, default `5`.
    * `:worker_opts` - extra options for `BullMQ.Worker`, such as
      `:lock_duration` or `:stalled_interval`. Config key
      `:bullmq_worker_opts`, default `[]`.
    * `:name` - the supervisor name. Defaults to `Sig.BullMQ.Supervisor`.

  The Redis connection is registered as `:sig_redis`, or as the config key
  `:bullmq_connection` when set.

      {Sig.BullMQ.Supervisor, redis_url: "redis://redis:6379", concurrency: 10}
  """
  use Supervisor

  @doc """
  Starts the supervisor. See the module docs for the options.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    {name, init_arg} = Keyword.pop(init_arg, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, init_arg, name: name)
  end

  @impl true
  def init(opts) do
    redis_url = option(opts, :redis_url, :redis_url, "redis://localhost:6379")
    conn_name = Sig.BullMQ.Queue.connection()

    connection = {BullMQ.RedisConnection, name: conn_name, url: redis_url}

    children =
      if option(opts, :worker, :bullmq_worker, true) do
        [connection, worker_spec(opts, conn_name)]
      else
        [connection]
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp worker_spec(opts, conn_name) do
    queue_name = option(opts, :queue_name, :bullmq_queue_name, "sig_workflows")
    concurrency = option(opts, :concurrency, :bullmq_concurrency, 5)
    extra = option(opts, :worker_opts, :bullmq_worker_opts, [])

    worker_opts =
      [
        name: :sig_bullmq_worker,
        queue: queue_name,
        connection: conn_name,
        concurrency: concurrency
      ]
      |> Keyword.merge(Sig.BullMQ.Worker.worker_opts())
      |> Keyword.merge(extra)

    {BullMQ.Worker, worker_opts}
  end

  defp option(opts, key, config_key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Application.get_env(:sig, config_key, default)
    end
  end
end

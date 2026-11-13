defmodule Sig.BullMQ.Supervisor do
  @moduledoc """
  Starts the Redis connection and the BullMQ worker that process asynchronous
  executions.

  Add it to your application's supervision tree, after the repo configured
  for Sig (see `Sig.Repo`), to run executions started with `async: true`:

      children = [
        MyApp.Repo,
        Sig.BullMQ.Supervisor
      ]

  Run it on every node that should process workflow jobs. Nodes that only
  enqueue jobs still need the Redis connection, so start the supervisor
  there too (or start a `BullMQ.RedisConnection` named `:sig_redis`).

  ## Options

  Each option falls back to the `:sig` application environment, then to a
  default:

    * `:redis_url` - Redis URL. Config key `:redis_url`, default
      `"redis://localhost:6379"`.
    * `:queue_name` - BullMQ queue name. Config key `:bullmq_queue_name`,
      default `"sig_workflows"`.
    * `:concurrency` - number of jobs processed concurrently. Config key
      `:bullmq_concurrency`, default `5`.

      {Sig.BullMQ.Supervisor, redis_url: "redis://redis:6379", concurrency: 10}
  """
  use Supervisor

  @doc """
  Starts the supervisor. See the module docs for the options.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    redis_url =
      opts[:redis_url] ||
        Application.get_env(:sig, :redis_url, "redis://localhost:6379")

    queue_name =
      opts[:queue_name] ||
        Application.get_env(:sig, :bullmq_queue_name, "sig_workflows")

    concurrency =
      opts[:concurrency] ||
        Application.get_env(:sig, :bullmq_concurrency, 5)

    conn_name = :sig_redis
    worker_name = :sig_bullmq_worker

    children = [
      {BullMQ.RedisConnection, name: conn_name, url: redis_url},
      {BullMQ.Worker,
       name: worker_name,
       queue: queue_name,
       connection: conn_name,
       processor: &Sig.BullMQ.Worker.process_job/1,
       concurrency: concurrency}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

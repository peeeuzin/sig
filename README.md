# Sig

`Sig` is a modern, resilient **Workflow Engine** library for Elixir, supporting Directed Acyclic Graph (DAG) flows, persistence with **Ecto** (PostgreSQL), and distributed queue execution with **BullMQ** (Redis).


## 🚀 Features

1. **Workflow & DAG Definition**:
   - Build flows with dependencies between nodes (`depends_on`).
   - Automatic detection of cycles and missing dependencies (Kahn's Algorithm).
   - Workflow-level **context** and **params** objects.
2. **Executions with Their Own Context**:
   - Each execution has its own **context** and **params** objects, which are merged hierarchically with those of the workflow and the node.
3. **Custom Node Modules (`run/1` or `run/2`)**:
   - User-defined nodes implementing `run/1` (receiving a `%Sig.NodeContext{}`) or `run/2` (receiving `params, context`).
   - Node outputs (`node_results`) are persisted and automatically shared with downstream nodes via `context.results`.
4. **Full Lifecycle Control**:
   - Suspend (`suspend_execution`, `suspend_workflow`).
   - Resume (`resume_execution`, `resume_workflow`).
   - Stop / Cancel (`stop_execution`, `stop_workflow`).
5. **Retries & Resilience**:
   - Configurable maximum number of attempts (`max_retries`) per node.
   - Linear/exponential backoff between attempts.
   - Attempt history and error logs stored in the database.
6. **Idempotency**:
   - **Execution level**: an `idempotency_key` prevents accidental duplicate executions.
   - **Node level**: already completed nodes are not re-run when the flow is resumed.
7. **Execution Modes**:
   - **Synchronous / Inline**: ideal for scripts, tests, and direct inline processing.
   - **Asynchronous & Distributed**: natively integrated with **BullMQ** and Redis for distribution across workers.

## 📥 Installation in a Phoenix application

Sig works like Oban: its tables are created by a migration in your own app,
and it reads and writes them through your app's Ecto repo.

### 1. Add the dependency

```elixir
# mix.exs
defp deps do
  [
    # ...
    {:sig, "~> 0.1.0"}
  ]
end
```

```bash
mix deps.get
```

### 2. Create the migration

```bash
mix ecto.gen.migration add_sig_tables
```

```elixir
# priv/repo/migrations/20261113000000_add_sig_tables.exs
defmodule MyApp.Repo.Migrations.AddSigTables do
  use Ecto.Migration

  def up, do: Sig.Migration.up(version: 1)

  # version: 1 drops all of Sig's tables
  def down, do: Sig.Migration.down(version: 1)
end
```

```bash
mix ecto.migrate
```

This creates the `workflows`, `workflow_executions` and `node_executions`
tables. Since it is a regular migration of `MyApp.Repo`, Phoenix's `test`
alias and your release's `MyApp.Release.migrate/0` pick it up with no extra
setup.

When a future Sig release adds schema changes, add a new migration with
`Sig.Migration.up(version: N)` / `Sig.Migration.down(version: N)`. Pass
`prefix: "sig"` to install the tables in another PostgreSQL schema (see
`Sig.Migration`).

### 3. Configure Sig

Like Oban, Sig does not start a repo of its own: it runs every query through
your application's repo. Tell it which one to use:

```elixir
# config/config.exs
config :sig, repo: MyApp.Repo
```

If you installed the tables in another schema with `Sig.Migration.up(prefix: "sig")`,
set the same prefix here:

```elixir
config :sig, repo: MyApp.Repo, prefix: "sig"
```

That's all the database setup there is. Sig shares `MyApp.Repo`'s connection
pool, its writes take part in your transactions (`MyApp.Repo.transaction/1`),
and in tests it uses the same SQL sandbox as the rest of your app, so your
existing `DataCase` works as is.

### 4. Start the BullMQ worker (optional)

Only needed to run executions with `async: true`. Configure Redis:

```elixir
# config/dev.exs
config :sig, redis_url: "redis://localhost:6379"

# config/runtime.exs
if config_env() == :prod do
  config :sig, redis_url: System.fetch_env!("REDIS_URL")
end
```

and add the supervisor to `lib/my_app/application.ex`, **after** your repo:

```elixir
children = [
  MyAppWeb.Telemetry,
  MyApp.Repo,
  # ...
  Sig.BullMQ.Supervisor,
  MyAppWeb.Endpoint
]
```

It accepts `:redis_url`, `:queue_name` and `:concurrency` options, e.g.
`{Sig.BullMQ.Supervisor, concurrency: 10}`.

> In tests, BullMQ jobs run in the worker's processes, which do not own a
> sandbox connection. Prefer synchronous executions (the default) in tests, or
> put the sandbox in shared mode for tests that use `async: true`.

### 5. Trigger a workflow from your app

Define your nodes under `lib/my_app/` and create the workflow once (e.g. in
`priv/repo/seeds.exs`, or lazily on first use). Then start executions from a
controller, LiveView or context:

```elixir
defmodule MyAppWeb.OrderController do
  use MyAppWeb, :controller

  def create(conn, %{"order_id" => order_id}) do
    workflow_id = Application.fetch_env!(:my_app, :order_workflow_id)

    {:ok, execution} =
      Sig.run_execution(workflow_id, %{"order_id" => order_id}, %{},
        idempotency_key: "order-#{order_id}",
        async: true
      )

    json(conn, %{execution_id: execution.id, status: execution.status})
  end
end
```

## 📦 Usage

### 1. Defining Node Modules

Each node is an Elixir module with a `run/1` or `run/2` function:

```elixir
defmodule MyNodes.FetchUser do
  use Sig.Node

  @impl true
  def run(context) do
    user_id = context.params["user_id"]
    # Return the result to be used by downstream nodes
    {:ok, %{"user_id" => user_id, "name" => "Pedro", "balance" => 150}}
  end
end

defmodule MyNodes.DebitAccount do
  use Sig.Node

  @impl true
  def run(context) do
    # Access the result of the previous 'fetch_user' node
    user = context.results["fetch_user"]
    amount = context.params["amount"] || 50
    new_balance = user["balance"] - amount

    {:ok, %{"new_balance" => new_balance, "debited" => amount}}
  end
end

defmodule MyNodes.SendReceipt do
  # Arity 2 is also supported: run(params, context)
  def run(params, context) do
    receipt = context.results["debit"]
    email = context.context["user_email"] || "pedro@example.com"
    prefix = params["prefix"] || "Receipt:"

    {:ok, %{"receipt" => "#{prefix} Debit of #{receipt["debited"]} sent to #{email}"}}
  end
end
```


### 2. Creating the Workflow

You can create it via the `Sig.Flow` DSL or by passing a map of attributes:

```elixir
flow =
  Sig.Flow.new("payment_pipeline",
    params: %{"currency" => "BRL"},
    context: %{"environment" => "production"}
  )
  |> Sig.Flow.add_node(:fetch_user, MyNodes.FetchUser)
  |> Sig.Flow.add_node(:debit, MyNodes.DebitAccount,
    depends_on: [:fetch_user],
    max_retries: 3,
    backoff_ms: 1000
  )
  |> Sig.Flow.add_node(:receipt, MyNodes.SendReceipt,
    depends_on: [:debit]
  )

{:ok, workflow} = Sig.create_workflow(flow)
```


### 3. Creating and Triggering Executions

Each execution has its own params and context:

> Params, context and results are stored as JSONB, so inside a node all map
> keys are **strings**, even if you used atoms when defining them. Read them
> with `params["key"]`, not `params[:key]`.

```elixir
# Direct execution with run_execution
{:ok, execution} =
  Sig.run_execution(
    workflow.id,
    %{"user_id" => 10, "amount" => 40},     # Execution params
    %{"user_email" => "pedro@email.com"},  # Execution context
    idempotency_key: "tx-order-001"    # Idempotency
  )

IO.inspect(execution.status)
# => "completed"

IO.inspect(execution.node_results)
# => %{
#      "fetch_user" => %{"balance" => 150, "name" => "Pedro", "user_id" => 10},
#      "debit" => %{"debited" => 40, "new_balance" => 110},
#      "receipt" => %{"receipt" => "Receipt: Debit of 40 sent to pedro@email.com"}
#    }
```

### 4. Control Functions

#### Execution Level:
```elixir
# Suspend
{:ok, execution} = Sig.suspend_execution(execution_id)

# Resume (picks up where it left off, without re-running completed nodes)
{:ok, execution} = Sig.resume_execution(execution_id)

# Stop / Cancel
{:ok, execution} = Sig.stop_execution(execution_id)
```

#### Workflow Level:
```elixir
# Suspend the workflow and all in-progress executions
{:ok, workflow} = Sig.suspend_workflow(workflow_id)

# Resume the workflow
{:ok, workflow} = Sig.resume_workflow(workflow_id)

# Stop the workflow and halt its active executions
{:ok, workflow} = Sig.stop_workflow(workflow_id)
```

### 5. Queue Execution with BullMQ (Distributed)

To run asynchronously with BullMQ and Redis:

```elixir
# Start the supervisor in your supervision tree, after your repo:
children = [
  MyApp.Repo,
  Sig.BullMQ.Supervisor
]

# Trigger the asynchronous execution:
{:ok, execution} = Sig.create_execution(workflow.id, %{"user_id" => 10})
{:ok, execution} = Sig.start_execution(execution.id, async: true)
```

### 6. Running Tests

```bash
mix test
```

The test suite uses [Testcontainers](https://github.com/testcontainers/testcontainers-elixir) to start throwaway PostgreSQL and Redis containers automatically, so the only requirement is a running Docker daemon. You don't need a local Postgres or Redis.

## 📄 License

Sig is released under the [MIT License](LICENSE).

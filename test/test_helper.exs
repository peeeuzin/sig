# Spin up throwaway Postgres and Redis containers for the test suite, and point
# the test repo (standing in for a host application's repo) at them.
{:ok, _} = Testcontainers.start_link()

alias Testcontainers.{PostgresContainer, RedisContainer}

{:ok, postgres} =
  PostgresContainer.new()
  |> PostgresContainer.with_database("sig_test")
  |> Testcontainers.start_container()

{:ok, redis} = Testcontainers.start_container(RedisContainer.new())

repo_config =
  :sig
  |> Application.get_env(Sig.Test.Repo, [])
  |> Keyword.merge(PostgresContainer.connection_parameters(postgres))

Application.put_env(:sig, Sig.Test.Repo, repo_config)

Application.put_env(
  :sig,
  Sig.Test.MigrationRepo,
  repo_config |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)
)

Application.put_env(:sig, :redis_url, RedisContainer.connection_url(redis))

{:ok, _} = Sig.Test.Repo.start_link()

# Runs test/support/migrations, which installs Sig's tables with Sig.Migration,
# the same way a host application would.
Ecto.Migrator.run(Sig.Test.Repo, "test/support/migrations", :up, all: true, log: false)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Sig.Test.Repo, :manual)

defmodule Sig.MigrationTest do
  # Ecto.Migrator takes its own lock and connections, which does not play well
  # with the SQL sandbox, so these tests use a repo without the sandbox and
  # clean up after themselves.
  use ExUnit.Case, async: false

  alias Sig.Test.MigrationRepo, as: Repo

  @prefix "sig_migration_test"
  @versions [30_000_000_000_001, 30_000_000_000_002, 30_000_000_000_003]

  setup do
    start_supervised!(Repo)

    on_exit(fn ->
      {:ok, pid} = Repo.start_link()
      Repo.query!(~s|DROP SCHEMA IF EXISTS "#{@prefix}" CASCADE|)
      Repo.query!("DELETE FROM schema_migrations WHERE version = ANY($1)", [@versions])
      Supervisor.stop(pid)
    end)
  end

  defmodule PrefixedMigration do
    use Ecto.Migration

    def up, do: Sig.Migration.up(version: 1, prefix: "sig_migration_test")
    def down, do: Sig.Migration.down(version: 1, prefix: "sig_migration_test")
  end

  defmodule DefaultMigration do
    use Ecto.Migration

    def up, do: Sig.Migration.up()
    def down, do: :ok
  end

  defp tables(prefix) do
    Repo.query!(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 ORDER BY table_name",
      [prefix]
    ).rows
    |> List.flatten()
  end

  defp version_comment(prefix) do
    Repo.query!(~s|SELECT obj_description('"#{prefix}".workflows'::regclass, 'pg_class')|).rows
    |> List.first()
    |> List.first()
  end

  defp migrate(direction, version, module) do
    apply(Ecto.Migrator, direction, [Repo, version, module, [log: false]])
  end

  test "creates the tables in the given prefix and records the version" do
    assert tables(@prefix) == []

    assert :ok = migrate(:up, 30_000_000_000_001, PrefixedMigration)

    assert tables(@prefix) == ["node_executions", "workflow_executions", "workflows"]
    assert version_comment(@prefix) == "1"
  end

  test "Sig reads and writes the prefixed tables when :prefix is configured" do
    assert :ok = migrate(:up, 30_000_000_000_001, PrefixedMigration)

    previous = Application.get_all_env(:sig) |> Keyword.take([:repo, :prefix])

    Application.put_env(:sig, :repo, Repo)
    Application.put_env(:sig, :prefix, @prefix)

    on_exit(fn ->
      Application.delete_env(:sig, :prefix)
      Enum.each(previous, fn {key, value} -> Application.put_env(:sig, key, value) end)
    end)

    flow =
      Sig.Flow.new("prefixed")
      |> Sig.Flow.add_node(:add, Sig.TestNodes.AddNumbers, params: %{"a" => 1, "b" => 2})

    {:ok, workflow} = Sig.create_workflow(flow)
    {:ok, execution} = Sig.run_execution(workflow)

    assert execution.status == "completed"
    assert execution.node_results["add"]["sum"] == 3

    count = fn table ->
      Repo.query!(~s|SELECT count(*) FROM "#{@prefix}".#{table}|).rows |> hd() |> hd()
    end

    assert count.("workflows") == 1
    assert count.("workflow_executions") == 1
    assert count.("node_executions") == 1
  end

  test "down removes the tables" do
    assert :ok = migrate(:up, 30_000_000_000_002, PrefixedMigration)
    assert :ok = migrate(:down, 30_000_000_000_002, PrefixedMigration)

    assert tables(@prefix) == []
  end

  test "up is a no-op when the version is already applied" do
    # The suite's own migration already installed version 1 in "public".
    assert version_comment("public") == "1"
    assert :ok = migrate(:up, 30_000_000_000_003, DefaultMigration)
    assert version_comment("public") == "1"
  end

  test "rejects unknown versions and invalid prefixes" do
    assert_raise ArgumentError, ~r/:version must be between 1 and 1/, fn ->
      Sig.Migration.up(version: 99)
    end

    assert_raise ArgumentError, ~r/:prefix must be a valid PostgreSQL identifier/, fn ->
      Sig.Migration.up(prefix: "bad; DROP TABLE workflows")
    end
  end
end

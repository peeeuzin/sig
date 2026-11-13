defmodule Sig.Migration do
  @moduledoc """
  Creates and upgrades Sig's database tables from your application's own
  migrations.

  The migrations run on your application's repo, the same one Sig uses at
  runtime (see `Sig.Repo`).

  Sig's tables are versioned. Generate a migration in your app:

  ```bash
  mix ecto.gen.migration add_sig_tables
  ```

  and call `up/1` and `down/1` from it:

  ```elixir
  defmodule MyApp.Repo.Migrations.AddSigTables do
    use Ecto.Migration

    def up, do: Sig.Migration.up(version: 1)

    # Passing version: 1 drops all of Sig's tables.
    def down, do: Sig.Migration.down(version: 1)
  end
  ```

  When a new version of Sig needs schema changes, its changelog will tell you
  the new version number. Create another migration that upgrades to it, and
  rolls back to the version you had before:

  ```elixir
  defmodule MyApp.Repo.Migrations.UpgradeSigTablesToV2 do
    use Ecto.Migration

    def up, do: Sig.Migration.up(version: 2)
    def down, do: Sig.Migration.down(version: 2)
  end
  ```

  Migrations are idempotent: `up/1` only applies the versions that are not
  yet in the database, and `down/1` only reverts the ones that are. The
  current version is stored as a comment on the `workflows` table.

  ## Prefixes

  Use the `:prefix` option to install the tables in a PostgreSQL schema other
  than `public`. The schema is created if it does not exist:

  ```elixir
  def up, do: Sig.Migration.up(version: 1, prefix: "sig")
  def down, do: Sig.Migration.down(version: 1, prefix: "sig")
  ```

  Then configure Sig to use the same prefix at runtime:

  ```elixir
  config :sig, repo: MyApp.Repo, prefix: "sig"
  ```
  """

  use Ecto.Migration

  alias Sig.Migrations.Postgres

  @initial_version 1
  @current_version 1
  @default_prefix "public"

  @doc """
  Applies Sig's migrations up to `:version`.

  ## Options

    * `:version` - the version to migrate to. Defaults to the latest version
      (`#{@current_version}`). Pin it explicitly in your migrations, so that
      upgrading Sig never changes what an existing migration does.
    * `:prefix` - the PostgreSQL schema to create the tables in. Defaults to
      `"public"`.
  """
  @spec up(keyword()) :: :ok
  def up(opts \\ []) when is_list(opts) do
    opts = with_defaults(opts, @current_version)
    current = migrated_version(opts)

    if current < opts.version do
      change((current + 1)..opts.version, :up, opts)
    end

    :ok
  end

  @doc """
  Reverts Sig's migrations down to, and including, `:version`.

  `down(version: 1)` removes all of Sig's tables. `down(version: 2)` reverts
  version 2 and every later one, leaving the database at version 1.

  ## Options

    * `:version` - the oldest version to revert. Defaults to `1`.
    * `:prefix` - the PostgreSQL schema holding the tables. Defaults to
      `"public"`.
  """
  @spec down(keyword()) :: :ok
  def down(opts \\ []) when is_list(opts) do
    opts = with_defaults(opts, @initial_version)
    current = migrated_version(opts)

    if current >= opts.version do
      change(current..opts.version//-1, :down, opts)
    end

    :ok
  end

  @doc """
  Returns the latest migration version available in this release of Sig.
  """
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc """
  Returns the version currently applied to the database, or `0` when Sig's
  tables do not exist.

  Must be called from within a migration.

  ## Options

    * `:prefix` - the PostgreSQL schema to inspect. Defaults to `"public"`.
  """
  @spec migrated_version(keyword() | map()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    prefix = opts |> Map.new() |> Map.get(:prefix, @default_prefix)

    query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_catalog.pg_class
    JOIN pg_catalog.pg_namespace ON pg_namespace.oid = pg_class.relnamespace
    WHERE pg_class.relname = 'workflows' AND pg_namespace.nspname = $1
    """

    case repo().query(query, [prefix], log: false) do
      {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
      {:ok, %{rows: [[nil]]}} -> @initial_version
      _ -> 0
    end
  end

  defp change(range, direction, opts) do
    for version <- range do
      module = version_module(version)
      apply(module, direction, [opts])
    end

    case direction do
      :up -> record_version(opts, Enum.max(range))
      :down -> record_version(opts, Enum.min(range) - 1)
    end
  end

  defp record_version(_opts, 0), do: :ok

  defp record_version(%{prefix: prefix}, version) do
    execute(~s|COMMENT ON TABLE "#{prefix}".workflows IS '#{version}'|)
  end

  defp version_module(version) do
    version
    |> Integer.to_string()
    |> String.pad_leading(2, "0")
    |> then(&Module.concat(Postgres, "V#{&1}"))
  end

  defp with_defaults(opts, default_version) do
    opts = Map.new(opts)
    version = Map.get(opts, :version, default_version)
    prefix = Map.get(opts, :prefix, @default_prefix)

    unless is_integer(version) and version in @initial_version..@current_version do
      raise ArgumentError,
            "Sig.Migration :version must be between #{@initial_version} and " <>
              "#{@current_version}, got: #{inspect(version)}"
    end

    unless is_binary(prefix) and Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/, prefix) do
      raise ArgumentError,
            "Sig.Migration :prefix must be a valid PostgreSQL identifier, got: #{inspect(prefix)}"
    end

    %{version: version, prefix: prefix}
  end
end

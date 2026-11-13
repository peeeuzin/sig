defmodule Sig.Repo do
  @moduledoc """
  Delegates Sig's database calls to your application's Ecto repo.

  Sig does not start a repo of its own. Like Oban, it uses the one you
  configure:

      config :sig, repo: MyApp.Repo

  All of Sig's queries go through this module, which forwards them to that
  repo. Since they share the repo, Sig's writes take part in your
  transactions, and in tests they use the same SQL sandbox as the rest of your
  app.

  ## Options

    * `:repo` (required) - the `Ecto.Repo` to use.
    * `:prefix` - the PostgreSQL schema where Sig's tables live. Defaults to
      `nil`, which uses the connection's search path (normally `public`). Set
      it to the same prefix you passed to `Sig.Migration.up/1`:

          config :sig, repo: MyApp.Repo, prefix: "sig"

  The functions below mirror the `Ecto.Repo` ones of the same name and add
  the configured `:prefix` to the options when one is set.
  """

  @doc """
  Returns the configured repo.

  Raises `ArgumentError` if `:repo` is not configured.
  """
  @spec repo() :: module()
  def repo do
    case Application.get_env(:sig, :repo) do
      repo when is_atom(repo) and not is_nil(repo) ->
        repo

      other ->
        raise ArgumentError, """
        Sig needs an Ecto repo, configure it with:

            config :sig, repo: MyApp.Repo

        got: #{inspect(other)}
        """
    end
  end

  @doc """
  Returns the configured prefix, or `nil` to use the connection's search path.
  """
  @spec prefix() :: String.t() | nil
  def prefix, do: Application.get_env(:sig, :prefix)

  @doc false
  def all(queryable, opts \\ []), do: repo().all(queryable, with_prefix(opts))

  @doc false
  def one!(queryable, opts \\ []), do: repo().one!(queryable, with_prefix(opts))

  @doc false
  def get(queryable, id, opts \\ []), do: repo().get(queryable, id, with_prefix(opts))

  @doc false
  def get!(queryable, id, opts \\ []), do: repo().get!(queryable, id, with_prefix(opts))

  @doc false
  def get_by(queryable, clauses, opts \\ []),
    do: repo().get_by(queryable, clauses, with_prefix(opts))

  @doc false
  def get_by!(queryable, clauses, opts \\ []),
    do: repo().get_by!(queryable, clauses, with_prefix(opts))

  @doc false
  def preload(structs_or_nil, preloads, opts \\ []),
    do: repo().preload(structs_or_nil, preloads, with_prefix(opts))

  @doc false
  def insert(struct_or_changeset, opts \\ []),
    do: repo().insert(struct_or_changeset, with_prefix(opts))

  @doc false
  def insert!(struct_or_changeset, opts \\ []),
    do: repo().insert!(struct_or_changeset, with_prefix(opts))

  @doc false
  def update(changeset, opts \\ []), do: repo().update(changeset, with_prefix(opts))

  @doc false
  def update!(changeset, opts \\ []), do: repo().update!(changeset, with_prefix(opts))

  @doc false
  def update_all(queryable, updates, opts \\ []),
    do: repo().update_all(queryable, updates, with_prefix(opts))

  @doc false
  def delete(struct_or_changeset, opts \\ []),
    do: repo().delete(struct_or_changeset, with_prefix(opts))

  @doc false
  def transaction(fun_or_multi, opts \\ []), do: repo().transaction(fun_or_multi, opts)

  defp with_prefix(opts) do
    case prefix() do
      nil -> opts
      prefix -> Keyword.put_new(opts, :prefix, prefix)
    end
  end
end

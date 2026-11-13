defmodule Sig.Test.MigrationRepo do
  @moduledoc false
  # A repo without the SQL sandbox, used to exercise Sig.Migration through
  # Ecto.Migrator (which needs its own connections and locks).
  use Ecto.Repo, otp_app: :sig, adapter: Ecto.Adapters.Postgres
end

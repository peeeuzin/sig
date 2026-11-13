defmodule Sig.Test.Repo do
  @moduledoc false
  # Stands in for the host application's repo in Sig's own test suite.
  use Ecto.Repo, otp_app: :sig, adapter: Ecto.Adapters.Postgres
end

defmodule Sig.Test.Repo.Migrations.CreateWorkflowTables do
  use Ecto.Migration

  def up, do: Sig.Migration.up(version: 1)
  def down, do: Sig.Migration.down(version: 1)
end

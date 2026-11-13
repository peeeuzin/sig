defmodule Sig.Migrations.Postgres.V01 do
  @moduledoc false
  # Initial schema: workflows, workflow_executions and node_executions.

  use Ecto.Migration

  def up(%{prefix: prefix}) do
    if prefix != "public" do
      execute(~s|CREATE SCHEMA IF NOT EXISTS "#{prefix}"|)
    end

    create_if_not_exists table(:workflows, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:params, :map, default: %{}, null: false)
      add(:context, :map, default: %{}, null: false)
      add(:nodes, :map, default: %{}, null: false)
      add(:status, :string, default: "active", null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(index(:workflows, [:status], prefix: prefix))
    create_if_not_exists(index(:workflows, [:name], prefix: prefix))

    create_if_not_exists table(:workflow_executions, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)

      add(
        :workflow_id,
        references(:workflows, type: :binary_id, on_delete: :delete_all, prefix: prefix),
        null: false
      )

      add(:idempotency_key, :string)
      add(:params, :map, default: %{}, null: false)
      add(:context, :map, default: %{}, null: false)
      add(:node_results, :map, default: %{}, null: false)
      add(:status, :string, default: "pending", null: false)
      add(:error, :map)
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(index(:workflow_executions, [:workflow_id], prefix: prefix))
    create_if_not_exists(index(:workflow_executions, [:status], prefix: prefix))

    create_if_not_exists(
      unique_index(:workflow_executions, [:workflow_id, :idempotency_key],
        name: :workflow_executions_wf_id_idemp_key_index,
        prefix: prefix
      )
    )

    create_if_not_exists table(:node_executions, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)

      add(
        :workflow_execution_id,
        references(:workflow_executions,
          type: :binary_id,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(:node_name, :string, null: false)
      add(:module, :string, null: false)
      add(:status, :string, default: "pending", null: false)
      add(:attempts, :integer, default: 0, null: false)
      add(:max_retries, :integer, default: 3, null: false)
      add(:params, :map, default: %{}, null: false)
      add(:result, :map)
      add(:error, :map)
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(index(:node_executions, [:workflow_execution_id], prefix: prefix))
    create_if_not_exists(index(:node_executions, [:status], prefix: prefix))

    create_if_not_exists(
      unique_index(:node_executions, [:workflow_execution_id, :node_name], prefix: prefix)
    )
  end

  def down(%{prefix: prefix}) do
    drop_if_exists(table(:node_executions, prefix: prefix))
    drop_if_exists(table(:workflow_executions, prefix: prefix))
    drop_if_exists(table(:workflows, prefix: prefix))
  end
end

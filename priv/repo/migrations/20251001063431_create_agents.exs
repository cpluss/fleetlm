defmodule Fleetlm.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :origin_url, :string, null: false
      add :webhook_path, :string, default: "/webhook", null: false

      # Context management configuration
      add :context_strategy, :string, default: "last_n", null: false
      add :context_strategy_config, :map, default: %{}, null: false

      # HTTP configuration
      add :timeout_ms, :integer, default: 30_000, null: false
      add :headers, :map, default: %{}
      add :status, :string, default: "enabled", null: false

      timestamps()
    end

    create index(:agents, [:status])
  end
end

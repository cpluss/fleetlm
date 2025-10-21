defmodule Fleetlm.Repo.Migrations.AddCompactionFieldsToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :compaction_enabled, :boolean, default: false, null: false
      add :compaction_token_budget, :integer, default: 50000, null: false
      add :compaction_trigger_ratio, :float, default: 0.7, null: false
      add :compaction_webhook_url, :string
    end
  end
end

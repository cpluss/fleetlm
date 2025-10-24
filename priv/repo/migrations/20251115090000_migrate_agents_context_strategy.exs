defmodule Fleetlm.Repo.Migrations.MigrateAgentsContextStrategy do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      remove :message_history_mode
      remove :message_history_limit
      remove :compaction_enabled
      remove :compaction_token_budget
      remove :compaction_trigger_ratio
      remove :compaction_webhook_url
      add :context_strategy, :string, default: "last_n", null: false
      add :context_strategy_config, :map, default: %{}, null: false
    end

    execute(
      "UPDATE agents SET context_strategy = 'last_n', context_strategy_config = jsonb_build_object('limit', 50)"
    )
  end
end

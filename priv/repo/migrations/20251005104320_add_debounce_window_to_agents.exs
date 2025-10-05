defmodule Fleetlm.Repo.Migrations.AddDebounceWindowToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :debounce_window_ms, :integer, default: 500, null: false
    end
  end
end

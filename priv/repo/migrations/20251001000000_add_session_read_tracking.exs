defmodule Fleetlm.Repo.Migrations.AddSessionReadTracking do
  use Ecto.Migration

  def change do
    alter table(:chat_sessions) do
      add :initiator_last_read_id, :string
      add :initiator_last_read_at, :utc_datetime_usec
      add :peer_last_read_id, :string
      add :peer_last_read_at, :utc_datetime_usec
    end

    create index(:chat_sessions, [:initiator_last_read_at])
    create index(:chat_sessions, [:peer_last_read_at])
  end
end

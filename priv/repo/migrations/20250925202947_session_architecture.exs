defmodule Fleetlm.Repo.Migrations.SessionArchitecture do
  use Ecto.Migration

  def up do
    drop_table_if_exists(:agent_delivery_logs)
    drop_table_if_exists(:agent_endpoints)
    drop_table_if_exists(:chat_messages)
    drop_table_if_exists(:chat_sessions)
    drop_table_if_exists(:dm_messages)
    drop_table_if_exists(:broadcast_messages)

    create table(:participants, primary_key: false) do
      add :id, :string, primary_key: true
      add :kind, :string, null: false
      add :display_name, :string, null: false
      add :status, :string, null: false, default: "active"
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")
      timestamps()
    end

    create unique_index(:participants, [:display_name])
    create index(:participants, [:kind])
    create index(:participants, [:status])

    create table(:chat_sessions, primary_key: false) do
      add :id, :string, primary_key: true

      add :initiator_id, references(:participants, type: :string, on_delete: :nothing),
        null: false

      add :peer_id, references(:participants, type: :string, on_delete: :nothing), null: false
      add :agent_id, references(:participants, type: :string, on_delete: :nothing)
      add :kind, :string, null: false
      add :status, :string, null: false, default: "open"
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")
      add :last_message_id, :string
      add :last_message_at, :utc_datetime_usec
      timestamps()
    end

    create index(:chat_sessions, [:initiator_id])
    create index(:chat_sessions, [:peer_id])
    create index(:chat_sessions, [:agent_id])
    create index(:chat_sessions, [:status])
    create index(:chat_sessions, [:last_message_at])

    create table(:chat_messages, primary_key: false) do
      add :id, :string, primary_key: true

      add :session_id, references(:chat_sessions, type: :string, on_delete: :delete_all),
        null: false

      add :sender_id, references(:participants, type: :string, on_delete: :nothing), null: false
      add :kind, :string, null: false
      add :content, :map, null: false, default: fragment("'{}'::jsonb")
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")
      add :shard_key, :integer, null: false
      timestamps(updated_at: false)
    end

    create index(:chat_messages, [:session_id, :inserted_at])
    create index(:chat_messages, [:sender_id, :inserted_at])

    create table(:agent_endpoints, primary_key: false) do
      add :id, :string, primary_key: true
      add :agent_id, references(:participants, type: :string, on_delete: :delete_all), null: false
      add :origin_url, :text, null: false
      add :auth_strategy, :string, null: false, default: "none"
      add :auth_value, :text
      add :headers, :map, null: false, default: fragment("'{}'::jsonb")
      add :timeout_ms, :integer, null: false, default: 5_000
      add :retry_policy, :map, null: false, default: fragment("'{}'::jsonb")
      add :status, :string, null: false, default: "enabled"
      timestamps()
    end

    create unique_index(:agent_endpoints, [:agent_id])
    create index(:agent_endpoints, [:status])

    create table(:agent_delivery_logs, primary_key: false) do
      add :id, :string, primary_key: true

      add :session_id, references(:chat_sessions, type: :string, on_delete: :delete_all),
        null: false

      add :message_id, references(:chat_messages, type: :string, on_delete: :delete_all),
        null: false

      add :agent_id, references(:participants, type: :string, on_delete: :nothing), null: false
      add :attempt, :integer, null: false, default: 1
      add :status, :string, null: false
      add :http_status, :integer
      add :latency_ms, :integer
      add :response_excerpt, :text
      add :error_reason, :text
      timestamps(updated_at: false)
    end

    create index(:agent_delivery_logs, [:session_id, :inserted_at])
    create index(:agent_delivery_logs, [:agent_id, :inserted_at])
    create index(:agent_delivery_logs, [:message_id])
  end

  def down do
    drop table(:agent_delivery_logs)
    drop table(:agent_endpoints)
    drop table(:chat_messages)
    drop table(:chat_sessions)
    drop table(:participants)
  end

  defp drop_table_if_exists(table) do
    execute("DROP TABLE IF EXISTS #{table} CASCADE")
  end
end

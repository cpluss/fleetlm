defmodule Fleetlm.Repo.Migrations.SessionArchitecture do
  use Ecto.Migration

  def up do
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
      add :id, :binary_id, primary_key: true

      add :initiator_id, references(:participants, type: :string, on_delete: :nothing),
        null: false

      add :peer_id, references(:participants, type: :string, on_delete: :nothing), null: false
      add :agent_id, references(:participants, type: :string, on_delete: :nothing)
      add :kind, :string, null: false
      add :status, :string, null: false, default: "open"
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")
      add :seq_name, :string, null: false
      add :last_message_id, :binary_id
      add :last_message_at, :utc_datetime_usec
      timestamps()
    end

    create index(:chat_sessions, [:initiator_id])
    create index(:chat_sessions, [:peer_id])
    create index(:chat_sessions, [:agent_id])
    create index(:chat_sessions, [:status])
    create index(:chat_sessions, [:last_message_at])

    create table(:chat_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, references(:chat_sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sender_id, references(:participants, type: :string, on_delete: :nothing), null: false
      add :seq, :bigint, null: false
      add :kind, :string, null: false
      add :content, :map, null: false, default: fragment("'{}'::jsonb")
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")
      add :shard_key, :integer, null: false
      timestamps(updated_at: false)
    end

    create unique_index(:chat_messages, [:session_id, :seq])
    create index(:chat_messages, [:session_id, :inserted_at])
    create index(:chat_messages, [:sender_id, :inserted_at])

    create table(:agent_endpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true
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
      add :id, :binary_id, primary_key: true

      add :session_id, references(:chat_sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :message_id, references(:chat_messages, type: :binary_id, on_delete: :delete_all),
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

    execute """
    CREATE OR REPLACE FUNCTION create_session_sequence(session_uuid uuid)
    RETURNS text
    LANGUAGE plpgsql
    AS $$
    DECLARE
      seq_name text := 'session_seq_' || replace(session_uuid::text, '-', '_');
    BEGIN
      EXECUTE format('CREATE SEQUENCE IF NOT EXISTS %I START 1 INCREMENT 1', seq_name);
      RETURN seq_name;
    END;
    $$;
    """

    execute """
    CREATE OR REPLACE FUNCTION drop_session_sequence(seq_name text)
    RETURNS void
    LANGUAGE plpgsql
    AS $$
    BEGIN
      EXECUTE format('DROP SEQUENCE IF EXISTS %I', seq_name);
    END;
    $$;
    """
  end

  def down do
    execute "DROP FUNCTION IF EXISTS drop_session_sequence(text);"
    execute "DROP FUNCTION IF EXISTS create_session_sequence(uuid);"

    drop table(:agent_delivery_logs)
    drop table(:agent_endpoints)
    drop table(:chat_messages)
    drop table(:chat_sessions)
    drop table(:participants)
  end
end

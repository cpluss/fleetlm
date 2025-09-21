defmodule Fleetlm.Repo.Migrations.ChatCore do
  use Ecto.Migration

  def up do
    # for gen_random_uuid()
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto"
    # for case-insensitive text
    execute "CREATE EXTENSION IF NOT EXISTS citext"

    # Threads
    create table(:threads, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :kind, :text, null: false
      # normalized unordered pair for DMs
      add :dm_key, :citext
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:threads, [:created_at])

    # Enforce allowed thread kinds
    create constraint(:threads, "threads_kind_check",
             check: "kind IN ('dm', 'room', 'broadcast')"
           )

    # If kind='dm', dm_key must be present & unique. Partial unique index.
    create unique_index(:threads, [:dm_key],
             where: "dm_key IS NOT NULL AND kind = 'dm'",
             name: "threads_dm_key_unique"
           )

    # Participants (humans, or agents)
    create table(:thread_participants, primary_key: false) do
      add :thread_id, references(:threads, type: :uuid, on_delete: :delete_all), null: false
      # external identifier, we do not generate these but rather
      # expect them to be passed in
      add :participant_id, :uuid, null: false
      add :role, :text, null: false
      add :joined_at, :utc_datetime_usec, null: false, default: fragment("now()")

      # Unread/read cursor (move out later)
      add :read_cursor_at, :utc_datetime_usec

      # Inbox info (move out later)
      add :last_message_at, :utc_datetime_usec
      add :last_message_preview, :text
    end

    create constraint(:thread_participants, :tp_role_check,
             check: "role IN ('user', 'agent', 'system')"
           )

    create unique_index(:thread_participants, [:thread_id, :participant_id], name: "tp_unique")
    # to lookup the "fresh" inbox items
    create index(:thread_participants, [:last_message_at])

    # Messages (append only)
    create table(:thread_messages, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :thread_id, references(:threads, type: :uuid, on_delete: :delete_all), null: false

      add :sender_id, :uuid, null: false
      add :role, :text, null: false
      add :kind, :text, null: false, default: "message"

      add :shard_key, :smallint, null: false

      add :text, :text
      add :metadata, :map

      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:thread_messages, :tm_role_check,
             check: "role IN ('user', 'agent', 'system')"
           )

    create constraint(:thread_messages, :tm_kind_check,
             check: "kind IN ('message', 'event', 'broadcast')"
           )

    # hot-path: last-N by thread
    create index(:thread_messages, [:thread_id, :created_at],
             name: "thread_messages_thread_created_desc"
           )

    create index(:thread_messages, [:sender_id, :created_at],
             name: "thread_messages_sender_created_desc"
           )

    create index(:thread_messages, [:shard_key, :created_at])

    create index(:thread_messages, [:created_at])
    create index(:thread_messages, [:thread_id])
  end

  def down do
    # Drop message-related indexes and constraints
    drop_if_exists index(:thread_messages, [:thread_id, :created_at],
                     name: "thread_messages_thread_created_desc"
                   )

    drop_if_exists index(:thread_messages, [:sender_id, :created_at],
                     name: "thread_messages_sender_created_desc"
                   )

    drop_if_exists index(:thread_messages, [:shard_key, :created_at])
    drop_if_exists index(:thread_messages, [:created_at])
    drop_if_exists index(:thread_messages, [:thread_id])
    drop_if_exists constraint(:thread_messages, :tm_role_check)
    drop_if_exists constraint(:thread_messages, :tm_kind_check)
    drop_if_exists table(:thread_messages)

    # Drop participant-related indexes and constraints
    drop_if_exists index(:thread_participants, [:last_message_at])
    drop_if_exists constraint(:thread_participants, :tp_role_check)
    drop_if_exists index(:thread_participants, [:thread_id, :participant_id], name: "tp_unique")
    drop_if_exists table(:thread_participants)

    # Drop thread-related indexes and constraints
    drop_if_exists index(:threads, [:created_at])
    drop_if_exists index(:threads, [:dm_key], name: "threads_dm_key_unique")
    drop_if_exists constraint(:threads, "threads_kind_check")
    drop_if_exists table(:threads)
  end
end

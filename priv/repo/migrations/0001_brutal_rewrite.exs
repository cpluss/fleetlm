defmodule Fleetlm.Repo.Migrations.BrutalRewrite do
  use Ecto.Migration

  def up do
    # Extensions
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto"

    # DM Messages (append-only, no participant management)
    create table(:dm_messages, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      # Core message data
      add :sender_id, :uuid, null: false
      add :recipient_id, :uuid, null: false
      add :text, :text
      add :metadata, :map

      # Write optimization
      add :shard_key, :smallint, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    # Broadcast Messages (1:many)
    create table(:broadcast_messages, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :sender_id, :uuid, null: false
      add :text, :text
      add :metadata, :map
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    # Constraints
    create constraint(:dm_messages, "dm_different_participants",
             check: "sender_id != recipient_id"
           )

    # Write-optimized indexes

    # Sharded writes
    create index(:dm_messages, [:shard_key, :created_at],
             name: "dm_messages_shard_created"
           )

    # Thread lookup (bidirectional conversation) - use raw SQL
    execute """
    CREATE INDEX dm_messages_conversation_created
    ON dm_messages (LEAST(sender_id, recipient_id), GREATEST(sender_id, recipient_id), created_at DESC)
    """

    # Per-user inbox
    create index(:dm_messages, [:recipient_id, :created_at],
             name: "dm_messages_recipient_created"
           )

    create index(:dm_messages, [:sender_id, :created_at],
             name: "dm_messages_sender_created"
           )

    create index(:broadcast_messages, [:created_at],
             name: "broadcast_messages_created"
           )
  end

  def down do
    drop table(:dm_messages)
    drop table(:broadcast_messages)
  end
end
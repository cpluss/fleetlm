defmodule Fleetlm.Repo.Migrations.AddDmKey do
  use Ecto.Migration

  def up do
    # Add dm_key field to dm_messages
    alter table(:dm_messages) do
      add :dm_key, :text, null: false, default: ""
    end

    # Populate dm_key for existing records
    execute """
    UPDATE dm_messages
    SET dm_key = CASE
      WHEN sender_id < recipient_id THEN sender_id || ':' || recipient_id
      ELSE recipient_id || ':' || sender_id
    END
    """

    # Remove default now that all records are populated
    alter table(:dm_messages) do
      modify :dm_key, :text, null: false
    end

    # Create dm_key index for fast conversation lookups
    create index(:dm_messages, [:dm_key, :created_at], name: "dm_messages_dm_key_created_desc")

    # Drop the old conversation index since dm_key replaces it
    drop_if_exists index(:dm_messages, [], name: "dm_messages_conversation_created")
  end

  def down do
    drop index(:dm_messages, [:dm_key, :created_at], name: "dm_messages_dm_key_created_desc")

    alter table(:dm_messages) do
      remove :dm_key
    end

    # Recreate the old conversation index
    execute """
    CREATE INDEX dm_messages_conversation_created
    ON dm_messages (LEAST(sender_id, recipient_id), GREATEST(sender_id, recipient_id), created_at DESC)
    """
  end
end

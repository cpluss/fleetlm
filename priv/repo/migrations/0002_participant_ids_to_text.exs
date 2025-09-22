defmodule Fleetlm.Repo.Migrations.ParticipantIdsToText do
  use Ecto.Migration

  def up do
    # Change participant ID fields from UUID to text to support arbitrary external IDs
    alter table(:dm_messages) do
      modify :sender_id, :text, null: false
      modify :recipient_id, :text, null: false
    end

    alter table(:broadcast_messages) do
      modify :sender_id, :text, null: false
    end

    # Drop old indexes
    drop index(:dm_messages, [:recipient_id, :created_at], name: "dm_messages_recipient_created")
    drop index(:dm_messages, [:sender_id, :created_at], name: "dm_messages_sender_created")
    drop_if_exists index(:dm_messages, [], name: "dm_messages_conversation_created")

    # Recreate indexes with text fields
    create index(:dm_messages, [:recipient_id, :created_at],
             name: "dm_messages_recipient_created"
           )

    create index(:dm_messages, [:sender_id, :created_at],
             name: "dm_messages_sender_created"
           )

    # Recreate conversation index
    execute """
    CREATE INDEX dm_messages_conversation_created
    ON dm_messages (LEAST(sender_id, recipient_id), GREATEST(sender_id, recipient_id), created_at DESC)
    """

    create index(:broadcast_messages, [:sender_id, :created_at],
             name: "broadcast_messages_sender_created"
           )
  end

  def down do
    # Convert back to UUIDs (this will fail if non-UUID data exists)
    alter table(:dm_messages) do
      modify :sender_id, :uuid, null: false
      modify :recipient_id, :uuid, null: false
    end

    alter table(:broadcast_messages) do
      modify :sender_id, :uuid, null: false
    end
  end
end
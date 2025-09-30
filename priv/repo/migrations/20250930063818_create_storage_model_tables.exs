defmodule Fleetlm.Repo.Migrations.CreateStorageModelTables do
  use Ecto.Migration

  @moduledoc """
  Creates the storage model tables for the messaging architecture.

  Index Strategy:
  - Messages: Optimized for hot-path writes (minimal indexes) and ordered retrieval by seq
  - Sessions: Indexed for participant-based lookups
  - Cursors: Unique composite index ensures one cursor per participant per session

  All tables include shard_key for future horizontal partitioning.
  """

  def change do
    # Sessions table - lightweight session metadata
    create table(:sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :sender_id, :string, null: false
      add :recipient_id, :string, null: false
      add :status, :string, null: false, default: "active"
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")
      add :shard_key, :integer

      timestamps()
    end

    # Indexes for session lookups
    # Composite index for finding sessions by participants (covers both sender->recipient and reverse lookups)
    create index(:sessions, [:sender_id, :recipient_id])
    # Note that we do not create indexes for recipient as we expect
    # it to be a very rare lookup given the nature of the architecture, as
    # every recipient will be an agent and is expected to have a ton of sessions.
    # create index(:sessions, [:recipient_id, :sender_id])
    create index(:sessions, [:status])
    # Shard key index for future distribution
    create index(:sessions, [:shard_key])

    # Messages table - core message storage with sequence numbers
    # Optimised for a single writer and multiple readers.
    create table(:messages, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_id, :string, null: false
      add :sender_id, :string, null: false
      add :recipient_id, :string, null: false
      add :seq, :integer, null: false
      add :kind, :string, null: false
      add :content, :map, null: false, default: fragment("'{}'::jsonb")
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")
      add :shard_key, :integer

      timestamps(updated_at: false)
    end

    # Unique constraint to ensure seq is unique within a session, prevents races
    # and enforce total order across the cluster. Will scream loudly in case
    # we violate it.
    #
    # This unique index also serves as our hot-path read index for ordered retrieval
    create unique_index(:messages, [:session_id, :seq])

    # Shard key index for future distribution
    create index(:messages, [:shard_key])

    # Cursors table - read position tracking
    create table(:cursors, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_id, :string, null: false
      add :participant_id, :string, null: false
      add :last_seq, :integer, null: false
      add :shard_key, :integer

      timestamps()
    end

    # Unique composite index for cursor lookups - one cursor per participant per session
    create unique_index(:cursors, [:session_id, :participant_id])

    # Index for finding all cursors for a participant across sessions
    create index(:cursors, [:participant_id])

    # Shard key index for future distribution
    create index(:cursors, [:shard_key])
  end
end

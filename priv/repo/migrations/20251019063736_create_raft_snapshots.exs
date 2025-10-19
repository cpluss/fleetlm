defmodule Fleetlm.Repo.Migrations.CreateRaftSnapshots do
  use Ecto.Migration

  def change do
    create table(:raft_snapshots, primary_key: false) do
      add :group_id, :integer, null: false
      add :raft_index, :bigint, null: false
      add :snapshot_data, :binary, null: false
      add :created_at, :utc_datetime, null: false, default: fragment("NOW()")
    end

    create unique_index(:raft_snapshots, [:group_id, :raft_index])

    # Index for cleanup queries (finding old snapshots to delete)
    execute(
      "CREATE INDEX raft_snapshots_cleanup_idx ON raft_snapshots (group_id, raft_index DESC)",
      "DROP INDEX raft_snapshots_cleanup_idx"
    )
  end
end

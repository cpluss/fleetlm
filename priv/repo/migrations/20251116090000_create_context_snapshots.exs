defmodule Fastpaca.Repo.Migrations.CreateContextSnapshots do
  use Ecto.Migration

  def change do
    create table(:context_snapshots, primary_key: false) do
      add(:session_id, :string, primary_key: true)
      add(:strategy_id, :string, null: false)
      add(:strategy_version, :string)
      add(:snapshot, :binary, null: false)
      add(:token_count, :integer, null: false)
      add(:last_compacted_seq, :bigint, null: false)
      add(:last_included_seq, :bigint, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end
  end
end

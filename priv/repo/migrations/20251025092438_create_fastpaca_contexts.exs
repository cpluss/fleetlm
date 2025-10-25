defmodule Fastpaca.Repo.Migrations.CreateFastpacaContexts do
  use Ecto.Migration

  def up do
    # Create contexts table
    create table(:contexts, primary_key: false) do
      add :id, :string, primary_key: true
      add :token_budget, :integer, null: false
      add :trigger_ratio, :float, null: false, default: 0.7
      add :policy, :map, null: false
      add :version, :integer, null: false, default: 0
      add :status, :string, null: false, default: "active"
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")

      timestamps()
    end

    create index(:contexts, [:status])
    create index(:contexts, [:inserted_at])

    # Drop old sessions table if it exists
    execute "DROP TABLE IF EXISTS sessions CASCADE"

    # Recreate messages table with new schema
    execute "DROP TABLE IF EXISTS messages CASCADE"

    create table(:messages, primary_key: false) do
      add :id, :string, primary_key: true
      add :context_id, :string, null: false
      add :seq, :integer, null: false
      add :role, :string, null: false
      add :parts, {:array, :map}, null: false
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :naive_datetime_usec, updated_at: false)
    end

    create index(:messages, [:context_id, :seq])
    create index(:messages, [:context_id, :inserted_at])
    create unique_index(:messages, [:context_id, :seq])
  end

  def down do
    drop table(:messages)
    drop table(:contexts)
  end
end

defmodule Fleetlm.Storage.Model.Cursor do
  @moduledoc """
  Maintaining read cursors for participants on a given session. Separate
  table in order to avoid hammering the session table with what could be
  quite frequent reads & updates.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "cursors" do
    belongs_to :session, Fleetlm.Storage.Model.Session, type: :string
    field :participant_id, :string
    field :last_seq, :integer

    # Sharding for convenience for future distribution if needed
    # in the database itself.
    field :shard_key, :integer

    timestamps()
  end

  @required_fields ~w(session_id participant_id last_seq shard_key)a

  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> ensure_id()
  end

  defp ensure_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, Uniq.UUID.uuid7(:slug))
      _ -> changeset
    end
  end
end

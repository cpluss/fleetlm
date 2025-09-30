defmodule FleetLM.Storage.Model.Session do
  @moduledoc """
  Model for the session.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  alias Ulid

  # Sessions are currently created and hardcoded to be between two participants, where
  # one is assumed to be a human and the other to be an agent.
  schema "sessions" do
    field :sender_id, :string
    field :recipient_id, :string

    field :status, :string, default: "active"
    field :metadata, :map, default: %{}

    # Sharding for convenience for future distribution if needed
    # in the database itself.
    field :shard_key, :integer

    timestamps()
  end

  @required_fields ~w(sender_id recipient_id status)a
  @optional_fields ~w(status metadata)a

  def changeset(session, attrs) do
    session
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ["active", "inactive", "archived"])
    |> ensure_id()
  end

  defp ensure_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, Ulid.generate())
      _ -> changeset
    end
  end
end

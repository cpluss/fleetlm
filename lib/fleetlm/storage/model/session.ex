defmodule FleetLM.Storage.Model.Session do
  @moduledoc """
  Model for the session.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  alias Ulid

  # Sessions are 1:1 conversations between a user (human) and an agent (AI).
  schema "sessions" do
    field :user_id, :string
    field :agent_id, :string

    field :status, :string, default: "active"
    field :metadata, :map, default: %{}

    # Sharding for convenience for future distribution if needed
    # in the database itself.
    field :shard_key, :integer

    timestamps()
  end

  @required_fields ~w(user_id agent_id status shard_key)a
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

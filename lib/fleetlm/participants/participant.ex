defmodule Fleetlm.Participants.Participant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "participants" do
    field :kind, :string
    field :display_name, :string
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}
    timestamps()
  end

  @required_fields ~w(id kind display_name)a
  @optional_fields ~w(status metadata)a

  def changeset(participant, attrs) do
    participant
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:kind, ["user", "agent", "system"])
    |> validate_inclusion(:status, ["active", "disabled"])
  end
end

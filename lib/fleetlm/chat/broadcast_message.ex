defmodule Fleetlm.Chat.BroadcastMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "broadcast_messages" do
    field :sender_id, :string
    field :text, :string
    field :metadata, :map
    field :created_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end

  @type t :: %__MODULE__{}

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:sender_id, :text, :metadata])
    |> validate_required([:sender_id])
  end
end

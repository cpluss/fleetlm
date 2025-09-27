defmodule Fleetlm.Sessions.ChatMessage do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fleetlm.Sessions.ChatSession
  alias Fleetlm.Participants.Participant
  alias Ulid

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "chat_messages" do
    belongs_to :session, ChatSession, type: :string
    belongs_to :sender, Participant, type: :string, foreign_key: :sender_id

    field :kind, :string
    field :content, :map, default: %{}
    field :metadata, :map, default: %{}
    field :shard_key, :integer

    timestamps(updated_at: false)
  end

  @required_fields ~w(session_id sender_id kind content metadata shard_key)a

  def changeset(message, attrs) do
    message
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:kind, ["text", "system", "tool_call"])
    |> ensure_id()
  end

  defp ensure_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, Ulid.generate())
      _ -> changeset
    end
  end
end

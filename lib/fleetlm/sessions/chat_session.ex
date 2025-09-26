defmodule Fleetlm.Sessions.ChatSession do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fleetlm.Participants.Participant

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  alias Ulid

  schema "chat_sessions" do
    belongs_to :initiator, Participant, foreign_key: :initiator_id
    belongs_to :peer, Participant, foreign_key: :peer_id
    belongs_to :agent, Participant, foreign_key: :agent_id

    field :kind, :string
    field :status, :string, default: "open"
    field :metadata, :map, default: %{}
    field :last_message_id, :string
    field :last_message_at, :utc_datetime_usec
    field :initiator_last_read_id, :string
    field :initiator_last_read_at, :utc_datetime_usec
    field :peer_last_read_id, :string
    field :peer_last_read_at, :utc_datetime_usec

    timestamps()
  end

  @required_fields ~w(initiator_id peer_id kind)a
  @optional_fields ~w(
    agent_id
    status
    metadata
    last_message_id
    last_message_at
    initiator_last_read_id
    initiator_last_read_at
    peer_last_read_id
    peer_last_read_at
  )a

  def changeset(session, attrs) do
    session
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:kind, ["human_dm", "agent_dm"])
    |> validate_inclusion(:status, ["open", "closed", "archived"])
    |> ensure_id()
  end

  defp ensure_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, Ulid.generate())
      _ -> changeset
    end
  end
end

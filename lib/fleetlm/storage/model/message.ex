defmodule FleetLM.Storage.Model.Message do
  @moduledoc """
  Model for the chat message.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "messages" do
    belongs_to :session, FleetLM.Storage.Model.Session, type: :string

    # We hardcode senders & recipients because we don't control participation
    # by default, it's up to the upstream application to manage.
    #
    # NOTE: these are not foreign keys in order to avoid writing a lot of queries
    # to multiple tables for a single message, since we don't control participation
    # we would need to _ensure_ participants are created before messages are created.
    field :sender_id, :string
    field :recipient_id, :string

    # Sequence number which dictates total order across the entire cluster.
    field :seq, :integer

    field :kind, :string
    field :content, :map, default: %{}
    field :metadata, :map, default: %{}

    # Sharding for convenience for future distribution if needed
    # in the database itself.
    field :shard_key, :integer

    timestamps(updated_at: false)
  end

  @required_fields ~w(session_id sender_id recipient_id seq kind content metadata shard_key)a

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

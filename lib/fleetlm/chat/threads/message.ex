defmodule Fleetlm.Chat.Threads.Message do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fleetlm.Chat.Threads.Thread

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @roles ~w(user agent system)
  @kinds ~w(message event broadcast)

  schema "thread_messages" do
    belongs_to :thread, Thread

    field :sender_id, :binary_id
    field :role, :string
    field :kind, :string, default: "message"
    field :shard_key, :integer
    field :text, :string
    field :metadata, :map

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:thread_id, :sender_id, :role, :kind, :text, :metadata, :shard_key])
    |> validate_required([:thread_id, :sender_id, :role, :shard_key])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:shard_key, greater_than_or_equal_to: 0, less_than: 65_536)
  end
end

defmodule Fleetlm.Chat.Threads.Participant do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fleetlm.Chat.Threads.Thread

  @primary_key false
  @foreign_key_type :binary_id
  @roles ~w(user agent system)

  schema "thread_participants" do
    belongs_to :thread, Thread, primary_key: true

    field :participant_id, :binary_id, primary_key: true
    field :role, :string
    field :joined_at, :utc_datetime_usec
    field :read_cursor_at, :utc_datetime_usec
    field :last_message_at, :utc_datetime_usec
    field :last_message_preview, :string
  end

  def changeset(participant, attrs) do
    participant
    |> cast(attrs, [
      :thread_id,
      :participant_id,
      :role,
      :joined_at,
      :read_cursor_at,
      :last_message_at,
      :last_message_preview
    ])
    |> validate_required([:thread_id, :participant_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:thread_id, :participant_id], name: "tp_unique")
  end
end

## PARTICIPANTS
# A participant is a user, agent, or system that is part of a thread.
# They have a role (user, agent, system) and a joined_at timestamp.
# They can also have a read_cursor_at timestamp, which is the last message they have read.
# They can also have a last_message_at timestamp, which is the last message they have sent.
# They can also have a last_message_preview, which is the last message they have sent.
defmodule Fleetlm.Chat.Threads.Participant do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    @roles ~w(user agent system)

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "thread_participants" do
        field :thread_id, :binary_id
        field :participant_id, :binary_id
        field :role, :string
        field :joined_at, :utc_datetime_usec
        field :read_cursor_at, :utc_datetime_usec
        field :last_message_at, :utc_datetime_usec
        field :last_message_preview, :string
    end

    def changeset(participant, attrs) do
      participant
        |> cast(attrs, [:thread_id, :participant_id, :role, :joined_at, :read_cursor_at, :last_message_at, :last_message_preview])
        |> validate_required([:thread_id, :participant_id, :role])
        |> validate_inclusion(:role, @roles)
        |> unique_constraint([:thread_id, :participant_id], name: "tp_unique")
    end
end

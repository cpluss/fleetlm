defmodule Fleetlm.Chat.Threads.Message do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    @roles ~w(user agent system)
    @kinds ~w(message event broadcast)

    schema "thread_messages" do
      field :thread_id, :binary_id
      field :sender_id, :binary_id
      field :role, :string
      field :kind, :string, default: "message"
      field :text, :string
      field :metadata, :map
      field :created_at, :utc_datetime_usec
    end

    def changeset(message, attrs) do
      message
        |> cast(attrs, [:thread_id, :sender_id, :role, :kind, :text, :metadata])
        |> validate_required([:thread_id, :sender_id, :role])
        |> validate_inclusion(:role, @roles)
        |> validate_inclusion(:kind, @kinds)
    end
end

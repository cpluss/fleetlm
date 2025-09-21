defmodule Fleetlm.Chat.Threads.Thread do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    @kinds ~w(dm room broadcast)

    schema "threads" do
      field :kind, :string
      field :dm_key, :string
      field :created_at, :utc_datetime_usec
      has_many :participants, Fleetlm.Chat.Threads.Participant
      has_many :messages, Fleetlm.Chat.Threads.Message
    end

    def changeset(thread, attrs) do
      thread
        |> cast(attrs, [:kind, :dm_key])
        |> validate_required([:kind])
        |> validate_inclusion(:kind, @kinds)
        |> maybe_require_dm_key()
        |> unique_constraint(:dm_key, name: "threads_dm_key_unique")
    end

    defp maybe_require_dm_key(changeset) do
      if get_field(changeset, :kind) == "dm" do
        changeset
        |> validate_required([:dm_key])
      else
        changeset
      end
    end
end

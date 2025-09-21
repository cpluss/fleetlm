defmodule Fleetlm.Chat.Threads.Thread do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(dm room broadcast)

  schema "threads" do
    field :kind, :string
    field :dm_key, :string

    has_many :participants, Fleetlm.Chat.Threads.Participant
    has_many :messages, Fleetlm.Chat.Threads.Message

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [:kind, :dm_key])
    |> validate_required([:kind])
    |> validate_inclusion(:kind, @kinds)
    |> maybe_require_dm_key()
    |> unique_constraint(:dm_key, name: "threads_dm_key_unique")
  end

  defp maybe_require_dm_key(%Ecto.Changeset{} = changeset) do
    if get_field(changeset, :kind) == "dm" do
      validate_required(changeset, [:dm_key])
    else
      changeset
    end
  end
end

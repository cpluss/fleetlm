defmodule Fleetlm.Chat.DmMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "dm_messages" do
    field :sender_id, :string
    field :recipient_id, :string
    field :text, :string
    field :metadata, :map
    field :shard_key, :integer
    field :created_at, :utc_datetime_usec
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:sender_id, :recipient_id, :text, :metadata, :shard_key])
    |> validate_required([:sender_id, :recipient_id])
    |> put_shard_key_if_missing()
    |> validate_required([:shard_key])
    |> validate_different_participants()
  end

  defp validate_different_participants(changeset) do
    sender_id = get_field(changeset, :sender_id)
    recipient_id = get_field(changeset, :recipient_id)

    if sender_id && recipient_id && sender_id == recipient_id do
      add_error(changeset, :recipient_id, "cannot be the same as sender")
    else
      changeset
    end
  end

  defp put_shard_key_if_missing(changeset) do
    case get_field(changeset, :shard_key) do
      nil ->
        sender_id = get_field(changeset, :sender_id)
        recipient_id = get_field(changeset, :recipient_id)

        if sender_id && recipient_id do
          dm_key = dm_key(sender_id, recipient_id)
          shard_key = :erlang.phash2(dm_key, 1024)
          put_change(changeset, :shard_key, shard_key)
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp dm_key(a, b) do
    [x, y] = Enum.sort([a, b])
    "#{x}:#{y}"
  end
end
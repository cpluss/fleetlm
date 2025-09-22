defmodule Fleetlm.Chat.DmMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "dm_messages" do
    field :sender_id, :string
    field :recipient_id, :string
    field :dm_key, :string
    field :text, :string
    field :metadata, :map
    field :shard_key, :integer
    field :created_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:sender_id, :recipient_id, :text, :metadata, :shard_key, :dm_key])
    |> validate_required([:sender_id, :recipient_id])
    |> put_dm_key_if_missing()
    |> put_shard_key_if_missing()
    |> validate_required([:dm_key, :shard_key])
    |> validate_different_participants()
  end

  defp put_dm_key_if_missing(changeset) do
    case get_field(changeset, :dm_key) do
      nil ->
        sender_id = get_field(changeset, :sender_id)
        recipient_id = get_field(changeset, :recipient_id)

        if sender_id && recipient_id do
          dm_key = generate_dm_key(sender_id, recipient_id)
          put_change(changeset, :dm_key, dm_key)
        else
          changeset
        end

      _ ->
        changeset
    end
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
        dm_key = get_field(changeset, :dm_key)

        if dm_key do
          shard_key = :erlang.phash2(dm_key, 1024)
          put_change(changeset, :shard_key, shard_key)
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  # Public function for generating dm_key
  def generate_dm_key(participant_a, participant_b) do
    [x, y] = Enum.sort([participant_a, participant_b])
    "#{x}:#{y}"
  end
end

defmodule Fastpaca.Storage.Model.Message do
  @moduledoc """
  Message model for Fastpaca contexts.

  Messages are stored in an append-only log per context.
  Each message has a monotonic sequence number within its context.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "messages" do
    field :context_id, :string             # Context this message belongs to
    field :seq, :integer                   # Per-context sequence number
    field :role, :string                   # "user" | "assistant" | "system" | "tool"
    field :parts, {:array, :map}           # Structured content [{type, ...}]
    field :metadata, :map, default: %{}    # User-defined fields

    timestamps(type: :naive_datetime_usec, updated_at: false)
  end

  @required_fields ~w(context_id seq role parts)a
  @optional_fields ~w(metadata)a

  def changeset(message, attrs) do
    message
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:role, ["user", "assistant", "system", "tool"])
    |> validate_parts()
    |> ensure_id()
  end

  defp validate_parts(changeset) do
    case get_field(changeset, :parts) do
      parts when is_list(parts) and length(parts) > 0 ->
        changeset

      _ ->
        add_error(changeset, :parts, "must be a non-empty list of message parts")
    end
  end

  defp ensure_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, Uniq.UUID.uuid7(:slug))
      _ -> changeset
    end
  end
end

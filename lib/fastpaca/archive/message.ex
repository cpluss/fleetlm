defmodule Fastpaca.Archive.Message do
  @moduledoc """
  Ecto schema for archived messages.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "messages" do
    field(:context_id, :string, primary_key: true)
    field(:seq, :integer, primary_key: true)
    field(:role, :string)
    field(:parts, :map)
    field(:metadata, :map)
    field(:token_count, :integer)
    field(:inserted_at, :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:context_id, :seq, :role, :parts, :metadata, :token_count, :inserted_at])
    |> validate_required([
      :context_id,
      :seq,
      :role,
      :parts,
      :metadata,
      :token_count,
      :inserted_at
    ])
  end
end

defmodule Fastpaca.Storage.Model.Context do
  @moduledoc """
  Context model - the core primitive for Fastpaca.

  A context contains:
  - Message log (full append-only history for users/replay)
  - Context window snapshot (token-budgeted view for LLMs)
  - Compaction policy (strategy for managing the window)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "contexts" do
    # Trigger mechanism (WHEN to compact)
    field :token_budget, :integer          # Max tokens for LLM window
    field :trigger_ratio, :float           # Compact when used_tokens > (budget * ratio)

    # Policy (HOW to compact)
    field :policy, :map                    # %{strategy: "last_n", config: %{limit: 200}}

    # State
    field :version, :integer, default: 0   # Monotonic version (bumps on append/compact)
    field :status, :string, default: "active"  # "active" | "tombstoned"
    field :metadata, :map, default: %{}    # User-defined fields

    timestamps()
  end

  @required_fields ~w(id token_budget policy)a
  @optional_fields ~w(trigger_ratio version status metadata)a

  def changeset(context, attrs) do
    context
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:token_budget, greater_than: 0)
    |> validate_number(:trigger_ratio, greater_than: 0, less_than_or_equal_to: 1)
    |> validate_inclusion(:status, ["active", "tombstoned"])
    |> validate_policy()
    |> put_default_trigger_ratio()
  end

  defp validate_policy(changeset) do
    case get_field(changeset, :policy) do
      %{"strategy" => strategy} when is_binary(strategy) ->
        changeset

      %{strategy: strategy} when is_binary(strategy) ->
        changeset

      _ ->
        add_error(changeset, :policy, "must include a strategy field")
    end
  end

  defp put_default_trigger_ratio(changeset) do
    case get_field(changeset, :trigger_ratio) do
      nil -> put_change(changeset, :trigger_ratio, 0.7)
      _ -> changeset
    end
  end
end

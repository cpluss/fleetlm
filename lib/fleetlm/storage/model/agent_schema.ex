defmodule Fleetlm.Storage.Model.AgentSchema do
  @moduledoc """
  Ecto schema for external AI agent endpoints.
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias Fleetlm.Context.Changeset, as: ContextChangeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "agents" do
    field :name, :string
    field :origin_url, :string
    field :webhook_path, :string, default: "/webhook"

    # Context management configuration
    field :context_strategy, :string, default: "last_n"
    field :context_strategy_config, :map, default: %{}

    # HTTP configuration
    field :timeout_ms, :integer, default: 30_000
    field :headers, :map, default: %{}
    field :status, :string, default: "enabled"

    # Debouncing configuration
    field :debounce_window_ms, :integer, default: 500

    timestamps()
  end

  @doc """
  Changeset for creating/updating agents.
  """
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :id,
      :name,
      :origin_url,
      :webhook_path,
      :context_strategy,
      :context_strategy_config,
      :timeout_ms,
      :headers,
      :status,
      :debounce_window_ms
    ])
    |> validate_required([:id, :name, :origin_url, :webhook_path])
    |> validate_inclusion(:status, ["enabled", "disabled"])
    |> validate_number(:timeout_ms, greater_than: 0)
    |> validate_number(:debounce_window_ms, greater_than_or_equal_to: 0)
    |> ContextChangeset.validate_strategy(:context_strategy, :context_strategy_config)
    |> unique_constraint(:id, name: :agents_pkey)
  end
end

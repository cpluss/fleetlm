defmodule Fleetlm.Agent.Schema do
  @moduledoc """
  Ecto schema for external AI agent endpoints.

  Agents are stateless HTTP endpoints that receive message history
  and return responses synchronously.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "agents" do
    field :name, :string
    field :origin_url, :string
    field :webhook_path, :string, default: "/webhook"

    # Message history configuration
    field :message_history_mode, :string, default: "tail"
    field :message_history_limit, :integer, default: 50

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
      :message_history_mode,
      :message_history_limit,
      :timeout_ms,
      :headers,
      :status,
      :debounce_window_ms
    ])
    |> validate_required([:id, :name, :origin_url, :webhook_path])
    |> validate_inclusion(:message_history_mode, ["tail", "entire", "last"])
    |> validate_inclusion(:status, ["enabled", "disabled"])
    |> validate_number(:timeout_ms, greater_than: 0)
    |> validate_number(:message_history_limit, greater_than: 0)
    |> validate_number(:debounce_window_ms, greater_than_or_equal_to: 0)
    |> unique_constraint(:id, name: :agents_pkey)
  end
end

defmodule Fleetlm.Storage.Model.AgentSchema do
  @moduledoc """
  Ecto schema for external AI agent endpoints.
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

    # Compaction configuration
    field :compaction_enabled, :boolean, default: false
    field :compaction_token_budget, :integer, default: 50_000
    field :compaction_trigger_ratio, :float, default: 0.7
    field :compaction_webhook_url, :string

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
      :debounce_window_ms,
      :compaction_enabled,
      :compaction_token_budget,
      :compaction_trigger_ratio,
      :compaction_webhook_url
    ])
    |> validate_required([:id, :name, :origin_url, :webhook_path])
    |> validate_inclusion(:message_history_mode, ["tail", "entire", "last"])
    |> validate_inclusion(:status, ["enabled", "disabled"])
    |> validate_number(:timeout_ms, greater_than: 0)
    |> validate_number(:message_history_limit, greater_than: 0)
    |> validate_number(:debounce_window_ms, greater_than_or_equal_to: 0)
    |> validate_number(:compaction_token_budget, greater_than: 0)
    |> validate_number(:compaction_trigger_ratio, greater_than: 0, less_than_or_equal_to: 1)
    |> unique_constraint(:id, name: :agents_pkey)
  end
end

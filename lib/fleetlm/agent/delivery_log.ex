defmodule Fleetlm.Agent.DeliveryLog do
  @moduledoc """
  Ecto schema for persisted agent delivery attempts.

  Each entry captures the outcome of a webhook call to an external agent,
  including status code, latency, and any error details. Logs drive the
  observability views in later phases and serve as an audit trail.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Ulid

  @primary_key {:id, :string, autogenerate: false}
  schema "agent_delivery_logs" do
    field :session_id, :string
    field :message_id, :string
    field :agent_id, :string
    field :attempt, :integer, default: 1
    field :status, :string
    field :http_status, :integer
    field :latency_ms, :integer
    field :response_excerpt, :string
    field :error_reason, :string
    timestamps(updated_at: false)
  end

  @required_fields ~w(session_id message_id agent_id status)a
  @optional_fields ~w(attempt http_status latency_ms response_excerpt error_reason)a

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:id | @required_fields ++ @optional_fields])
    |> put_default_id()
    |> validate_required(@required_fields)
  end

  defp put_default_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, Ulid.generate())
      _ -> changeset
    end
  end
end

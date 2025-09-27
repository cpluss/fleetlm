defmodule Fleetlm.Agent.AgentEndpoint do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fleetlm.Conversation.Participant
  alias Ulid

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "agent_endpoints" do
    belongs_to :agent, Participant, type: :string

    field :origin_url, :string
    field :auth_strategy, :string, default: "none"
    field :auth_value, :string
    field :headers, :map, default: %{}
    field :timeout_ms, :integer, default: 5_000
    field :retry_policy, :map, default: %{}
    field :status, :string, default: "enabled"

    timestamps()
  end

  @required_fields ~w(agent_id origin_url)a
  @optional_fields ~w(auth_strategy auth_value headers timeout_ms retry_policy status)a

  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:auth_strategy, ["none", "bearer", "hmac"])
    |> validate_inclusion(:status, ["enabled", "disabled"])
    |> validate_number(:timeout_ms, greater_than: 0)
    |> ensure_id()
  end

  defp ensure_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, Ulid.generate())
      _ -> changeset
    end
  end
end

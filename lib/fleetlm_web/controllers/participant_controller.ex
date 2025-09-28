defmodule FleetlmWeb.ParticipantController do
  use FleetlmWeb, :controller

  alias Fleetlm.Conversation.Participants

  action_fallback FleetlmWeb.FallbackController

  def index(conn, params) do
    opts =
      []
      |> maybe_put(:kind, Map.get(params, "kind"))
      |> maybe_put(:status, Map.get(params, "status"))

    participants = Participants.list_participants(opts)

    json(conn, %{participants: Enum.map(participants, &serialize/1)})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, participant} <- Participants.get_participant(id) do
      json(conn, %{participant: serialize(participant)})
    end
  end

  def create(conn, params) do
    with {:ok, id} <- fetch_param(params, "id"),
         {:ok, kind} <- fetch_param(params, "kind"),
         {:ok, display_name} <- fetch_param(params, "display_name"),
         attrs <-
           %{}
           |> Map.put(:id, id)
           |> Map.put(:kind, kind)
           |> Map.put(:display_name, display_name)
           |> maybe_put_optional(:status, Map.get(params, "status"))
           |> maybe_put_optional(:metadata, Map.get(params, "metadata")),
         {:ok, participant} <- Participants.create_participant(attrs) do
      conn
      |> put_status(:created)
      |> json(%{participant: serialize(participant)})
    end
  end

  defp serialize(participant) do
    %{
      id: participant.id,
      kind: participant.kind,
      display_name: participant.display_name,
      status: participant.status,
      metadata: participant.metadata,
      inserted_at: encode_datetime(participant.inserted_at),
      updated_at: encode_datetime(participant.updated_at)
    }
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)

  defp fetch_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      {:ok, value} ->
        {:error,
         %ArgumentError{message: "#{key} must be a non-empty string (got #{inspect(value)})"}}

      :error ->
        {:error, %ArgumentError{message: "#{key} is required"}}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_optional(map, _key, nil), do: map
  defp maybe_put_optional(map, key, value), do: Map.put(map, key, value)
end

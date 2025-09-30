defmodule FleetlmWeb.SessionChannel do
  @moduledoc """
  Socket channel for streaming messages within a session.
  """

  use FleetlmWeb, :channel

  alias Fleetlm.Runtime.Router
  alias FleetLM.Storage.Model.Session

  @impl true
  def join(
        "session:" <> session_id,
        _params,
        %{assigns: %{participant_id: participant_id}} = socket
      ) do
    with {:ok, session} <- authorize(session_id, participant_id),
         {:ok, result} <- Router.join(session_id, participant_id, last_seq: 0, limit: 100) do
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "session:" <> session_id)

      response = %{session_id: session_id, messages: result.messages}

      {:ok, response, assign(socket, :session, session)}
    else
      {:error, reason} -> {:error, %{reason: error_reason(reason)}}
    end
  end

  @impl true
  def handle_info({:session_message, payload}, socket) do
    push(socket, "message", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in(
        "send",
        %{"content" => content},
        %{assigns: %{session: session, participant_id: participant_id}} = socket
      ) do
    sender_id = participant_id
    kind = Map.get(content, "kind", "text")
    message_content = Map.get(content, "content", %{})
    metadata = Map.get(content, "metadata", %{})

    case Router.append_message(session.id, sender_id, kind, message_content, metadata) do
      {:ok, _message} -> {:noreply, socket}
      {:error, reason} -> {:reply, {:error, %{error: inspect(reason)}}, socket}
    end
  end

  defp authorize(session_id, participant_id) do
    session = Fleetlm.Repo.get(Session, session_id)

    case session do
      nil ->
        {:error, :not_found}

      %Session{} = session ->
        if participant_id in [session.sender_id, session.recipient_id] do
          {:ok, session}
        else
          {:error, :unauthorized}
        end
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp error_reason(:unauthorized), do: "unauthorized"
  defp error_reason(:not_found), do: "not found"
  defp error_reason(other), do: inspect(other)
end

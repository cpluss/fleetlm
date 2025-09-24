defmodule FleetlmWeb.UserSocket do
  use Phoenix.Socket

  channel "conversation:*", FleetlmWeb.ConversationChannel
  channel "inbox:*", FleetlmWeb.InboxChannel

  @impl true
  def connect(%{"participant_id" => participant_id}, socket, _connect_info)
      when is_binary(participant_id) do
    socket = ensure_transport(socket)
    {:ok, assign(socket, :participant_id, participant_id)}
  end

  def connect(%{"participant_id" => participant_id}, socket, _info) do
    socket = ensure_transport(socket)
    {:ok, assign(socket, :participant_id, to_string(participant_id))}
  end

  def connect(_params, _socket, _info), do: :error

  @impl true
  def id(socket), do: "participant_socket:" <> socket.assigns.participant_id

  defp ensure_transport(%Phoenix.Socket{transport: nil} = socket) do
    %{socket | transport: :test}
  end

  defp ensure_transport(socket), do: socket
end

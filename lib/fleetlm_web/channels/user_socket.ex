defmodule FleetlmWeb.UserSocket do
  use Phoenix.Socket

  channel "session:*", FleetlmWeb.SessionChannel
  channel "inbox:*", FleetlmWeb.InboxChannel

  @impl true
  def connect(%{"user_id" => user_id}, socket, _connect_info) when is_binary(user_id) do
    socket = ensure_transport(socket)
    {:ok, assign(socket, :user_id, user_id)}
  end

  def connect(%{"user_id" => user_id}, socket, _info) do
    socket = ensure_transport(socket)
    {:ok, assign(socket, :user_id, to_string(user_id))}
  end

  def connect(%{"agent_id" => agent_id}, socket, info) do
    connect(%{"user_id" => agent_id}, socket, info)
  end

  def connect(_params, _socket, _info), do: :error

  @impl true
  def id(socket), do: "user_socket:" <> socket.assigns.user_id

  defp ensure_transport(%Phoenix.Socket{transport: nil} = socket) do
    %{socket | transport: :test}
  end

  defp ensure_transport(socket), do: socket
end

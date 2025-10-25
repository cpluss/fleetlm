defmodule FastpacaWeb.ContextChannel do
  @moduledoc """
  WebSocket channel for context updates.

  Clients join `context:CONTEXT_ID` to receive real-time updates.

  ## Events (from server to client)

  1. "message" - New message appended
     %{seq: 42, role: "user", parts: [...], version: 42}

  2. "compaction" - Context compacted
     %{version: 43, strategy: "last_n", compacted_range: [1, 340]}

  That's it! KISS.
  """

  use Phoenix.Channel

  @impl true
  def join("context:" <> context_id, _params, socket) do
    # Subscribe to PubSub for this context
    Phoenix.PubSub.subscribe(Fastpaca.PubSub, "context:#{context_id}")

    {:ok, assign(socket, :context_id, context_id)}
  end

  @impl true
  def handle_info({:message, payload}, socket) do
    push(socket, "message", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:compaction, payload}, socket) do
    push(socket, "compaction", payload)
    {:noreply, socket}
  end
end

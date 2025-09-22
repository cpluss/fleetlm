defmodule FleetlmWeb.ThreadChannel do
  use FleetlmWeb, :channel

  alias Fleetlm.Cache
  alias Fleetlm.Chat
  alias Phoenix.PubSub

  @pubsub Fleetlm.PubSub
  @history_limit 40

  @impl true
  def join("thread:" <> thread_id, _params, socket) do
    participant_id = socket.assigns.participant_id

    with true <- Chat.participant_in_thread?(thread_id, participant_id),
         {:ok, _pid} <- Chat.ensure_thread_runtime(thread_id) do
      :ok = PubSub.subscribe(@pubsub, "thread:" <> thread_id)

      # Try cache first, fallback to database
      history =
        case Cache.get_messages(thread_id, @history_limit) do
          nil ->
            thread_id
            |> Chat.list_thread_messages(limit: @history_limit)
            |> Enum.reverse()

          cached_messages ->
            cached_messages |> Enum.reverse()
        end

      history = Enum.map(history, &serialize_message/1)

      {:ok, %{"messages" => history}, assign(socket, :thread_id, thread_id)}
    else
      false -> {:error, %{reason: "unauthorized"}}
      {:error, reason} -> {:error, %{reason: inspect(reason)}}
    end
  end

  @impl true
  def handle_in("message:new", payload, socket) do
    attrs =
      payload
      |> Map.put("thread_id", socket.assigns.thread_id)
      |> Map.put("sender_id", socket.assigns.participant_id)

    case Chat.dispatch_message(attrs) do
      {:ok, message} ->
        {:reply, {:ok, serialize_message(message)}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_info({:thread_message, message}, socket) do
    push(socket, "message", serialize_message(message))
    {:noreply, socket}
  end

  defp serialize_message(message) do
    %{
      "id" => message.id,
      "thread_id" => message.thread_id,
      "sender_id" => message.sender_id,
      "role" => message.role,
      "kind" => message.kind,
      "text" => message.text,
      "metadata" => message.metadata,
      "created_at" => encode_datetime(message.created_at)
    }
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)
end

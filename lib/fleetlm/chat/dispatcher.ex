defmodule Fleetlm.Chat.Dispatcher do
  @moduledoc """
  Entry point for chat commands. Transports call into this module which
  coordinates the chat runtime processes.
  """

  alias Fleetlm.Chat.{
    ConversationServer,
    ConversationSupervisor,
    DmKey,
    InboxServer,
    InboxSupervisor,
    Storage
  }

  @type send_message_attrs :: %{
          required(:sender_id) => String.t(),
          optional(:recipient_id) => String.t(),
          optional(:dm_key) => String.t(),
          optional(:text) => String.t() | nil,
          optional(:metadata) => map()
        }

  @spec open_conversation(String.t(), String.t(), String.t() | nil) ::
          {:ok, %{dm_key: String.t(), initial_message: Fleetlm.Chat.Event.DmMessage.t() | nil}}
          | {:error, term()}
  def open_conversation(participant_a, participant_b, initial_text \\ nil) do
    dm_key = DmKey.build(participant_a, participant_b)

    with {:ok, _pid} <- ConversationSupervisor.ensure_started(dm_key),
         {:ok, _} <- InboxSupervisor.ensure_started(participant_a),
         {:ok, _} <- InboxSupervisor.ensure_started(participant_b) do
      ConversationServer.ensure_open(dm_key, participant_a, participant_b, initial_text)
    end
  end

  @spec send_message(send_message_attrs()) ::
          {:ok, Fleetlm.Chat.Event.DmMessage.t()} | {:error, term()}
  def send_message(attrs) when is_map(attrs) do
    with {:ok, dm} <- resolve_dm(attrs),
         {:ok, _pid} <- ConversationSupervisor.ensure_started(dm.key),
         {:ok, _} <- InboxSupervisor.ensure_started(dm.first),
         {:ok, _} <- InboxSupervisor.ensure_started(dm.second) do
      metadata = Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}
      text = Map.get(attrs, :text) || Map.get(attrs, "text")
      sender_id = Map.fetch!(attrs, :sender_id)

      recipient_id =
        Map.get(attrs, :recipient_id) || Map.get(attrs, "recipient_id") ||
          DmKey.other_participant(dm, sender_id)

      ConversationServer.send_message(dm.key, sender_id, recipient_id, text, metadata)
    end
  end

  @spec convo_history(String.t(), keyword()) :: [Fleetlm.Chat.Event.DmMessage.t()]
  def convo_history(dm_key, opts \\ []) do
    with {:ok, _pid} <- ConversationSupervisor.ensure_started(dm_key) do
      ConversationServer.history(dm_key, opts)
    else
      {:error, reason} -> raise "failed to load history: #{inspect(reason)}"
    end
  end

  @spec inbox_snapshot(String.t()) :: [Fleetlm.Chat.Event.DmActivity.t()]
  def inbox_snapshot(participant_id) do
    with {:ok, _pid} <- InboxSupervisor.ensure_started(participant_id) do
      InboxServer.snapshot(participant_id)
    else
      {:error, reason} -> raise "failed to load inbox: #{inspect(reason)}"
    end
  end

  @spec list_broadcast_messages(keyword()) :: [Fleetlm.Chat.BroadcastMessage.t()]
  def list_broadcast_messages(opts \\ []) do
    Storage.list_broadcast_messages(opts)
  end

  @spec send_broadcast(String.t(), String.t() | nil, map()) ::
          {:ok, Fleetlm.Chat.Event.BroadcastMessage.t()} | {:error, term()}
  def send_broadcast(sender_id, text, metadata \\ %{}) do
    case Storage.persist_broadcast_message(sender_id, text, metadata) do
      {:ok, message} ->
        event = Fleetlm.Chat.Event.BroadcastMessage.from_message(message)
        Fleetlm.Chat.Events.publish_broadcast_message(event)
        {:ok, event}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_dm(%{dm_key: dm_key}) when is_binary(dm_key), do: {:ok, DmKey.parse!(dm_key)}
  defp resolve_dm(%{"dm_key" => dm_key}) when is_binary(dm_key), do: {:ok, DmKey.parse!(dm_key)}

  defp resolve_dm(%{sender_id: sender_id, recipient_id: recipient_id})
       when is_binary(sender_id) and is_binary(recipient_id) do
    {:ok, DmKey.parse!(DmKey.build(sender_id, recipient_id))}
  rescue
    e -> {:error, e}
  end

  defp resolve_dm(%{"sender_id" => sender_id, "recipient_id" => recipient_id})
       when is_binary(sender_id) and is_binary(recipient_id) do
    resolve_dm(%{sender_id: sender_id, recipient_id: recipient_id})
  end

  defp resolve_dm(_), do: {:error, :invalid_dm_key}
end

defmodule Fleetlm.Chat do
  @moduledoc """
  Canonical Chat runtime API. All public chat operations flow through this module.
  """

  alias Fleetlm.Chat.{ConversationServer, ConversationSupervisor, DmKey, Event, Storage}

  @type send_message_attrs :: %{
          required(:sender_id) => String.t(),
          optional(:recipient_id) => String.t(),
          optional(:dm_key) => String.t(),
          optional(:text) => String.t() | nil,
          optional(:metadata) => map()
        }

  ## DM operations

  @doc """
  Deterministically generate a DM key for two participants.
  """
  @spec generate_dm_key(String.t(), String.t()) :: String.t()
  def generate_dm_key(participant_a, participant_b) do
    DmKey.build(participant_a, participant_b)
  end

  @doc """
  Send a DM message using map attributes.
  """
  @spec send_message(send_message_attrs()) :: {:ok, Event.DmMessage.t()} | {:error, term()}
  def send_message(attrs) when is_map(attrs) do
    with {:ok, dm} <- resolve_dm(attrs),
         {:ok, _pid} <- ConversationSupervisor.ensure_started(dm.key) do
      metadata = Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}
      text = Map.get(attrs, :text) || Map.get(attrs, "text")
      sender_id = Map.get(attrs, :sender_id) || Map.get(attrs, "sender_id")

      with {:ok, sender_id} <- ensure_binary(sender_id) do
        recipient_id =
          Map.get(attrs, :recipient_id) ||
            Map.get(attrs, "recipient_id") ||
            DmKey.other_participant(dm, sender_id)

        ConversationServer.send_message(dm.key, sender_id, recipient_id, text, metadata)
      end
    end
  end

  @doc """
  Convenience version of `send_message/1` using positional arguments.
  """
  @spec send_message(String.t(), String.t(), String.t(), map()) ::
          {:ok, Event.DmMessage.t()} | {:error, term()}
  def send_message(sender_id, recipient_id, text, metadata \\ %{}) do
    send_message(%{
      sender_id: sender_id,
      recipient_id: recipient_id,
      text: text,
      metadata: metadata
    })
  end

  @doc """
  Retrieve the message history for a conversation.
  """
  @spec get_messages(String.t(), keyword()) :: {:ok, [Event.DmMessage.t()]} | {:error, term()}
  def get_messages(dm_key, opts \\ []) do
    with {:ok, dm} <- resolve_dm(%{dm_key: dm_key}),
         {:ok, _pid} <- ConversationSupervisor.ensure_started(dm.key) do
      {:ok, ConversationServer.history(dm.key, opts)}
    end
  end

  @doc """
  Stub for future read-state handling.
  """
  @spec mark_read(String.t(), String.t(), keyword()) :: {:error, :not_implemented}
  def mark_read(_dm_key, _participant_id, _opts \\ []), do: {:error, :not_implemented}

  @doc false
  @spec inbox_snapshot(String.t()) :: [Event.DmActivity.t()]
  def inbox_snapshot(participant_id) do
    Storage.list_dm_threads(participant_id)
    |> Enum.map(fn thread ->
      %Event.DmActivity{
        participant_id: participant_id,
        dm_key: thread.dm_key,
        other_participant_id: thread.other_participant_id,
        last_sender_id: nil,
        last_message_text: nil,
        last_message_at: thread.last_message_at,
        unread_count: 0
      }
    end)
  end

  ## Runtime coordination

  @doc """
  Touch a conversation process to keep it alive.
  """
  @spec heartbeat(String.t()) :: :ok | {:error, term()}
  def heartbeat(dm_key) do
    case ConversationSupervisor.ensure_started(dm_key) do
      {:ok, _pid} ->
        ConversationServer.heartbeat(dm_key)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Broadcast operations

  @spec send_broadcast_message(String.t(), String.t() | nil, map()) ::
          {:ok, Event.BroadcastMessage.t()} | {:error, term()}
  def send_broadcast_message(sender_id, text, metadata \\ %{}) do
    case Storage.persist_broadcast_message(sender_id, text, metadata) do
      {:ok, message} ->
        event = Event.BroadcastMessage.from_message(message)
        Fleetlm.Chat.Events.publish_broadcast_message(event)
        {:ok, event}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec list_broadcast_messages(keyword()) :: [Event.BroadcastMessage.t()]
  def list_broadcast_messages(opts \\ []) do
    Storage.list_broadcast_messages(opts)
    |> Enum.map(&Event.BroadcastMessage.from_message/1)
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

  defp ensure_binary(value) when is_binary(value), do: {:ok, value}
  defp ensure_binary(nil), do: {:error, :missing_sender_id}
  defp ensure_binary(value), do: {:ok, to_string(value)}
end

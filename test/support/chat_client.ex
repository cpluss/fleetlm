defmodule Fleetlm.ChatCase.Client do
  @moduledoc false

  alias Fleetlm.Chat
  alias Fleetlm.Chat.InboxServer
  alias FleetlmWeb.{ConversationChannel, InboxChannel, UserSocket}
  alias Phoenix.ChannelTest

  defstruct [:participant_id, :socket, inbox: nil, conversations: %{}]

  @type t :: %__MODULE__{
          participant_id: String.t(),
          socket: Phoenix.Socket.t(),
          inbox: %{socket: Phoenix.Socket.t(), topic: String.t(), join_ref: String.t()} | nil,
          conversations: %{
            optional(String.t()) => %{
              socket: Phoenix.Socket.t(),
              topic: String.t(),
              join_ref: String.t()
            }
          }
        }

  @spec start(String.t()) :: {:ok, t()} | {:error, term()}
  def start(participant_id) when is_binary(participant_id) do
    params = %{"participant_id" => participant_id}

    case ChannelTest.__connect__(FleetlmWeb.Endpoint, UserSocket, params, []) do
      {:ok, socket} ->
        {:ok,
         %__MODULE__{
           participant_id: participant_id,
           socket: socket,
           inbox: nil,
           conversations: %{}
         }}

      other ->
        other
    end
  end

  @spec join_inbox(t()) :: {:ok, t(), map()} | {:error, term()}
  def join_inbox(%__MODULE__{} = client) do
    topic = inbox_topic(client.participant_id)

    case ChannelTest.subscribe_and_join(client.socket, InboxChannel, topic, %{}) do
      {:ok, reply, inbox_socket} ->
        meta = %{socket: inbox_socket, topic: topic, join_ref: inbox_socket.join_ref}
        {:ok, %{client | socket: inbox_socket, inbox: meta}, reply}

      {:error, _} = error ->
        error
    end
  end

  @spec join_conversation(t(), binary() | {:dm_key, String.t()} | :broadcast) ::
          {:ok, t(), map()} | {:error, term()}
  def join_conversation(%__MODULE__{} = client, target) do
    {dm_key, topic} = resolve_conversation_target(client, target)

    case ChannelTest.subscribe_and_join(client.socket, ConversationChannel, topic, %{}) do
      {:ok, reply, conversation_socket} ->
        reply_dm_key = reply["dm_key"] || dm_key

        meta = %{
          socket: conversation_socket,
          topic: topic,
          join_ref: conversation_socket.join_ref
        }

        client =
          client
          |> Map.put(:socket, conversation_socket)
          |> Map.update!(:conversations, &Map.put(&1, reply_dm_key, meta))

        {:ok, client, reply}

      {:error, _} = error ->
        error
    end
  end

  @spec dm_key(t(), String.t()) :: String.t()
  def dm_key(%__MODULE__{participant_id: participant_id}, other_participant) do
    Chat.generate_dm_key(participant_id, other_participant)
  end

  @spec send_message(t(), String.t(), String.t(), map()) ::
          {:ok, Chat.Events.DmMessage.t()} | {:error, term()}
  def send_message(%__MODULE__{} = client, recipient_id, text, metadata \\ %{}) do
    Chat.send_message(%{
      sender_id: client.participant_id,
      recipient_id: recipient_id,
      text: text,
      metadata: metadata
    })
  end

  @spec send_broadcast(t(), String.t(), map()) ::
          {:ok, Chat.Events.BroadcastMessage.t()} | {:error, term()}
  def send_broadcast(%__MODULE__{} = client, text, metadata \\ %{}) do
    Chat.send_broadcast_message(client.participant_id, text, metadata)
  end

  @spec flush_inbox(t()) :: :ok
  def flush_inbox(%__MODULE__{} = client) do
    InboxServer.flush(client.participant_id)
  end

  @spec wait_for_message(t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :timeout} | {:error, :not_joined}
  def wait_for_message(%__MODULE__{} = client, dm_key, opts \\ []) do
    case Map.fetch(client.conversations, dm_key) do
      :error ->
        {:error, :not_joined}

      {:ok, meta} ->
        timeout = Keyword.get(opts, :timeout, 500)
        attempts = Keyword.get(opts, :attempts, 1)
        match_fun = Keyword.get(opts, :match)
        do_wait_for_message(meta, timeout, attempts, match_fun, [])
    end
  end

  @spec wait_for_inbox_update(t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :timeout} | {:error, :no_inbox}
  def wait_for_inbox_update(%__MODULE__{} = client, dm_key, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 500)
    attempts = Keyword.get(opts, :attempts, 5)
    match_fun = Keyword.get(opts, :match)

    case inbox_meta(client) do
      nil -> {:error, :no_inbox}
      _ -> do_wait_for_inbox_update(client, dm_key, timeout, attempts, match_fun)
    end
  end

  @spec wait_for_inbox_updates(t(), keyword()) ::
          {:ok, [map()]} | {:error, :timeout} | {:error, :no_inbox}
  def wait_for_inbox_updates(%__MODULE__{} = client, opts \\ []) do
    meta = inbox_meta(client)

    case meta do
      nil ->
        {:error, :no_inbox}

      %{topic: _topic} ->
        timeout = Keyword.get(opts, :timeout, 500)
        attempts = Keyword.get(opts, :attempts, 3)
        do_wait_for_inbox_updates(meta, timeout, attempts, [])
    end
  end

  @spec close_inbox(t()) :: {:ok, t()} | {:error, :no_inbox}
  def close_inbox(%__MODULE__{inbox: nil}), do: {:error, :no_inbox}

  def close_inbox(%__MODULE__{} = client) do
    Process.unlink(client.inbox.socket.channel_pid)
    :ok = ChannelTest.close(client.inbox.socket)
    {:ok, %{client | inbox: nil}}
  end

  @spec close_conversation(t(), String.t()) :: {:ok, t()} | {:error, :not_joined}
  def close_conversation(%__MODULE__{} = client, dm_key) when is_binary(dm_key) do
    case Map.pop(client.conversations, dm_key) do
      {nil, _} ->
        {:error, :not_joined}

      {meta, conversations} ->
        Process.unlink(meta.socket.channel_pid)
        :ok = ChannelTest.close(meta.socket)
        {:ok, %{client | conversations: conversations}}
    end
  end

  @spec find_inbox_update([map()], String.t()) :: map() | nil
  def find_inbox_update(updates, dm_key) when is_list(updates) and is_binary(dm_key) do
    Enum.find(updates, fn update -> update["dm_key"] == dm_key end)
  end

  defp inbox_meta(%__MODULE__{inbox: inbox}), do: inbox

  defp do_wait_for_message(_meta, _timeout, 0, _match_fun, buffer) do
    requeue(buffer)
    {:error, :timeout}
  end

  defp do_wait_for_message(meta, timeout, attempts, match_fun, buffer) do
    receive do
      %Phoenix.Socket.Message{
        event: "message",
        topic: topic,
        join_ref: join_ref,
        payload: payload
      } = msg ->
        cond do
          topic == meta.topic and join_ref == meta.join_ref and
              (is_nil(match_fun) or match_fun.(payload)) ->
            requeue(buffer)
            {:ok, payload}

          topic == meta.topic and join_ref == meta.join_ref ->
            do_wait_for_message(meta, timeout, attempts - 1, match_fun, buffer)

          true ->
            do_wait_for_message(meta, timeout, attempts, match_fun, [msg | buffer])
        end

      %Phoenix.Socket.Message{} = msg ->
        do_wait_for_message(meta, timeout, attempts, match_fun, [msg | buffer])
    after
      timeout ->
        do_wait_for_message(meta, timeout, attempts - 1, match_fun, buffer)
    end
  end

  defp do_wait_for_inbox_updates(_meta, _timeout, 0, buffer) do
    requeue(buffer)
    {:error, :timeout}
  end

  defp do_wait_for_inbox_updates(meta, timeout, attempts, buffer) do
    receive do
      %Phoenix.Socket.Message{event: "tick", topic: topic, join_ref: join_ref, payload: payload} =
          msg ->
        if topic == meta.topic and join_ref == meta.join_ref do
          requeue(buffer)
          updates = Map.get(payload, "updates", [])
          {:ok, updates}
        else
          do_wait_for_inbox_updates(meta, timeout, attempts, [msg | buffer])
        end

      %Phoenix.Socket.Message{} = msg ->
        do_wait_for_inbox_updates(meta, timeout, attempts, [msg | buffer])
    after
      timeout ->
        do_wait_for_inbox_updates(meta, timeout, attempts - 1, buffer)
    end
  end

  defp do_wait_for_inbox_update(_client, _dm_key, _timeout, 0, _match_fun), do: {:error, :timeout}

  defp do_wait_for_inbox_update(client, dm_key, timeout, attempts, match_fun) do
    case wait_for_inbox_updates(client, timeout: timeout, attempts: 1) do
      {:ok, updates} ->
        case find_inbox_update(updates, dm_key) do
          nil ->
            do_wait_for_inbox_update(client, dm_key, timeout, attempts - 1, match_fun)

          update ->
            if match_fun && not match_fun.(update) do
              do_wait_for_inbox_update(client, dm_key, timeout, attempts - 1, match_fun)
            else
              {:ok, update}
            end
        end

      {:error, :timeout} ->
        do_wait_for_inbox_update(client, dm_key, timeout, attempts - 1, match_fun)

      {:error, :no_inbox} ->
        {:error, :no_inbox}
    end
  end

  defp resolve_conversation_target(_client, :broadcast) do
    {"broadcast", conversation_topic("broadcast")}
  end

  defp resolve_conversation_target(_client, {:dm_key, dm_key}) when is_binary(dm_key) do
    {dm_key, conversation_topic(dm_key)}
  end

  defp resolve_conversation_target(%__MODULE__{participant_id: participant_id}, other_participant)
       when is_binary(other_participant) do
    dm_key = Chat.generate_dm_key(participant_id, other_participant)
    {dm_key, conversation_topic(dm_key)}
  end

  defp conversation_topic("broadcast"), do: "conversation:broadcast"
  defp conversation_topic(dm_key) when is_binary(dm_key), do: "conversation:" <> dm_key

  defp inbox_topic(participant_id), do: "inbox:" <> participant_id

  defp requeue(messages) do
    messages
    |> Enum.reverse()
    |> Enum.each(&send(self(), &1))
  end
end

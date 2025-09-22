defmodule Fleetlm.TestClient do
  @moduledoc """
  Lightweight Phoenix channel client for manual testing.

  Usage:

      mix run scripts/test_client.exs -- --participant-id <uuid>

  Starts a websocket connection, joins the participant channel, and
  automatically subscribes to threads as metadata updates arrive.
  """

  alias Fleetlm.TestClient.Socket

  def main(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        switches: [participant_id: :string, url: :string],
        aliases: [p: :participant_id, u: :url]
      )

    extras = parse_positional_args(rest)

    participant_id =
      opts[:participant_id] || Map.get(extras, "participant_id") ||
        System.get_env("PARTICIPANT_ID") || Ecto.UUID.generate()

    base_url =
      opts[:url] || Map.get(extras, "url") ||
        System.get_env("TEST_CLIENT_SOCKET_URL") ||
        "ws://localhost:4000/socket/websocket"

    url = build_url(base_url, participant_id)

    name = Socket.name(participant_id)

    case Socket.start_link(url, participant_id: participant_id, owner: self(), name: name) do
      {:ok, pid} ->
        IO.puts("\nConnected as #{participant_id}")

        IO.puts(
          "Commands: list | dm <participant_id> [message] | send <dm_key> <message> | read <dm_key> | quit\n"
        )

        input_loop(pid)

      {:error, {:already_started, _}} ->
        IO.puts("Client already running for #{participant_id}, reusing process")

        case Socket.whereis(participant_id) do
          nil -> Mix.raise("client process not found")
          pid -> input_loop(pid)
        end

      {:error, reason} ->
        Mix.raise("failed to start client: #{inspect(reason)}")
    end
  end

  defp build_url(url, participant_id) do
    uri = URI.parse(url)

    params =
      (uri.query || "")
      |> URI.decode_query(%{})
      |> Map.put("participant_id", participant_id)
      |> URI.encode_query()

    %{uri | query: params} |> URI.to_string()
  end

  defp input_loop(client) do
    case IO.gets("> ") do
      :eof ->
        WebSockex.cast(client, :stop)
        :ok

      {:error, _} ->
        WebSockex.cast(client, :stop)
        :ok

      line ->
        line
        |> String.trim()
        |> handle_command(client)

        input_loop(client)
    end
  end

  defp handle_command("", _client), do: :ok

  defp handle_command("help", _client) do
    IO.puts(
      "Commands: list | dm <participant_id> [message] | send <dm_key> <message> | read <dm_key> | quit"
    )
  end

  defp handle_command("list", client) do
    WebSockex.cast(client, {:list, self()})

    receive do
      {:dm_list, rows} ->
        Enum.each(rows, &IO.puts/1)
    after
      1_000 -> IO.puts("timeout waiting for list reply")
    end
  end

  defp handle_command("quit", client) do
    WebSockex.cast(client, :stop)
    System.halt(0)
  end

  defp handle_command("read " <> rest, client) do
    dm_key = String.trim(rest)

    if dm_key == "" do
      IO.puts("usage: read <dm_key>")
    else
      WebSockex.cast(client, {:mark_read, dm_key})
    end
  end

  defp handle_command("dm " <> rest, client) do
    case String.split(rest, ~r/\s+/, parts: 2) do
      [participant_id] when participant_id not in [nil, ""] ->
        WebSockex.cast(client, {:create_dm, participant_id, nil})

      [participant_id, message]
      when participant_id not in [nil, ""] and message not in [nil, ""] ->
        WebSockex.cast(client, {:create_dm, participant_id, message})

      _ ->
        IO.puts("usage: dm <participant_id> [message]")
    end
  end

  defp handle_command("send " <> rest, client) do
    case String.split(rest, ~r/\s+/, parts: 2) do
      [dm_key, message] when message not in [nil, ""] ->
        WebSockex.cast(client, {:send_message, dm_key, message})

      _ ->
        IO.puts("usage: send <dm_key> <message>")
    end
  end

  defp handle_command(cmd, _client) do
    IO.puts("unknown command: #{cmd}")
  end

  defp parse_positional_args(args) do
    {acc, awaiting} =
      Enum.reduce(args, {%{}, nil}, fn
        arg, {map, nil} ->
          case String.split(arg, "=", parts: 2) do
            [key, value] -> {Map.put(map, key, value), nil}
            _ -> {map, arg}
          end

        arg, {map, key} ->
          {Map.put(map, key, arg), nil}
      end)

    case awaiting do
      nil -> acc
      _ -> acc
    end
  end
end

defmodule Fleetlm.TestClient.Socket do
  use WebSockex

  require Logger

  def name(participant_id), do: {:global, {__MODULE__, participant_id}}

  def whereis(participant_id) do
    case :global.whereis_name(name(participant_id)) do
      :undefined -> nil
      pid -> pid
    end
  end

  def start_link(url, opts) do
    participant_id = Keyword.fetch!(opts, :participant_id)
    owner = Keyword.get(opts, :owner, self())
    name = Keyword.get(opts, :name, name(participant_id))

    state = %{
      participant_id: participant_id,
      owner: owner,
      ref: 1,
      pending: %{},
      joined_dms: MapSet.new(),
      dm_threads: %{},
      unreads: %{},
      heartbeat_ref: nil
    }

    WebSockex.start_link(url, __MODULE__, state, name: name)
  end

  @impl true
  def handle_connect(_conn, state) do
    send(self(), :join_participant)
    {:ok, schedule_heartbeat(state)}
  end

  @impl true
  def handle_frame({:text, payload}, state) do
    case Jason.decode(payload) do
      {:ok, message} ->
        process_message(message, state)

      {:error, _} ->
        IO.puts("[client] failed to decode frame: #{payload}")
        {:ok, state}
    end
  end

  @impl true
  def handle_cast({:create_dm, participant_id, message}, state) do
    {state, frame} = create_dm(state, participant_id, message)
    reply_with_frames(state, [frame])
  end

  def handle_cast({:send_message, dm_key, text}, state) do
    {state, frame} = push_message(state, dm_key, text)
    reply_with_frames(state, [frame])
  end

  def handle_cast({:list, caller}, state) do
    rows =
      state.dm_threads
      |> Enum.map(fn {dm_key, meta} ->
        unread = Map.get(state.unreads, dm_key, 0)
        preview = Map.get(meta, "last_message_text") || "(none)"
        timestamp = Map.get(meta, "last_message_at") || "-"
        other_participant = Map.get(meta, "other_participant_id") || "?"
        "#{dm_key} | #{other_participant} | unread=#{unread} | last=#{preview} @ #{timestamp}"
      end)
      |> Enum.sort()

    send(caller, {:dm_list, rows})
    {:ok, state}
  end

  def handle_cast({:mark_read, dm_key}, state) do
    unreads = Map.put(state.unreads, dm_key, 0)
    {:ok, %{state | unreads: unreads}}
  end

  def handle_cast({:get_state, caller}, state) do
    snapshot = Map.take(state, [:dm_threads, :unreads, :joined_dms])
    send(caller, {:client_state, snapshot})
    {:ok, state}
  end

  def handle_cast(:stop, state) do
    {:close, 1000, "client requested", state}
  end

  @impl true
  def handle_info(:join_participant, state) do
    {state, frame} = join_participant(state)
    reply_with_frames(state, [frame])
  end

  @impl true
  def handle_info(:heartbeat, state) do
    {state, frame} = heartbeat(state)
    reply_with_frames(schedule_heartbeat(state), [frame])
  end

  def handle_info({:send_frames, frames}, state) do
    reply_with_frames(state, frames)
  end

  def handle_info(msg, state) do
    Logger.debug("socket info #{inspect(msg)}")
    {:ok, state}
  end

  ### Internal helpers

  defp schedule_heartbeat(state) do
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)
    %{state | heartbeat_ref: Process.send_after(self(), :heartbeat, 25_000)}
  end

  defp next_ref(state) do
    ref = Integer.to_string(state.ref)
    {%{state | ref: state.ref + 1}, ref}
  end

  defp join_participant(state) do
    {state, ref} = next_ref(state)
    frame = encode_message("participant:#{state.participant_id}", "phx_join", %{}, ref)
    state = put_pending(state, ref, {:join_participant})
    {state, {:text, frame}}
  end

  defp heartbeat(state) do
    {state, ref} = next_ref(state)
    frame = encode_message("phoenix", "heartbeat", %{}, ref)
    {state, {:text, frame}}
  end

  defp create_dm(state, participant_id, message) do
    payload = %{"participant_id" => participant_id, "message" => message}
    {state, ref} = next_ref(state)
    frame = encode_message("participant:#{state.participant_id}", "dm:create", payload, ref)
    state = put_pending(state, ref, {:create_dm, participant_id, message})
    {state, {:text, frame}}
  end

  defp push_message(state, dm_key, text) do
    payload = %{"text" => text}
    {state, ref} = next_ref(state)
    frame = encode_message("dm:#{dm_key}", "message:new", payload, ref)
    state = put_pending(state, ref, {:push, dm_key})
    {state, {:text, frame}}
  end

  defp put_pending(state, ref, value) do
    %{state | pending: Map.put(state.pending, ref, value)}
  end

  defp process_message(%{"event" => "phx_reply", "ref" => ref} = message, state) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        {:ok, state}

      {action, pending} ->
        state = %{state | pending: pending}
        handle_reply(action, message, state)
    end
  end

  defp process_message(%{"topic" => topic, "event" => "tick", "payload" => payload}, state) do
    {state, frames} = handle_tick(topic, payload, state)
    reply_with_frames(state, frames)
  end

  defp process_message(%{"topic" => topic, "event" => "message", "payload" => payload}, state) do
    handle_dm_message(topic, payload, state)
  end

  defp process_message(%{"event" => "phx_error", "topic" => topic}, state) do
    IO.puts("[client] channel error on #{topic}")
    {:ok, state}
  end

  defp process_message(other, state) do
    IO.puts("[client] unhandled message: #{inspect(other)}")
    {:ok, state}
  end

  defp handle_reply({:join_participant}, %{"payload" => %{"response" => response}}, state) do
    dm_threads = Map.new(response["dm_threads"] || [], &{&1["dm_key"], &1})

    IO.puts("✅ Subscribed to ParticipantChannel - will receive notifications for all DM activity")

    if map_size(dm_threads) > 0 do
      IO.puts("📬 Found #{map_size(dm_threads)} existing DM thread(s):")

      Enum.each(dm_threads, fn {dm_key, meta} ->
        IO.puts(
          "  - DM #{dm_key} with #{meta["other_participant_id"]} last=#{meta["last_message_text"] || "(none)"}"
        )
      end)

      IO.puts("🔗 Auto-subscribing to all DM threads for real-time messages...")
    else
      IO.puts("📭 No existing DM threads found")
    end

    {state, frames} = ensure_dm_joins(state, Map.keys(dm_threads))
    reply_with_frames(%{state | dm_threads: dm_threads}, frames)
  end

  defp handle_reply(
         {:join_dm, dm_key},
         %{"payload" => %{"response" => %{"messages" => history}}},
         state
       ) do
    IO.puts("✅ Subscribed to ThreadChannel for DM #{dm_key} - will receive real-time messages")

    if length(history) > 0 do
      IO.puts("📜 Message history (#{length(history)} messages):")

      Enum.each(history, fn msg ->
        print_message(msg)
      end)
    else
      IO.puts("📭 No message history for this DM")
    end

    {:ok, state}
  end

  defp handle_reply({:push, dm_key}, %{"payload" => %{"status" => "ok"}}, state) do
    unreads = Map.put(state.unreads, dm_key, 0)
    {:ok, %{state | unreads: unreads}}
  end

  defp handle_reply(
         {:create_dm, participant_id, message},
         %{"payload" => %{"response" => response}},
         state
       ) do
    thread_id = response["thread_id"]
    IO.puts("✓ DM created with #{participant_id}: #{thread_id}")

    # The thread_id from legacy API is actually a fake dm_key format
    # We need to generate the real dm_key
    dm_key = generate_dm_key(state.participant_id, participant_id)

    # Add the new DM to our local state
    dm_meta = %{
      "dm_key" => dm_key,
      "other_participant_id" => participant_id,
      "last_message_text" => message,
      "last_message_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    dm_threads = Map.put(state.dm_threads, dm_key, dm_meta)
    unreads = Map.put(state.unreads, dm_key, 0)

    # Auto-join the new DM
    {state, frames} = ensure_dm_join(%{state | dm_threads: dm_threads, unreads: unreads}, dm_key)
    reply_with_frames(state, frames)
  end

  defp handle_reply(_action, _message, state), do: {:ok, state}

  defp generate_dm_key(participant_a, participant_b) do
    [x, y] = Enum.sort([participant_a, participant_b])
    "#{x}:#{y}"
  end

  defp handle_tick("participant:" <> _participant, %{"updates" => updates}, state) do
    Enum.reduce(updates, {state, []}, fn update, {st, frames} ->
      dm_key = update["dm_key"] || update[:dm_key]
      other_participant = update["other_participant_id"]
      last_message = update["last_message_text"]
      sender_id = update["sender_id"]

      # Display notification for new messages from others
      if sender_id && sender_id != st.participant_id do
        IO.puts("🔔 New message in DM #{dm_key} from #{other_participant}: #{last_message}")
      end

      dm_threads = Map.put(st.dm_threads, dm_key, update)
      unread = unread_increment(st, dm_key, update)
      unreads = Map.put(st.unreads, dm_key, unread)

      {st, extra} = ensure_dm_join(%{st | dm_threads: dm_threads, unreads: unreads}, dm_key)
      {st, frames ++ extra}
    end)
  end

  defp handle_tick(_topic, _payload, state), do: {state, []}

  defp unread_increment(state, dm_key, %{"sender_id" => sender_id}) do
    current = Map.get(state.unreads, dm_key, 0)

    if sender_id == state.participant_id do
      0
    else
      current + 1
    end
  end

  defp unread_increment(state, dm_key, update) when is_map(update) do
    sender_id = update["sender_id"] || update[:sender_id]
    current = Map.get(state.unreads, dm_key, 0)

    if sender_id == state.participant_id do
      0
    else
      current + 1
    end
  end

  defp handle_dm_message("dm:" <> dm_key, payload, state) do
    # Display the message with DM context
    sender_id = payload["sender_id"]

    if sender_id != state.participant_id do
      IO.puts("💬 [DM #{dm_key}] Real-time message:")
    end

    print_message(payload)

    unreads =
      if payload["sender_id"] == state.participant_id do
        Map.put(state.unreads, dm_key, 0)
      else
        Map.update(state.unreads, dm_key, 1, &(&1 + 1))
      end

    {:ok, %{state | unreads: unreads}}
  end

  defp ensure_dm_joins(state, dm_keys) do
    Enum.reduce(dm_keys, {state, []}, fn dm_key, {st, frames} ->
      {st, frame} = ensure_dm_join(st, dm_key)
      {st, frames ++ frame}
    end)
  end

  defp ensure_dm_join(state, dm_key) do
    if MapSet.member?(state.joined_dms, dm_key) do
      {state, []}
    else
      {state, ref} = next_ref(state)
      frame = encode_message("dm:#{dm_key}", "phx_join", %{}, ref)

      state = %{
        state
        | pending: Map.put(state.pending, ref, {:join_dm, dm_key}),
          joined_dms: MapSet.put(state.joined_dms, dm_key)
      }

      {state, [{:text, frame}]}
    end
  end

  defp print_message(payload) do
    created_at = Map.get(payload, "created_at") || ""
    IO.puts("[#{created_at}] #{payload["sender_id"]}: #{payload["text"]}")
  end

  defp encode_message(topic, event, payload, ref) do
    Jason.encode!(%{
      "topic" => topic,
      "event" => event,
      "payload" => payload,
      "ref" => ref
    })
  end

  defp reply_with_frames(state, []), do: {:ok, state}

  defp reply_with_frames(state, [frame]), do: {:reply, frame, state}

  defp reply_with_frames(state, [frame | rest]) do
    send(self(), {:send_frames, rest})
    {:reply, frame, state}
  end
end

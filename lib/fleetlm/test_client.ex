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
        IO.puts("Commands: list | send <thread_id> <message> | read <thread_id> | quit\n")
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
    IO.puts("Commands: list | send <thread_id> <message> | read <thread_id> | quit")
  end

  defp handle_command("list", client) do
    WebSockex.cast(client, {:list, self()})

    receive do
      {:thread_list, rows} ->
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
    thread_id = String.trim(rest)

    if thread_id == "" do
      IO.puts("usage: read <thread_id>")
    else
      WebSockex.cast(client, {:mark_read, thread_id})
    end
  end

  defp handle_command("send " <> rest, client) do
    case String.split(rest, ~r/\s+/, parts: 2) do
      [thread_id, message] when message not in [nil, ""] ->
        WebSockex.cast(client, {:send_message, thread_id, message})

      _ ->
        IO.puts("usage: send <thread_id> <message>")
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
      joined_threads: MapSet.new(),
      threads: %{},
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
  def handle_cast({:send_message, thread_id, text}, state) do
    {state, frame} = push_message(state, thread_id, text)
    reply_with_frames(state, [frame])
  end

  def handle_cast({:list, caller}, state) do
    rows =
      state.threads
      |> Enum.map(fn {thread_id, meta} ->
        unread = Map.get(state.unreads, thread_id, 0)
        preview = Map.get(meta, "last_message_preview") || "(none)"
        timestamp = Map.get(meta, "last_message_at") || "-"
        "#{thread_id} | unread=#{unread} | last=#{preview} @ #{timestamp}"
      end)
      |> Enum.sort()

    send(caller, {:thread_list, rows})
    {:ok, state}
  end

  def handle_cast({:mark_read, thread_id}, state) do
    unreads = Map.put(state.unreads, thread_id, 0)
    {:ok, %{state | unreads: unreads}}
  end

  def handle_cast({:get_state, caller}, state) do
    snapshot = Map.take(state, [:threads, :unreads, :joined_threads])
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

  defp push_message(state, thread_id, text) do
    payload = %{"text" => text}
    {state, ref} = next_ref(state)
    frame = encode_message("thread:#{thread_id}", "message:new", payload, ref)
    state = put_pending(state, ref, {:push, thread_id})
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
    handle_thread_message(topic, payload, state)
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
    threads = Map.new(response["threads"] || [], &{&1["thread_id"], &1})

    Enum.each(threads, fn {thread_id, meta} ->
      IO.puts(
        "Joined participant channel: thread #{thread_id} last=#{meta["last_message_preview"] || "(none)"}"
      )
    end)

    {state, frames} = ensure_thread_joins(state, Map.keys(threads))
    reply_with_frames(%{state | threads: threads}, frames)
  end

  defp handle_reply(
         {:join_thread, thread_id},
         %{"payload" => %{"response" => %{"messages" => history}}},
         state
       ) do
    IO.puts("History for #{thread_id}:")

    Enum.each(history, fn msg ->
      print_message(msg)
    end)

    {:ok, state}
  end

  defp handle_reply({:push, thread_id}, %{"payload" => %{"status" => "ok"}}, state) do
    unreads = Map.put(state.unreads, thread_id, 0)
    {:ok, %{state | unreads: unreads}}
  end

  defp handle_reply(_action, _message, state), do: {:ok, state}

  defp handle_tick("participant:" <> _participant, %{"updates" => updates}, state) do
    Enum.reduce(updates, {state, []}, fn update, {st, frames} ->
      thread_id = update["thread_id"]
      IO.puts("[tick] #{thread_id} :: #{update["last_message_preview"]}")

      threads = Map.put(st.threads, thread_id, update)
      unread = unread_increment(st, thread_id, update)
      unreads = Map.put(st.unreads, thread_id, unread)

      {st, extra} = ensure_thread_join(%{st | threads: threads, unreads: unreads}, thread_id)
      {st, frames ++ extra}
    end)
  end

  defp handle_tick(_topic, _payload, state), do: {state, []}

  defp unread_increment(state, thread_id, %{"sender_id" => sender_id}) do
    current = Map.get(state.unreads, thread_id, 0)

    if sender_id == state.participant_id do
      0
    else
      current + 1
    end
  end

  defp handle_thread_message("thread:" <> thread_id, payload, state) do
    print_message(payload)

    unreads =
      if payload["sender_id"] == state.participant_id do
        Map.put(state.unreads, thread_id, 0)
      else
        Map.update(state.unreads, thread_id, 1, &(&1 + 1))
      end

    {:ok, %{state | unreads: unreads}}
  end

  defp ensure_thread_joins(state, thread_ids) do
    Enum.reduce(thread_ids, {state, []}, fn thread_id, {st, frames} ->
      {st, frame} = ensure_thread_join(st, thread_id)
      {st, frames ++ frame}
    end)
  end

  defp ensure_thread_join(state, thread_id) do
    if MapSet.member?(state.joined_threads, thread_id) do
      {state, []}
    else
      {state, ref} = next_ref(state)
      frame = encode_message("thread:#{thread_id}", "phx_join", %{}, ref)

      state = %{
        state
        | pending: Map.put(state.pending, ref, {:join_thread, thread_id}),
          joined_threads: MapSet.put(state.joined_threads, thread_id)
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

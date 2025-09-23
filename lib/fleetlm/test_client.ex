defmodule Fleetlm.TestClient do
  @moduledoc """
  Minimal CLI utility for chatting with the FleetLM runtime.

  Features:
    * Connects to Phoenix channels for real-time updates
    * Sends DMs via the REST API
    * Optional broadcast helper (`! message`)

  Input commands:
    @recipient message   – direct message (recipient like `alice` or `user:alice`)
    ! message             – broadcast
    /sub dm_key           – subscribe to a DM by key
    /history target       – fetch last 40 messages against a recipient or dm_key
    /help                 – show commands
    /quit                 – exit
  """

  alias Fleetlm.Chat
  alias Fleetlm.TestClient.Socket

  @default_socket_url "ws://localhost:4000/socket/websocket"
  @default_api_url "http://localhost:4000/api"

  def main(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [participant_id: :string, socket_url: :string, api_url: :string],
        aliases: [p: :participant_id, s: :socket_url, a: :api_url]
      )

    participant_id =
      (opts[:participant_id] || System.get_env("PARTICIPANT_ID") || random_participant())
      |> normalize_participant()

    socket_url =
      opts[:socket_url] || System.get_env("TEST_CLIENT_SOCKET_URL") || @default_socket_url

    api_url = opts[:api_url] || System.get_env("TEST_CLIENT_API_URL") || @default_api_url
    api_url = String.trim_trailing(api_url, "/")

    {:ok, socket} = Socket.start_link(socket_url, participant_id: participant_id, owner: self())

    input_pid = spawn_link(fn -> input_loop(self()) end)

    init_state = %{
      participant_id: participant_id,
      socket: socket,
      api_url: api_url,
      subscriptions: MapSet.new(),
      input_pid: input_pid
    }

    print_banner(participant_id, socket_url, api_url)
    event_loop(init_state)
  end

  defp event_loop(state) do
    receive do
      {:input, :eof} ->
        Socket.stop(state.socket)
        :ok

      {:input, line} ->
        state
        |> handle_input(line)
        |> event_loop()

      {:socket, {:connected, url}} ->
        client_log("websocket connected to #{url}")
        event_loop(state)

      {:socket, :conversation_ready} ->
        client_log("conversation channel ready")
        event_loop(state)

      {:socket, :inbox_ready} ->
        client_log("inbox channel joined")
        event_loop(state)

      {:socket, {:subscribed, dm_key, history}} ->
        client_log("subscribed to #{dm_key} (#{length(history)} messages)")
        Enum.each(history, &print_message(&1, :history))
        event_loop(put_in(state.subscriptions, MapSet.put(state.subscriptions, dm_key)))

      {:socket, {:dm_message, payload}} ->
        print_message(payload, :live)
        event_loop(state)

      {:socket, {:broadcast, payload}} ->
        print_broadcast(payload)
        event_loop(state)

      {:socket, {:inbox_update, update}} ->
        print_inbox(update)
        event_loop(state)

      {:socket, {:error, context, reason}} ->
        client_log("error #{context}: #{inspect(reason)}")
        event_loop(state)

      other ->
        client_log("unhandled #{inspect(other)}")
        event_loop(state)
    end
  end

  defp handle_input(state, line)

  defp handle_input(state, "") do
    state
  end

  defp handle_input(state, "/help") do
    print_help()
    state
  end

  defp handle_input(state, "/quit") do
    Socket.stop(state.socket)
    Process.exit(state.input_pid, :normal)
    System.halt(0)
  end

  defp handle_input(state, "/sub " <> dm_key) do
    dm_key = String.trim(dm_key)

    cond do
      dm_key == "" ->
        client_log("usage: /sub <dm_key>")
        state

      MapSet.member?(state.subscriptions, dm_key) ->
        client_log("already subscribed to #{dm_key}")
        state

      true ->
        Socket.subscribe(state.socket, dm_key)
        update_subscriptions(state, dm_key)
    end
  end

  defp handle_input(state, "/history " <> target) do
    target = String.trim(target)

    dm_key =
      cond do
        target == "" ->
          nil

        String.contains?(target, ":") && length(String.split(target, ":")) >= 4 ->
          target

        true ->
          recipient = normalize_participant(target)
          Chat.generate_dm_key(state.participant_id, recipient)
      end

    case dm_key do
      nil ->
        client_log("usage: /history <recipient|dm_key>")
        state

      dm_key ->
        fetch_history(state, dm_key)
        state
    end
  end

  defp handle_input(state, "@" <> rest) do
    case String.split(rest, ~r/\s+/, parts: 2, trim: true) do
      [recipient, message] when message not in [nil, ""] ->
        recipient = normalize_participant(recipient)
        dm_key = Chat.generate_dm_key(state.participant_id, recipient)
        state = ensure_subscription(state, dm_key)

        case send_dm(state.api_url, dm_key, state.participant_id, message) do
          {:ok, payload} ->
            print_message(payload, :outgoing)
            state

          {:error, reason} ->
            client_log("failed to send: #{reason}")
            state
        end

      _ ->
        client_log("usage: @recipient message")
        state
    end
  end

  defp handle_input(state, "!" <> message) do
    message = String.trim(message)

    if message == "" do
      client_log("usage: ! message")
      state
    else
      state = ensure_subscription(state, "broadcast")

      case send_broadcast(state.api_url, state.participant_id, message) do
        {:ok, payload} ->
          print_broadcast(Map.put(payload, "sender_id", state.participant_id))
          state

        {:error, reason} ->
          client_log("failed to broadcast: #{reason}")
          state
      end
    end
  end

  defp handle_input(state, line) do
    client_log("unknown command: #{line}")
    state
  end

  defp ensure_subscription(state, dm_key) do
    if MapSet.member?(state.subscriptions, dm_key) do
      state
    else
      Socket.subscribe(state.socket, dm_key)
      update_subscriptions(state, dm_key)
    end
  end

  defp update_subscriptions(state, dm_key) do
    %{state | subscriptions: MapSet.put(state.subscriptions, dm_key)}
  end

  defp fetch_history(state, dm_key) do
    url = "#{state.api_url}/conversations/#{dm_key}/messages"

    case Req.get(url, params: [participant_id: state.participant_id]) do
      {:ok, %Req.Response{status: status, body: %{"messages" => messages}}}
      when status in 200..299 ->
        client_log("history for #{dm_key} (#{length(messages)} messages)")
        Enum.each(messages, &print_message(&1, :history))

      {:ok, %Req.Response{status: status, body: body}} ->
        client_log("history request failed (#{status}): #{inspect(body)}")

      {:error, reason} ->
        client_log("history request error: #{Exception.message(reason)}")
    end
  end

  defp send_dm(api_url, dm_key, sender_id, message) do
    url = "#{api_url}/conversations/#{dm_key}/messages"
    body = %{sender_id: sender_id, text: message, metadata: %{}}

    case Req.post(url, json: body) do
      {:ok, %Req.Response{status: status, body: payload}} when status in 200..299 ->
        {:ok, payload}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, Exception.message(reason)}
    end
  end

  defp send_broadcast(api_url, sender_id, message) do
    url = "#{api_url}/conversations/broadcast/messages"
    body = %{sender_id: sender_id, text: message, metadata: %{}}

    case Req.post(url, json: body) do
      {:ok, %Req.Response{status: status, body: payload}} when status in 200..299 ->
        {:ok, payload}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, Exception.message(reason)}
    end
  end

  defp print_message(%{"dm_key" => dm_key} = payload, origin) do
    sender = payload["sender_id"]
    text = payload["text"]
    created_at = payload["created_at"] || ""
    marker = origin_marker(origin)
    IO.puts("#{marker} [#{dm_key}] #{sender}: #{text} #{created_at}")
  end

  defp print_message(payload, origin) do
    sender = payload["sender_id"]
    text = payload["text"]
    created_at = payload["created_at"] || ""
    marker = origin_marker(origin)
    IO.puts("#{marker} #{sender}: #{text} #{created_at}")
  end

  defp print_broadcast(payload) do
    sender = payload["sender_id"]
    text = payload["text"]
    IO.puts("<< [broadcast] #{sender}: #{text}")
  end

  defp print_inbox(%{"dm_key" => dm_key} = update) do
    last = update["last_message_text"] || ""
    unread = update["unread_count"] || 0
    other = update["other_participant_id"]
    IO.puts("!! inbox #{dm_key} (#{other}) last=#{inspect(last)} unread=#{unread}")
  end

  defp origin_marker(:history), do: "--"
  defp origin_marker(:outgoing), do: ">>"
  defp origin_marker(:live), do: "<<"
  defp origin_marker(_), do: "--"

  defp input_loop(owner) do
    case IO.gets("") do
      :eof -> send(owner, {:input, :eof})
      {:error, _} -> send(owner, {:input, :eof})
      line -> send(owner, {:input, String.trim(line)})
    end

    input_loop(owner)
  end

  defp print_banner(participant_id, socket_url, api_url) do
    IO.puts("Connected as #{participant_id}")
    IO.puts("  socket: #{socket_url}")
    IO.puts("  api:    #{api_url}")
    print_help()
  end

  defp print_help do
    IO.puts("Commands:")
    IO.puts("  @recipient message   send DM")
    IO.puts("  ! message             broadcast")
    IO.puts("  /sub dm_key           subscribe to DM key")
    IO.puts("  /history target       fetch history by participant or dm key")
    IO.puts("  /help                 show commands")
    IO.puts("  /quit                 exit")
  end

  defp client_log(message), do: IO.puts("[client] #{message}")

  defp normalize_participant(""), do: raise(ArgumentError, "participant cannot be blank")

  defp normalize_participant(participant) do
    participant = participant |> to_string() |> String.trim()

    if String.contains?(participant, ":") do
      participant
    else
      "user:" <> participant
    end
  end

  defp random_participant do
    "user:" <> Ecto.UUID.generate()
  end
end

defmodule Fleetlm.TestClient.Socket do
  @moduledoc false
  use WebSockex

  def start_link(url, opts) do
    participant_id = Keyword.fetch!(opts, :participant_id)
    owner = Keyword.fetch!(opts, :owner)
    name = Keyword.get(opts, :name, name(participant_id))

    url = append_participant(url, participant_id)

    state = %{
      url: url,
      participant_id: participant_id,
      owner: owner,
      ref: 1,
      pending: %{},
      subscriptions: MapSet.new(),
      conversation_ready?: true,
      inbox_ready?: false,
      heartbeat_ref: nil
    }

    WebSockex.start_link(url, __MODULE__, state, name: name)
  end

  def name(participant_id), do: {:global, {__MODULE__, participant_id}}

  def join_channels(pid), do: WebSockex.cast(pid, :join_channels)
  def subscribe(pid, dm_key), do: WebSockex.cast(pid, {:subscribe, dm_key})
  def stop(pid), do: WebSockex.cast(pid, :stop)

  @impl true
  def handle_connect(_conn, state) do
    send(state.owner, {:socket, {:connected, state.url}})
    send(self(), :join_channels)
    {:ok, schedule_heartbeat(state)}
  end

  @impl true
  def handle_cast(:join_channels, state) do
    {state, frames} =
      state
      |> push("inbox:" <> state.participant_id, "phx_join", %{}, {:inbox_join})
      |> collect_frame([])

    send(state.owner, {:socket, :conversation_ready})

    reply_with_frames(state, frames)
  end

  def handle_cast({:subscribe, dm_key}, state) do
    if MapSet.member?(state.subscriptions, dm_key) do
      {:ok, state}
    else
      {state, frames} =
        state
        |> push(
          "conversation:" <> dm_key,
          "phx_join",
          %{},
          {:subscribe, dm_key}
        )
        |> collect_frame([])

      reply_with_frames(state, frames)
    end
  end

  def handle_cast(:stop, state) do
    {:close, 1000, "client requested", state}
  end

  @impl true
  def handle_frame({:text, payload}, state) do
    case Jason.decode(payload) do
      {:ok, %{"event" => "phx_reply", "ref" => ref} = message} ->
        handle_reply(ref, message, state)

      {:ok,
       %{"topic" => "conversation:" <> _ = _topic, "event" => "message", "payload" => payload}} ->
        dispatch_message(payload, state)

      {:ok, %{"topic" => "inbox:" <> _ = _topic, "event" => "message", "payload" => payload}} ->
        send(state.owner, {:socket, {:dm_message, payload}})
        {:ok, state}

      {:ok,
       %{
         "topic" => "inbox:" <> _ = _topic,
         "event" => "tick",
         "payload" => %{"updates" => updates}
       }} ->
        Enum.each(updates, &send(state.owner, {:socket, {:inbox_update, &1}}))
        {:ok, state}

      {:ok, other} ->
        send(state.owner, {:socket, {:error, :frame, other}})
        {:ok, state}

      {:error, reason} ->
        send(state.owner, {:socket, {:error, :decode, reason}})
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:join_channels, state) do
    handle_cast(:join_channels, state)
  end

  def handle_info(:heartbeat, state) do
    {state, frames} =
      state
      |> push("phoenix", "heartbeat", %{}, nil)
      |> collect_frame([])

    reply_with_frames(schedule_heartbeat(state), frames)
  end

  def handle_info({:send_frames, frames}, state) do
    reply_with_frames(state, frames)
  end

  def handle_info(_, state), do: {:ok, state}

  defp handle_reply(ref, message, state) do
    case Map.pop(state.pending, ref) do
      {nil, pending} -> {:ok, %{state | pending: pending}}
      {action, pending} -> process_reply(action, message, %{state | pending: pending})
    end
  end

  defp process_reply({:inbox_join}, %{"payload" => %{"status" => "ok"}}, state) do
    send(state.owner, {:socket, :inbox_ready})
    {:ok, %{state | inbox_ready?: true}}
  end

  defp process_reply(
         {:subscribe, dm_key},
         %{"payload" => %{"status" => "ok", "response" => resp}},
         state
       ) do
    history = Map.get(resp, "messages", [])
    send(state.owner, {:socket, {:subscribed, resp["dm_key"] || dm_key, history}})
    subscriptions = MapSet.put(state.subscriptions, dm_key)
    {:ok, %{state | subscriptions: subscriptions}}
  end

  defp process_reply(action, message, state) do
    send(state.owner, {:socket, {:error, action, message}})
    {:ok, state}
  end

  defp dispatch_message(%{"dm_key" => _} = payload, state) do
    send(state.owner, {:socket, {:dm_message, payload}})
    {:ok, state}
  end

  defp dispatch_message(payload, state) do
    send(state.owner, {:socket, {:broadcast, payload}})
    {:ok, state}
  end

  defp push(state, topic, event, payload, action) do
    {state, ref} = next_ref(state)

    pending =
      if action do
        Map.put(state.pending, ref, action)
      else
        state.pending
      end

    frame = encode(topic, event, payload, ref)
    {%{state | pending: pending}, frame}
  end

  defp collect_frame({state, frame}, frames), do: {state, frames ++ [frame]}

  defp next_ref(state), do: {%{state | ref: state.ref + 1}, Integer.to_string(state.ref)}

  defp encode(topic, event, payload, ref) do
    {:text,
     Jason.encode!(%{
       "topic" => topic,
       "event" => event,
       "payload" => payload,
       "ref" => ref
     })}
  end

  defp reply_with_frames(state, []), do: {:ok, state}

  defp reply_with_frames(state, [frame]), do: {:reply, frame, state}

  defp reply_with_frames(state, [frame | rest]) do
    send(self(), {:send_frames, rest})
    {:reply, frame, state}
  end

  defp schedule_heartbeat(state) do
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)
    ref = Process.send_after(self(), :heartbeat, 25_000)
    %{state | heartbeat_ref: ref}
  end

  defp append_participant(url, participant_id) do
    uri = URI.parse(url)

    params =
      (uri.query || "")
      |> URI.decode_query(%{})
      |> Map.put("participant_id", participant_id)
      |> URI.encode_query()

    %{uri | query: params} |> URI.to_string()
  end
end

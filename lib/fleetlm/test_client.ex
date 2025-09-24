defmodule Fleetlm.TestClient do
  @moduledoc """
  Command-driven CLI utility for interacting with the FleetLM runtime.

  Usage: `mix run scripts/test_client.exs <command> [options]`

  Commands:
    send_dm        Send a direct message between two participants
    send_broadcast Send a broadcast message
    history        Fetch message history for a DM key or peer
    inbox          List inbox conversations for a participant
    listen         Stream live updates over the websocket
    chat           Engage in an interactive chat session between two users
    help           Show general or command-specific help

  The CLI defaults to JSON Lines output so it can be consumed by tools and LLM agents.
  Human-friendly rendering is available via `--format=human`.
  """

  alias Fleetlm.Chat
  alias Fleetlm.TestClient.Socket

  @default_socket_url "ws://localhost:4000/socket/websocket"
  @default_api_url "http://localhost:4000/api"

  # Entry point -----------------------------------------------------------------

  def main([]) do
    print_usage(:stderr)
    System.halt(64)
  end

  def main(["help"]) do
    print_usage(:stdout)
  end

  def main(["help", command]) do
    case command_usage(command) do
      {:ok, text} ->
        IO.puts(text)

      :error ->
        IO.puts(:stderr, "Unknown command: #{command}")
        print_usage(:stderr)
        System.halt(64)
    end
  end

  def main([command | rest]) do
    case dispatch(String.downcase(command), rest) do
      {:ok, :stream} ->
        :ok

      {:ok, events, format, exit_code} ->
        Enum.each(events, &emit(&1, format))
        System.halt(exit_code)

      {:error, exit_code, event, format} ->
        emit(event, format)
        System.halt(exit_code)
    end
  end

  def main(_args) do
    print_usage(:stderr)
    System.halt(64)
  end

  # Dispatch --------------------------------------------------------------------

  defp dispatch("send_dm", args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          from: :string,
          to: :string,
          text: :string,
          file: :string,
          stdin: :boolean,
          format: :string,
          api_url: :string
        ],
        aliases: [f: :from, t: :to]
      )

    cond do
      rest != [] ->
        {:error, 64, error_event("send_dm", "Unexpected arguments: #{Enum.join(rest, " ")}"),
         infer_format(opts[:format])}

      invalid != [] ->
        {:error, 64, error_event("send_dm", "Invalid options: #{inspect(invalid)}"),
         infer_format(opts[:format])}

      true ->
        run_send_dm(opts)
    end
  end

  defp dispatch("send_broadcast", args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          from: :string,
          text: :string,
          file: :string,
          stdin: :boolean,
          format: :string,
          api_url: :string
        ]
      )

    cond do
      rest != [] ->
        {:error, 64,
         error_event("send_broadcast", "Unexpected arguments: #{Enum.join(rest, " ")}"),
         infer_format(opts[:format])}

      invalid != [] ->
        {:error, 64, error_event("send_broadcast", "Invalid options: #{inspect(invalid)}"),
         infer_format(opts[:format])}

      true ->
        run_send_broadcast(opts)
    end
  end

  defp dispatch("history", args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          participant: :string,
          with: :string,
          "dm-key": :string,
          limit: :integer,
          format: :string,
          api_url: :string
        ]
      )

    cond do
      rest != [] ->
        {:error, 64, error_event("history", "Unexpected arguments: #{Enum.join(rest, " ")}"),
         infer_format(opts[:format])}

      invalid != [] ->
        {:error, 64, error_event("history", "Invalid options: #{inspect(invalid)}"),
         infer_format(opts[:format])}

      true ->
        run_history(opts)
    end
  end

  defp dispatch("inbox", args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [participant: :string, format: :string, socket_url: :string]
      )

    cond do
      rest != [] ->
        {:error, 64, error_event("inbox", "Unexpected arguments: #{Enum.join(rest, " ")}"),
         infer_format(opts[:format])}

      invalid != [] ->
        {:error, 64, error_event("inbox", "Invalid options: #{inspect(invalid)}"),
         infer_format(opts[:format])}

      true ->
        run_inbox(opts)
    end
  end

  defp dispatch("listen", args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          participant: :string,
          "dm-key": :keep,
          with: :keep,
          broadcast: :boolean,
          format: :string,
          socket_url: :string,
          api_url: :string
        ]
      )

    cond do
      rest != [] ->
        {:error, 64, error_event("listen", "Unexpected arguments: #{Enum.join(rest, " ")}"),
         infer_format(opts[:format])}

      invalid != [] ->
        {:error, 64, error_event("listen", "Invalid options: #{inspect(invalid)}"),
         infer_format(opts[:format])}

      true ->
        run_listen(opts)
    end
  end

  defp dispatch("chat", args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          from: :string,
          to: :string,
          format: :string,
          socket_url: :string,
          api_url: :string
        ]
      )

    cond do
      rest != [] ->
        {:error, 64, error_event("chat", "Unexpected arguments: #{Enum.join(rest, " ")}"),
         infer_format(opts[:format])}

      invalid != [] ->
        {:error, 64, error_event("chat", "Invalid options: #{inspect(invalid)}"),
         infer_format(opts[:format])}

      true ->
        run_chat(opts)
    end
  end

  defp dispatch(_, _args) do
    {:error, 64, %{event: "error", context: "dispatch", reason: "Unknown command"}, :jsonl}
  end

  # Command implementations ------------------------------------------------------

  defp run_send_dm(opts) do
    with {:ok, from} <- require_participant(opts[:from], :from),
         {:ok, to} <- require_participant(opts[:to], :to),
         {:ok, message} <- resolve_message(opts),
         {:ok, api_url} <- resolve_api_url(opts[:api_url]),
         format <- infer_format(opts[:format]) do
      dm_key = Chat.generate_dm_key(from, to)

      case send_dm(api_url, dm_key, from, message) do
        {:ok, payload} ->
          event = %{
            event: "dm.sent",
            dm_key: dm_key,
            sender: from,
            recipient: to,
            message: payload
          }

          {:ok, [event], format, 0}

        {:error, reason, meta} ->
          event = error_event("send_dm", reason, meta)
          {:error, 70, event, format}
      end
    else
      {:error, :participant, which} ->
        format = infer_format(opts[:format])
        {:error, 64, error_event("send_dm", "Missing required --#{which}"), format}

      {:error, :message, msg} ->
        format = infer_format(opts[:format])
        {:error, 64, error_event("send_dm", msg), format}

      {:error, :api_url, msg} ->
        format = infer_format(opts[:format])
        {:error, 64, error_event("send_dm", msg), format}
    end
  end

  defp run_send_broadcast(opts) do
    with {:ok, from} <- require_participant(opts[:from], :from),
         {:ok, message} <- resolve_message(opts),
         {:ok, api_url} <- resolve_api_url(opts[:api_url]),
         format <- infer_format(opts[:format]) do
      case send_broadcast(api_url, from, message) do
        {:ok, payload} ->
          event = %{event: "broadcast.sent", sender: from, message: payload}
          {:ok, [event], format, 0}

        {:error, reason, meta} ->
          event = error_event("send_broadcast", reason, meta)
          {:error, 70, event, format}
      end
    else
      {:error, :participant, which} ->
        format = infer_format(opts[:format])
        {:error, 64, error_event("send_broadcast", "Missing required --#{which}"), format}

      {:error, :message, msg} ->
        format = infer_format(opts[:format])
        {:error, 64, error_event("send_broadcast", msg), format}

      {:error, :api_url, msg} ->
        format = infer_format(opts[:format])
        {:error, 64, error_event("send_broadcast", msg), format}
    end
  end

  defp run_history(opts) do
    with {:ok, participant} <- require_participant(opts[:participant], :participant),
         {:ok, dm_key} <- resolve_dm_key(participant, opts[:with], opts[:"dm-key"]),
         {:ok, api_url} <- resolve_api_url(opts[:api_url]),
         format <- infer_format(opts[:format]) do
      limit = opts[:limit]

      case fetch_history(api_url, dm_key, participant, limit) do
        {:ok, messages} ->
          events =
            messages
            |> Enum.map(fn msg ->
              %{
                event: "history.message",
                dm_key: dm_key,
                message: msg
              }
            end)

          {:ok, events, format, 0}

        {:error, reason, meta} ->
          {:error, 70, error_event("history", reason, meta), format}
      end
    else
      {:error, :participant, which} ->
        format = infer_format(opts[:format])
        {:error, 64, error_event("history", "Missing required --#{which}"), format}

      {:error, :dm_key, message} ->
        format = infer_format(opts[:format])
        {:error, 64, error_event("history", message), format}

      {:error, :api_url, msg} ->
        format = infer_format(opts[:format])
        {:error, 64, error_event("history", msg), format}
    end
  end

  defp run_inbox(opts) do
    format = infer_format(opts[:format])

    with {:ok, participant} <- require_participant(opts[:participant], :participant),
         {:ok, socket_url} <- resolve_socket_url(opts[:socket_url]) do
      {:ok, socket} =
        Socket.start_link(socket_url,
          participant_id: participant,
          owner: self()
        )

      result = await_inbox_snapshot(socket, participant, [])
      Socket.stop(socket)

      case result do
        {:ok, events} ->
          {:ok, events, format, 0}

        {:error, event} ->
          {:error, 70, event, format}
      end
    else
      {:error, :participant, which} ->
        format = infer_format(opts[:format])
        {:error, 64, error_event("inbox", "Missing required --#{which}"), format}

      {:error, :socket_url, msg} ->
        format = infer_format(opts[:format])
        {:error, 64, error_event("inbox", msg), format}
    end
  end

  defp await_inbox_snapshot(socket, participant, events) do
    receive do
      {:socket, {:connected, url}} ->
        await_inbox_snapshot(socket, participant, [
          %{event: "session.connected", url: url} | events
        ])

      {:socket, :inbox_ready} ->
        await_inbox_snapshot(socket, participant, [%{event: "inbox.ready"} | events])

      {:socket, {:inbox_snapshot, conversations}} ->
        snapshot_events =
          Enum.map(conversations, fn convo ->
            %{event: "inbox.entry", participant: participant, conversation: convo}
          end)

        {:ok, Enum.reverse(events) ++ snapshot_events}

      {:socket, {:inbox_update, update}} ->
        await_inbox_snapshot(socket, participant, [
          %{event: "inbox.update", update: update} | events
        ])

      {:socket, {:disconnected, reason}} ->
        await_inbox_snapshot(
          socket,
          participant,
          [%{event: "session.disconnected", reason: inspect(reason)} | events]
        )

      {:socket, {:closed, code, reason}} ->
        {:error,
         error_event("inbox", "Connection closed before snapshot", %{code: code, reason: reason})}

      {:socket, {:error, context, reason}} ->
        {:error, error_event("inbox", inspect(reason), %{context: context})}

      other ->
        await_inbox_snapshot(socket, participant, [
          %{event: "inbox.unhandled", payload: inspect(other)} | events
        ])
    after
      5_000 ->
        {:error, error_event("inbox", "Timed out while waiting for inbox snapshot")}
    end
  end

  defp run_listen(opts) do
    format = infer_format(opts[:format])

    with {:ok, participant} <- require_participant(opts[:participant], :participant),
         {:ok, socket_url} <- resolve_socket_url(opts[:socket_url]) do
      dm_keys =
        opts
        |> Keyword.get_values(:"dm-key")
        |> Enum.reject(&is_nil/1)

      with_participants =
        opts
        |> Keyword.get_values(:with)
        |> Enum.reject(&is_nil/1)

      resolved_dm_keys =
        Enum.reduce(with_participants, dm_keys, fn other, acc ->
          other = normalize_participant(other)
          [Chat.generate_dm_key(participant, other) | acc]
        end)

      targets =
        resolved_dm_keys
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      broadcast? = opts[:broadcast] || false

      {:ok, socket} =
        Socket.start_link(socket_url,
          participant_id: participant,
          owner: self()
        )

      Enum.each(targets, &Socket.subscribe(socket, &1))
      if broadcast?, do: Socket.subscribe(socket, "broadcast")

      emit(
        %{
          event: "listen.started",
          participant: participant,
          dm_keys: targets,
          broadcast: broadcast?
        },
        format
      )

      listen_loop(%{
        socket: socket,
        format: format,
        dm_keys: MapSet.new(targets),
        include_broadcast?: broadcast?,
        participant: participant
      })

      {:ok, :stream}
    else
      {:error, :participant, which} ->
        {:error, 64, error_event("listen", "Missing required --#{which}"), format}

      {:error, :socket_url, msg} ->
        {:error, 64, error_event("listen", msg), format}
    end
  end

  defp run_chat(opts) do
    format = infer_format(opts[:format])

    with {:ok, from} <- require_participant(opts[:from], :from),
         {:ok, to} <- require_participant(opts[:to], :to),
         {:ok, socket_url} <- resolve_socket_url(opts[:socket_url]),
         {:ok, api_url} <- resolve_api_url(opts[:api_url]) do
      dm_key = Chat.generate_dm_key(from, to)

      {:ok, socket} =
        Socket.start_link(socket_url,
          participant_id: from,
          owner: self()
        )

      Socket.subscribe(socket, dm_key)

      IO.puts(
        :stderr,
        "Chat session started. Type messages and press enter. Commands: /quit, /history"
      )

      input_pid = spawn_link(fn -> chat_input_loop(self()) end)

      chat_loop(%{
        socket: socket,
        dm_key: dm_key,
        from: from,
        to: to,
        api_url: api_url,
        format: format,
        input_pid: input_pid,
        closing?: false,
        seen_message_ids: MapSet.new()
      })

      {:ok, :stream}
    else
      {:error, :participant, which} ->
        {:error, 64, error_event("chat", "Missing required --#{which}"), format}

      {:error, :socket_url, msg} ->
        {:error, 64, error_event("chat", msg), format}

      {:error, :api_url, msg} ->
        {:error, 64, error_event("chat", msg), format}
    end
  end

  # Listen loop -----------------------------------------------------------------

  defp listen_loop(state) do
    receive do
      {:socket, {:connected, url}} ->
        emit(%{event: "session.connected", url: url}, state.format)
        listen_loop(state)

      {:socket, {:inbox_snapshot, conversations}} ->
        Enum.each(conversations, fn convo ->
          emit(
            %{event: "inbox.entry", participant: state.participant, conversation: convo},
            state.format
          )
        end)

        listen_loop(state)

      {:socket, :inbox_ready} ->
        emit(%{event: "inbox.ready"}, state.format)
        listen_loop(state)

      {:socket, {:subscribed, dm_key, history}} ->
        emit(
          %{event: "subscription.created", dm_key: dm_key, history_count: length(history)},
          state.format
        )

        Enum.each(history, fn msg ->
          emit(%{event: "message.history", dm_key: dm_key, message: msg}, state.format)
        end)

        listen_loop(%{state | dm_keys: MapSet.put(state.dm_keys, dm_key)})

      {:socket, {:conversation_message, payload}} ->
        dm_key = payload["dm_key"]

        if MapSet.member?(state.dm_keys, dm_key) do
          emit(%{event: "message.live", dm_key: dm_key, message: payload}, state.format)
        end

        listen_loop(state)

      {:socket, {:inbox_message, payload}} ->
        dm_key = payload["dm_key"]

        if MapSet.member?(state.dm_keys, dm_key) do
          emit(%{event: "message.live", dm_key: dm_key, message: payload}, state.format)
        end

        listen_loop(state)

      {:socket, {:broadcast, payload}} ->
        if state.include_broadcast? do
          emit(%{event: "broadcast.live", message: payload}, state.format)
        end

        listen_loop(state)

      {:socket, {:inbox_update, update}} ->
        emit(%{event: "inbox.update", update: update}, state.format)
        listen_loop(state)

      {:socket, {:error, context, reason}} ->
        emit(error_event("listen", inspect(reason), %{context: context}), state.format)
        listen_loop(state)

      {:socket, {:disconnected, reason}} ->
        emit(%{event: "session.disconnected", reason: inspect(reason)}, state.format)
        listen_loop(state)

      {:socket, {:closed, code, reason}} ->
        stop_input(state.input_pid)
        emit(%{event: "session.closed", code: code, reason: reason}, state.format)
        :ok

      {:halt, reason} ->
        emit(%{event: "listen.stopped", reason: reason}, state.format)
        :ok

      other ->
        emit(%{event: "listen.unhandled", payload: inspect(other)}, state.format)
        listen_loop(state)
    end
  end

  # Chat loop -------------------------------------------------------------------

  defp chat_loop(state) do
    receive do
      {:socket, {:connected, url}} ->
        emit(%{event: "session.connected", url: url}, state.format)
        chat_loop(state)

      {:socket, :inbox_ready} ->
        chat_loop(state)

      {:socket, {:subscribed, dm_key, history}} ->
        emit(%{event: "chat.ready", dm_key: dm_key, history_count: length(history)}, state.format)

        Enum.each(history, fn msg ->
          emit(%{event: "message.history", dm_key: dm_key, message: msg}, state.format)
        end)

        chat_loop(state)

      {:socket, {:conversation_message, payload}} ->
        if payload["dm_key"] == state.dm_key do
          message_id = payload["id"]

          unless MapSet.member?(state.seen_message_ids, message_id) do
            # Deduplicate by message ID to handle duplicate conversation channel messages
            emit(%{event: "message.live", dm_key: state.dm_key, message: payload}, state.format)
            chat_loop(%{state | seen_message_ids: MapSet.put(state.seen_message_ids, message_id)})
          else
            chat_loop(state)
          end
        else
          chat_loop(state)
        end

      {:socket, {:inbox_message, _payload}} ->
        # Ignore inbox messages in chat mode - these are just metadata/previews
        chat_loop(state)

      {:socket, {:broadcast, _payload}} ->
        chat_loop(state)

      {:socket, {:inbox_update, _update}} ->
        chat_loop(state)

      {:socket, {:inbox_snapshot, _conversations}} ->
        chat_loop(state)

      {:socket, {:error, context, reason}} ->
        emit(error_event("chat", inspect(reason), %{context: context}), state.format)
        chat_loop(state)

      {:socket, {:disconnected, reason}} ->
        emit(%{event: "session.disconnected", reason: inspect(reason)}, state.format)
        chat_loop(state)

      {:socket, {:closed, code, reason}} ->
        emit(%{event: "session.closed", code: code, reason: reason}, state.format)
        :ok

      {:chat_input, :quit} ->
        Socket.stop(state.socket)
        stop_input(state.input_pid)
        emit(%{event: "chat.finished", reason: "quit"}, state.format)
        chat_loop(%{state | closing?: true})

      {:chat_input, :history} ->
        case fetch_history(state.api_url, state.dm_key, state.from, nil) do
          {:ok, messages} ->
            Enum.each(messages, fn msg ->
              emit(%{event: "history.message", dm_key: state.dm_key, message: msg}, state.format)
            end)

          {:error, reason, meta} ->
            emit(error_event("chat", reason, meta), state.format)
        end

        chat_loop(state)

      {:chat_input, {:message, message}} ->
        case send_dm(state.api_url, state.dm_key, state.from, message) do
          {:ok, payload} ->
            emit(%{event: "message.sent", dm_key: state.dm_key, message: payload}, state.format)

          {:error, reason, meta} ->
            emit(error_event("chat", reason, meta), state.format)
        end

        chat_loop(state)

      {:chat_input, :eof} ->
        Socket.stop(state.socket)
        stop_input(state.input_pid)
        emit(%{event: "chat.finished", reason: "eof"}, state.format)
        chat_loop(%{state | closing?: true})

      other ->
        emit(%{event: "chat.unhandled", payload: inspect(other)}, state.format)
        chat_loop(state)
    end
  end

  defp chat_input_loop(parent) do
    IO.write(:stderr, "message> ")

    case IO.gets("") do
      nil ->
        send(parent, {:chat_input, :eof})
        :ok

      :eof ->
        send(parent, {:chat_input, :eof})
        :ok

      line ->
        case String.trim(line) do
          "" ->
            chat_input_loop(parent)

          "/quit" ->
            send(parent, {:chat_input, :quit})
            :ok

          "/history" ->
            send(parent, {:chat_input, :history})
            chat_input_loop(parent)

          message ->
            send(parent, {:chat_input, {:message, message}})
            chat_input_loop(parent)
        end
    end
  end

  defp stop_input(nil), do: :ok

  defp stop_input(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :normal)
    :ok
  end

  # Helpers ---------------------------------------------------------------------

  defp require_participant(nil, which), do: {:error, :participant, which}

  defp require_participant(participant, _which) do
    {:ok, normalize_participant(participant)}
  end

  defp resolve_dm_key(_participant, nil, nil), do: {:error, :dm_key, "Provide --with or --dm-key"}

  defp resolve_dm_key(_participant, nil, dm_key) when dm_key not in [nil, ""] do
    {:ok, dm_key}
  end

  defp resolve_dm_key(participant, with, nil) when with not in [nil, ""] do
    other = normalize_participant(with)
    {:ok, Chat.generate_dm_key(participant, other)}
  end

  defp resolve_dm_key(_participant, _with, _dm_key),
    do: {:error, :dm_key, "Invalid DM key parameters"}

  defp resolve_message(opts) do
    cond do
      text = opts[:text] ->
        {:ok, text}

      file = opts[:file] ->
        case File.read(file) do
          {:ok, body} -> {:ok, String.trim_trailing(body)}
          {:error, reason} -> {:error, :message, "Unable to read file #{file}: #{reason}"}
        end

      opts[:stdin] ->
        message = IO.read(:stdio, :all) || ""
        {:ok, String.trim(message)}

      true ->
        {:error, :message, "Provide --text, --file, or --stdin"}
    end
  end

  defp resolve_api_url(nil) do
    case System.get_env("TEST_CLIENT_API_URL") do
      nil -> {:ok, @default_api_url}
      value -> resolve_api_url(value)
    end
  end

  defp resolve_api_url(url) when is_binary(url) do
    url = String.trim(url)

    if url == "" do
      {:error, :api_url, "API URL cannot be blank"}
    else
      {:ok, String.trim_trailing(url, "/")}
    end
  end

  defp resolve_socket_url(nil) do
    case System.get_env("TEST_CLIENT_SOCKET_URL") do
      nil -> {:ok, @default_socket_url}
      value -> resolve_socket_url(value)
    end
  end

  defp resolve_socket_url(url) when is_binary(url) do
    url = String.trim(url)

    if url == "" do
      {:error, :socket_url, "Socket URL cannot be blank"}
    else
      {:ok, url}
    end
  end

  defp send_dm(api_url, dm_key, sender_id, message) do
    url = "#{api_url}/conversations/#{dm_key}/messages"
    body = %{sender_id: sender_id, text: message, metadata: %{}}

    case Req.post(url, json: body) do
      {:ok, %Req.Response{status: status, body: payload}} when status in 200..299 ->
        {:ok, payload}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}", %{body: body}}

      {:error, reason} ->
        {:error, Exception.message(reason), %{stage: :http}}
    end
  end

  defp send_broadcast(api_url, sender_id, message) do
    url = "#{api_url}/conversations/broadcast/messages"
    body = %{sender_id: sender_id, text: message, metadata: %{}}

    case Req.post(url, json: body) do
      {:ok, %Req.Response{status: status, body: payload}} when status in 200..299 ->
        {:ok, payload}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}", %{body: body}}

      {:error, reason} ->
        {:error, Exception.message(reason), %{stage: :http}}
    end
  end

  defp fetch_history(api_url, dm_key, participant, limit) do
    url = "#{api_url}/conversations/#{dm_key}/messages"
    params = Enum.reject([participant_id: participant, limit: limit], fn {_k, v} -> is_nil(v) end)

    case Req.get(url, params: params) do
      {:ok, %Req.Response{status: status, body: %{"messages" => messages}}}
      when status in 200..299 ->
        {:ok, messages}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}", %{body: body}}

      {:error, reason} ->
        {:error, Exception.message(reason), %{stage: :http}}
    end
  end

  defp normalize_participant(participant) do
    participant = participant |> to_string() |> String.trim()

    cond do
      participant == "" -> raise(ArgumentError, "participant cannot be blank")
      String.contains?(participant, ":") -> participant
      true -> "user:" <> participant
    end
  end

  # Formatting ------------------------------------------------------------------

  defp infer_format(nil), do: :jsonl
  defp infer_format("jsonl"), do: :jsonl
  defp infer_format("human"), do: :human
  defp infer_format("compact"), do: :compact
  defp infer_format(atom) when atom in [:jsonl, :human, :compact], do: atom
  defp infer_format(_), do: :jsonl

  defp emit(event, format) do
    output =
      case format do
        :jsonl -> Jason.encode!(event)
        :human -> human_format(event)
        :compact -> compact_format(event)
      end

    IO.puts(output)
  rescue
    error ->
      IO.puts(:stderr, "Failed to encode event #{inspect(event)}: #{Exception.message(error)}")
  end

  defp human_format(%{
         event: "dm.sent",
         dm_key: dm_key,
         sender: sender,
         recipient: recipient,
         message: message
       }) do
    "DM sent #{dm_key} #{sender} -> #{recipient}: #{message["text"]}"
  end

  defp human_format(%{event: "message.sent", dm_key: dm_key, message: message}) do
    "You -> #{dm_key}: #{message["text"]}"
  end

  defp human_format(%{event: "message.live", dm_key: dm_key, message: message}) do
    sender = message["sender_id"] || "unknown"
    text = message["text"] || ""
    "#{dm_key} #{sender}: #{text}"
  end

  defp human_format(%{event: "history.message", dm_key: dm_key, message: message}) do
    sender = message["sender_id"] || "unknown"
    text = message["text"] || ""
    timestamp = message["created_at"] || ""
    "[#{timestamp}] #{dm_key} #{sender}: #{text}"
  end

  defp human_format(%{event: "broadcast.sent", sender: sender, message: message}) do
    "Broadcast from #{sender}: #{message["text"]}"
  end

  defp human_format(%{event: "broadcast.live", message: message}) do
    sender = message["sender_id"] || "broadcast"
    text = message["text"] || ""
    "Broadcast #{sender}: #{text}"
  end

  defp human_format(%{event: "inbox.entry", conversation: convo}) do
    dm_key = convo["dm_key"] || "unknown"
    last = convo["last_message_text"] || ""
    unread = convo["unread_count"] || 0
    "Inbox #{dm_key} unread=#{unread} last=#{last}"
  end

  defp human_format(%{event: "inbox.update", update: update}) do
    dm_key = update["dm_key"] || "unknown"
    unread = update["unread_count"] || 0
    last = update["last_message_text"] || ""
    "Inbox update #{dm_key} unread=#{unread} last=#{last}"
  end

  defp human_format(%{event: "session.connected", url: url}), do: "Connected to #{url}"

  defp human_format(%{event: "session.disconnected", reason: reason}),
    do: "Disconnected: #{reason}"

  defp human_format(%{event: "session.closed", code: code, reason: reason}),
    do: "Connection closed (#{code}): #{reason}"

  defp human_format(%{event: "chat.ready", dm_key: dm_key, history_count: count}),
    do: "Chat ready for #{dm_key} (#{count} messages)"

  defp human_format(%{
         event: "listen.started",
         participant: participant,
         dm_keys: dm_keys,
         broadcast: broadcast?
       }) do
    targets = Enum.join(dm_keys, ", ")
    "Listening as #{participant} targets=[#{targets}] broadcast=#{broadcast?}"
  end

  defp human_format(%{event: "chat.finished", reason: reason}), do: "Chat finished (#{reason})"

  defp human_format(%{event: "error", context: context, reason: reason} = event) do
    hint = event[:meta] && " hint=#{inspect(event[:meta])}"
    "Error (#{context}): #{reason}#{hint || ""}"
  end

  defp human_format(event), do: "Event: #{inspect(event)}"

  defp compact_format(event) do
    event
    |> Map.to_list()
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> Enum.join(" ")
  end

  defp error_event(context, reason, meta \\ %{}) do
    %{event: "error", context: context, reason: reason, meta: meta}
  end

  # Usage -----------------------------------------------------------------------

  defp print_usage(device) do
    IO.puts(device, "Usage: mix run scripts/test_client.exs <command> [options]")
    IO.puts(device, "Commands:")
    IO.puts(device, "  send_dm --from --to --text|--file|--stdin")
    IO.puts(device, "  send_broadcast --from --text|--file|--stdin")
    IO.puts(device, "  history --participant (--with|--dm-key) [--limit]")
    IO.puts(device, "  inbox --participant")
    IO.puts(device, "  listen --participant [--dm-key ...] [--with ...] [--broadcast]")
    IO.puts(device, "  chat --from --to")
    IO.puts(device, "  help [command]")
  end

  defp command_usage("send_dm") do
    {:ok,
     "send_dm --from <participant> --to <participant> (--text | --file | --stdin)\n" <>
       "Options:\n" <>
       "  --format=human|jsonl|compact\n" <>
       "  --api-url=<url>"}
  end

  defp command_usage("send_broadcast") do
    {:ok,
     "send_broadcast --from <participant> (--text | --file | --stdin)\n" <>
       "Options:\n" <>
       "  --format=human|jsonl|compact\n" <>
       "  --api-url=<url>"}
  end

  defp command_usage("history") do
    {:ok,
     "history --participant <participant> (--with <participant> | --dm-key <key>) [--limit N]\n" <>
       "Options:\n" <>
       "  --format=human|jsonl|compact\n" <>
       "  --api-url=<url>"}
  end

  defp command_usage("inbox") do
    {:ok,
     "inbox --participant <participant>\n" <>
       "Options:\n" <>
       "  --format=human|jsonl|compact\n" <>
       "  --socket-url=<url>"}
  end

  defp command_usage("listen") do
    {:ok,
     "listen --participant <participant> [--dm-key <key> ...] [--with <participant> ...] [--broadcast]\n" <>
       "Options:\n" <>
       "  --format=human|jsonl|compact\n" <>
       "  --socket-url=<url>"}
  end

  defp command_usage("chat") do
    {:ok,
     "chat --from <participant> --to <participant>\n" <>
       "Options:\n" <>
       "  --format=human|jsonl|compact\n" <>
       "  --socket-url=<url>\n" <>
       "  --api-url=<url>"}
  end

  defp command_usage(_), do: :error
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
      heartbeat_ref: nil
    }

    WebSockex.start_link(url, __MODULE__, state, name: name)
  end

  def name(participant_id), do: {:global, {__MODULE__, participant_id}}

  def subscribe(pid, dm_key), do: WebSockex.cast(pid, {:subscribe, dm_key})
  def stop(pid), do: WebSockex.cast(pid, :stop)

  @impl true
  def handle_connect(_conn, state) do
    send(state.owner, {:socket, {:connected, state.url}})
    send(self(), :join_inbox)
    {:ok, schedule_heartbeat(state)}
  end

  @impl true
  def handle_cast(:stop, state) do
    {:close, 1000, "client requested", state}
  end

  def handle_cast({:subscribe, dm_key}, state) do
    dm_key = String.trim(dm_key)

    cond do
      dm_key == "" ->
        {:ok, state}

      MapSet.member?(state.subscriptions, dm_key) ->
        {:ok, state}

      true ->
        {state, frame} =
          push(state, "conversation:" <> dm_key, "phx_join", %{}, {:subscribe, dm_key})

        {:reply, frame, state}
    end
  end

  @impl true
  def handle_frame({:text, payload}, state) do
    case Jason.decode(payload) do
      {:ok, %{"event" => "phx_reply", "ref" => ref} = message} ->
        handle_reply(ref, message, state)

      {:ok,
       %{"topic" => "conversation:" <> _ = _topic, "event" => "message", "payload" => payload}} ->
        dispatch_message(payload, state)

      {:ok,
       %{"topic" => "conversation:" <> _ = _topic, "event" => "broadcast", "payload" => payload}} ->
        send(state.owner, {:socket, {:broadcast, payload}})
        {:ok, state}

      {:ok, %{"topic" => "inbox:" <> _ = _topic, "event" => "message", "payload" => payload}} ->
        send(state.owner, {:socket, {:inbox_message, payload}})
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
  def handle_info(:join_inbox, state) do
    {state, frame} = push(state, "inbox:" <> state.participant_id, "phx_join", %{}, {:inbox_join})
    {:reply, frame, state}
  end

  def handle_info(:heartbeat, state) do
    {state, frame} = push(state, "phoenix", "heartbeat", %{}, nil)
    {:reply, frame, schedule_heartbeat(state)}
  end

  def handle_info({:send_frames, frames}, state) do
    reply_with_frames(state, frames)
  end

  def handle_info(_, state), do: {:ok, state}

  @impl true
  def handle_disconnect(map, state) do
    send(state.owner, {:socket, {:disconnected, map}})
    {:ok, %{state | heartbeat_ref: nil}}
  end

  @impl true
  def terminate({:remote, code, reason}, state) do
    send(state.owner, {:socket, {:closed, code, reason}})
    :ok
  end

  def terminate(reason, state) do
    send(state.owner, {:socket, {:closed, nil, inspect(reason)}})
    :ok
  end

  defp handle_reply(ref, message, state) do
    case Map.pop(state.pending, ref) do
      {nil, pending} -> {:ok, %{state | pending: pending}}
      {action, pending} -> process_reply(action, message, %{state | pending: pending})
    end
  end

  defp process_reply(
         {:inbox_join},
         %{"payload" => %{"status" => "ok", "response" => resp}},
         state
       ) do
    conversations = Map.get(resp, "conversations", [])
    send(state.owner, {:socket, {:inbox_snapshot, conversations}})
    send(state.owner, {:socket, :inbox_ready})
    {:ok, state}
  end

  defp process_reply({:inbox_join}, %{"payload" => %{"status" => "ok"}}, state) do
    send(state.owner, {:socket, :inbox_ready})
    {:ok, state}
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
    send(state.owner, {:socket, {:conversation_message, payload}})
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

  defp reply_with_frames(state, []), do: {:ok, state}
  defp reply_with_frames(state, [frame]), do: {:reply, frame, state}

  defp reply_with_frames(state, [frame | rest]) do
    send(self(), {:send_frames, rest})
    {:reply, frame, state}
  end

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

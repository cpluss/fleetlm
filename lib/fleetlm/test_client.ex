defmodule Fleetlm.TestClient do
  @moduledoc """
  Minimal CLI for interacting with the session-based runtime.

  Commands:
    create_session --initiator ID --peer ID
    send_message --session ID --sender ID --text "message"
    history --session ID [--limit N]
    inbox --participant ID
    help [command]
  """

  alias Fleetlm.Conversation

  def main([]) do
    print_usage(:stderr)
    System.halt(64)
  end

  def main(["help" | rest]) do
    case rest do
      [] -> print_usage(:stdout)
      [cmd] -> IO.puts(command_usage(cmd))
      _ -> print_usage(:stdout)
    end
  end

  def main([command | args]) do
    case dispatch(String.downcase(command), args) do
      {:ok, message} ->
        IO.puts(:stdout, Jason.encode!(message))
        System.halt(0)

      {:error, msg, exit_code} ->
        IO.puts(:stderr, msg)
        System.halt(exit_code)
    end
  end

  defp dispatch("create_session", args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [initiator: :string, peer: :string])

    with {:ok, initiator} <- require_participant(opts[:initiator], :initiator),
         {:ok, peer} <- require_participant(opts[:peer], :peer) do
      {:ok, session} =
        Conversation.start_session(%{initiator_id: initiator, peer_id: peer})

      {:ok, %{event: "session.created", session: render_session(session)}}
    else
      {:error, :participant, which} ->
        {:error, "Missing required --#{which}", 64}

      {:error, reason} ->
        {:error, inspect(reason), 70}
    end
  end

  defp dispatch("send_message", args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [session: :string, sender: :string, text: :string])

    with {:ok, session_id} <- require_session(opts[:session]),
         {:ok, sender} <- require_participant(opts[:sender], :sender),
         {:ok, text} <- require_text(opts[:text]) do
      {:ok, message} =
        Conversation.append_message(session_id, %{
          sender_id: sender,
          kind: "text",
          content: %{text: text}
        })

      {:ok,
       %{
         event: "session.message",
         session_id: session_id,
         message: render_message(message)
       }}
    else
      {:error, :session} -> {:error, "Missing required --session", 64}
      {:error, :participant, which} -> {:error, "Missing required --#{which}", 64}
      {:error, :text} -> {:error, "Missing required --text", 64}
      {:error, reason} -> {:error, inspect(reason), 70}
    end
  end

  defp dispatch("history", args) do
    {opts, _, _} = OptionParser.parse(args, strict: [session: :string, limit: :integer])

    with {:ok, session_id} <- require_session(opts[:session]) do
      messages =
        Conversation.list_messages(session_id, limit: opts[:limit] || 50)
        |> Enum.map(&render_message/1)

      {:ok, %{event: "session.history", session_id: session_id, messages: messages}}
    else
      {:error, :session} -> {:error, "Missing required --session", 64}
    end
  end

  defp dispatch("inbox", args) do
    {opts, _, _} = OptionParser.parse(args, strict: [participant: :string])

    with {:ok, participant} <- require_participant(opts[:participant], :participant) do
      sessions =
        Conversation.list_sessions_for_participant(participant)
        |> Enum.map(&render_session/1)

      {:ok, %{event: "inbox.snapshot", participant: participant, sessions: sessions}}
    else
      {:error, :participant, which} -> {:error, "Missing required --#{which}", 64}
    end
  end

  defp dispatch(_, _args), do: {:error, "Unknown command", 64}

  defp render_session(session) do
    %{
      id: session.id,
      initiator_id: session.initiator_id,
      peer_id: session.peer_id,
      agent_id: session.agent_id,
      kind: session.kind,
      status: session.status,
      metadata: session.metadata,
      last_message_id: session.last_message_id,
      last_message_at: encode_datetime(session.last_message_at)
    }
  end

  defp render_message(message) do
    %{
      id: message.id,
      session_id: message.session_id,
      sender_id: message.sender_id,
      kind: message.kind,
      content: message.content,
      metadata: message.metadata,
      inserted_at: encode_datetime(message.inserted_at)
    }
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)

  defp require_participant(nil, which), do: {:error, :participant, which}
  defp require_participant(value, _), do: {:ok, normalize_participant(value)}

  defp require_session(nil), do: {:error, :session}
  defp require_session(value), do: {:ok, String.trim(value)}

  defp require_text(nil), do: {:error, :text}
  defp require_text(text), do: {:ok, text}

  defp normalize_participant(value) when is_binary(value), do: String.trim(value)
  defp normalize_participant(value), do: to_string(value)

  defp print_usage(device) do
    IO.puts(device, "Usage: mix run scripts/test_client.exs <command> [options]")
    IO.puts(device, "Commands: create_session, send_message, history, inbox, help")
  end

  defp command_usage("create_session") do
    "create_session --initiator ID --peer ID"
  end

  defp command_usage("send_message") do
    "send_message --session ID --sender ID --text \"message\""
  end

  defp command_usage("history") do
    "history --session ID [--limit N]"
  end

  defp command_usage("inbox") do
    "inbox --participant ID"
  end

  defp command_usage(_), do: ""
end

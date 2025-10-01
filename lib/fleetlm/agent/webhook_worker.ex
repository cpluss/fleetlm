defmodule Fleetlm.Agent.WebhookWorker do
  @moduledoc """
  Pooled worker for agent webhook delivery using Req + Finch HTTP/2 client.

  Handles the complete webhook flow:
  1. Load agent config
  2. Load session
  3. Fetch message history (based on agent's mode: tail/entire/last)
  4. POST to agent endpoint with Req + Finch
  5. Stream JSONL response line-by-line
  6. Append each agent message to session as it arrives
  """

  use GenServer
  require Logger

  alias Fleetlm.Agent
  alias Fleetlm.Runtime.Router
  alias FleetLM.Storage.API, as: StorageAPI

  # 10 minutes for long-running agent requests
  @receive_timeout 10 * 60 * 1000

  ## Public API (called by poolboy)

  def start_link(_args) do
    GenServer.start_link(__MODULE__, [])
  end

  ## GenServer Implementation

  @impl true
  def init(_args) do
    {:ok, %{stats: %{dispatches: 0, successes: 0, failures: 0}}}
  end

  @impl true
  def handle_cast({:dispatch, session_id, agent_id}, state) do
    # Spawn task to avoid blocking the worker
    Task.start(fn -> do_dispatch(session_id, agent_id) end)
    {:noreply, update_in(state.stats.dispatches, &(&1 + 1))}
  end

  ## Private Functions

  defp do_dispatch(session_id, agent_id) do
    start_time = System.monotonic_time(:millisecond)

    result =
      with {:ok, agent} <- Agent.get(agent_id),
           :ok <- check_agent_enabled(agent),
           {:ok, session} <- StorageAPI.get_session(session_id),
           {:ok, messages} <- fetch_message_history(session_id, agent),
           # post_to_agent now streams and appends messages directly
           :ok <- post_to_agent(agent, session, messages) do
        :ok
      else
        error -> error
      end

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      :ok ->
        Logger.debug("Agent webhook success",
          session_id: session_id,
          agent_id: agent_id,
          duration_ms: duration
        )

        log_success(agent_id, session_id, duration)

      {:error, reason} ->
        Logger.warning("Agent webhook failed: #{inspect(reason)}",
          session_id: session_id,
          agent_id: agent_id,
          duration_ms: duration
        )

        log_failure(agent_id, session_id, reason, duration)
    end
  end

  defp check_agent_enabled(%{status: "enabled"}), do: :ok
  defp check_agent_enabled(_), do: {:error, :agent_disabled}

  # Fetch message history based on agent configuration
  defp fetch_message_history(session_id, agent) do
    case agent.message_history_mode do
      "tail" ->
        StorageAPI.get_messages(session_id, 0, agent.message_history_limit)

      "entire" ->
        Logger.warning("Fetching ENTIRE message history for session #{session_id} (expensive!)",
          session_id: session_id,
          agent_id: agent.id
        )

        StorageAPI.get_all_messages(session_id)

      "last" ->
        {:ok, messages} = StorageAPI.get_messages(session_id, 0, 1)
        {:ok, Enum.take(messages, -1)}
    end
  end

  # POST to agent endpoint using Req + Finch
  defp post_to_agent(agent, session, messages) do
    payload = build_payload(session, messages)
    url = agent.origin_url <> agent.webhook_path
    headers = build_headers_map(agent)

    req_post_streaming(url, payload, headers, session.id, agent.id)
  end

  # POST with streaming JSONL response handling
  defp req_post_streaming(url, payload, headers, session_id, agent_id) do
    body = Jason.encode!(payload)

    # Base options
    base_opts = [
      url: url,
      method: :post,
      headers: headers,
      body: body,
      connect_options: [timeout: 5_000],
      pool_timeout: 50,
      receive_timeout: @receive_timeout,
      retry: false
    ]

    # Merge test opts first, then add defaults
    req_opts =
      base_opts
      |> Keyword.merge(Application.get_env(:fleetlm, :agent_req_opts, []))
      |> Keyword.put_new(:finch, Fleetlm.Finch)
      |> Keyword.put_new(:into, :self)

    req = Req.new(req_opts)

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        # Handle three cases: binary JSONL, decoded map, or stream
        result =
          cond do
            is_binary(body) ->
              # JSONL string response
              process_jsonl_body(body, session_id, agent_id)

            is_map(body) and not Map.has_key?(body, :__struct__) ->
              # Decoded JSON response (plug adapter auto-decodes)
              # Parse and append single message
              line = Jason.encode!(body)
              parse_and_append_message(line, session_id, agent_id)

            true ->
              # Streaming response (Finch with :self)
              consume_stream(body, session_id, agent_id, "")
          end

        case result do
          {:ok, _message_count} -> :ok
          error -> error
        end

      {:ok, %Req.Response{status: status}} ->
        Logger.error("HTTP error: #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("Req request failed: #{inspect(reason)}",
          url: url,
          session_id: session_id,
          agent_id: agent_id
        )

        {:error, {:request_failed, reason}}
    end
  end

  # Process complete JSONL body (for test mode)
  defp process_jsonl_body(body, session_id, agent_id) do
    lines =
      body
      |> String.split("\n")
      |> Enum.reject(&(&1 == "" or String.trim(&1) == ""))

    Enum.reduce_while(lines, {:ok, 0}, fn line, {:ok, count} ->
      case parse_and_append_message(line, session_id, agent_id) do
        :ok ->
          {:cont, {:ok, count + 1}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # Consume streaming response, parsing JSONL and appending messages
  defp consume_stream(stream, session_id, agent_id, buffer, message_count \\ 0) do
    receive do
      {^stream, {:data, chunk}} ->
        # Add chunk to buffer and process complete lines
        new_buffer = buffer <> chunk
        {lines, remaining} = extract_lines(new_buffer)

        # Process each complete line as a JSONL message
        result =
          Enum.reduce_while(lines, {:ok, message_count}, fn line, {:ok, count} ->
            case parse_and_append_message(line, session_id, agent_id) do
              :ok -> {:cont, {:ok, count + 1}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        case result do
          {:ok, new_count} ->
            consume_stream(stream, session_id, agent_id, remaining, new_count)

          error ->
            error
        end

      {^stream, :done} ->
        # Process any remaining buffer content
        if buffer != "" and String.trim(buffer) != "" do
          case parse_and_append_message(buffer, session_id, agent_id) do
            :ok -> {:ok, message_count + 1}
            error -> error
          end
        else
          {:ok, message_count}
        end

      {^stream, {:error, reason}} ->
        {:error, {:stream_error, reason}}
    after
      @receive_timeout ->
        {:error, :receive_timeout}
    end
  end

  # Extract complete lines from buffer (newline-delimited)
  defp extract_lines(buffer) do
    case :binary.split(buffer, "\n", [:global]) do
      [] ->
        {[], buffer}

      parts ->
        # Last part might be incomplete if it doesn't end with \n
        {complete, [last]} = Enum.split(parts, -1)
        {complete, last}
    end
  end

  # Parse single JSONL line and append to session
  defp parse_and_append_message(line, session_id, agent_id) do
    line = String.trim(line)

    if line == "" do
      :ok
    else
      case Jason.decode(line) do
        {:ok, %{"kind" => kind, "content" => content} = msg} ->
          metadata = Map.get(msg, "metadata", %{})

          Router.append_message(
            session_id,
            agent_id,
            kind,
            content,
            metadata
          )

        {:ok, _other} ->
          Logger.warning("Invalid JSONL message format (missing kind/content)",
            session_id: session_id,
            agent_id: agent_id,
            line: line
          )

          {:error, :invalid_message_format}

        {:error, reason} ->
          Logger.warning("Failed to parse JSONL line: #{inspect(reason)}",
            session_id: session_id,
            agent_id: agent_id,
            line: line
          )

          {:error, {:json_decode_failed, reason}}
      end
    end
  end

  defp build_payload(session, messages) do
    %{
      session_id: session.id,
      agent_id: session.agent_id,
      user_id: session.user_id,
      messages: Enum.map(messages, &format_message/1)
    }
  end

  defp format_message(msg) do
    %{
      seq: msg.seq,
      sender_id: msg.sender_id,
      kind: msg.kind,
      content: msg.content,
      inserted_at: NaiveDateTime.to_iso8601(msg.inserted_at)
    }
  end

  defp build_headers_map(agent) do
    base = %{
      "content-type" => "application/json",
      "accept" => "application/json"
    }

    # Merge custom headers
    Map.merge(base, agent.headers)
  end

  defp log_success(agent_id, session_id, duration) do
    Agent.log_delivery(%{
      agent_id: agent_id,
      session_id: session_id,
      status: "success",
      latency_ms: duration
    })
  end

  defp log_failure(agent_id, session_id, reason, duration) do
    Agent.log_delivery(%{
      agent_id: agent_id,
      session_id: session_id,
      status: "failed",
      error: inspect(reason),
      latency_ms: duration
    })
  end
end

defmodule Fleetlm.Agent.WebhookWorker do
  @moduledoc """
  Pooled worker for agent webhook delivery using :gun HTTP client.

  Handles the complete webhook flow:
  1. Load agent config
  2. Load session
  3. Fetch message history (based on agent's mode: tail/entire/last)
  4. POST to agent endpoint with :gun
  5. Parse response
  6. Append agent's response to session
  """

  use GenServer
  require Logger

  alias Fleetlm.Agent
  alias Fleetlm.Runtime.Router
  alias FleetLM.Storage.API, as: StorageAPI

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
      case Agent.get(agent_id) do
        {:ok, agent} ->
          dispatch_to_agent(session_id, agent_id, agent)

        {:error, _reason} = error ->
          error
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

  defp dispatch_to_agent(session_id, agent_id, agent) do
    case check_agent_enabled(agent) do
      :ok ->
        case StorageAPI.get_session(session_id) do
          {:ok, session} ->
            {:ok, messages} = fetch_message_history(session_id, agent)

            case post_to_agent(agent, session, messages) do
              {:ok, response} ->
                case append_agent_response(session_id, agent_id, response) do
                  {:ok, _message} -> :ok
                  {:error, _reason} = error -> error
                end

              {:error, _reason} = error ->
                error
            end

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
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

  # POST to agent endpoint using :gun
  defp post_to_agent(agent, session, messages) do
    payload = build_payload(session, messages)

    # Check for test mode
    case Application.get_env(:fleetlm, :agent_webhook_test_mode) do
      %{enabled: true, test_pid: test_pid} ->
        # Test mode - send payload to test process and get mocked response
        send(test_pid, {:agent_webhook_called, payload})

        # Get response from ETS table set by test (queue-like behavior)
        case :ets.first(:agent_responses) do
          :"$end_of_table" ->
            {:error, :no_test_response}

          key ->
            case :ets.lookup(:agent_responses, key) do
              [{^key, response}] when is_map(response) ->
                # Remove this response from the queue
                :ets.delete(:agent_responses, key)
                # Validate response has required fields and convert
                case response do
                  %{"kind" => kind, "content" => content, "metadata" => metadata} ->
                    {:ok, %{kind: kind, content: content, metadata: metadata}}

                  %{"kind" => kind, "content" => content} ->
                    {:ok, %{kind: kind, content: content, metadata: %{}}}

                  %{"kind" => _kind} ->
                    {:error, :missing_content}

                  %{"content" => _content} ->
                    {:error, :missing_kind}

                  _ ->
                    {:error, :invalid_response}
                end

              [{^key, ""}] ->
                :ets.delete(:agent_responses, key)
                {:error, :empty_response}

              [] ->
                {:error, :no_test_response}
            end
        end

      _ ->
        # Production mode - real HTTP call
        url = agent.origin_url <> agent.webhook_path
        uri = URI.parse(url)
        headers = build_headers(agent)
        body = Jason.encode!(payload)

        with {:ok, conn_pid} <- gun_connect(uri),
             {:ok, response_body} <-
               gun_post(conn_pid, uri.path || "/", headers, body, agent.timeout_ms) do
          :gun.close(conn_pid)
          parse_agent_response(response_body)
        else
          {:error, reason} = error ->
            Logger.error("HTTP request failed: #{inspect(reason)}",
              agent_id: agent.id,
              url: url
            )

            error
        end
    end
  end

  defp gun_connect(uri) do
    host = to_charlist(uri.host)
    port = uri.port || if uri.scheme == "https", do: 443, else: 80
    opts = %{protocols: [:http]}

    case :gun.open(host, port, opts) do
      {:ok, conn_pid} ->
        case :gun.await_up(conn_pid, 5000) do
          {:ok, _protocol} ->
            {:ok, conn_pid}

          {:error, reason} ->
            :gun.close(conn_pid)
            {:error, {:await_up_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  defp gun_post(conn_pid, path, headers, body, timeout) do
    stream_ref = :gun.post(conn_pid, path, headers, body)

    case :gun.await(conn_pid, stream_ref, timeout) do
      {:response, :fin, status, _headers} when status in 200..299 ->
        {:ok, ""}

      {:response, :nofin, status, _headers} when status in 200..299 ->
        case :gun.await_body(conn_pid, stream_ref, timeout) do
          {:ok, response_body} -> {:ok, response_body}
          {:error, reason} -> {:error, {:body_read_failed, reason}}
        end

      {:response, _fin, status, _headers} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:await_failed, reason}}
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

  defp build_headers(agent) do
    base = [
      {~c"content-type", ~c"application/json"},
      {~c"accept", ~c"application/json"}
    ]

    # Add custom headers
    custom =
      Enum.map(agent.headers, fn {k, v} ->
        {to_charlist(k), to_charlist(v)}
      end)

    base ++ custom
  end

  defp parse_agent_response(body) when is_binary(body) and body != "" do
    case Jason.decode(body) do
      {:ok, %{"kind" => kind, "content" => content, "metadata" => metadata}} ->
        {:ok, %{kind: kind, content: content, metadata: metadata}}

      {:ok, %{"kind" => kind, "content" => content}} ->
        {:ok, %{kind: kind, content: content, metadata: %{}}}

      {:ok, %{"kind" => _kind}} ->
        {:error, :missing_content}

      {:ok, %{"content" => _content}} ->
        {:error, :missing_kind}

      {:ok, _other} ->
        {:error, :invalid_response_format}

      {:error, reason} ->
        {:error, {:json_decode_failed, reason}}
    end
  end

  defp parse_agent_response(""), do: {:error, :empty_response}

  defp append_agent_response(session_id, agent_id, response) do
    Router.append_message(
      session_id,
      agent_id,
      response.kind,
      response.content,
      response.metadata
    )
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

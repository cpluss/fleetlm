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
    {:ok, %{stats: %{dispatches: 0, successes: 0, failures: 0}, jobs: %{}}}
  end

  @impl true
  def handle_cast({:dispatch, session_id, agent_id}, state) do
    Logger.info("Dispatching agent webhook",
      session_id: session_id,
      agent_id: agent_id
    )

    start_time = System.monotonic_time(:millisecond)

    case begin_dispatch(session_id, agent_id, start_time) do
      {:ok, job} ->
        stats = increment_stats(state.stats, :dispatches)
        jobs = Map.put(state.jobs, job.ref, job)
        {:noreply, %{state | stats: stats, jobs: jobs}}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time

        Logger.warning("Agent webhook failed: #{inspect(reason)}",
          session_id: session_id,
          agent_id: agent_id,
          duration_ms: duration
        )

        log_failure(agent_id, session_id, reason, duration)

        stats = increment_stats(state.stats, :failures)
        {:noreply, %{state | stats: stats}}
    end
  end

  @impl true
  def handle_info(message, %{jobs: jobs} = state) do
    case locate_job(message, jobs) do
      :unknown ->
        {:noreply, state}

      {:error, ref, job, reason} ->
        {:noreply, fail_job(state, ref, job, reason)}

      {:ok, ref, job, chunks} ->
        case process_chunks(job, chunks) do
          {:ok, pending_job} ->
            {:noreply, %{state | jobs: Map.put(state.jobs, ref, pending_job)}}

          {:done, finished_job} ->
            {:noreply, succeed_job(state, ref, finished_job)}

          {:error, reason, errored_job} ->
            {:noreply, fail_job(state, ref, errored_job, reason)}
        end
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

          case Router.append_message(session_id, agent_id, kind, content, metadata) do
            {:ok, _message} -> :ok
            {:error, reason} -> {:error, reason}
          end

        {:ok, _other} ->
          Logger.warning("Invalid JSONL message format (missing kind/content)",
            session_id: session_id,
            agent_id: agent_id,
            line: line
          )

          # Emit telemetry - CRITICAL protocol violation
          Fleetlm.Observability.Telemetry.emit_agent_parse_error(
            agent_id,
            session_id,
            :missing_fields,
            line
          )

          {:error, :invalid_message_format}

        {:error, reason} ->
          Logger.warning("Failed to parse JSONL line: #{inspect(reason)}",
            session_id: session_id,
            agent_id: agent_id,
            line: line
          )

          # Emit telemetry - CRITICAL protocol violation
          Fleetlm.Observability.Telemetry.emit_agent_parse_error(
            agent_id,
            session_id,
            :invalid_json,
            line
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

  defp begin_dispatch(session_id, agent_id, started_at) do
    with {:ok, agent} <- Agent.get(agent_id),
         :ok <- check_agent_enabled(agent),
         {:ok, session} <- StorageAPI.get_session(session_id),
         {:ok, messages} <- fetch_message_history(session_id, agent),
         {:ok, response} <- start_async_request(agent, session, messages) do
      async = response.body

      job = %{
        ref: async.ref,
        session_id: session_id,
        agent_id: agent_id,
        response: response,
        buffer: "",
        message_count: 0,
        started_at: started_at
      }

      {:ok, job}
    else
      {:error, _} = error -> error
    end
  end

  defp start_async_request(agent, session, messages) do
    payload = build_payload(session, messages)
    url = agent.origin_url <> agent.webhook_path
    headers = build_headers_map(agent)
    body = Jason.encode!(payload)

    base_opts = [
      url: url,
      method: :post,
      headers: headers,
      body: body,
      pool_timeout: 50,
      receive_timeout: @receive_timeout,
      retry: false
    ]

    req_opts =
      base_opts
      |> Keyword.merge(Application.get_env(:fleetlm, :agent_req_opts, []))
      |> Keyword.put(:into, :self)
      |> Keyword.put_new(:finch, Fleetlm.Finch)

    case Req.request(Req.new(req_opts)) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        Logger.info("Agent webhook request started",
          session_id: session.id,
          agent_id: agent.id,
          status: status,
          async: match?(%Req.Response.Async{}, response.body)
        )

        {:ok, response}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp locate_job(message, jobs) do
    Enum.find_value(jobs, :unknown, fn {ref, job} ->
      case Req.parse_message(job.response, message) do
        :unknown -> nil
        {:ok, chunks} -> {:ok, ref, job, chunks}
        {:error, reason} -> {:error, ref, job, reason}
      end
    end)
  end

  defp process_chunks(job, chunks) do
    Enum.reduce_while(chunks, {:ok, job}, fn chunk, {:ok, current_job} ->
      case handle_chunk(current_job, chunk) do
        {:ok, updated_job} ->
          {:cont, {:ok, updated_job}}

        {:done, updated_job} ->
          {:halt, {:done, updated_job}}

        {:error, reason, errored_job} ->
          {:halt, {:error, reason, errored_job}}
      end
    end)
    |> case do
      {:ok, updated_job} -> {:ok, updated_job}
      {:done, updated_job} -> {:done, updated_job}
      {:error, reason, errored_job} -> {:error, reason, errored_job}
    end
  end

  defp handle_chunk(job, {:data, data}) do
    buffer = job.buffer <> data
    {lines, remaining} = extract_lines(buffer)

    Enum.reduce_while(lines, {:ok, %{job | buffer: remaining}}, fn line, {:ok, acc_job} ->
      case append_message(acc_job, line) do
        {:ok, next_job} -> {:cont, {:ok, next_job}}
        {:error, reason, errored_job} -> {:halt, {:error, reason, errored_job}}
      end
    end)
  end

  defp handle_chunk(job, {:trailers, _trailers}), do: {:ok, job}
  defp handle_chunk(job, :done), do: {:done, job}
  defp handle_chunk(job, _other), do: {:ok, job}

  defp append_message(job, line) do
    case parse_and_append_message(line, job.session_id, job.agent_id) do
      :ok ->
        {:ok, increment_count(job)}

      {:error, reason} ->
        {:error, reason, job}
    end
  end

  defp increment_count(job) do
    Map.update!(job, :message_count, &(&1 + 1))
  end

  defp succeed_job(state, ref, job) do
    duration = System.monotonic_time(:millisecond) - job.started_at
    duration_us = duration * 1000

    Logger.debug("Agent webhook success",
      session_id: job.session_id,
      agent_id: job.agent_id,
      messages: job.message_count,
      duration_ms: duration
    )

    # Emit telemetry
    Fleetlm.Observability.Telemetry.emit_agent_webhook(
      job.agent_id,
      job.session_id,
      :ok,
      duration_us,
      message_count: job.message_count,
      status_code: 200
    )

    log_success(job.agent_id, job.session_id, duration)

    stats = increment_stats(state.stats, :successes)
    %{state | stats: stats, jobs: Map.delete(state.jobs, ref)}
  end

  defp fail_job(state, ref, job, reason) do
    duration = System.monotonic_time(:millisecond) - job.started_at
    duration_us = duration * 1000

    Logger.warning("Agent webhook failed: #{inspect(reason)}",
      session_id: job.session_id,
      agent_id: job.agent_id,
      duration_ms: duration
    )

    # Emit telemetry - CRITICAL for agent reliability tracking
    error_type = classify_error(reason)

    Fleetlm.Observability.Telemetry.emit_agent_webhook(
      job.agent_id,
      job.session_id,
      :error,
      duration_us,
      error_type: error_type,
      message_count: 0
    )

    log_failure(job.agent_id, job.session_id, reason, duration)

    Req.cancel_async_response(job.response)

    stats = increment_stats(state.stats, :failures)
    %{state | stats: stats, jobs: Map.delete(state.jobs, ref)}
  end

  defp classify_error({:request_failed, %Req.TransportError{}}), do: :connection
  defp classify_error({:request_failed, %Req.HTTPError{}}), do: :connection
  defp classify_error({:http_error, _}), do: :http_error
  defp classify_error(_), do: :unknown

  defp increment_stats(stats, key) do
    Map.update(stats, key, 1, &(&1 + 1))
  end
end

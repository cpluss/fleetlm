defmodule Fleetlm.Agent.Dispatch do
  @moduledoc """
  Executes a single agent webhook.

  Runs in a short-lived task: builds payload, sends the HTTP request, streams the
  JSONL response, and appends agent messages back into the session.
  """

  require Logger

  alias Fleetlm.Agent
  alias Fleetlm.Agent.StreamAssembler
  alias Fleetlm.Observability.Telemetry
  alias Fleetlm.Runtime
  alias Fleetlm.Storage
  alias Phoenix.PubSub

  @type job :: %{
          agent_id: String.t(),
          session_id: String.t(),
          user_id: String.t(),
          last_sent: non_neg_integer(),
          target_seq: non_neg_integer(),
          first_seq: non_neg_integer(),
          enqueued_at: integer(),
          started_at: integer()
        }

  @spec run(job()) ::
          {:ok,
           %{
             duration_ms: integer(),
             message_count: non_neg_integer(),
             started_at: integer(),
             enqueued_at: integer()
           }}
          | {:error, term()}
  def run(
        %{
          agent_id: agent_id,
          session_id: session_id,
          started_at: started_at,
          enqueued_at: enqueued_at
        } = job
      ) do
    started_ms = System.monotonic_time(:millisecond)

    with {:ok, agent} <- Agent.Cache.get(agent_id),
         :ok <- ensure_enabled(agent),
         {:ok, history} <- fetch_history(session_id, agent, job),
         {:ok, message_count} <- dispatch(agent, job, history) do
      duration_ms = System.monotonic_time(:millisecond) - started_ms

      Telemetry.emit_agent_webhook(
        agent_id,
        session_id,
        :ok,
        duration_ms * 1000,
        message_count: message_count,
        status_code: 200
      )

      {:ok,
       %{
         duration_ms: duration_ms,
         message_count: message_count,
         started_at: started_at,
         enqueued_at: enqueued_at
       }}
    else
      {:error, reason} = error ->
        duration_ms = System.monotonic_time(:millisecond) - started_ms

        Telemetry.emit_agent_webhook(
          agent_id,
          session_id,
          :error,
          duration_ms * 1000,
          error_type: classify_error(reason),
          message_count: 0
        )

        error
    end
  end

  defp dispatch(agent, job, messages) do
    payload = build_payload(agent, job.session_id, job.user_id, messages)
    url = build_url(agent)

    payload_json = Jason.encode!(payload)

    log_agent_request(job, payload, url, byte_size(payload_json))

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
      | custom_headers(agent)
    ]

    # We stream and buffer response bodies in order to handle streaming
    # message responses, intermediary updates, etc without leaning on
    # SSE. This way the webhook can stream jsonl output, or updates, as
    # it pleases.
    acc = %{
      buffer: "",
      count: 0,
      status: nil,
      session_id: job.session_id,
      agent_id: job.agent_id,
      user_id: job.user_id,
      assembler: StreamAssembler.new(role: "assistant")
    }

    request =
      Finch.build(:post, url, headers, payload_json)
      |> Finch.stream(Fleetlm.Agent.HTTP, acc, &handle_stream_chunk/2,
        receive_timeout: agent.timeout_ms,
        pool_timeout: agent.timeout_ms
      )

    case request do
      {:ok, %{assembler: _} = acc} ->
        case flush_buffer(acc) do
          {:ok, final_acc} ->
            log_agent_response(job, final_acc)
            handle_stream_result(final_acc)

          {:error, reason} ->
            Logger.error(
              "[agent_dispatch] flush_failed agent=#{job.agent_id} session=#{job.session_id} reason=#{inspect(reason)}"
            )

            {:error, reason}
        end

      {:ok, {:error, reason}} ->
        Logger.error(
          "[agent_dispatch] stream_failed agent=#{job.agent_id} session=#{job.session_id} reason=#{inspect(reason)}"
        )

        {:error, reason}

      {:ok, other} ->
        Logger.error(
          "[agent_dispatch] unexpected_accumulator agent=#{job.agent_id} session=#{job.session_id} acc=#{inspect(other)}"
        )

        {:error, {:invalid_accumulator, other}}

      {:error, reason} ->
        Logger.error(
          "[agent_dispatch] request_failed agent=#{job.agent_id} session=#{job.session_id} reason=#{inspect(reason)}"
        )

        {:error, {:request_failed, reason}}
    end
  end

  defp handle_stream_result(%{status: status, count: count})
       when is_integer(status) and status in 200..299 do
    {:ok, count}
  end

  defp handle_stream_result(%{status: status}) when is_integer(status) do
    {:error, {:http_error, status}}
  end

  defp handle_stream_result(_acc) do
    {:error, {:request_failed, :missing_status}}
  end

  defp handle_stream_chunk({:status, status}, acc), do: %{acc | status: status}

  defp handle_stream_chunk({:headers, _headers}, acc), do: acc

  defp handle_stream_chunk({:data, data}, acc) when is_map(acc) and is_map_key(acc, :assembler) do
    new_buffer = acc.buffer <> data
    lines = String.split(new_buffer, "\n")
    {complete_lines, [remaining]} = Enum.split(lines, -1)

    result =
      Enum.reduce_while(complete_lines, {:ok, %{acc | buffer: ""}}, fn line, {:ok, acc} ->
        case process_line(line, acc) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, reason, acc} -> {:halt, {:error, reason, acc}}
        end
      end)

    case result do
      {:ok, acc} ->
        %{acc | buffer: remaining}

      {:error, reason, _acc} ->
        {:error, reason}
    end
  end

  defp flush_buffer(%{buffer: buffer, assembler: _} = acc) when is_binary(buffer) do
    trimmed = String.trim(buffer)

    cond do
      buffer == "" ->
        {:ok, acc}

      trimmed == "" ->
        {:ok, %{acc | buffer: ""}}

      true ->
        case process_line(trimmed, %{acc | buffer: ""}) do
          {:ok, acc} -> {:ok, acc}
          {:error, reason, _acc} -> {:error, reason}
        end
    end
  end

  defp process_line(line, %{assembler: _} = acc) do
    trimmed = String.trim(line)

    if trimmed == "" do
      {:ok, acc}
    else
      case Jason.decode(trimmed) do
        {:ok, chunk} ->
          ingest_chunk(chunk, acc)

        {:error, reason} ->
          Telemetry.emit_agent_parse_error(acc.agent_id, acc.session_id, :invalid_json, trimmed)
          {:error, {:json_decode_failed, reason}, acc}
      end
    end
  end

  defp ingest_chunk(chunk, %{assembler: assembler} = acc) when is_map(chunk) do
    chunk_type = Map.get(chunk, "type", "unknown")

    case StreamAssembler.ingest(assembler, chunk) do
      {:ok, new_state, actions} ->
        Telemetry.emit_agent_stream_chunk(acc.agent_id, acc.session_id, chunk_type, :ok)
        acc = %{acc | assembler: new_state}

        case apply_stream_actions(acc, actions) do
          {:ok, acc} -> {:ok, acc}
          {:error, reason, acc} -> {:error, reason, acc}
        end

      {:error, reason, new_state, actions} ->
        Telemetry.emit_agent_stream_chunk(acc.agent_id, acc.session_id, chunk_type, :error)
        acc = %{acc | assembler: new_state}

        case apply_stream_actions(acc, actions) do
          {:ok, acc} -> {:error, reason, acc}
          {:error, reason2, acc} -> {:error, reason2, acc}
        end
    end
  end

  defp apply_stream_actions(acc, actions) do
    Enum.reduce_while(actions, {:ok, acc}, fn action, {:ok, acc} ->
      case handle_stream_action(acc, action) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason, acc} -> {:halt, {:error, reason, acc}}
      end
    end)
  end

  defp handle_stream_action(acc, {:chunk, chunk}) do
    PubSub.broadcast(
      Fleetlm.PubSub,
      "session:#{acc.session_id}",
      {:session_stream_chunk, %{"agent_id" => acc.agent_id, "chunk" => chunk}}
    )

    {:ok, acc}
  end

  defp handle_stream_action(acc, {:finalize, message, meta}) do
    part_count = length(Map.get(message, "parts", []))

    Telemetry.emit_agent_stream_finalized(
      acc.agent_id,
      acc.session_id,
      meta.termination,
      part_count
    )

    case persist_message(acc, message, meta) do
      {:ok, acc} ->
        {:ok, %{acc | assembler: StreamAssembler.new(role: "assistant")}}

      {:error, reason, acc} ->
        {:error, reason, acc}
    end
  end

  defp handle_stream_action(acc, {:abort, _chunk}) do
    {:ok, acc}
  end

  # Persists the final assembled message from the stream to the session.
  # The `termination` metadata tag indicates how the stream ended:
  # - `:finish` - agent completed normally with a "finish" chunk
  # - `:abort` - agent cancelled the stream early with an "abort" chunk
  defp persist_message(acc, message, meta) do
    parts = Map.get(message, "parts", [])
    content = %{"id" => message["id"], "role" => message["role"], "parts" => parts}

    base_metadata =
      case Map.get(message, "metadata") do
        %{} = map -> map
        _ -> %{}
      end

    metadata =
      base_metadata
      |> Map.put("termination", Atom.to_string(meta.termination))

    metadata =
      case Map.get(meta, :finish_chunk) do
        nil -> metadata
        finish_chunk -> Map.put(metadata, "_finish_chunk", finish_chunk)
      end

    case Runtime.append_message(
           acc.session_id,
           acc.agent_id,
           acc.user_id,
           "assistant",
           content,
           metadata
         ) do
      {:ok, _seq} ->
        {:ok, %{acc | count: acc.count + 1}}

      {:timeout, _leader} ->
        Logger.error(
          "[agent_dispatch] append_timeout agent=#{acc.agent_id} session=#{acc.session_id} kind=assistant"
        )

        {:error, :timeout, acc}

      {:error, reason} ->
        Logger.error(
          "[agent_dispatch] append_failed agent=#{acc.agent_id} session=#{acc.session_id} kind=assistant reason=#{inspect(reason)}"
        )

        {:error, reason, acc}
    end
  end

  defp log_agent_request(job, payload, url, payload_bytes) do
    messages = Map.fetch!(payload, :messages)

    # Logger.info(
    #   "[agent_dispatch] request agent=#{job.agent_id} session=#{job.session_id} user=#{job.user_id} " <>
    #     "messages=#{length(messages)} target_seq=#{job.target_seq} last_sent=#{job.last_sent} " <>
    #     "attempts=#{Map.get(job, :attempts, 0)} bytes=#{payload_bytes} url=#{url}"
    # )
  end

  defp log_agent_response(job, %{status: status, count: count}) do
    cond do
      is_integer(status) and status in 200..299 ->
        Logger.info(
          "[agent_dispatch] response agent=#{job.agent_id} session=#{job.session_id} status=#{status} messages_appended=#{count}"
        )

      is_integer(status) ->
        Logger.warning(
          "[agent_dispatch] response_non_success agent=#{job.agent_id} session=#{job.session_id} status=#{status} messages_appended=#{count}"
        )

      true ->
        Logger.warning(
          "[agent_dispatch] response_missing_status agent=#{job.agent_id} session=#{job.session_id} messages_appended=#{count}"
        )
    end
  end

  defp preview_from_parts(parts) when is_list(parts) do
    parts
    |> Enum.find(fn part -> part["type"] == "text" end)
    |> case do
      %{"text" => text} -> String.slice(text, 0, 200)
      _ -> "n/a"
    end
  end

  defp preview_from_parts(_), do: "n/a"

  defp ensure_enabled(%{status: "enabled"}), do: :ok
  defp ensure_enabled(_), do: {:error, :agent_disabled}

  defp fetch_history(session_id, agent, _job) do
    case agent.message_history_mode do
      "tail" ->
        Runtime.get_messages(session_id, 0, agent.message_history_limit)

      "entire" ->
        # this is an expensive operation and should be avoided if possible, however
        # due to our message history mode, we need to fetch all messages. There is
        # most likely a better solution that would allow the agent to summarise their
        # current session themselves, but this will do for now.
        Storage.get_all_messages(session_id)

      "last" ->
        {:ok, messages} = Runtime.get_messages(session_id, 0, 1)
        {:ok, Enum.take(messages, -1)}
    end
  end

  defp build_payload(agent, session_id, user_id, messages) do
    %{
      session_id: session_id,
      agent_id: agent.id,
      user_id: user_id,
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

  defp build_url(agent) do
    uri = URI.parse(agent.origin_url)
    base_path = uri.path || "/"
    webhook_path = agent.webhook_path || "/webhook"
    path = Path.join(base_path, webhook_path)

    %{uri | path: path}
    |> URI.to_string()
  end

  defp custom_headers(agent) do
    agent.headers
    |> Map.new(fn {k, v} -> {String.downcase(to_string(k)), v} end)
    |> Enum.to_list()
  end

  defp classify_error({:request_failed, reason}), do: {:connection, reason}
  defp classify_error({:http_error, status}), do: {:http_error, status}
  defp classify_error({:json_decode_failed, reason}), do: {:invalid_payload, reason}
  defp classify_error(:agent_disabled), do: :disabled
  defp classify_error(:receive_timeout), do: :timeout
  defp classify_error(other), do: {:unknown, other}
end

defmodule Fleetlm.Agent.Dispatch do
  @moduledoc """
  Executes a single agent webhook.

  Runs in a short-lived task: builds payload, sends the HTTP request, streams the
  JSONL response, and appends agent messages back into the session.
  """

  require Logger

  alias Fleetlm.Agent
  alias Fleetlm.Observability.Telemetry
  alias Fleetlm.Runtime.Router
  alias Fleetlm.Storage

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
      agent_id: job.agent_id
    }

    request =
      Finch.build(:post, url, headers, payload_json)
      |> Finch.stream(Fleetlm.Agent.HTTP, acc, &handle_stream_chunk/2,
        receive_timeout: agent.timeout_ms,
        pool_timeout: agent.timeout_ms
      )

    case request do
      {:ok, acc} ->
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

  defp handle_stream_chunk({:status, status}, acc) do
    %{acc | status: status}
  end

  defp handle_stream_chunk({:headers, _headers}, acc) do
    acc
  end

  defp handle_stream_chunk({:data, data}, acc) do
    # Append new data to buffer
    new_buffer = acc.buffer <> data

    # Process each complete line within the buffer
    lines = String.split(new_buffer, "\n")
    {complete_lines, [remaining]} = Enum.split(lines, -1)

    result =
      Enum.reduce_while(complete_lines, {:ok, acc.count}, fn line, {:ok, count} ->
        case append_line(line, acc.session_id, acc.agent_id) do
          :ok -> {:cont, {:ok, count + 1}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, new_count} ->
        %{acc | buffer: remaining, count: new_count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp flush_buffer(%{buffer: buffer} = acc) when is_binary(buffer) do
    cond do
      buffer == "" ->
        {:ok, acc}

      String.trim(buffer) == "" ->
        {:ok, %{acc | buffer: ""}}

      true ->
        case append_line(buffer, acc.session_id, acc.agent_id) do
          :ok ->
            {:ok, %{acc | buffer: "", count: acc.count + 1}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # append a single line to the session, note that this
  # has a side effect of _writing messages_ to the session.
  defp append_line(line, session_id, agent_id) do
    trimmed = String.trim(line)

    if trimmed == "" do
      :ok
    else
      case Jason.decode(trimmed) do
        {:ok, %{"kind" => kind, "content" => content} = msg} ->
          metadata = Map.get(msg, "metadata", %{})

          case Router.append_message(session_id, agent_id, kind, content, metadata) do
            {:ok, appended_message} ->
    Logger.info(
      "[agent_dispatch] appended agent=#{agent_id} session=#{session_id} kind=#{kind} " <>
        "seq=#{Map.get(appended_message, :seq)} metadata=#{map_size(metadata)} preview=#{preview_content(content)}"
    )

              :ok

            {:error, reason} ->
              Logger.error(
                "[agent_dispatch] append_failed agent=#{agent_id} session=#{session_id} kind=#{kind} reason=#{inspect(reason)}"
              )

              {:error, reason}
          end

        {:ok, _other} ->
          Telemetry.emit_agent_parse_error(agent_id, session_id, :missing_fields, trimmed)
          {:error, :invalid_message_format}

        {:error, reason} ->
          Telemetry.emit_agent_parse_error(agent_id, session_id, :invalid_json, trimmed)
          {:error, {:json_decode_failed, reason}}
      end
    end
  end

  defp log_agent_request(job, payload, url, payload_bytes) do
    messages = Map.fetch!(payload, :messages)

    Logger.info(
      "[agent_dispatch] request agent=#{job.agent_id} session=#{job.session_id} user=#{job.user_id} " <>
        "messages=#{length(messages)} target_seq=#{job.target_seq} last_sent=#{job.last_sent} " <>
        "attempts=#{Map.get(job, :attempts, 0)} bytes=#{payload_bytes} url=#{url}"
    )
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

  defp preview_content(content) do
    inspect(content, pretty: false, limit: 6, printable_limit: 200)
  end

  defp ensure_enabled(%{status: "enabled"}), do: :ok
  defp ensure_enabled(_), do: {:error, :agent_disabled}

  defp fetch_history(session_id, agent, _job) do
    case agent.message_history_mode do
      "tail" ->
        Storage.get_messages(session_id, 0, agent.message_history_limit)

      "entire" ->
        # this is an expensive operation and should be avoided if possible, however
        # due to our message history mode, we need to fetch all messages. There is
        # most likely a better solution that would allow the agent to summarise their
        # current session themselves, but this will do for now.
        Storage.get_all_messages(session_id)

      "last" ->
        {:ok, messages} = Storage.get_messages(session_id, 0, 1)
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

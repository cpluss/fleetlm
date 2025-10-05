defmodule Fleetlm.Agent.Dispatch do
  @moduledoc """
  Executes a single agent webhook.

  Runs in a short-lived task: builds payload, sends the HTTP request, streams the
  JSONL response, and appends agent messages back into the session.
  """

  alias Fleetlm.Agent
  alias Fleetlm.Observability.Telemetry
  alias Fleetlm.Runtime.Router
  alias Fleetlm.Storage

  @receive_timeout 10 * 60 * 1000

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

  ## HTTP dispatch --------------------------------------------------------------

  defp dispatch(agent, job, messages) do
    payload = build_payload(agent, job.session_id, job.user_id, messages)
    url = build_url(agent)

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
      | custom_headers(agent)
    ]

    request =
      Finch.build(:post, url, headers, Jason.encode!(payload))
      |> Finch.request(Fleetlm.Agent.HTTP,
        receive_timeout: @receive_timeout,
        pool_timeout: agent.timeout_ms
      )

    case request do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        process_json_lines(body, job.session_id, job.agent_id)

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  ## Message helpers ------------------------------------------------------------

  defp process_json_lines(body, session_id, agent_id) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, 0}, fn line, {:ok, count} ->
      case append_line(line, session_id, agent_id) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp append_line(line, session_id, agent_id) do
    trimmed = String.trim(line)

    if trimmed == "" do
      :ok
    else
      case Jason.decode(trimmed) do
        {:ok, %{"kind" => kind, "content" => content} = msg} ->
          metadata = Map.get(msg, "metadata", %{})

          case Router.append_message(session_id, agent_id, kind, content, metadata) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
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

  ## Data loading & payload -----------------------------------------------------

  defp ensure_enabled(%{status: "enabled"}), do: :ok
  defp ensure_enabled(_), do: {:error, :agent_disabled}

  defp fetch_history(session_id, agent, _job) do
    case agent.message_history_mode do
      "tail" ->
        Storage.get_messages(session_id, 0, agent.message_history_limit)

      "entire" ->
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

  ## HTTP helpers ---------------------------------------------------------------

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

  ## Error classification -------------------------------------------------------

  defp classify_error({:request_failed, reason}), do: {:connection, reason}
  defp classify_error({:http_error, status}), do: {:http_error, status}
  defp classify_error({:json_decode_failed, reason}), do: {:invalid_payload, reason}
  defp classify_error(:agent_disabled), do: :disabled
  defp classify_error(:receive_timeout), do: :timeout
  defp classify_error(other), do: {:unknown, other}
end

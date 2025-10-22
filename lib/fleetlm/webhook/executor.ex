defmodule Fleetlm.Webhook.Executor do
  @moduledoc """
  Generic webhook executor for all job types.

  Both message and compact jobs follow the same pattern:
  1. POST JSON payload to webhook URL
  2. Stream JSONL responses back
  3. Parse and persist results
  4. Report completion/failure to FSM
  """

  require Logger

  alias Fleetlm.Runtime
  alias Fleetlm.Storage.AgentCache
  alias Fleetlm.Storage
  alias Phoenix.PubSub

  @doc """
  Execute a webhook job.
  """
  def execute(%{type: :message} = job) do
    Logger.debug("Executing message job", session_id: job.session_id)

    started_at = System.monotonic_time(:millisecond)

    client = webhook_client()

    with {:ok, agent} <- AgentCache.get(job.context.agent_id),
         :ok <- ensure_enabled(agent),
         {:ok, final_job, total_count} <- process_message_job(job, agent, client) do
      duration_ms = System.monotonic_time(:millisecond) - started_at

      Fleetlm.Observability.Telemetry.emit_agent_webhook(
        agent.id,
        job.session_id,
        :ok,
        duration_ms * 1000,
        message_count: total_count,
        status_code: 200
      )

      Logger.info("Message job completed",
        session_id: job.session_id,
        duration_ms: duration_ms,
        count: total_count
      )

      case Runtime.processing_complete(job.session_id, final_job.context.last_sent_seq) do
        :ok ->
          :ok

        {:error, reason} = error ->
          Logger.error("processing_complete failed",
            session_id: job.session_id,
            reason: inspect(reason)
          )

          Runtime.processing_failed(job.session_id, reason)
          error
      end
    else
      {:error, reason} = error ->
        duration_ms = System.monotonic_time(:millisecond) - started_at

        Fleetlm.Observability.Telemetry.emit_agent_webhook(
          job.context.agent_id,
          job.session_id,
          :error,
          duration_ms * 1000,
          error_type: classify_error(reason),
          message_count: 0
        )

        Logger.error("Message job failed", session_id: job.session_id, reason: inspect(reason))
        Runtime.processing_failed(job.session_id, reason)
        error
    end
  end

  def execute(%{type: :compact} = job) do
    Logger.debug("Executing compact job", session_id: job.session_id)

    started_at = System.monotonic_time(:millisecond)

    # Execute webhook
    case webhook_client().call_compaction_webhook(job.webhook_url, job.payload) do
      {:ok, summary} ->
        duration = System.monotonic_time(:millisecond) - started_at
        Logger.info("Compact job completed", session_id: job.session_id, duration_ms: duration)
        Runtime.compaction_complete(job.session_id, summary)
        :ok

      {:error, reason} ->
        Logger.error("Compact job failed", session_id: job.session_id, reason: inspect(reason))
        Runtime.compaction_failed(job.session_id, reason)
        {:error, reason}
    end
  end

  ## Private

  defp process_message_job(job, agent, client, total_count \\ 0) do
    job = drain_target_updates(job)

    if job.context.target_seq <= job.context.last_sent_seq do
      {:ok, job, total_count}
    else
      with {:ok, messages} <- fetch_history(job, agent),
           {:ok, payload} <- build_message_payload(agent, job, messages),
           {:ok, iteration_count} <- dispatch_once(agent, payload, job, client) do
        updated_job =
          job
          |> update_last_sent()
          |> drain_target_updates()

        process_message_job(updated_job, agent, client, total_count + iteration_count)
      end
    end
  end

  defp dispatch_once(agent, payload, job, client) do
    handler = fn action, acc -> handle_message_action(action, acc, job) end

    case client.call_agent_webhook(agent, payload, handler) do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_message_payload(agent, job, messages) do
    formatted =
      Enum.map(messages, &format_message/1)

    {:ok,
     %{
       session_id: job.session_id,
       agent_id: agent.id,
       user_id: job.context.user_id,
       messages: formatted
     }}
  end

  defp fetch_history(job, agent) do
    case agent.message_history_mode do
      "tail" ->
        Runtime.get_messages(job.session_id, 0, agent.message_history_limit)

      "entire" ->
        Storage.get_all_messages(job.session_id)

      "last" ->
        case Runtime.get_messages(job.session_id, 0, 1) do
          {:ok, messages} -> {:ok, Enum.take(messages, -1)}
          other -> other
        end

      _other ->
        Runtime.get_messages(job.session_id, 0, agent.message_history_limit)
    end
  end

  defp handle_message_action({:chunk, chunk}, acc, job) do
    # Emit TTFT on first chunk
    acc =
      if not Map.get(acc, :ttft_emitted, false) and not is_nil(job.context.user_message_sent_at) do
        now = System.monotonic_time(:millisecond)
        ttft_ms = now - job.context.user_message_sent_at

        Fleetlm.Observability.Telemetry.emit_ttft(
          job.context.agent_id,
          job.session_id,
          ttft_ms
        )

        Map.put(acc, :ttft_emitted, true)
      else
        acc
      end

    # Broadcast chunk to live sessions
    PubSub.broadcast(
      Fleetlm.PubSub,
      "session:#{job.session_id}",
      {:session_stream_chunk, %{"agent_id" => job.context.agent_id, "chunk" => chunk}}
    )

    {:ok, acc}
  end

  defp handle_message_action({:finalize, message, meta}, acc, job) do
    # Persist finalized message
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
           job.session_id,
           job.context.agent_id,
           job.context.user_id,
           "assistant",
           content,
           metadata
         ) do
      {:ok, _seq} ->
        {:ok, acc}

      {:timeout, _leader} ->
        Logger.error("Message persist timeout", session_id: job.session_id)
        {:error, :timeout, acc}

      {:error, reason} ->
        Logger.error("Message persist failed",
          session_id: job.session_id,
          reason: inspect(reason)
        )

        {:error, reason, acc}
    end
  end

  defp classify_error({:request_failed, reason}), do: {:connection, reason}
  defp classify_error({:http_error, status}), do: {:http_error, status}
  defp classify_error({:json_decode_failed, reason}), do: {:invalid_payload, reason}
  defp classify_error(:agent_disabled), do: :disabled
  defp classify_error(:receive_timeout), do: :timeout
  defp classify_error(other), do: {:unknown, other}

  defp format_message(message) do
    %{
      seq: message.seq,
      sender_id: message.sender_id,
      kind: message.kind,
      content: message.content,
      inserted_at: NaiveDateTime.to_iso8601(message.inserted_at)
    }
  end

  defp ensure_enabled(%{status: "enabled"}), do: :ok
  defp ensure_enabled(_), do: {:error, :agent_disabled}

  defp update_last_sent(job) do
    job
    |> put_in([:context, :last_sent_seq], job.context.target_seq)
    |> put_in([:context, :user_message_sent_at], nil)
  end

  defp drain_target_updates(job) do
    receive do
      {:update_target, new_target, new_sent_at} ->
        current_target = job.context.target_seq || 0

        next_target =
          case new_target do
            value when is_integer(value) -> max(current_target, value)
            _ -> current_target
          end

        job
        |> put_in([:context, :target_seq], next_target)
        |> update_user_timestamp(new_sent_at)
        |> drain_target_updates()

      {:update_target, new_target} ->
        current_target = job.context.target_seq || 0

        next_target =
          case new_target do
            value when is_integer(value) -> max(current_target, value)
            _ -> current_target
          end

        job
        |> put_in([:context, :target_seq], next_target)
        |> drain_target_updates()
    after
      0 ->
        job
    end
  end

  defp update_user_timestamp(job, nil), do: job

  defp update_user_timestamp(job, timestamp) do
    put_in(job, [:context, :user_message_sent_at], timestamp)
  end

  defp webhook_client do
    Application.get_env(:fleetlm, :webhook_client, Fleetlm.Webhook.Client)
  end
end

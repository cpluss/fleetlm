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

  alias Fleetlm.Webhook.Client
  alias Fleetlm.Runtime
  alias Fleetlm.Storage.AgentCache
  alias Phoenix.PubSub

  @doc """
  Execute a webhook job.
  """
  def execute(%{type: :message} = job) do
    Logger.debug("Executing message job", session_id: job.session_id)

    started_at = System.monotonic_time(:millisecond)

    # Fetch agent config
    {:ok, agent} = AgentCache.get(job.context.agent_id)

    # Build payload
    payload = build_message_payload(agent, job)

    # Stream handler for message responses
    handler = fn action, acc ->
      handle_message_action(action, acc, job)
    end

    # Execute webhook
    case Client.call_agent_webhook(agent, payload, handler) do
      {:ok, count} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at

        # Emit webhook telemetry
        Fleetlm.Observability.Telemetry.emit_agent_webhook(
          agent.id,
          job.session_id,
          :ok,
          duration_ms * 1000,
          message_count: count,
          status_code: 200
        )

        Logger.info("Message job completed", session_id: job.session_id, duration_ms: duration_ms, count: count)
        Runtime.processing_complete(job.session_id, job.context.target_seq)
        :ok

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at

        # Emit error telemetry
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
        {:error, reason}
    end
  end

  def execute(%{type: :compact} = job) do
    Logger.debug("Executing compact job", session_id: job.session_id)

    started_at = System.monotonic_time(:millisecond)

    # Execute webhook
    case Client.call_compaction_webhook(job.webhook_url, job.payload) do
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

  defp build_message_payload(agent, job) do
    %{
      session_id: job.session_id,
      agent_id: agent.id,
      user_id: job.context.user_id,
      messages: job.payload.messages
    }
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
        Logger.error("Message persist failed", session_id: job.session_id, reason: inspect(reason))
        {:error, reason, acc}
    end
  end

  defp classify_error({:request_failed, reason}), do: {:connection, reason}
  defp classify_error({:http_error, status}), do: {:http_error, status}
  defp classify_error({:json_decode_failed, reason}), do: {:invalid_payload, reason}
  defp classify_error(:agent_disabled), do: :disabled
  defp classify_error(:receive_timeout), do: :timeout
  defp classify_error(other), do: {:unknown, other}
end

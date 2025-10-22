defmodule Fleetlm.Webhook.Executor do
  @moduledoc """
  Helper utilities used by webhook workers to talk to agents and compaction
  webhooks. Keeps HTTP/streaming logic out of the state machine.
  """

  require Logger

  alias Fleetlm.Observability.Telemetry
  alias Fleetlm.Runtime
  alias Fleetlm.Storage
  alias Fleetlm.Storage.AgentCache
  alias Phoenix.PubSub

  @type catch_up_params :: %{
          session_id: String.t(),
          agent_id: String.t(),
          user_id: String.t(),
          from_seq: non_neg_integer(),
          to_seq: non_neg_integer(),
          user_message_sent_at: integer() | nil
        }

  @spec catch_up(catch_up_params()) ::
          {:ok, %{last_sent_seq: non_neg_integer(), message_count: non_neg_integer()}}
          | {:error, term()}
  def catch_up(%{
        session_id: session_id,
        agent_id: agent_id,
        user_id: user_id,
        from_seq: from_seq,
        to_seq: to_seq,
        user_message_sent_at: user_message_sent_at
      }) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, agent} <- AgentCache.get(agent_id),
         :ok <- ensure_enabled(agent),
         {:ok, messages} <- select_history(agent, session_id),
         {:ok, payload} <- build_payload(agent, session_id, user_id, messages),
         {:ok, count} <-
           dispatch(agent, payload, session_id, agent_id, user_id, user_message_sent_at) do
      duration_ms = System.monotonic_time(:millisecond) - started_at

      Telemetry.emit_agent_webhook(
        agent_id,
        session_id,
        :ok,
        duration_ms * 1000,
        message_count: count,
        status_code: 200
      )

      Logger.info("Agent catch-up completed",
        session_id: session_id,
        duration_ms: duration_ms,
        from_seq: from_seq,
        to_seq: to_seq,
        messages: count
      )

      {:ok, %{last_sent_seq: to_seq, message_count: count}}
    else
      {:error, reason} = error ->
        duration_ms = System.monotonic_time(:millisecond) - started_at

        Telemetry.emit_agent_webhook(
          agent_id,
          session_id,
          :error,
          duration_ms * 1000,
          message_count: 0,
          error_type: classify_error(reason)
        )

        Logger.error("Agent catch-up failed",
          session_id: session_id,
          reason: inspect(reason)
        )

        error
    end
  end

  @type compaction_params :: %{
          session_id: String.t(),
          webhook_url: String.t(),
          payload: map()
        }

  @spec compact(compaction_params()) :: {:ok, map()} | {:error, term()}
  def compact(%{session_id: session_id, webhook_url: url, payload: payload}) do
    started_at = System.monotonic_time(:millisecond)

    case webhook_client().call_compaction_webhook(url, payload) do
      {:ok, summary} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at

        Logger.info("Compaction webhook completed",
          session_id: session_id,
          duration_ms: duration_ms
        )

        {:ok, summary}

      {:error, reason} ->
        Logger.error("Compaction webhook failed",
          session_id: session_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  ## Helpers

  defp ensure_enabled(%{status: "enabled"}), do: :ok
  defp ensure_enabled(_agent), do: {:error, :agent_disabled}

  defp select_history(agent, session_id) do
    case agent.message_history_mode do
      "tail" ->
        Runtime.get_messages(session_id, 0, agent.message_history_limit)

      "entire" ->
        Storage.get_all_messages(session_id)

      "last" ->
        case Runtime.get_messages(session_id, 0, 1) do
          {:ok, messages} -> {:ok, Enum.take(messages, -1)}
          other -> other
        end

      _other ->
        Runtime.get_messages(session_id, 0, agent.message_history_limit)
    end
  end

  defp build_payload(agent, session_id, user_id, messages) do
    formatted =
      Enum.map(messages, fn message ->
        %{
          seq: message.seq,
          sender_id: message.sender_id,
          kind: message.kind,
          content: message.content,
          inserted_at: NaiveDateTime.to_iso8601(message.inserted_at)
        }
      end)

    {:ok,
     %{
       session_id: session_id,
       agent_id: agent.id,
       user_id: user_id,
       messages: formatted
     }}
  end

  defp dispatch(agent, payload, session_id, agent_id, user_id, user_message_sent_at) do
    handler = fn action, acc ->
      handle_action(action, acc, session_id, agent_id, user_id, user_message_sent_at)
    end

    case webhook_client().call_agent_webhook(agent, payload, handler) do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_action({:chunk, chunk}, acc, session_id, agent_id, _user_id, sent_at) do
    acc =
      maybe_emit_ttft(acc, agent_id, session_id, sent_at)

    PubSub.broadcast(
      Fleetlm.PubSub,
      "session:#{session_id}",
      {:session_stream_chunk, %{"agent_id" => agent_id, "chunk" => chunk}}
    )

    {:ok, acc}
  end

  defp handle_action({:finalize, message, meta}, acc, session_id, agent_id, user_id, _sent_at) do
    with {:ok, _seq} <-
           persist_agent_message(session_id, agent_id, user_id, message, meta) do
      {:ok, acc}
    end
  end

  defp maybe_emit_ttft(acc, _agent_id, _session_id, nil), do: acc

  defp maybe_emit_ttft(acc, agent_id, session_id, sent_at) do
    case Map.get(acc, :ttft_emitted, false) do
      true ->
        acc

      false ->
        now = System.monotonic_time(:millisecond)
        Telemetry.emit_ttft(agent_id, session_id, now - sent_at)
        Map.put(acc, :ttft_emitted, true)
    end
  end

  defp persist_agent_message(session_id, agent_id, user_id, message, meta) do
    parts = Map.get(message, "parts", [])

    content =
      %{
        "id" => message["id"],
        "role" => message["role"],
        "parts" => parts
      }

    metadata =
      message
      |> Map.get("metadata", %{})
      |> Map.put("termination", Atom.to_string(meta.termination))
      |> maybe_put_finish_chunk(meta)

    case Runtime.append_message(
           session_id,
           agent_id,
           user_id,
           "assistant",
           content,
           metadata
         ) do
      {:ok, seq} ->
        {:ok, seq}

      {:timeout, leader} ->
        Logger.error("Persisting agent message timed out",
          session_id: session_id,
          leader: inspect(leader)
        )

        {:error, :timeout}

      {:error, reason} ->
        Logger.error("Persisting agent message failed",
          session_id: session_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp maybe_put_finish_chunk(metadata, %{finish_chunk: chunk})
       when not is_nil(chunk) do
    Map.put(metadata, "_finish_chunk", chunk)
  end

  defp maybe_put_finish_chunk(metadata, _meta), do: metadata

  defp classify_error({:request_failed, reason}), do: {:connection, reason}
  defp classify_error({:http_error, status}), do: {:http_error, status}
  defp classify_error({:json_decode_failed, reason}), do: {:invalid_payload, reason}
  defp classify_error(:agent_disabled), do: :disabled
  defp classify_error(:receive_timeout), do: :timeout
  defp classify_error(other), do: {:unknown, other}

  defp webhook_client do
    Application.get_env(:fleetlm, :webhook_client, Fleetlm.Webhook.Client)
  end
end

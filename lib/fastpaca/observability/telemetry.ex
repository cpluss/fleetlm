defmodule Fastpaca.Observability.Telemetry do
  @moduledoc """
  Centralised telemetry helpers so event names and metadata are consistent.

  Exposes small, purpose-built emitters that wrap `:telemetry.execute/3`.
  """

  @type token_source :: :client | :server

  @doc """
  Emit an event when a message is appended, including token counting source.

  Measurements:
    - `:token_count` – integer token count for the message

  Metadata:
    - `:context_id` – context identifier
    - `:source` – `:client` or `:server` depending on who supplied the count
    - `:role` – message role (user/assistant/system)
  """
  @spec message_appended(token_source(), non_neg_integer(), String.t(), String.t()) :: :ok
  def message_appended(source, token_count, context_id, role)
      when source in [:client, :server] and is_integer(token_count) and token_count >= 0 and
             is_binary(context_id) and is_binary(role) do
    :telemetry.execute(
      [:fastpaca, :messages, :append],
      %{token_count: token_count},
      %{context_id: context_id, source: source, role: role}
    )

    :ok
  end

  @doc """
  Emit an event describing a single archive flush tick.

  Measurements:
    - `:elapsed_ms` – time spent in flush loop
    - `:attempted` – rows attempted to write
    - `:inserted` – rows successfully inserted (idempotent)
    - `:pending_rows` – total pending rows in ETS after flush
    - `:pending_contexts` – total contexts with pending rows after flush
  """
  @spec archive_flush(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok
  def archive_flush(
        elapsed_ms,
        attempted,
        inserted,
        pending_rows,
        pending_contexts,
        bytes_attempted,
        bytes_inserted
      )
      when is_integer(elapsed_ms) and elapsed_ms >= 0 and is_integer(attempted) and attempted >= 0 and
             is_integer(inserted) and inserted >= 0 and is_integer(pending_rows) and
             pending_rows >= 0 and
             is_integer(pending_contexts) and pending_contexts >= 0 do
    :telemetry.execute(
      [:fastpaca, :archive, :flush],
      %{
        elapsed_ms: elapsed_ms,
        attempted: attempted,
        inserted: inserted,
        pending_rows: pending_rows,
        pending_contexts: pending_contexts,
        bytes_attempted: bytes_attempted,
        bytes_inserted: bytes_inserted
      },
      %{}
    )

    :ok
  end

  @doc """
  Emit an event when an archive acknowledgement is applied by Raft.

  Measurements:
    - `:lag` – last_seq - archived_seq (messages)
    - `:trimmed` – number of entries removed from the tail
    - `:tail_size` – entries currently in the tail after trim
    - `:llm_token_count` – tokens in the LLM window

  Metadata:
    - `:context_id`
    - `:archived_seq`
    - `:last_seq`
    - `:tail_keep`
  """
  @spec archive_ack_applied(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok
  def archive_ack_applied(
        context_id,
        last_seq,
        archived_seq,
        trimmed,
        tail_keep,
        tail_size,
        llm_token_count
      )
      when is_binary(context_id) and is_integer(last_seq) and last_seq >= 0 and
             is_integer(archived_seq) and
             archived_seq >= 0 and is_integer(trimmed) and trimmed >= 0 and is_integer(tail_keep) and
             tail_keep > 0 and
             is_integer(llm_token_count) and llm_token_count >= 0 do
    lag = max(last_seq - archived_seq, 0)

    :telemetry.execute(
      [:fastpaca, :archive, :ack],
      %{lag: lag, trimmed: trimmed, tail_size: tail_size, llm_token_count: llm_token_count},
      %{
        context_id: context_id,
        archived_seq: archived_seq,
        last_seq: last_seq,
        tail_keep: tail_keep
      }
    )

    :ok
  end

  @doc """
  Emit an event per archived batch (per context).

  Measurements:
    - `:batch_rows` – number of rows in batch
    - `:batch_bytes` – total payload bytes in batch (approx)
    - `:avg_message_bytes` – average payload bytes per message in batch
    - `:pending_after` – pending rows left for this context after trim

  Metadata:
    - `:context_id`
  """
  @spec archive_batch(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok
  def archive_batch(context_id, batch_rows, batch_bytes, avg_message_bytes, pending_after)
      when is_binary(context_id) and is_integer(batch_rows) and batch_rows >= 0 and
             is_integer(batch_bytes) and batch_bytes >= 0 and is_integer(avg_message_bytes) and
             avg_message_bytes >= 0 and is_integer(pending_after) and pending_after >= 0 do
    :telemetry.execute(
      [:fastpaca, :archive, :batch],
      %{
        batch_rows: batch_rows,
        batch_bytes: batch_bytes,
        avg_message_bytes: avg_message_bytes,
        pending_after: pending_after
      },
      %{context_id: context_id}
    )

    :ok
  end

  @doc """
  Emit queue age gauge (seconds) across all contexts.
  """
  @spec archive_queue_age(non_neg_integer()) :: :ok
  def archive_queue_age(seconds) when is_integer(seconds) and seconds >= 0 do
    :telemetry.execute(
      [:fastpaca, :archive, :queue_age],
      %{seconds: seconds},
      %{}
    )

    :ok
  end
end

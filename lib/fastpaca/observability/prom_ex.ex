defmodule Fastpaca.Observability.PromEx do
  @moduledoc """
  PromEx metrics for Fastpaca runtime and archiver.

  Exposes metrics based on telemetry events emitted by
  Fastpaca.Observability.Telemetry and core libraries.
  """

  use PromEx, otp_app: :fastpaca

  import Telemetry.Metrics

  @impl true
  def plugins do
    []
  end

  @impl true
  def dashboards do
    []
  end

  def metrics do
    [
      messages_metrics(),
      archive_metrics(),
      drain_metrics()
    ]
  end

  defp messages_metrics do
    PromEx.build(
      :fastpaca_messages,
      [
        counter("fastpaca_messages_append_total",
          event_name: [:fastpaca, :messages, :append],
          description: "Total messages appended",
          tags: [:source, :role]
        ),
        summary("fastpaca_messages_token_count",
          event_name: [:fastpaca, :messages, :append],
          measurement: :token_count,
          description: "Token count per appended message",
          unit: :token,
          tags: [:source, :role],
          reporter_options: [buckets: [10, 50, 100, 500, 1000, 5000, 10000]]
        )
      ]
    )
  end

  defp archive_metrics do
    PromEx.build(
      :fastpaca_archive,
      [
        last_value("fastpaca_archive_pending_rows",
          event_name: [:fastpaca, :archive, :flush],
          measurement: :pending_rows,
          description: "Pending rows in archive ETS queue"
        ),
        last_value("fastpaca_archive_pending_contexts",
          event_name: [:fastpaca, :archive, :flush],
          measurement: :pending_contexts,
          description: "Contexts with pending rows in archive ETS queue"
        ),
        summary("fastpaca_archive_flush_duration_ms",
          event_name: [:fastpaca, :archive, :flush],
          measurement: :elapsed_ms,
          description: "Archive flush tick duration",
          unit: {:native, :millisecond}
        ),
        counter("fastpaca_archive_attempted_total",
          event_name: [:fastpaca, :archive, :flush],
          measurement: :attempted,
          description: "Total rows attempted to archive"
        ),
        counter("fastpaca_archive_inserted_total",
          event_name: [:fastpaca, :archive, :flush],
          measurement: :inserted,
          description: "Total rows inserted into archive"
        ),
        counter("fastpaca_archive_bytes_attempted_total",
          event_name: [:fastpaca, :archive, :flush],
          measurement: :bytes_attempted,
          description: "Total payload bytes attempted to archive"
        ),
        counter("fastpaca_archive_bytes_inserted_total",
          event_name: [:fastpaca, :archive, :flush],
          measurement: :bytes_inserted,
          description: "Total payload bytes successfully archived"
        ),
        distribution("fastpaca_archive_batch_rows",
          event_name: [:fastpaca, :archive, :batch],
          measurement: :batch_rows,
          description: "Rows per archive batch (per context)",
          reporter_options: [buckets: [1, 10, 50, 100, 500, 1_000, 2_000, 5_000, 10_000]],
          tags: [:context_id]
        ),
        distribution("fastpaca_archive_batch_bytes",
          event_name: [:fastpaca, :archive, :batch],
          measurement: :batch_bytes,
          description: "Payload bytes per archive batch (per context)",
          reporter_options: [buckets: [1_024, 10_240, 102_400, 1_048_576, 10_485_760, 52_428_800]],
          tags: [:context_id]
        ),
        distribution("fastpaca_archive_message_bytes",
          event_name: [:fastpaca, :archive, :batch],
          measurement: :avg_message_bytes,
          description: "Average message bytes per batch (per context)",
          reporter_options: [buckets: [100, 1_000, 5_000, 10_000, 50_000, 100_000, 1_000_000]],
          tags: [:context_id]
        ),
        last_value("fastpaca_archive_oldest_age_seconds",
          event_name: [:fastpaca, :archive, :queue_age],
          measurement: :seconds,
          description: "Oldest pending message age across the archive queue (seconds)"
        ),
        last_value("fastpaca_archive_lag",
          event_name: [:fastpaca, :archive, :ack],
          measurement: :lag,
          description: "Archive lag (messages) per context",
          tags: [:context_id]
        ),
        last_value("fastpaca_archive_tail_size",
          event_name: [:fastpaca, :archive, :ack],
          measurement: :tail_size,
          description: "In-Raft tail size after trim",
          tags: [:context_id]
        ),
        counter("fastpaca_archive_trimmed_total",
          event_name: [:fastpaca, :archive, :ack],
          measurement: :trimmed,
          description: "Total entries trimmed from Raft tail",
          tags: [:context_id]
        ),
        last_value("fastpaca_archive_llm_token_count",
          event_name: [:fastpaca, :archive, :ack],
          measurement: :llm_token_count,
          description: "LLM window token count",
          tags: [:context_id]
        )
      ]
    )
  end

  defp drain_metrics do
    PromEx.build(
      :fastpaca_drain,
      [
        summary("fastpaca_drain_duration_ms",
          event_name: [:fastpaca, :runtime, :drain],
          measurement: :elapsed_ms,
          description: "Drain total duration",
          unit: {:native, :millisecond}
        ),
        counter("fastpaca_drain_snapshots_ok_total",
          event_name: [:fastpaca, :runtime, :drain],
          measurement: :snapshot_ok,
          description: "Snapshots completed successfully"
        ),
        counter("fastpaca_drain_snapshots_error_total",
          event_name: [:fastpaca, :runtime, :drain],
          measurement: :snapshot_errors,
          description: "Snapshots failed or timed out"
        )
      ]
    )
  end
end

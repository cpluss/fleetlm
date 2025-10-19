defmodule Fleetlm.Observability.PromEx.ChatPlugin do
  @moduledoc """
  PromEx plugin exposing chat-specific counters and gauges for Prometheus.

  Captures message throughput and active runtime process counts without
  introducing additional processes or persistent state.
  """

  use PromEx.Plugin

  import Telemetry.Metrics
  alias PromEx.MetricTypes.Event

  @impl true
  def event_metrics(_opts) do
    [
      Event.build(:fleetlm_chat_message_metrics, [
        counter(
          [:fleetlm, :chat, :messages, :sent, :total],
          event_name: [:fleetlm, :chat, :message, :sent],
          measurement: :count,
          description: "Total chat messages sent.",
          tags: [:role],
          tag_values: &message_tags/1
        )
      ]),
      Event.build(:fleetlm_session_append_metrics, [
        distribution(
          [:fleetlm, :session, :append, :duration],
          event_name: [:fleetlm, :session, :append, :stop],
          measurement: :duration,
          description: "Session append duration (ms).",
          unit: {:microsecond, :millisecond},
          reporter_options: [buckets: [10, 25, 50, 75, 100, 150, 200, 300, 500, 1000]],
          tags: [:status, :strategy, :kind],
          tag_values: &append_tags/1
        ),
        counter(
          [:fleetlm, :session, :append, :total],
          event_name: [:fleetlm, :session, :append, :stop],
          measurement: :count,
          description: "Session append operations.",
          tags: [:status, :strategy, :kind],
          tag_values: &append_tags/1
        )
      ]),
      Event.build(:fleetlm_session_fanout_metrics, [
        distribution(
          [:fleetlm, :session, :fanout, :duration],
          event_name: [:fleetlm, :session, :fanout],
          measurement: :duration,
          description: "Session fan-out duration (ms) by type.",
          unit: {:microsecond, :millisecond},
          reporter_options: [buckets: [5, 10, 20, 40, 80, 120, 200, 400, 800]],
          tags: [:type],
          tag_values: &fanout_tags/1
        ),
        counter(
          [:fleetlm, :session, :fanout, :total],
          event_name: [:fleetlm, :session, :fanout],
          measurement: :count,
          description: "Session fan-out operations.",
          tags: [:type],
          tag_values: &fanout_tags/1
        )
      ]),
      Event.build(:fleetlm_session_queue_metrics, [
        distribution(
          [:fleetlm, :session, :queue, :length],
          event_name: [:fleetlm, :session, :queue, :length],
          measurement: :length,
          description: "Session GenServer mailbox length.",
          reporter_options: [buckets: [0, 1, 2, 5, 10, 20, 50, 100]]
        )
      ]),
      Event.build(:fleetlm_chat_conversation_metrics, [
        counter(
          [:fleetlm, :chat, :conversations, :started, :total],
          event_name: [:fleetlm, :conversation, :started],
          measurement: :count,
          description: "Total conversations started."
        ),
        counter(
          [:fleetlm, :chat, :conversations, :stopped, :total],
          event_name: [:fleetlm, :conversation, :stopped],
          measurement: :count,
          description: "Total conversations stopped.",
          tags: [:reason],
          tag_values: &conversation_reason/1
        ),
        last_value(
          [:fleetlm, :chat, :conversations, :active, :count],
          event_name: [:fleetlm, :conversation, :active_count],
          description: "Active conversation processes.",
          measurement: :count,
          tags: [:scope],
          tag_values: &scope_tag/1
        )
      ]),
      Event.build(:fleetlm_chat_inbox_metrics, [
        counter(
          [:fleetlm, :chat, :inboxes, :started, :total],
          event_name: [:fleetlm, :inbox, :started],
          measurement: :count,
          description: "Total inbox processes started."
        ),
        counter(
          [:fleetlm, :chat, :inboxes, :stopped, :total],
          event_name: [:fleetlm, :inbox, :stopped],
          measurement: :count,
          description: "Total inbox processes stopped.",
          tags: [:reason],
          tag_values: &inbox_reason/1
        ),
        last_value(
          [:fleetlm, :chat, :inboxes, :active, :count],
          event_name: [:fleetlm, :inbox, :active_count],
          description: "Active inbox processes.",
          measurement: :count,
          tags: [:scope],
          tag_values: &scope_tag/1
        )
      ]),
      Event.build(:fleetlm_cache_metrics, [
        counter(
          [:fleetlm, :cache, :hits, :total],
          event_name: [:fleetlm, :cache, :hit],
          measurement: :count,
          description: "Cache hits.",
          tags: [:cache],
          tag_values: &cache_tag/1
        ),
        counter(
          [:fleetlm, :cache, :misses, :total],
          event_name: [:fleetlm, :cache, :miss],
          measurement: :count,
          description: "Cache misses.",
          tags: [:cache],
          tag_values: &cache_tag/1
        ),
        distribution(
          [:fleetlm, :cache, :hit, :duration],
          event_name: [:fleetlm, :cache, :hit],
          measurement: :duration,
          description: "Cache hit latency (ms).",
          unit: {:microsecond, :millisecond},
          reporter_options: [buckets: [5, 10, 20, 40, 80, 160, 320]],
          tags: [:cache],
          tag_values: &cache_tag/1
        ),
        distribution(
          [:fleetlm, :cache, :miss, :duration],
          event_name: [:fleetlm, :cache, :miss],
          measurement: :duration,
          description: "Cache miss latency (ms).",
          unit: {:microsecond, :millisecond},
          reporter_options: [buckets: [20, 40, 80, 160, 320, 640, 1280]],
          tags: [:cache],
          tag_values: &cache_tag/1
        )
      ]),
      Event.build(:fleetlm_pubsub_metrics, [
        counter(
          [:fleetlm, :pubsub, :broadcast, :total],
          event_name: [:fleetlm, :pubsub, :broadcast],
          measurement: :count,
          description: "PubSub broadcasts.",
          tags: [:topic_group],
          tag_values: &pubsub_tag/1
        ),
        distribution(
          [:fleetlm, :pubsub, :broadcast, :duration],
          event_name: [:fleetlm, :pubsub, :broadcast],
          measurement: :duration,
          description: "PubSub broadcast duration (ms).",
          unit: {:microsecond, :millisecond},
          reporter_options: [buckets: [5, 10, 20, 40, 80, 160, 320]],
          tags: [:topic_group],
          tag_values: &pubsub_tag/1
        )
      ]),
      Event.build(:fleetlm_raft_append_metrics, [
        distribution(
          [:fleetlm, :raft, :append, :duration],
          event_name: [:fleetlm, :raft, :append],
          measurement: :duration,
          description: "Raft append latency (ms) - CRITICAL: validates <150ms p99 target.",
          unit: {:microsecond, :millisecond},
          reporter_options: [buckets: [1, 2, 5, 10, 20, 50, 100, 150, 200, 500, 1000]],
          tags: [:status, :group_id, :lane],
          tag_values: &raft_append_tags/1
        ),
        counter(
          [:fleetlm, :raft, :append, :total],
          event_name: [:fleetlm, :raft, :append],
          measurement: :count,
          description: "Raft append operations.",
          tags: [:status, :group_id, :lane],
          tag_values: &raft_append_tags/1
        )
      ]),
      Event.build(:fleetlm_raft_read_metrics, [
        distribution(
          [:fleetlm, :raft, :read, :duration],
          event_name: [:fleetlm, :raft, :read],
          measurement: :duration,
          description: "Raft read latency (ms) - tail_only = hot, tail_and_db = cold.",
          unit: {:microsecond, :millisecond},
          reporter_options: [buckets: [1, 2, 5, 10, 20, 50, 100, 200]],
          tags: [:path, :group_id],
          tag_values: &raft_read_tags/1
        ),
        counter(
          [:fleetlm, :raft, :read, :total],
          event_name: [:fleetlm, :raft, :read],
          measurement: :count,
          description: "Raft read operations.",
          tags: [:path, :group_id],
          tag_values: &raft_read_tags/1
        ),
        distribution(
          [:fleetlm, :raft, :read, :message_count],
          event_name: [:fleetlm, :raft, :read],
          measurement: :message_count,
          description: "Messages returned per read operation.",
          reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 200]],
          tags: [:path, :group_id],
          tag_values: &raft_read_tags/1
        )
      ]),
      Event.build(:fleetlm_raft_state_metrics, [
        last_value(
          [:fleetlm, :raft, :state, :in_state_count],
          event_name: [:fleetlm, :raft, :state],
          measurement: :in_state_count,
          description: "Messages in Raft ETS ring (not yet flushed to Postgres).",
          tags: [:group_id, :lane],
          tag_values: &raft_state_tags/1
        ),
        last_value(
          [:fleetlm, :raft, :state, :pending_flush_count],
          event_name: [:fleetlm, :raft, :state],
          measurement: :pending_flush_count,
          description: "Messages pending flush (>watermark) - CRITICAL: validates flush keeps up.",
          tags: [:group_id, :lane],
          tag_values: &raft_state_tags/1
        ),
        last_value(
          [:fleetlm, :raft, :state, :conversation_count],
          event_name: [:fleetlm, :raft, :state],
          measurement: :conversation_count,
          description: "Conversations cached in Raft state (hot metadata).",
          tags: [:group_id, :lane],
          tag_values: &raft_state_tags/1
        ),
        last_value(
          [:fleetlm, :raft, :state, :ring_fill_pct],
          event_name: [:fleetlm, :raft, :state],
          measurement: :ring_fill_pct,
          description: "Ring fill percentage (for backpressure detection).",
          tags: [:group_id, :lane],
          tag_values: &raft_state_tags/1
        )
      ]),
      Event.build(:fleetlm_raft_flush_metrics, [
        distribution(
          [:fleetlm, :raft, :flush, :duration],
          event_name: [:fleetlm, :raft, :flush],
          measurement: :duration,
          description: "Raft flush to Postgres latency (ms).",
          unit: {:microsecond, :millisecond},
          reporter_options: [buckets: [50, 100, 200, 500, 1000, 2000, 5000, 10000]],
          tags: [:status, :group_id],
          tag_values: &raft_flush_tags/1
        ),
        counter(
          [:fleetlm, :raft, :flush, :total],
          event_name: [:fleetlm, :raft, :flush],
          measurement: :count,
          description: "Raft flush operations.",
          tags: [:status, :group_id],
          tag_values: &raft_flush_tags/1
        ),
        distribution(
          [:fleetlm, :raft, :flush, :messages_flushed],
          event_name: [:fleetlm, :raft, :flush],
          measurement: :messages_flushed,
          description: "Messages flushed per flush operation - CRITICAL: high = lag building up.",
          reporter_options: [buckets: [0, 10, 50, 100, 500, 1000, 5000, 10000]],
          tags: [:status, :group_id],
          tag_values: &raft_flush_tags/1
        )
      ])
    ]
  end

  defp message_tags(metadata) do
    role = metadata |> Map.get(:role, "unknown") |> to_string()
    %{role: role}
  end

  defp append_tags(metadata) do
    %{
      status: metadata |> Map.get(:status, "unknown") |> stringify_label(),
      strategy: metadata |> Map.get(:strategy, "unknown") |> stringify_label(),
      kind: metadata |> Map.get(:kind, "unknown") |> stringify_label()
    }
  end

  defp fanout_tags(metadata) do
    %{type: metadata |> Map.get(:type, :unknown) |> stringify_label()}
  end

  defp cache_tag(metadata) do
    %{cache: metadata |> Map.get(:cache, :unknown) |> stringify_label()}
  end

  defp pubsub_tag(metadata) do
    topic = metadata |> Map.get(:topic, "unknown") |> to_string()
    group = topic |> String.split(":", parts: 2) |> List.first()
    %{topic_group: group || "unknown"}
  end

  defp conversation_reason(metadata) do
    reason = metadata |> Map.get(:reason, "unknown") |> stringify_label()
    %{reason: reason}
  end

  defp inbox_reason(metadata), do: conversation_reason(metadata)

  defp scope_tag(metadata) do
    scope = metadata |> Map.get(:scope, :global) |> stringify_label()
    %{scope: scope}
  end

  defp raft_append_tags(metadata) do
    %{
      status: metadata |> Map.get(:status, :unknown) |> stringify_label(),
      group_id: metadata |> Map.get(:group_id, -1) |> to_string(),
      lane: metadata |> Map.get(:lane, -1) |> to_string()
    }
  end

  defp raft_read_tags(metadata) do
    %{
      path: metadata |> Map.get(:path, :unknown) |> stringify_label(),
      group_id: metadata |> Map.get(:group_id, -1) |> to_string()
    }
  end

  defp raft_state_tags(metadata) do
    %{
      group_id: metadata |> Map.get(:group_id, -1) |> to_string(),
      lane: metadata |> Map.get(:lane, -1) |> to_string()
    }
  end

  defp raft_flush_tags(metadata) do
    %{
      status: metadata |> Map.get(:status, :unknown) |> stringify_label(),
      group_id: metadata |> Map.get(:group_id, -1) |> to_string()
    }
  end

  defp stringify_label(value) when is_binary(value), do: value
  defp stringify_label(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_label({:shutdown, inner}), do: stringify_label(inner)
  defp stringify_label(value), do: inspect(value)
end

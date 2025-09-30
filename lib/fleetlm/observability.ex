defmodule Fleetlm.Observability do
  @moduledoc false

  alias Fleetlm.Observability.Telemetry

  def child_spec(opts \\ []) do
    Fleetlm.Observability.PromEx.child_spec(opts)
  end

  def start_link(opts \\ []) do
    Fleetlm.Observability.PromEx.start_link(opts)
  end

  defdelegate conversation_started(dm_key), to: Telemetry
  defdelegate conversation_stopped(dm_key, reason), to: Telemetry
  defdelegate inbox_started(user_id), to: Telemetry
  defdelegate inbox_stopped(user_id, reason), to: Telemetry
  defdelegate message_sent(dm_key, sender_id, recipient_id, metadata \\ %{}), to: Telemetry
  defdelegate measure_session_append(session_id, metadata \\ %{}, fun), to: Telemetry
  defdelegate record_session_queue_depth(session_id, queue_len), to: Telemetry
  defdelegate record_session_fanout(session_id, type, duration_us, metadata \\ %{}), to: Telemetry
  defdelegate emit_cache_event(event, cache_name, key, duration_us \\ nil), to: Telemetry
  defdelegate emit_pubsub_broadcast(topic, event, duration_us), to: Telemetry
  defdelegate record_disk_log_append(slot, duration_us, metadata \\ %{}), to: Telemetry
end

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
  defdelegate inbox_started(participant_id), to: Telemetry
  defdelegate inbox_stopped(participant_id, reason), to: Telemetry
  defdelegate message_sent(dm_key, sender_id, recipient_id, metadata \\ %{}), to: Telemetry
  defdelegate emit_cache_event(event, cache_name, key, duration_us \\ nil), to: Telemetry
  defdelegate emit_pubsub_broadcast(topic, event, duration_us), to: Telemetry
end

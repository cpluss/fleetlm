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
      ])
    ]
  end

  defp message_tags(metadata) do
    role = metadata |> Map.get(:role, "unknown") |> to_string()
    %{role: role}
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

  defp stringify_label(value) when is_binary(value), do: value
  defp stringify_label(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_label({:shutdown, inner}), do: stringify_label(inner)
  defp stringify_label(value), do: inspect(value)
end

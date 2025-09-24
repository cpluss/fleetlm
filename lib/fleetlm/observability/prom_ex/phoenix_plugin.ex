defmodule Fleetlm.Observability.PromEx.PhoenixPlugin do
  @moduledoc """
  Phoenix PromEx plugin with sanitized tag values for test transports.

  Delegates to the upstream `PromEx.Plugins.Phoenix` metrics while ensuring
  telemetry metadata missing the `:transport` tag is coalesced to a stable
  string so Prometheus aggregations do not drop the measurement.
  """

  use PromEx.Plugin

  alias PromEx.MetricTypes.Event
  alias PromEx.Plugins.Phoenix, as: PhoenixPlugin

  @impl true
  def event_metrics(opts) do
    opts
    |> PhoenixPlugin.event_metrics()
    |> Enum.map(&sanitize_event_metrics/1)
  end

  defp sanitize_event_metrics(%Event{} = event) do
    metrics = Enum.map(event.metrics, &sanitize_metric/1)
    %{event | metrics: metrics}
  end

  defp sanitize_metric(%{tags: tags} = metric) when is_list(tags) do
    if Enum.any?(tags, &(&1 == :transport)) do
      Map.update(metric, :tag_values, nil, fn original ->
        original = original || (&default_tag_values/1)

        fn metadata ->
          metadata
          |> original.()
          |> Map.update(:transport, "unknown", &normalize_transport/1)
        end
      end)
    else
      metric
    end
  end

  defp sanitize_metric(metric), do: metric

  defp normalize_transport(nil), do: "unknown"
  defp normalize_transport(value) when is_binary(value), do: value
  defp normalize_transport(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_transport(value), do: inspect(value)

  defp default_tag_values(metadata) when is_map(metadata), do: metadata
  defp default_tag_values(_metadata), do: %{}
end

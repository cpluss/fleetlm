defmodule Fleetlm.Observability.PromEx do
  @moduledoc """
  PromEx configuration for the FleetLM application.

  PromEx exposes Prometheus metrics via `PromEx.Plug` and ships a collection of
  plugins that instrument Phoenix, Ecto and the BEAM runtime. A custom plugin
  captures chat-specific counters and gauges.
  """

  use PromEx, otp_app: :fleetlm

  @impl true
  def plugins do
    [
      {PromEx.Plugins.Application, otp_app: :fleetlm},
      PromEx.Plugins.Beam,
      {PromEx.Plugins.Ecto, otp_app: :fleetlm, repos: [Fleetlm.Repo]},
      {Fleetlm.Observability.PromEx.PhoenixPlugin,
       router: FleetlmWeb.Router, endpoint: FleetlmWeb.Endpoint},
      Fleetlm.Observability.PromEx.ChatPlugin
    ]
  end

  @impl true
  def dashboards, do: []
end

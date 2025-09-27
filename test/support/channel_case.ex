defmodule FleetlmWeb.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest

      alias FleetlmWeb.UserSocket

      @endpoint FleetlmWeb.Endpoint
    end
  end

  setup tags do
    Fleetlm.DataCase.setup_sandbox(tags)
    Fleetlm.Runtime.TestHelper.reset()
    :ok
  end
end

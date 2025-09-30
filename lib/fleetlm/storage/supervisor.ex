defmodule FleetLM.Storage.Supervisor do
  @moduledoc """
  Supervisor for the storage layer.

  Starts one SlotLogServer per slot (default 64 slots).
  Each SlotLogServer manages a disk_log and asynchronously flushes to postgres.
  """

  use Supervisor

  @num_slots Application.compile_env(:fleetlm, :num_storage_slots, 64)

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Start one SlotLogServer per slot
    children =
      for slot <- 0..(@num_slots - 1) do
        Supervisor.child_spec(
          {FleetLM.Storage.SlotLogServer, slot},
          id: {FleetLM.Storage.SlotLogServer, slot}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
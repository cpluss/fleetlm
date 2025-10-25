defmodule Fastpaca.Runtime.DrainCoordinatorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fastpaca.Runtime.DrainCoordinator

  @coordinator DrainCoordinator

  describe "trigger_drain/0" do
    test "returns :ok when there are no local Raft groups" do
      assert capture_log(fn -> DrainCoordinator.trigger_drain() end) |> is_binary()
      assert :ok == DrainCoordinator.trigger_drain()
    end

    test "returns already_draining when state is locked" do
      coordinator = Process.whereis(@coordinator)
      assert is_pid(coordinator)

      :sys.replace_state(coordinator, fn _ -> %{draining: true} end)

      assert {:error, :already_draining} = GenServer.call(@coordinator, :drain)

      :sys.replace_state(coordinator, fn _ -> %{draining: false} end)
    end
  end
end

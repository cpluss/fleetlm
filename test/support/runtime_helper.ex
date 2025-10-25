defmodule Fastpaca.Runtime.TestHelper do
  @moduledoc false

  require ExUnit.CaptureLog
  require Logger

  def reset do
    ExUnit.CaptureLog.capture_log(fn ->
      # Cleanup Raft data directory (test mode only)
      cleanup_raft_test_data()

      # Brief wait to ensure all database operations complete
      Process.sleep(25)
    end)

    :ok
  end

  defp cleanup_raft_test_data do
    test_data_dir = Application.get_env(:fastpaca, :raft_data_dir, "tmp/test_raft")

    if String.contains?(test_data_dir, "test") do
      File.rm_rf(test_data_dir)
    end
  end
end

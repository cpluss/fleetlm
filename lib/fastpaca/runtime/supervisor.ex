defmodule Fastpaca.Runtime.Supervisor do
  use Supervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    archive_children =
      if archive_enabled?() do
        [
          {Fastpaca.Archive,
           [
             flush_interval_ms: archive_interval(),
             adapter: Fastpaca.Archive.Adapter.Postgres,
             adapter_opts: []
           ]}
        ]
      else
        []
      end

    children =
      [
        # Task.Supervisor for async Raft group startup
        {Task.Supervisor, name: Fastpaca.RaftTaskSupervisor},
        # Presence replicates ready-node membership across the cluster
        Fastpaca.Runtime.RaftTopology.Presence,
        # Topology coordinator (monitors cluster, manages Raft membership)
        Fastpaca.Runtime.RaftTopology,
        # Graceful drain coordinator for SIGTERM handling
        Fastpaca.Runtime.DrainCoordinator
      ] ++ archive_children

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp archive_interval do
    case Application.get_env(:fastpaca, :archive_flush_interval_ms) ||
           System.get_env("FASTPACA_ARCHIVE_FLUSH_INTERVAL_MS") do
      nil -> 5_000
      val when is_integer(val) -> val
      val when is_binary(val) -> String.to_integer(val)
    end
  end

  defp archive_enabled? do
    from_env =
      case System.get_env("FASTPACA_ARCHIVER_ENABLED") do
        nil -> false
        val -> val not in ["", "false", "0", "no", "off"]
      end

    Application.get_env(:fastpaca, :archive_enabled, false) || from_env
  end
end

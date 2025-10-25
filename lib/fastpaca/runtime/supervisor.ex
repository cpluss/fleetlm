defmodule Fastpaca.Runtime.Supervisor do
  use Supervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    flusher_children =
      if Application.get_env(:fastpaca, :runtime_flusher_enabled, true) do
        [Fastpaca.Runtime.Flusher]
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
      ] ++ flusher_children

    Supervisor.init(children, strategy: :one_for_one)
  end
end

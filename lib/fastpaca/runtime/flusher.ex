defmodule Fastpaca.Runtime.Flusher do
  @moduledoc """
  Background Postgres flusher (DISABLED for MVP).

  In v1.0, messages live ONLY in Raft (3× replicated in RAM).
  No Postgres writes on the hot path.

  In v1.1, we'll re-enable this for:
  - Archival (long-term message history)
  - Analytics (query patterns, usage metrics)
  - Compliance (audit logs)

  ## Why Disabled?

  - Raft provides strong durability (3× replication, quorum writes)
  - Reduces complexity for initial release
  - Postgres becomes optional write-behind layer later
  """

  use GenServer
  require Logger

  @doc """
  Start the flusher (no-op for now).
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("Flusher started (DISABLED - Raft-only mode)")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:flush, state) do
    # No-op
    {:noreply, state}
  end

  @doc """
  Flush synchronously (no-op for now).
  """
  def flush_sync do
    :ok
  end
end

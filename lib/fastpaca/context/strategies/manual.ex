defmodule Fastpaca.Context.Strategies.Manual do
  @moduledoc """
  Manual compaction strategy - never auto-compacts.

  Just sets the `needs_compaction` flag when triggered.
  Client must call POST /contexts/:id/compact manually.
  """

  @behaviour Fastpaca.Context.Strategy

  @impl true
  def compact(snapshot, _config) do
    # Never compact automatically
    # Just flag that compaction is needed
    new_snapshot = put_in(snapshot.metadata[:needs_compaction], true)
    {:noop, new_snapshot}
  end
end

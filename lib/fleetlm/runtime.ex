defmodule Fleetlm.Runtime do
  @moduledoc """
  Session and inbox runtime supervision.

  Provides the public API for interacting with session processes across
  the cluster. Routes operations to the correct owner node using the HashRing.
  """

  # Delegate session operations to Router
  defdelegate append_message(session_id, sender_id, kind, content, metadata \\ %{}),
    to: Fleetlm.Runtime.Router

  defdelegate join(session_id, user_id, opts \\ []), to: Fleetlm.Runtime.Router
  defdelegate drain(session_id), to: Fleetlm.Runtime.Router
end

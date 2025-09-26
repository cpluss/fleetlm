defmodule Fleetlm.Sessions.CacheSupervisor do
  @moduledoc """
  Supervisor that boots the Cachex instances used by the session runtime.

  This mirrors the original chat cache supervisor but only starts the caches
  required for session tails and inbox snapshots. It lives under
  `Fleetlm.Sessions.Supervisor` so the entire runtime can be restarted together.
  """

  use Supervisor
  import Cachex.Spec

  alias Fleetlm.Sessions.Cache

  @session_tail_ttl :timer.minutes(5)
  @inbox_ttl :timer.minutes(5)

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      Supervisor.child_spec({Cachex, cache_opts(Cache.tail_cache(), @session_tail_ttl)},
        id: Cache.tail_cache()
      ),
      Supervisor.child_spec({Cachex, cache_opts(Cache.inbox_cache(), @inbox_ttl)},
        id: Cache.inbox_cache()
      )
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp cache_opts(name, ttl) do
    [
      name: name,
      expiration:
        expiration(
          default: ttl,
          interval: :timer.minutes(1),
          lazy: true
        )
    ]
  end
end

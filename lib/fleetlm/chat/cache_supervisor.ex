defmodule Fleetlm.Chat.CacheSupervisor do
  @moduledoc false

  use Supervisor

  import Cachex.Spec
  alias Fleetlm.Chat.Cache

  @dm_tails_ttl :timer.minutes(5)
  @inbox_ttl :timer.minutes(5)
  @read_cursor_ttl :timer.minutes(15)

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      Supervisor.child_spec({Cachex, cache_opts(Cache.dm_tails_cache(), @dm_tails_ttl)},
        id: Cache.dm_tails_cache()
      ),
      Supervisor.child_spec({Cachex, cache_opts(Cache.inbox_cache(), @inbox_ttl)},
        id: Cache.inbox_cache()
      ),
      Supervisor.child_spec({Cachex, cache_opts(Cache.read_cursors_cache(), @read_cursor_ttl)},
        id: Cache.read_cursors_cache()
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

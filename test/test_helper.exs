# Application is already started by mix test with config from config/test.exs
# Just verify it started successfully
{:ok, _} = Application.ensure_all_started(:fleetlm)

# Tests must run serially because:
# 1. SlotLogServers are started on-demand and must be isolated per test
# 2. Runtime processes (SessionServer, InboxServer) are global and must be cleaned between tests
# 3. Application.put_env changes affect global state
ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(Fleetlm.Repo, {:shared, self()})

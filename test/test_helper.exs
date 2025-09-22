{:ok, _} = Application.ensure_all_started(:fleetlm)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Fleetlm.Repo, :manual)

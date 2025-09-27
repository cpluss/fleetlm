{:ok, _} = Application.ensure_all_started(:fleetlm)

ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(Fleetlm.Repo, :manual)

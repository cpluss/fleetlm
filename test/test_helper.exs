Enum.each(Path.wildcard(Path.join(__DIR__, "support/**/*.ex")), &Code.require_file/1)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Fleetlm.Repo, :manual)

log_dir =
  Application.get_env(
    :fleetlm,
    :slot_log_dir,
    Application.app_dir(:fleetlm, "priv/runtime/slot_logs")
  )

_ = File.rm_rf(log_dir)
:ok = File.mkdir_p(log_dir)

{:ok, _} = Application.ensure_all_started(:fleetlm)

ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(Fleetlm.Repo, :manual)

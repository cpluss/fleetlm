base_slot_dir = Path.join(System.tmp_dir!(), "fleetlm-slot-logs")
_ = File.rm_rf(base_slot_dir)
:ok = File.mkdir_p(base_slot_dir)
Application.put_env(:fleetlm, :slot_log_dir, base_slot_dir)

{:ok, _} = Application.ensure_all_started(:fleetlm)

# We cannot run tests concurrently because the runtime tears down and restarts
# globally supervised processes (shard supervisors, persistence workers, etc.)
# and switches application configuration (slot log directories) on the fly.
# Running more than one test at a time would cause cross-test interference.
ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(Fleetlm.Repo, :manual)

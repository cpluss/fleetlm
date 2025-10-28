defmodule Fastpaca.ArchiveTest do
  use ExUnit.Case, async: false

  alias Fastpaca.Runtime
  alias Fastpaca.Context.Config

  setup do
    # Ensure clean raft data for isolation
    Fastpaca.Runtime.TestHelper.reset()
    :ok
  end

  test "flush archives and trims via ack" do
    # Keep a very small tail so trim is obvious
    old = Application.get_env(:fastpaca, :tail_keep)
    Application.put_env(:fastpaca, :tail_keep, 2)

    on_exit(fn ->
      if old,
        do: Application.put_env(:fastpaca, :tail_keep, old),
        else: Application.delete_env(:fastpaca, :tail_keep)
    end)

    # Start Archive with the test adapter (no Postgres)
    {:ok, _pid} =
      start_supervised(
        {Fastpaca.Archive,
         flush_interval_ms: 100, adapter: Fastpaca.Archive.TestAdapter, adapter_opts: []}
      )

    config = %Config{
      token_budget: 100_000,
      trigger_ratio: 0.7,
      policy: %{strategy: :last_n, config: %{limit: 100}}
    }

    ctx_id = "ctx-arch-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, _} = Runtime.upsert_context(ctx_id, config)

    inbound = for i <- 1..5, do: {"user", [%{type: "text", text: "m#{i}"}], %{}, 1}
    {:ok, _} = Runtime.append_messages(ctx_id, inbound)

    # Wait until archived_seq catches up
    eventually(
      fn ->
        {:ok, ctx} = Runtime.get_context(ctx_id)
        assert ctx.archived_seq == ctx.last_seq
        # Tail should retain only 2 messages
        tail = Fastpaca.Context.MessageLog.entries(ctx.message_log)
        assert length(tail) == 2
      end,
      timeout: 2_000
    )
  end

  # Helper to wait for condition
  defp eventually(fun, opts) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, 1_000)
    interval = Keyword.get(opts, :interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline, interval)
  end

  defp do_eventually(fun, deadline, interval) do
    try do
      fun.()
    rescue
      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(interval)
          do_eventually(fun, deadline, interval)
        else
          fun.()
        end
    end
  end
end

defmodule Fleetlm.TestCase do
  @moduledoc """
  Canonical test case for FleetLM with proper isolation.

  Provides:
  - Ecto sandbox with {:shared, self()} mode for spawned processes
  - Isolated slot log directory per test
  - Runtime process cleanup (SessionServer, InboxServer, SlotLogServer)
  - Graceful teardown

  ## Usage

  For tests requiring storage/runtime:

      use Fleetlm.TestCase

  For controller/view tests:

      use Fleetlm.TestCase, mode: :conn

  For channel tests:

      use Fleetlm.TestCase, mode: :channel

  ## Slot Log Isolation

  Each test gets its own temporary slot log directory. SlotLogServers are started
  lazily via `Fleetlm.Storage.Supervisor.ensure_started/1`, sharing the same
  supervision pattern we use for sessions and inboxes. Tests flush and stop
  active slot servers during teardown to maintain isolation.
  """

  use ExUnit.CaseTemplate
  require Logger

  using opts do
    mode = Keyword.get(opts, :mode, :storage)

    quote do
      alias Fleetlm.Repo
      alias Fleetlm.Storage, as: StorageAPI
      alias Fleetlm.Storage, as: API
      alias Fleetlm.Storage.{SlotLogServer, Entry, DiskLog}
      alias Fleetlm.Storage.Model.{Session, Message, Cursor}

      import Fleetlm.TestCase

      Module.register_attribute(__MODULE__, :fleetlm_test_mode, persist: true)
      @fleetlm_test_mode unquote(mode)

      unquote(mode_specific_imports(mode))
    end
  end

  setup tags do
    # Create isolated slot log directory
    temp_dir = create_temp_slot_dir(tags)

    # Setup database sandbox
    setup_database_sandbox(tags)

    # Configure test environment
    previous_config = configure_test_env(temp_dir)

    on_exit(fn ->
      cleanup_runtime_processes()
      cleanup_slot_logs(temp_dir)
      restore_config(previous_config)
    end)

    context = %{slot_log_dir: temp_dir}

    # Add mode-specific context (e.g., conn for :conn mode)
    # Mode is stored in @fleetlm_test_mode by the using macro (persisted attribute)
    context =
      case tags[:module].__info__(:attributes)[:fleetlm_test_mode] do
        [:conn] -> Map.put(context, :conn, Phoenix.ConnTest.build_conn())
        _ -> context
      end

    {:ok, context}
  end

  # Helpers

  @doc """
  Create a test session in the database.
  """
  def create_test_session(user_id \\ "alice", agent_id \\ "agent:bob", metadata \\ %{}) do
    {:ok, session} = Fleetlm.Storage.create_session(user_id, agent_id, metadata)
    session
  end

  @doc """
  Build an Entry struct for testing (does not persist).
  """
  def build_entry(slot, session_id, seq, opts \\ []) do
    message_id = Keyword.get(opts, :message_id, Uniq.UUID.uuid7(:slug))
    sender_id = Keyword.get(opts, :sender_id, "sender-#{seq}")
    recipient_id = Keyword.get(opts, :recipient_id, "recipient-#{seq}")
    kind = Keyword.get(opts, :kind, "text")
    content = Keyword.get(opts, :content, %{"text" => "message #{seq}"})
    metadata = Keyword.get(opts, :metadata, %{})
    idempotency_key = Keyword.get(opts, :idempotency_key, "idem-#{seq}")

    message = %Fleetlm.Storage.Model.Message{
      id: message_id,
      session_id: session_id,
      sender_id: sender_id,
      recipient_id: recipient_id,
      seq: seq,
      kind: kind,
      content: content,
      metadata: metadata,
      shard_key: slot,
      inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    }

    Fleetlm.Storage.Entry.from_message(slot, seq, idempotency_key, message)
  end

  @doc """
  Wait for a slot to flush with timeout.
  Returns :ok on success, raises on timeout.
  """
  def wait_for_flush(slot, timeout \\ 2_000) do
    Fleetlm.Storage.SlotLogServer.notify_next_flush(slot)

    receive do
      :flushed -> :ok
    after
      timeout -> raise "Timeout waiting for slot #{slot} to flush"
    end
  end

  @doc """
  Retry the provided assertion until it succeeds or the timeout elapses.
  Re-raises the last assertion error when the timeout is exceeded.
  """
  def eventually(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, 1_000)
    interval = Keyword.get(opts, :interval, 25)
    deadline = System.monotonic_time(:millisecond) + timeout

    try_eventually(fun, interval, deadline)
  end

  @doc """
  Ensure a SlotLogServer is running for the given slot.
  Delegates to the canonical storage supervisor so tests use the same
  supervision tree as the runtime.
  """
  def ensure_slot_server(slot) do
    Fleetlm.Storage.Supervisor.ensure_started(slot)
  end

  @doc """
  Allow a spawned process to access the current test's sandbox connection.
  Returns :ok when the process is registered successfully.
  """
  def allow_sandbox_access(pid) when is_pid(pid) do
    case Process.get(:fleetlm_sandbox_owner) do
      nil -> {:error, :no_owner}
      owner -> Ecto.Adapters.SQL.Sandbox.allow(Fleetlm.Repo, owner, pid)
    end
  end

  # Private functions

  defp mode_specific_imports(:conn) do
    quote do
      use FleetlmWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest

      @endpoint FleetlmWeb.Endpoint
    end
  end

  defp mode_specific_imports(:channel) do
    quote do
      import Phoenix.ChannelTest

      alias FleetlmWeb.UserSocket
      @endpoint FleetlmWeb.Endpoint
    end
  end

  defp mode_specific_imports(_storage) do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
    end
  end

  defp create_temp_slot_dir(tags) do
    test_name =
      [tags[:case], tags[:test], System.unique_integer([:positive])]
      |> Enum.map(&format_tag/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("-")

    temp_dir = Path.join(System.tmp_dir!(), "fleetlm-test-#{test_name}")

    File.rm_rf!(temp_dir)
    File.mkdir_p!(temp_dir)

    temp_dir
  end

  defp format_tag(nil), do: ""
  defp format_tag(atom) when is_atom(atom), do: Atom.to_string(atom) |> sanitize()
  defp format_tag(str) when is_binary(str), do: sanitize(str)
  defp format_tag(other), do: to_string(other) |> sanitize()

  defp sanitize(str) do
    str
    |> String.replace(~r/[^A-Za-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0..100)
  end

  defp setup_database_sandbox(tags) do
    ownership_timeout = if tags[:async], do: 120_000, else: 300_000

    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(
        Fleetlm.Repo,
        shared: not tags[:async],
        ownership_timeout: ownership_timeout
      )

    Process.put(:fleetlm_sandbox_owner, pid)

    on_exit(fn ->
      Process.delete(:fleetlm_sandbox_owner)
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)
  end

  defp configure_test_env(temp_dir) do
    previous = %{
      slot_log_dir: Application.get_env(:fleetlm, :slot_log_dir),
      skip_terminate_db_ops: Application.get_env(:fleetlm, :skip_terminate_db_ops),
      disable_agent_webhooks: Application.get_env(:fleetlm, :disable_agent_webhooks),
      agent_dispatch_tick_ms: Application.get_env(:fleetlm, :agent_dispatch_tick_ms),
      agent_dispatch_max_concurrency:
        Application.get_env(:fleetlm, :agent_dispatch_max_concurrency),
      agent_debounce_window_ms: Application.get_env(:fleetlm, :agent_debounce_window_ms)
    }

    Application.put_env(:fleetlm, :slot_log_dir, temp_dir)
    Application.put_env(:fleetlm, :skip_terminate_db_ops, true)
    Application.put_env(:fleetlm, :disable_agent_webhooks, true)
    Application.put_env(:fleetlm, :agent_dispatch_tick_ms, 10)
    Application.put_env(:fleetlm, :agent_dispatch_max_concurrency, 1_000)
    Application.put_env(:fleetlm, :agent_debounce_window_ms, 0)

    previous
  end

  defp cleanup_runtime_processes do
    Fleetlm.Runtime.TestHelper.reset()
    cleanup_agent_tasks()
    Process.sleep(25)
  end

  defp cleanup_agent_tasks do
    # Terminate all agent dispatch tasks
    Task.Supervisor.children(Fleetlm.Agent.Engine.TaskSupervisor)
    |> Enum.each(&Task.Supervisor.terminate_child(Fleetlm.Agent.Engine.TaskSupervisor, &1))

    # Clear the agent dispatch queue
    if :ets.whereis(:agent_dispatch_queue) != :undefined do
      :ets.delete_all_objects(:agent_dispatch_queue)
    end
  end

  defp try_eventually(fun, interval, deadline) do
    fun.()
    :ok
  rescue
    error in [ExUnit.AssertionError] ->
      if System.monotonic_time(:millisecond) >= deadline do
        reraise(error, __STACKTRACE__)
      else
        Process.sleep(interval)
        try_eventually(fun, interval, deadline)
      end
  end

  defp cleanup_slot_logs(temp_dir) do
    Fleetlm.Storage.Supervisor.active_slots()
    |> Enum.each(fn slot ->
      case Fleetlm.Storage.Supervisor.flush_slot(slot) do
        {:error, reason} ->
          Logger.warning("Failed to flush slot #{slot} during test cleanup: #{inspect(reason)}")

        _ ->
          :ok
      end

      case Fleetlm.Storage.Supervisor.stop_slot(slot) do
        {:error, reason} ->
          Logger.warning("Failed to stop slot #{slot} during test cleanup: #{inspect(reason)}")

        _ ->
          :ok
      end
    end)

    File.rm_rf(temp_dir)
  end

  defp restore_config(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:fleetlm, key)
      {key, value} -> Application.put_env(:fleetlm, key, value)
    end)
  end
end

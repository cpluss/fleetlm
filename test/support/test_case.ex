defmodule Fleetlm.TestCase do
  @moduledoc """
  Canonical test case for FleetLM with proper isolation.

  Provides:
  - Ecto sandbox with {:shared, self()} mode for spawned processes
  - Runtime process cleanup (InboxServer, Raft groups)
  - Graceful teardown

  ## Usage

  For tests requiring storage/runtime:

      use Fleetlm.TestCase

  For controller/view tests:

      use Fleetlm.TestCase, mode: :conn

  For channel tests:

      use Fleetlm.TestCase, mode: :channel

  ## Raft Architecture

  Tests now use Raft for message storage. No per-test slot log isolation needed
  since Raft state lives in RAM and is automatically cleaned between tests.
  """

  use ExUnit.CaseTemplate
  require Logger

  using opts do
    mode = Keyword.get(opts, :mode, :storage)

    quote do
      alias Fleetlm.Repo
      alias Fleetlm.Storage, as: StorageAPI
      alias Fleetlm.Storage, as: API
      alias Fleetlm.Storage.Model.{Session, Message, Cursor}

      import Fleetlm.TestCase

      Module.register_attribute(__MODULE__, :fleetlm_test_mode, persist: true)
      @fleetlm_test_mode unquote(mode)

      unquote(mode_specific_imports(mode))
    end
  end

  setup tags do
    # Setup database sandbox
    setup_database_sandbox(tags)

    # Configure test environment
    previous_config = configure_test_env()

    on_exit(fn ->
      cleanup_runtime_processes()
      restore_config(previous_config)
    end)

    context = %{}

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

  defp configure_test_env do
    previous = %{
      disable_agent_webhooks: Application.get_env(:fleetlm, :disable_agent_webhooks),
      agent_dispatch_tick_ms: Application.get_env(:fleetlm, :agent_dispatch_tick_ms),
      agent_debounce_window_ms: Application.get_env(:fleetlm, :agent_debounce_window_ms)
    }

    Application.put_env(:fleetlm, :disable_agent_webhooks, true)
    Application.put_env(:fleetlm, :agent_dispatch_tick_ms, 10)
    Application.put_env(:fleetlm, :agent_debounce_window_ms, 0)

    previous
  end

  defp cleanup_runtime_processes do
    Fleetlm.Runtime.TestHelper.reset()
    cleanup_agent_tasks()
    Process.sleep(25)
  end

  defp cleanup_agent_tasks do
    Fleetlm.Webhook.WorkerSupervisor.stop_all()
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

  defp restore_config(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:fleetlm, key)
      {key, value} -> Application.put_env(:fleetlm, key, value)
    end)
  end
end

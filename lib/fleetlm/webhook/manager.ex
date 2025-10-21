defmodule Fleetlm.Webhook.Manager do
  @moduledoc """
  Coordinates webhook job lifecycle on the Raft leader node.

  Responsibilities:
  - Ensure exactly one job per session
  - Track jobs in ETS (:webhook_jobs table)
  - Monitor job tasks and handle crashes
  - Push target updates to running message jobs
  - Stop all jobs on leader→follower transition

  Jobs are spawned via Task.Supervisor and report back to Raft FSM
  via Runtime API commands (processing_complete, compaction_complete).
  """

  use GenServer
  require Logger

  alias Fleetlm.Webhook.Executor

  @table :webhook_jobs

  # ETS schema: {session_id, task_pid, task_ref, job_type}
  # job_type: :message | :compact

  @type job_type :: :message | :compact

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensure exactly one message job for session.

  If job exists, pushes target update via message.
  If no job, spawns new one via Task.Supervisor.

  IMPORTANT: This function is < 1ms (safe for Ra :mod_call).
  """
  @spec ensure_message_job(String.t(), map()) :: :ok
  def ensure_message_job(session_id, conversation) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, pid, _ref, :message}] when is_pid(pid) ->
        # Job exists, push target update (batching/interruption)
        send(pid, {:update_target, conversation.target_seq})
        :ok

      [{^session_id, _pid, _ref, :compact}] ->
        # Compact job running, can't process yet
        # FSM should have queued the message in pending_user_seq
        :ok

      [] ->
        # Start new message job
        start_message_job(session_id, conversation)
        :ok
    end
  end

  @doc """
  Ensure exactly one compact job for session.

  If job exists (unlikely), do nothing.
  If no job, spawn new one via Task.Supervisor.

  IMPORTANT: This function is < 1ms (safe for Ra :mod_call).
  """
  @spec ensure_compact_job(String.t(), map()) :: :ok
  def ensure_compact_job(session_id, compact_job) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, _pid, _ref, _type}] ->
        # Job already exists, don't spawn another
        :ok

      [] ->
        # Start new compact job
        start_compact_job(session_id, compact_job)
        :ok
    end
  end

  @doc """
  Stop all jobs (called on leader→follower transition).
  """
  @spec stop_all_jobs() :: :ok
  def stop_all_jobs do
    GenServer.call(__MODULE__, :stop_all_jobs)
  end

  ## GenServer callbacks

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:stop_all_jobs, _from, state) do
    Logger.info("Stopping all webhook jobs (leader→follower transition)")

    :ets.foldl(
      fn {session_id, pid, _ref, job_type}, _acc ->
        Logger.debug("Stopping webhook job", session_id: session_id, type: job_type)
        Process.exit(pid, :kill)
        :ok
      end,
      :ok,
      @table
    )

    :ets.delete_all_objects(@table)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    # Job died, clean up ETS
    case :ets.match_object(@table, {:_, pid, ref, :_}) do
      [{session_id, ^pid, ^ref, job_type}] ->
        :ets.delete(@table, session_id)

        Logger.warning("Webhook job died",
          session_id: session_id,
          type: job_type,
          reason: inspect(reason)
        )

      [] ->
        :ok
    end

    {:noreply, state}
  end

  ## Private

  defp start_message_job(session_id, conversation) do
    # Build job struct
    job = %{
      type: :message,
      session_id: session_id,
      webhook_url: nil,  # Fetched by executor from agent config
      payload: %{
        messages: []  # Fetched by executor
      },
      context: %{
        agent_id: conversation.agent_id,
        user_id: conversation.user_id,
        target_seq: conversation.target_seq,
        last_sent_seq: conversation.last_sent_seq
      }
    }

    {:ok, pid} =
      Task.Supervisor.start_child(Fleetlm.Webhook.Manager.TaskSupervisor, fn ->
        # Check for target updates before executing
        updated_job = check_mailbox_for_updates(job)
        Executor.execute(updated_job)
      end)

    ref = Process.monitor(pid)
    :ets.insert(@table, {session_id, pid, ref, :message})

    Logger.debug("Started message job", session_id: session_id, pid: inspect(pid))
  end

  defp start_compact_job(session_id, compact_job) do
    # compact_job already has the right structure from FSM
    job = Map.put(compact_job, :type, :compact)

    {:ok, pid} =
      Task.Supervisor.start_child(Fleetlm.Webhook.Manager.TaskSupervisor, fn ->
        Executor.execute(job)
      end)

    ref = Process.monitor(pid)
    :ets.insert(@table, {session_id, pid, ref, :compact})

    Logger.debug("Started compact job", session_id: session_id, pid: inspect(pid))
  end

  defp check_mailbox_for_updates(job) do
    receive do
      {:update_target, new_target} ->
        Logger.debug("Job received target update", new_target: new_target)
        put_in(job, [:context, :target_seq], new_target)
    after
      0 -> job
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:set, :public, :named_table, {:read_concurrency, true}])
        rescue
          ArgumentError ->
            # Another process beat us to table creation
            :ok
        end

      _ ->
        :ok
    end
  end
end

defmodule Fleetlm.Runtime.Persistence.Worker do
  @moduledoc """
  Asynchronous tail worker that flushes slot log entries into Postgres.

  The slot server hands entries to the worker after they have been written to
  disk. The worker serialises persistence to keep write load predictable and
  deduplicates inserts by checking for existing message ids. Replay support can
  be layered on top of this worker by streaming the log on start; for now we
  focus on the live tail path.
  """

  use GenServer

  require Logger

  alias Fleetlm.Runtime.Storage.Entry
  alias Fleetlm.Conversation.Persistence

  @type state :: %{
          slot: non_neg_integer(),
          queue: :queue.queue(Entry.t()),
          processing?: boolean(),
          watchers: %{optional(String.t()) => [GenServer.from()]},
          persisted: MapSet.t(String.t())
        }

  # Public API ----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    slot = Keyword.fetch!(opts, :slot)
    gen_opts = Keyword.drop(opts, [:slot, :log_path])

    GenServer.start_link(__MODULE__, %{slot: slot}, gen_opts)
  end

  @spec enqueue(pid(), Entry.t()) :: :ok
  def enqueue(pid, %Entry{} = entry) when is_pid(pid) do
    GenServer.cast(pid, {:enqueue, entry})
  end

  @doc """
  Wait until the worker confirms that the message has been persisted.
  """
  @spec await(pid(), String.t(), timeout()) :: :ok | {:error, :timeout}
  def await(pid, message_id, timeout \\ 5_000) when is_binary(message_id) do
    ref = Process.monitor(pid)

    try do
      case GenServer.call(pid, {:await, message_id}, timeout) do
        :ok -> :ok
      end
    catch
      :exit, {:timeout, _} ->
        {:error, :timeout}
    after
      Process.demonitor(ref, [:flush])
    end
  end

  # GenServer callbacks --------------------------------------------------------

  @impl true
  def init(%{slot: slot}) do
    state = %{
      slot: slot,
      queue: :queue.new(),
      processing?: false,
      watchers: %{},
      persisted: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:enqueue, %Entry{} = entry}, state) do
    queue = :queue.in(entry, state.queue)
    state = %{state | queue: queue}
    {:noreply, ensure_processing(state)}
  end

  @impl true
  def handle_call({:await, message_id}, from, state) do
    if MapSet.member?(state.persisted, message_id) do
      {:reply, :ok, state}
    else
      watchers = Map.update(state.watchers, message_id, [from], &[from | &1])
      {:noreply, %{state | watchers: watchers}}
    end
  end

  @impl true
  def handle_info(:process_queue, state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        {:noreply, %{state | processing?: false}}

      {{:value, %Entry{} = entry}, queue} ->
        {result, state} = persist_entry(entry, %{state | queue: queue})
        state = acknowledge_watchers(entry.message_id, state)

        case result do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "slot #{state.slot} failed to persist entry #{entry.message_id}: #{inspect(reason)}"
            )
        end

        {:noreply, ensure_processing(state)}
    end
  end

  defp ensure_processing(%{processing?: true} = state), do: state

  defp ensure_processing(%{queue: queue} = state) do
    case :queue.is_empty(queue) do
      true ->
        %{state | processing?: false}

      false ->
        Process.send_after(self(), :process_queue, 0)
        %{state | processing?: true}
    end
  end

  defp persist_entry(%Entry{} = entry, state) do
    case persistence_mode() do
      :noop ->
        {:ok, mark_persisted(entry, state)}

      _ ->
        case Persistence.persist_entry(entry) do
          :ok ->
            {:ok, mark_persisted(entry, state)}

          :already_persisted ->
            {:ok, mark_persisted(entry, state)}

          {:error, reason} ->
            {{:error, reason}, state}
        end
    end
  end

  defp mark_persisted(entry, state) do
    %{state | persisted: MapSet.put(state.persisted, entry.message_id)}
  end

  defp acknowledge_watchers(message_id, state) do
    case Map.pop(state.watchers, message_id) do
      {nil, watchers} ->
        %{state | watchers: watchers}

      {waiting, watchers} ->
        Enum.each(waiting, fn from -> GenServer.reply(from, :ok) end)
        %{state | watchers: watchers}
    end
  end

  defp persistence_mode do
    Application.get_env(:fleetlm, :persistence_worker_mode, :live)
  end
end

defmodule Fleetlm.Runtime.Sharding.SlotServer do
  @moduledoc """
  Slot-scoped owner process that represents the shard responsible for a range
  of session ids in the consistent hash ring.

  Each slot server is the single writer for its shard. That keeps ordering and
  durability decisions localized while allowing us to add node-local hot-path
  state (ETS caches, disk logs, idempotency checks) in later phases. Horde keeps
  exactly one slot server per slot alive across the cluster and migrates it when
  hash-ring ownership changes, giving us a distributed load balancer whose fan
  out is the slot count.
  """

  use GenServer, restart: :transient

  alias Fleetlm.Runtime.Sharding.HashRing
  alias Fleetlm.Sessions

  require Logger

  defstruct [:slot, status: :accepting]

  @type status :: :accepting | :draining
  @type state :: %__MODULE__{slot: non_neg_integer(), status: status()}
  @local_registry Fleetlm.Runtime.Sharding.LocalRegistry

  @spec start_link(non_neg_integer()) :: GenServer.on_start()
  def start_link(slot) when is_integer(slot) and slot >= 0 do
    name = {:via, Registry, {@local_registry, {:shard, slot}}}
    GenServer.start_link(__MODULE__, slot, name: name)
  end

  @spec current_status(GenServer.server()) :: status()
  def current_status(server) do
    GenServer.call(server, :status)
  end

  @spec rebalance(non_neg_integer()) :: :ok
  def rebalance(slot) do
    case Registry.lookup(@local_registry, {:shard, slot}) do
      [{pid, _}] ->
        GenServer.cast(pid, :rebalance)

      [] ->
        :ok
    end
  end

  @impl true
  def init(slot) do
    Process.flag(:trap_exit, true)

    expected_node = HashRing.owner_node(slot)

    if expected_node != Node.self() do
      Logger.warning(
        "SlotServer #{slot} refused to start; expected owner #{inspect(expected_node)}"
      )

      {:stop, {:wrong_owner, expected_node}}
    else
      Logger.debug("Shard #{slot} now accepting traffic on #{inspect(Node.self())}")
      {:ok, %__MODULE__{slot: slot}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call({:append, session_id, attrs}, _from, state) do
    with :ok <- ensure_owner(state) do
      {:reply, Sessions.append_message(session_id, attrs), state}
    else
      {:handoff, expected} -> handoff_reply(state, expected)
    end
  end

  def handle_call({:replay, session_id, opts}, _from, state) do
    with :ok <- ensure_owner(state) do
      {:reply, Sessions.list_messages(session_id, opts), state}
    else
      {:handoff, expected} -> handoff_reply(state, expected)
    end
  end

  def handle_call({:mark_read, session_id, participant_id, opts}, _from, state) do
    with :ok <- ensure_owner(state) do
      {:reply, Sessions.mark_read(session_id, participant_id, opts), state}
    else
      {:handoff, expected} -> handoff_reply(state, expected)
    end
  end

  @impl true
  def handle_cast(:rebalance, %{slot: slot} = state) do
    expected = HashRing.owner_node(slot)

    if expected == Node.self() do
      {:noreply, state}
    else
      Logger.info(
        "Shard #{slot} transitioning to draining on #{inspect(Node.self())}; owner should be #{inspect(expected)}"
      )

      {:stop, {:handoff, expected}, %{state | status: :draining}}
    end
  end

  @impl true
  def terminate(reason, %{slot: slot}) do
    Logger.debug("Shard #{slot} terminating with reason=#{inspect(reason)}")
    :ok
  end

  defp ensure_owner(%{slot: slot}) do
    expected = HashRing.owner_node(slot)

    if expected == Node.self() do
      :ok
    else
      {:handoff, expected}
    end
  end

  defp handoff_reply(state, expected) do
    Logger.debug("Shard #{state.slot} deferring request; expected owner #{inspect(expected)}")

    {:reply, {:error, :handoff}, %{state | status: :draining}}
  end
end

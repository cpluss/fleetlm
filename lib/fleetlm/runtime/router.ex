defmodule Fleetlm.Runtime.Router do
  @moduledoc """
  Routes Phoenix gateway calls to the correct shard slot owner.

  Logically this module is the ingress into the distributed sharding fabric. It
  maps a session id → slot (via the consistent `HashRing`), ensures the slot’s
  owner process is running (`Slots.ensure_slot_started/1`), and then executes a
  synchronous request against that owner. If the cluster rebalance is in
  flight, the router backs off and retries until the slot settles on its new
  node. This keeps the gateway code in Phoenix simple while letting us change
  the internals of the shard owners without disrupting the HTTP/WS surface.
  """

  alias Fleetlm.Runtime.Sharding.{HashRing, Slots, SlotServer}

  require Logger

  @max_attempts 5
  @call_timeout 5_000
  @base_backoff 25
  @local_registry Fleetlm.Runtime.Sharding.LocalRegistry

  @spec append(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def append(session_id, attrs) when is_binary(session_id) and is_map(attrs) do
    call_shard(session_id, {:append, session_id, attrs})
  end

  @spec replay(String.t(), keyword()) :: [term()] | {:error, term()}
  def replay(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    call_shard(session_id, {:replay, session_id, opts})
  end

  @spec mark_read(String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def mark_read(session_id, participant_id, opts \\ [])
      when is_binary(session_id) and is_binary(participant_id) and is_list(opts) do
    call_shard(session_id, {:mark_read, session_id, participant_id, opts})
  end

  @spec await_persistence(String.t(), String.t(), timeout()) :: :ok | {:error, term()}
  def await_persistence(session_id, message_id, timeout \\ 5_000)
      when is_binary(session_id) and is_binary(message_id) do
    slot = HashRing.slot_for_session(session_id)
    owner = HashRing.owner_node(slot)

    with :ok <- ensure_owner(slot, owner) do
      if owner == Node.self() do
        SlotServer.await_persistence(slot, message_id, timeout)
      else
        try do
          :erpc.call(owner, SlotServer, :await_persistence, [slot, message_id, timeout])
        catch
          :exit, reason -> {:error, {:remote_exit, reason}}
        end
      end
    else
      {:retry, reason} -> {:error, reason}
    end
  end

  defp call_shard(session_id, message, attempt \\ 0)

  defp call_shard(session_id, message, attempt) when attempt < @max_attempts do
    slot = HashRing.slot_for_session(session_id)
    owner = HashRing.owner_node(slot)

    case ensure_owner(slot, owner) do
      :ok ->
        case safe_call(slot, owner, message) do
          {:retry, reason} ->
            backoff(attempt, session_id, reason)
            call_shard(session_id, message, attempt + 1)

          other ->
            other
        end

      {:retry, reason} ->
        backoff(attempt, session_id, reason)
        call_shard(session_id, message, attempt + 1)
    end
  end

  defp call_shard(_session_id, _message, _attempt), do: {:error, :timeout}

  defp ensure_owner(slot, owner) do
    if owner == Node.self() do
      case Slots.ensure_slot_started(slot) do
        :ok -> :ok
        {:error, reason} -> {:retry, {:start_failed, reason}}
      end
    else
      try do
        case :erpc.call(owner, Slots, :ensure_slot_started, [slot]) do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, reason} -> {:retry, {:remote_start_failed, reason}}
          other -> {:retry, {:remote_start_unknown, other}}
        end
      catch
        :exit, reason -> {:retry, {:erpc_exit, reason}}
      end
    end
  end

  defp safe_call(slot, owner, message) do
    if owner == Node.self() do
      local_call(slot, message, @call_timeout)
    else
      try do
        :erpc.call(owner, __MODULE__, :remote_call, [slot, message, @call_timeout])
      catch
        :exit, reason ->
          Logger.warning("Remote shard call failed: #{inspect(reason)}")
          {:retry, {:remote_exit, reason}}
      end
    end
  end

  def remote_call(slot, message, timeout) do
    local_call(slot, message, timeout)
  end

  defp local_call(slot, message, timeout) do
    case Registry.lookup(@local_registry, {:shard, slot}) do
      [{pid, _}] ->
        try do
          case GenServer.call(pid, message, timeout) do
            {:error, :handoff} -> {:retry, :handoff}
            {:retry, reason} -> {:retry, reason}
            other -> other
          end
        catch
          :exit, {:noproc, _} ->
            {:retry, :noproc}

          :exit, {:timeout, _} ->
            {:retry, :timeout}

          :exit, reason ->
            Logger.warning("Shard call crashed: #{inspect(reason)}")
            {:retry, {:exit, reason}}
        end

      [] ->
        {:retry, :noproc}
    end
  end

  defp backoff(attempt, session_id, reason) do
    delay = trunc(:math.pow(2, attempt) * @base_backoff)

    Logger.debug(
      "Retrying shard call for #{session_id}: reason=#{inspect(reason)} delay=#{delay}ms"
    )

    Process.sleep(delay)
  end
end

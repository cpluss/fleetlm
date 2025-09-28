defmodule Fleetlm.Runtime.Sharding.Slots do
  @moduledoc """
  Supervisory helpers for keeping slot-owner processes aligned with the hash ring.

  Think of this module as the control plane for the sharding system. It loads the
  current `HashRing`, ensures each slot has a live owner (`SlotServer`), and
  triggers rebalance operations when the ring changes. The combination of the
  ring plus these helpers gives us a distributed load balancer: every session id
  maps to a slot, every slot maps to a node, and ownership can be shifted in
  small batches without disrupting the rest of the cluster.
  """

  alias Fleetlm.Runtime.Sharding.HashRing
  alias Fleetlm.Runtime.Sharding.SlotServer
  alias Fleetlm.Runtime.Sharding.Supervisor

  @local_registry Fleetlm.Runtime.Sharding.LocalRegistry
  @spec ensure_slots_started() :: :ok | {:error, term()}
  def ensure_slots_started do
    %{slot_count: slot_count} = HashRing.current()

    errors =
      0..(slot_count - 1)
      |> Enum.reduce([], fn slot, acc ->
        case ensure_slot_started(slot) do
          :ok -> acc
          {:error, {:already_started, _pid}} -> acc
          {:error, {:already_present, _pid}} -> acc
          {:error, :already_started} -> acc
          {:error, {:name_already_registered, _pid}} -> acc
          other -> [other | acc]
        end
      end)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  @spec ensure_slot_started(non_neg_integer()) :: :ok | {:error, term()}
  def ensure_slot_started(slot) do
    case lookup_slot(slot) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          :ok
        else
          start_slot_with_retry(slot, 3)
        end

      _ ->
        start_slot_with_retry(slot, 3)
    end
  end

  defp start_slot_with_retry(_slot, 0), do: {:error, :max_retries_exceeded}

  defp start_slot_with_retry(slot, retries) do
    spec = %{
      id: {:shard, slot},
      start: {SlotServer, :start_link, [slot]},
      restart: :transient,
      shutdown: 15_000,
      type: :worker
    }

    try do
      case Horde.DynamicSupervisor.start_child(Supervisor, spec) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, {:already_present, _pid}} -> :ok
        {:error, :already_started} -> :ok
        {:error, {:name_already_registered, _pid}} -> :ok
        {:error, :name_conflict} -> :ok
        other -> other
      end
    catch
      :exit, {:noproc, _} when retries > 0 ->
        # Supervisor might be shutting down, wait and retry
        Process.sleep(200 + :rand.uniform(300))
        start_slot_with_retry(slot, retries - 1)

      :exit, {:noproc, _} ->
        {:error, :supervisor_unavailable}

      :exit, reason when retries > 0 ->
        require Logger

        Logger.warning(
          "Supervisor exit during slot #{slot} start (#{inspect(reason)}), retrying..."
        )

        Process.sleep(200 + :rand.uniform(300))
        start_slot_with_retry(slot, retries - 1)

      :exit, reason ->
        {:error, {:supervisor_exit, reason}}
    end
  end

  @spec rebalance_all() :: :ok
  def rebalance_all do
    %{slot_count: slot_count} = HashRing.current()

    Enum.each(0..(slot_count - 1), fn slot ->
      owner = HashRing.owner_node(slot)

      if owner == Node.self() do
        SlotServer.rebalance(slot)
      else
        try do
          :erpc.cast(owner, SlotServer, :rebalance, [slot])
        catch
          # Node might be down or unreachable
          _, reason ->
            require Logger
            Logger.warning("Failed to rebalance slot #{slot} on #{owner}: #{inspect(reason)}")
        end
      end
    end)

    :ok
  end

  defp lookup_slot(slot) do
    case Registry.lookup(@local_registry, {:shard, slot}) do
      [{pid, _}] -> {:ok, pid}
      _ -> :not_found
    end
  end

  @spec stop_slot(non_neg_integer(), term()) :: :ok
  def stop_slot(slot, reason \\ :normal) do
    SlotServer.stop(slot, reason)
  end
end

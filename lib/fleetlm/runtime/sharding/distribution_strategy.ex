defmodule Fleetlm.Runtime.Sharding.DistributionStrategy do
  @moduledoc """
  Horde distribution strategy that keeps shard processes on the nodes selected by the hash ring.
  """

  @behaviour Horde.DistributionStrategy

  alias Fleetlm.Runtime.Sharding.HashRing

  require Logger

  @impl true
  def choose_node(%{id: {:shard, slot}} = spec, members) do
    preferred_node = HashRing.owner_node(slot)

    case find_member(preferred_node, members) do
      {:ok, member} ->
        {:ok, member}

      :error ->
        fallback(members, spec, preferred_node)
    end
  end

  def choose_node(spec, members) do
    fallback(members, spec, nil)
  end

  @impl true
  def has_quorum?(members) when is_list(members) do
    members
    |> Enum.any?(fn
      %Horde.DynamicSupervisor.Member{status: :alive} -> true
      _ -> false
    end)
  end

  defp find_member(node, members) do
    members
    |> Enum.find(fn
      %Horde.DynamicSupervisor.Member{name: {_name, ^node}, status: :alive} -> true
      _ -> false
    end)
    |> case do
      nil -> :error
      member -> {:ok, member}
    end
  end

  defp fallback([], spec, preferred_node) do
    Logger.warning(
      "No Horde members available for #{inspect(spec.id)}; preferred=#{inspect(preferred_node)}"
    )

    {:error, "no members available"}
  end

  defp fallback(members, spec, preferred_node) do
    case Enum.find(members, &(&1.status == :alive)) do
      nil ->
        Logger.warning(
          "No alive Horde members for #{inspect(spec.id)}; preferred=#{inspect(preferred_node)}"
        )

        {:error, "no alive members"}

      member ->
        Logger.debug(
          "Falling back to #{inspect(member.name)} for #{inspect(spec.id)}; preferred=#{inspect(preferred_node)}"
        )

        {:ok, member}
    end
  end
end

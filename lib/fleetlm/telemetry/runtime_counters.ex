defmodule Fleetlm.Telemetry.RuntimeCounters do
  @moduledoc false

  @key {__MODULE__, :atomics}

  @conversations_index 1
  @inboxes_index 2

  def setup do
    case :persistent_term.get(@key, nil) do
      nil -> :persistent_term.put(@key, :atomics.new(2, []))
      _ -> :ok
    end
  end

  def increment(:conversations_active, delta), do: update(@conversations_index, delta)
  def increment(:inboxes_active, delta), do: update(@inboxes_index, delta)

  defp update(index, delta) do
    atomics = ensure_atomics()
    new_value = :atomics.add_get(atomics, index, delta)

    if new_value < 0 do
      :atomics.put(atomics, index, 0)
      0
    else
      new_value
    end
  end

  defp ensure_atomics do
    case :persistent_term.get(@key, nil) do
      nil ->
        atomics = :atomics.new(2, [])
        :persistent_term.put(@key, atomics)
        atomics

      atomics ->
        atomics
    end
  end
end

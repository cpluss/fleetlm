defmodule Fleetlm.TestSupport.SlotLogs do
  @moduledoc false

  def prepare(tags) do
    base_dir = Path.join(System.tmp_dir!(), "fleetlm-slot-logs")
    File.mkdir_p!(base_dir)

    unique =
      [
        tags[:case] |> module_name(),
        tags[:test] |> test_name(),
        System.unique_integer([:positive]) |> Integer.to_string()
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("-")

    dir = Path.join(base_dir, unique)
    previous = Application.get_env(:fleetlm, :slot_log_dir)

    File.rm_rf(dir)
    File.mkdir_p!(dir)
    Application.put_env(:fleetlm, :slot_log_dir, dir)

    {dir, previous}
  end

  def cleanup({dir, previous}) do
    File.rm_rf(dir)

    case previous do
      nil -> Application.delete_env(:fleetlm, :slot_log_dir)
      _ -> Application.put_env(:fleetlm, :slot_log_dir, previous)
    end

    :ok
  end

  defp module_name(nil), do: ""

  defp module_name(module) when is_atom(module) do
    module
    |> Module.split()
    |> Enum.map(&sanitize/1)
    |> Enum.join("_")
  end

  defp module_name(other) when is_binary(other), do: sanitize(other)
  defp module_name(other), do: other |> to_string() |> sanitize()

  defp test_name(nil), do: ""
  defp test_name(name) when is_atom(name), do: Atom.to_string(name) |> sanitize()
  defp test_name(other) when is_binary(other), do: sanitize(other)
  defp test_name(other), do: other |> to_string() |> sanitize()

  defp sanitize(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9]+/, "_")
    |> String.trim("_")
  end
end

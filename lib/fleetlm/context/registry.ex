defmodule Fleetlm.Context.Registry do
  @moduledoc """
  Registry of available context strategies.

  Built-in strategies can be extended via the application environment:

      config :fleetlm, :context_strategies, %{
        "custom" => MyApp.Context.CustomStrategy
      }
  """

  @default_strategies %{
    "last_n" => Fleetlm.Context.Strategies.LastN,
    "strip_tool_results" => Fleetlm.Context.Strategies.StripToolResults,
    "webhook" => Fleetlm.Context.Strategies.Webhook
  }

  @type strategy_id :: String.t()

  @doc """
  Fetch the module registered for a strategy id.
  """
  @spec fetch(strategy_id()) :: {:ok, module()} | {:error, :unknown_strategy}
  def fetch(id) when is_binary(id) do
    case all() do
      %{^id => module} -> {:ok, module}
      _ -> {:error, :unknown_strategy}
    end
  end

  @doc """
  Return the merged strategy registry.
  """
  @spec all() :: %{strategy_id() => module()}
  def all do
    Application.get_env(:fleetlm, :context_strategies, %{})
    |> Enum.reduce(@default_strategies, fn {id, module}, acc -> Map.put(acc, id, module) end)
  end
end

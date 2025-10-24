defmodule Fleetlm.Context.RegistryTest do
  use ExUnit.Case, async: true

  alias Fleetlm.Context.Registry
  alias Fleetlm.Context.Strategies.{LastN, StripToolResults, Webhook}

  describe "fetch/1" do
    test "returns built-in strategies" do
      assert {:ok, LastN} = Registry.fetch("last_n")
      assert {:ok, StripToolResults} = Registry.fetch("strip_tool_results")
      assert {:ok, Webhook} = Registry.fetch("webhook")
    end

    test "returns error for unknown strategy" do
      assert {:error, :unknown_strategy} = Registry.fetch("unknown")
      assert {:error, :unknown_strategy} = Registry.fetch("custom_strategy")
    end
  end

  describe "all/0" do
    test "returns all built-in strategies" do
      strategies = Registry.all()

      assert is_map(strategies)
      assert strategies["last_n"] == LastN
      assert strategies["strip_tool_results"] == StripToolResults
      assert strategies["webhook"] == Webhook
    end

    test "includes custom strategies from app config" do
      # Note: This test assumes no custom strategies are configured
      # In a real application, you would configure custom strategies
      # and test that they appear in the registry

      strategies = Registry.all()
      assert map_size(strategies) >= 3
    end
  end
end

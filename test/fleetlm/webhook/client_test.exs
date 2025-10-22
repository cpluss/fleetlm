defmodule Fleetlm.Webhook.ClientTest do
  use ExUnit.Case, async: true

  alias Fleetlm.Webhook.Client

  test "build_agent_url preserves origin path for absolute webhook paths" do
    agent = %{
      origin_url: "https://api.example.com/base",
      webhook_path: "/webhook",
      headers: %{}
    }

    assert Client.build_agent_url(agent) == "https://api.example.com/base/webhook"
  end

  test "build_agent_url appends relative webhook paths" do
    agent = %{
      origin_url: "https://api.example.com/base/nested",
      webhook_path: "callback",
      headers: %{}
    }

    assert Client.build_agent_url(agent) == "https://api.example.com/base/nested/callback"
  end

  test "build_agent_url honours absolute webhook URLs" do
    agent = %{
      origin_url: "https://api.example.com/base",
      webhook_path: "https://hooks.example.net/agent",
      headers: %{}
    }

    assert Client.build_agent_url(agent) == "https://hooks.example.net/agent"
  end
end

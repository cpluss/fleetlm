defmodule Fleetlm.Runtime.WebhookEndToEndTest do
  use Fleetlm.TestCase

  alias Fleetlm.Runtime
  alias Fleetlm.Runtime.WebhookEndToEndTest.StubClient

  setup do
    previous_webhook_client = Application.get_env(:fleetlm, :webhook_client)
    previous_disable = Application.get_env(:fleetlm, :disable_agent_webhooks)

    Application.put_env(:fleetlm, :webhook_client, StubClient)
    Application.put_env(:fleetlm, :disable_agent_webhooks, false)

    {:ok, counter} = StubClient.start_counter()

    on_exit(fn ->
      if Process.alive?(counter), do: Agent.stop(counter)

      if previous_webhook_client do
        Application.put_env(:fleetlm, :webhook_client, previous_webhook_client)
      else
        Application.delete_env(:fleetlm, :webhook_client)
      end

      if previous_disable == nil do
        Application.delete_env(:fleetlm, :disable_agent_webhooks)
      else
        Application.put_env(:fleetlm, :disable_agent_webhooks, previous_disable)
      end
    end)

    :ok
  end

  defmodule StubClient do
    def start_counter do
      Agent.start_link(fn -> 0 end, name: __MODULE__.Counter)
    end

    def call_agent_webhook(_agent, _payload, _handler) do
      Agent.update(__MODULE__.Counter, &(&1 + 1))
      {:error, :stub_failure}
    end

    def call_compaction_webhook(_url, _payload), do: {:ok, %{}}

    def count do
      Agent.get(__MODULE__.Counter, & &1)
    end
  end

  test "webhook fires for each user message in same session" do
    agent_id = Uniq.UUID.uuid7(:slug)

    {:ok, _agent} =
      Fleetlm.Agent.create(%{
        id: agent_id,
        name: "Webhook Stub Agent",
        origin_url: "https://example.org",
        webhook_path: "/stub",
        timeout_ms: 1_000,
        status: "enabled"
      })

    session = create_test_session("user-webhook", agent_id)

    {:ok, _seq1} =
      Runtime.append_message(
        session.id,
        session.user_id,
        session.agent_id,
        "text",
        %{"text" => "hello webhook"},
        %{}
      )

    eventually(
      fn ->
        assert StubClient.count() == 1
      end,
      timeout: 5_000
    )

    {:ok, _seq2} =
      Runtime.append_message(
        session.id,
        session.user_id,
        session.agent_id,
        "text",
        %{"text" => "second message"},
        %{}
      )

    eventually(
      fn ->
        assert StubClient.count() == 2
      end,
      timeout: 5_000
    )
  end
end

defmodule Fleetlm.Context.Strategies.WebhookTest do
  use ExUnit.Case, async: true

  alias Fleetlm.Context.Strategies.Webhook

  defp message(text, seq) do
    %{"seq" => seq, "content" => %{"text" => text}}
  end

  test "append_message triggers compaction when token budget exceeded" do
    config = %{"compaction_url" => "https://example.com", "max_tokens" => 1}

    {:ok, snapshot} =
      Webhook.append_message(nil, message(String.duplicate("a", 4), 1), config, [])

    assert {:compact, next_snapshot, {:webhook, job}} =
             Webhook.append_message(snapshot, message(String.duplicate("b", 4), 2), config, [])

    assert next_snapshot.metadata[:compaction_inflight]
    assert :queue.is_queue(next_snapshot.metadata[:pending_queue])
    assert job.url == "https://example.com"
    assert job.payload[:pending_messages]
    assert job.payload[:token_budget] == 1
  end

  test "append_message honours compaction_inflight flag" do
    config = %{"compaction_url" => "https://example.com", "max_tokens" => 1}

    {:ok, snapshot} =
      Webhook.append_message(nil, message(String.duplicate("a", 4), 1), config, [])

    {:compact, inflight_snapshot, _job} =
      Webhook.append_message(snapshot, message(String.duplicate("b", 4), 2), config, [])

    assert inflight_snapshot.metadata[:compaction_inflight]

    assert {:ok, _snapshot} =
             Webhook.append_message(
               inflight_snapshot,
               message(String.duplicate("c", 4), 3),
               config,
               []
             )
  end

  test "apply_compaction replaces summary and clears pending" do
    config = %{"compaction_url" => "https://example.com", "max_tokens" => 1}

    {:ok, snapshot} =
      Webhook.append_message(nil, message(String.duplicate("a", 4), 1), config, [])

    {:compact, inflight_snapshot, _job} =
      Webhook.append_message(snapshot, message(String.duplicate("b", 4), 2), config, [])

    result = %{"messages" => [%{"seq" => 100, "content" => %{"text" => "summary"}}]}

    assert {:ok, applied} = Webhook.apply_compaction(inflight_snapshot, result, config, [])
    assert applied.summary_messages == result["messages"]
    assert applied.pending_messages == []
    refute applied.metadata[:compaction_inflight]
    assert applied.metadata[:summary_token_count] == applied.token_count
  end

  test "apply_compaction rejects summaries that exceed budget" do
    config = %{"compaction_url" => "https://example.com", "max_tokens" => 1}

    {:ok, snapshot} =
      Webhook.append_message(nil, message(String.duplicate("a", 4), 1), config, [])

    result = %{
      "messages" => [
        %{"seq" => 100, "content" => %{"text" => String.duplicate("b", 16)}}
      ]
    }

    assert {:error, :summary_over_token_budget} =
             Webhook.apply_compaction(snapshot, result, config, [])
  end
end

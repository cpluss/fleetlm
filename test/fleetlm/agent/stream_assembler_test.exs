defmodule Fleetlm.Agent.StreamAssemblerTest do
  use ExUnit.Case, async: true

  alias Fleetlm.Agent.StreamAssembler

  test "accumulates text chunks and finalizes message" do
    state = StreamAssembler.new()

    assert {:ok, state, [{:chunk, %{"type" => "text-start"}}]} =
             StreamAssembler.ingest(state, %{"type" => "text-start", "id" => "text-1"})

    assert {:ok, state, [{:chunk, _}]} =
             StreamAssembler.ingest(state, %{
               "type" => "text-delta",
               "id" => "text-1",
               "delta" => "Hel"
             })

    assert {:ok, state, [{:chunk, _}]} =
             StreamAssembler.ingest(state, %{
               "type" => "text-delta",
               "id" => "text-1",
               "delta" => "lo"
             })

    assert {:ok, state, [{:chunk, _}]} =
             StreamAssembler.ingest(state, %{"type" => "text-end", "id" => "text-1"})

    finish_chunk = %{"type" => "finish", "messageMetadata" => %{"latency_ms" => 123}}

    assert {:ok, _state, actions} = StreamAssembler.ingest(state, finish_chunk)

    assert [{:chunk, ^finish_chunk}, {:finalize, message, %{termination: :finish}}] = actions

    assert message["role"] == "assistant"
    assert is_binary(message["id"])
    assert message["metadata"] == %{"latency_ms" => 123}

    assert [part] = message["parts"]
    assert part["type"] == "text"
    assert part["text"] == "Hello"
    assert part["state"] == "done"
  end

  test "tracks tool lifecycle" do
    state = StreamAssembler.new()

    start_chunk = %{
      "type" => "tool-input-start",
      "toolCallId" => "call-1",
      "toolName" => "weather"
    }

    assert {:ok, state, [{:chunk, ^start_chunk}]} = StreamAssembler.ingest(state, start_chunk)

    delta_chunk = %{
      "type" => "tool-input-delta",
      "toolCallId" => "call-1",
      "inputTextDelta" => "{\"city\":"
    }

    assert {:ok, state, [{:chunk, ^delta_chunk}]} = StreamAssembler.ingest(state, delta_chunk)

    continue_chunk = %{
      "type" => "tool-input-delta",
      "toolCallId" => "call-1",
      "inputTextDelta" => "\"Paris\"}"
    }

    assert {:ok, state, [{:chunk, ^continue_chunk}]} =
             StreamAssembler.ingest(state, continue_chunk)

    available_chunk = %{
      "type" => "tool-input-available",
      "toolCallId" => "call-1",
      "toolName" => "weather",
      "input" => %{"city" => "Paris"}
    }

    assert {:ok, state, [{:chunk, ^available_chunk}]} =
             StreamAssembler.ingest(state, available_chunk)

    output_chunk = %{
      "type" => "tool-output-available",
      "toolCallId" => "call-1",
      "output" => %{"temperature" => 20}
    }

    assert {:ok, state, [{:chunk, ^output_chunk}]} = StreamAssembler.ingest(state, output_chunk)

    {:ok, _state, actions} = StreamAssembler.ingest(state, %{"type" => "finish"})

    [{:chunk, _}, {:finalize, message, %{termination: :finish}}] = actions

    [part] = message["parts"]
    assert part["type"] == "tool-weather"
    assert part["toolCallId"] == "call-1"
    assert part["state"] == "output-available"
    assert part["input"] == %{"city" => "Paris"}
    assert part["output"] == %{"temperature" => 20}
  end

  test "abort finalizes message" do
    state = StreamAssembler.new()
    {:ok, state, _} = StreamAssembler.ingest(state, %{"type" => "text-start", "id" => "t"})

    {:ok, _state, actions} = StreamAssembler.ingest(state, %{"type" => "abort"})

    assert [{:chunk, _}, {:finalize, message, %{termination: :abort}}, {:abort, _}] = actions
    assert [part] = message["parts"]
    assert part["state"] == "done"
  end

  test "data chunks overwrite by id" do
    state = StreamAssembler.new()

    chunk1 = %{"type" => "data-chart", "id" => "chart", "data" => %{"points" => [1]}}
    chunk2 = %{"type" => "data-chart", "id" => "chart", "data" => %{"points" => [1, 2]}}

    {:ok, state, _} = StreamAssembler.ingest(state, chunk1)
    {:ok, state, _} = StreamAssembler.ingest(state, chunk2)
    {:ok, _state, actions} = StreamAssembler.ingest(state, %{"type" => "finish"})

    [{:chunk, _}, {:finalize, message, _}] = actions
    assert [%{"type" => "data-chart", "data" => %{"points" => [1, 2]}}] = message["parts"]
  end

  test "handles streamed conversation with step markers" do
    chunks = [
      %{"type" => "start"},
      %{"type" => "start-step"},
      %{
        "type" => "text-start",
        "id" => "msg_123",
        "providerMetadata" => %{"openai" => %{"itemId" => "msg_123"}}
      },
      %{"type" => "text-delta", "id" => "msg_123", "delta" => "Not"},
      %{"type" => "text-delta", "id" => "msg_123", "delta" => " much"},
      %{"type" => "text-delta", "id" => "msg_123", "delta" => "!"},
      %{"type" => "text-delta", "id" => "msg_123", "delta" => " How"},
      %{"type" => "text-delta", "id" => "msg_123", "delta" => " can"},
      %{"type" => "text-delta", "id" => "msg_123", "delta" => " I"},
      %{"type" => "text-delta", "id" => "msg_123", "delta" => " assist"},
      %{"type" => "text-delta", "id" => "msg_123", "delta" => " you"},
      %{"type" => "text-delta", "id" => "msg_123", "delta" => " today"},
      %{"type" => "text-delta", "id" => "msg_123", "delta" => "?"},
      %{"type" => "text-end", "id" => "msg_123"},
      %{"type" => "finish-step"},
      %{"type" => "finish"}
    ]

    {_state, final_actions} =
      Enum.reduce(chunks, {StreamAssembler.new(), []}, fn chunk, {state, _} ->
        {:ok, new_state, actions} = StreamAssembler.ingest(state, chunk)
        {new_state, actions}
      end)

    [{:chunk, %{"type" => "finish"}}, {:finalize, message, %{termination: :finish}}] =
      final_actions

    assert [%{"type" => "step-start"}, text_part] = message["parts"]
    assert text_part["type"] == "text"
    assert text_part["text"] == "Not much! How can I assist you today?"
    assert text_part["state"] == "done"
    assert text_part["providerMetadata"] == %{"openai" => %{"itemId" => "msg_123"}}
  end
end

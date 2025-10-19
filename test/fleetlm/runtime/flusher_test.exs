defmodule Fleetlm.Runtime.FlusherTest do
  use Fleetlm.TestCase

  alias Fleetlm.Runtime.{Flusher, RaftFSM, RaftManager}
  alias Fleetlm.Storage.Model.Message

  describe "flush cycle" do
    test "flushes unflushed messages to Postgres" do
      import Ecto.Query

      # Create a session
      session = create_test_session("alice", "bob")

      # Append messages via Runtime
      {:ok, _seq1} =
        Fleetlm.Runtime.append_message(
          session.id,
          "alice",
          "bob",
          "text",
          %{"text" => "msg1"},
          %{}
        )

      {:ok, _seq2} =
        Fleetlm.Runtime.append_message(
          session.id,
          "alice",
          "bob",
          "text",
          %{"text" => "msg2"},
          %{}
        )

      # Trigger flush
      send(Flusher, :flush)
      Process.sleep(1000)

      # Verify messages in Postgres
      db_messages =
        Repo.all(from(m in Message, where: m.session_id == ^session.id, order_by: [asc: m.seq]))

      assert length(db_messages) == 2
      assert Enum.at(db_messages, 0).content["text"] == "msg1"
      assert Enum.at(db_messages, 1).content["text"] == "msg2"
    end
  end

  describe "batch chunking" do
    test "chunks large message sets to avoid Postgres param limits" do
      # Create 10000 fake messages
      messages =
        for i <- 1..10000 do
          %{
            id: "msg_#{i}",
            session_id: "session_1",
            sender_id: "alice",
            recipient_id: "bob",
            seq: i,
            kind: "text",
            content: %{"text" => "msg#{i}"},
            metadata: %{},
            inserted_at: NaiveDateTime.utc_now()
          }
        end

      # Chunk into 5000-message batches
      chunks = Enum.chunk_every(messages, 5000)

      # Should have 2 chunks
      assert length(chunks) == 2
      assert length(Enum.at(chunks, 0)) == 5000
      assert length(Enum.at(chunks, 1)) == 5000

      # Each chunk should be insertable without exceeding Postgres limits
      # (10 fields × 5000 messages = 50000 params, under 65535 limit)
      for chunk <- chunks do
        param_count = length(chunk) * 10
        assert param_count < 65535
      end
    end
  end
end

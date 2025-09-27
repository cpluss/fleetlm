Code.require_file("support/bench_helper.exs", __DIR__)

defmodule ParticipantWorkloadBench do
  @moduledoc """
  Comprehensive benchmarks for participant (human user) workloads and general session operations.

  Tests include:
  - Human participant inbox and session operations
  - Session creation and message sending patterns
  - Read tracking and unread count calculations
  - Mixed human/agent interaction scenarios
  - Session lifecycle operations (create, message, mark read)
  """

  import Bench.Helper
  alias Fleetlm.Conversation

  def run_benchmarks(opts \\ []) do
    dataset_size = Keyword.get(opts, :dataset, :standard)

    IO.puts("👥 Participant Workload Performance Benchmarks")
    IO.puts("==============================================")
    IO.puts("Dataset: #{dataset_size}")
    IO.puts("")

    # Create test data based on specified size
    data = create_test_data(dataset_size)

    IO.puts("📋 Test Data:")
    IO.puts("   Humans: #{length(data.humans)}")
    IO.puts("   Agents: #{length(data.agents)}")
    IO.puts("   Sessions: #{length(data.sessions)}")
    IO.puts("")

    # Run benchmark scenarios
    run_benchmark("Participant Workload", build_scenarios(data), time: 5, memory_time: 2)
  end

  defp create_test_data(:lightweight), do: create_lightweight_test_data()
  defp create_test_data(:standard), do: create_standard_test_data()
  defp create_test_data(:heavy), do: create_heavy_test_data()

  defp build_scenarios(data) do
    %{
      "Human Inbox Check" => fn ->
        human = Enum.random(data.humans)
        Conversation.get_inbox_snapshot(human)
      end,

      "Human Session List" => fn ->
        human = Enum.random(data.humans)
        Conversation.list_sessions_for_participant(human, limit: 20)
      end,

      "Human Session List with Unread Counts" => fn ->
        human = Enum.random(data.humans)
        Conversation.list_sessions_with_unread_counts(human, limit: 20)
      end,

      "Human Message Send" => fn ->
        human = Enum.random(data.humans)
        session = Enum.random(data.sessions)

        # Only send if human is part of the session
        if human in [session.initiator_id, session.peer_id] do
          Conversation.append_message(session.id, %{
            sender_id: human,
            kind: "text",
            content: %{text: "Human message"}
          })
        else
          :skipped
        end
      end,

      "Session Creation" => fn ->
        [participant1, participant2] = Enum.take_random(data.all_participants, 2)
        Conversation.start_session(%{
          initiator_id: participant1,
          peer_id: participant2
        })
      end,

      "Mark Messages as Read" => fn ->
        human = Enum.random(data.humans)
        # Find a session where this human participates
        session = Enum.find(data.sessions, fn s ->
          human in [s.initiator_id, s.peer_id]
        end)

        if session do
          Conversation.mark_read(session.id, human)
        else
          :skipped
        end
      end,

      "Mixed Human/Agent Conversation" => fn ->
        # Simulate a conversation between human and agent
        human = Enum.random(data.humans)
        agent = Enum.random(data.agents)

        {:ok, session} = Conversation.start_session(%{
          initiator_id: human,
          peer_id: agent
        })

        # Human sends message
        Conversation.append_message(session.id, %{
          sender_id: human,
          kind: "text",
          content: %{text: "Hello agent"}
        })

        # Agent responds
        Conversation.append_message(session.id, %{
          sender_id: agent,
          kind: "text",
          content: %{text: "Hello human"}
        })

        # Human checks inbox
        Conversation.get_inbox_snapshot(human)
      end,

      "Concurrent Human Activity" => fn ->
        # Test multiple humans performing actions simultaneously
        data.humans
        |> Enum.take(min(5, length(data.humans)))
        |> Task.async_stream(
          fn human ->
            # Each human checks inbox and potentially sends a message
            inbox = Conversation.get_inbox_snapshot(human)

            # Sometimes send a message
            if :rand.uniform(3) == 1 do
              session = Enum.find(data.sessions, fn s ->
                human in [s.initiator_id, s.peer_id]
              end)

              if session do
                Conversation.append_message(session.id, %{
                  sender_id: human,
                  kind: "text",
                  content: %{text: "Concurrent message"}
                })
              end
            end

            length(inbox)
          end,
          timeout: :infinity,
          max_concurrency: 5
        )
        |> Enum.map(fn {:ok, result} -> result end)
      end,

      "Session History Load" => fn ->
        session = Enum.random(data.sessions)
        Conversation.list_messages(session.id, limit: 50)
      end
    }
  end

  def run_query_analysis(opts \\ []) do
    dataset_size = Keyword.get(opts, :dataset, :standard)

    IO.puts("🔍 Participant Workload Query Analysis")
    IO.puts("======================================")
    IO.puts("")

    data = create_test_data(dataset_size)
    human = Enum.random(data.humans)
    session = Enum.random(data.sessions)

    # Analyze key operations
    benchmark_with_queries("Human Inbox Check", fn ->
      Conversation.get_inbox_snapshot(human)
    end)

    benchmark_with_queries("Session List with Unread Counts", fn ->
      Conversation.list_sessions_with_unread_counts(human, limit: 20)
    end)

    benchmark_with_queries("Session Creation", fn ->
      [p1, p2] = Enum.take_random(data.all_participants, 2)
      Conversation.start_session(%{initiator_id: p1, peer_id: p2})
    end)

    benchmark_with_queries("Message Send", fn ->
      Conversation.append_message(session.id, %{
        sender_id: human,
        kind: "text",
        content: %{text: "Analysis message"}
      })
    end)

    benchmark_with_queries("Mark as Read", fn ->
      Conversation.mark_read(session.id, human)
    end)

    benchmark_with_queries("Session History Load", fn ->
      Conversation.list_messages(session.id, limit: 50)
    end)

    IO.puts("")
  end

  def run_scalability_test(opts \\ []) do
    IO.puts("⚡ Participant Scalability Test")
    IO.puts("==============================")
    IO.puts("")

    # Test with increasing numbers of participants
    Enum.each([5, 10, 20, 50], fn participant_count ->
      IO.puts("🔸 Testing with #{participant_count} participants...")

      data = create_standard_test_data(
        humans: div(participant_count * 2, 3),
        agents: div(participant_count, 3),
        sessions: participant_count,
        messages_per_session: 3,
        warm_caches: false
      )

      # Test concurrent inbox checks
      {time_ms, queries, _results} = benchmark_with_queries(
        "#{participant_count} Concurrent Inbox Checks",
        fn ->
          data.all_participants
          |> Task.async_stream(
            fn participant -> Conversation.get_inbox_snapshot(participant) end,
            timeout: :infinity,
            max_concurrency: participant_count
          )
          |> Enum.map(fn {:ok, result} -> result end)
        end
      )

      queries_per_participant = Float.round(queries / participant_count, 1)
      IO.puts("   Queries per participant: #{queries_per_participant}")
      IO.puts("   Avg time per participant: #{Float.round(time_ms / participant_count, 2)}ms")
      IO.puts("")
    end)
  end
end

# Setup database once
Bench.Helper.global_setup()

# Parse command line arguments
{opts, _args, _invalid} = OptionParser.parse(System.argv(),
  switches: [dataset: :string, analysis: :boolean, scalability: :boolean],
  aliases: [d: :dataset, a: :analysis, s: :scalability]
)

dataset = case opts[:dataset] do
  "light" -> :lightweight
  "heavy" -> :heavy
  _ -> :standard
end

cond do
  opts[:analysis] ->
    ParticipantWorkloadBench.run_query_analysis(dataset: dataset)
  opts[:scalability] ->
    ParticipantWorkloadBench.run_scalability_test()
  true ->
    ParticipantWorkloadBench.run_benchmarks(dataset: dataset)
end
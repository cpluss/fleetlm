Code.require_file("support/bench_helper.exs", __DIR__)

defmodule AgentWorkloadBench do
  @moduledoc """
  Comprehensive benchmarks for agent workloads simulating real-world usage patterns.

  Tests include:
  - Single agent inbox operations (baseline performance)
  - Concurrent agent processing (scalability testing)
  - Agent response generation and delivery
  - Cache hit/miss scenarios
  - Different dataset sizes for load testing
  """

  import Bench.Helper
  alias Fleetlm.Conversation

  def run_benchmarks(opts \\ []) do
    dataset_size = Keyword.get(opts, :dataset, :standard)

    IO.puts("🤖 Agent Workload Performance Benchmarks")
    IO.puts("========================================")
    IO.puts("Dataset: #{dataset_size}")
    IO.puts("")

    # Create test data based on specified size
    data = create_test_data(dataset_size)

    IO.puts("📋 Test Data:")
    IO.puts("   Agents: #{length(data.agents)}")
    IO.puts("   Humans: #{length(data.humans)}")
    IO.puts("   Sessions: #{length(data.sessions)}")
    IO.puts("")

    # Run benchmark scenarios
    run_benchmark("Agent Workload", build_scenarios(data), time: 5, memory_time: 2)
  end

  defp create_test_data(:lightweight), do: create_lightweight_test_data()
  defp create_test_data(:standard), do: create_standard_test_data()
  defp create_test_data(:heavy), do: create_heavy_test_data()

  defp build_scenarios(data) do
    %{
      "Single Agent Inbox Check" => fn ->
        agent = Enum.random(data.agents)
        Conversation.get_inbox_snapshot(agent)
      end,

      "Single Agent Session List" => fn ->
        agent = Enum.random(data.agents)
        Conversation.list_sessions_for_participant(agent, limit: 20)
      end,

      "Agent Message Send" => fn ->
        agent = Enum.random(data.agents)
        session = Enum.random(data.sessions)

        # Only send if agent is part of the session
        if agent in [session.initiator_id, session.peer_id] do
          Conversation.append_message(session.id, %{
            sender_id: agent,
            kind: "text",
            content: %{text: "Benchmark response"}
          })
        else
          :skipped
        end
      end,

      "Concurrent Agent Inbox Load" => fn ->
        # Test all agents checking their inboxes concurrently
        data.agents
        |> Task.async_stream(
          fn agent ->
            Conversation.get_inbox_snapshot(agent)
          end,
          timeout: :infinity,
          max_concurrency: length(data.agents)
        )
        |> Enum.map(fn {:ok, result} -> result end)
      end,

      "Agent Workflow Simulation" => fn ->
        # Simulate realistic agent workflow: check inbox, respond to messages
        agent = Enum.random(data.agents)

        # Agent checks inbox
        inbox = Conversation.get_inbox_snapshot(agent, limit: 5)

        # Agent responds to some sessions
        agent_sessions = Enum.filter(data.sessions, fn session ->
          agent in [session.initiator_id, session.peer_id]
        end)

        response_count = min(length(agent_sessions), 2)
        Enum.each(Enum.take_random(agent_sessions, response_count), fn session ->
          Conversation.append_message(session.id, %{
            sender_id: agent,
            kind: "text",
            content: %{text: "Workflow response"}
          })
        end)

        length(inbox)
      end,

      "Cold Cache Agent Load" => fn ->
        # Clear caches to simulate cold start
        Cachex.clear(:fleetlm_session_inboxes)

        agent = Enum.random(data.agents)
        Conversation.get_inbox_snapshot(agent)
      end
    }
  end

  def run_query_analysis(opts \\ []) do
    dataset_size = Keyword.get(opts, :dataset, :standard)

    IO.puts("🔍 Agent Workload Query Analysis")
    IO.puts("================================")
    IO.puts("")

    data = create_test_data(dataset_size)
    agent = Enum.random(data.agents)

    # Analyze key operations
    benchmark_with_queries("Single Agent Inbox (Warm Cache)", fn ->
      Conversation.get_inbox_snapshot(agent)
    end)

    benchmark_with_queries("Single Agent Inbox (Cold Cache)", fn ->
      Cachex.clear(:fleetlm_session_inboxes)
      Conversation.get_inbox_snapshot(agent)
    end)

    benchmark_with_queries("Agent Session List", fn ->
      Conversation.list_sessions_for_participant(agent, limit: 20)
    end)

    benchmark_with_queries("Concurrent Agent Inbox (#{length(data.agents)} agents)", fn ->
      data.agents
      |> Task.async_stream(fn a -> Conversation.get_inbox_snapshot(a) end,
                          timeout: :infinity, max_concurrency: length(data.agents))
      |> Enum.map(fn {:ok, result} -> result end)
    end)

    IO.puts("")
  end
end

# Setup database once
Bench.Helper.global_setup()

# Parse command line arguments
{opts, _args, _invalid} = OptionParser.parse(System.argv(),
  switches: [dataset: :string, analysis: :boolean],
  aliases: [d: :dataset, a: :analysis]
)

dataset = case opts[:dataset] do
  "light" -> :lightweight
  "heavy" -> :heavy
  _ -> :standard
end

if opts[:analysis] do
  AgentWorkloadBench.run_query_analysis(dataset: dataset)
else
  AgentWorkloadBench.run_benchmarks(dataset: dataset)
end
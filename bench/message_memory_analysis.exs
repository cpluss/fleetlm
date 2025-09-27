Code.require_file("support/bench_helper.exs", __DIR__)

defmodule MessageMemoryAnalysis do
  @moduledoc """
  Deep dive analysis of memory usage patterns in message sending operations.

  Investigates the 365% memory deviation observed in benchmarks by testing:
  - Different message types and sizes
  - Agent vs human message sending
  - Session types (agent_dm vs human_dm)
  - Cache states and session server initialization
  - Transaction overhead and cleanup patterns
  """

  import Bench.Helper
  alias Fleetlm.Sessions

  def run_analysis do
    IO.puts("🔍 Message Memory Usage Analysis")
    IO.puts("===============================")
    IO.puts("")

    # Setup database and test data
    global_setup()
    data = create_lightweight_test_data()

    IO.puts("📋 Test Setup:")
    IO.puts("   Agents: #{length(data.agents)}")
    IO.puts("   Humans: #{length(data.humans)}")
    IO.puts("   Sessions: #{length(data.sessions)}")
    IO.puts("")

    # Run targeted memory analysis
    analyze_message_types(data)
    analyze_session_types(data)
    analyze_sender_types(data)
    analyze_cache_states(data)
    analyze_concurrent_patterns(data)

    IO.puts("✅ Memory analysis complete!")
  end

  defp analyze_message_types(data) do
    IO.puts("🔸 Message Content Size Analysis")
    IO.puts("-------------------------------")

    session = Enum.random(data.sessions)
    sender = session.initiator_id

    # Test different message sizes
    message_sizes = [
      {"Small", "Hi"},
      {"Medium", String.duplicate("Hello world! ", 10)},
      {"Large", String.duplicate("This is a large message content. ", 50)},
      {"JSON", %{type: "structured", data: %{items: Enum.to_list(1..20)}} |> Jason.encode!()}
    ]

    Enum.each(message_sizes, fn {size_name, content} ->
      {memory_kb, time_us} = measure_message_memory(session.id, sender, content)
      IO.puts("   #{size_name}: #{memory_kb}KB (#{Float.round(time_us/1000, 2)}ms)")
    end)

    IO.puts("")
  end

  defp analyze_session_types(data) do
    IO.puts("🔸 Session Type Analysis")
    IO.puts("-----------------------")

    # Find different session types
    agent_session = Enum.find(data.sessions, fn s ->
      s.initiator_id in data.agents or s.peer_id in data.agents
    end)

    human_session = Enum.find(data.sessions, fn s ->
      s.initiator_id in data.humans and s.peer_id in data.humans
    end)

    if agent_session do
      sender = if agent_session.initiator_id in data.agents, do: agent_session.peer_id, else: agent_session.initiator_id
      {memory_kb, time_us} = measure_message_memory(agent_session.id, sender, "Test message to agent session")
      IO.puts("   Agent Session: #{memory_kb}KB (#{Float.round(time_us/1000, 2)}ms)")
    end

    if human_session do
      {memory_kb, time_us} = measure_message_memory(human_session.id, human_session.initiator_id, "Test message to human session")
      IO.puts("   Human Session: #{memory_kb}KB (#{Float.round(time_us/1000, 2)}ms)")
    end

    IO.puts("")
  end

  defp analyze_sender_types(data) do
    IO.puts("🔸 Sender Type Analysis")
    IO.puts("----------------------")

    session = Enum.random(data.sessions)

    # Agent sending message
    if session.initiator_id in data.agents do
      {memory_kb, time_us} = measure_message_memory(session.id, session.initiator_id, "Message from agent")
      IO.puts("   Agent Sender: #{memory_kb}KB (#{Float.round(time_us/1000, 2)}ms)")
    end

    # Human sending message
    human_sender = if session.initiator_id in data.humans, do: session.initiator_id, else: session.peer_id
    {memory_kb, time_us} = measure_message_memory(session.id, human_sender, "Message from human")
    IO.puts("   Human Sender: #{memory_kb}KB (#{Float.round(time_us/1000, 2)}ms)")

    IO.puts("")
  end

  defp analyze_cache_states(data) do
    IO.puts("🔸 Cache State Analysis")
    IO.puts("----------------------")

    session = Enum.random(data.sessions)
    sender = session.initiator_id

    # Warm cache scenario
    Sessions.get_inbox_snapshot(sender)  # Warm up
    {memory_warm, time_warm} = measure_message_memory(session.id, sender, "Warm cache message")
    IO.puts("   Warm Cache: #{memory_warm}KB (#{Float.round(time_warm/1000, 2)}ms)")

    # Cold cache scenario
    cleanup()  # Clear caches
    {memory_cold, time_cold} = measure_message_memory(session.id, sender, "Cold cache message")
    IO.puts("   Cold Cache: #{memory_cold}KB (#{Float.round(time_cold/1000, 2)}ms)")

    memory_diff = memory_cold - memory_warm
    time_diff = (time_cold - time_warm) / 1000
    IO.puts("   Difference: +#{memory_diff}KB (+#{Float.round(time_diff, 2)}ms)")

    IO.puts("")
  end

  defp analyze_concurrent_patterns(data) do
    IO.puts("🔸 Concurrent Message Pattern Analysis")
    IO.puts("-------------------------------------")

    # Single message
    session = Enum.random(data.sessions)
    {memory_single, time_single} = measure_message_memory(session.id, session.initiator_id, "Single message")
    IO.puts("   Single Message: #{memory_single}KB (#{Float.round(time_single/1000, 2)}ms)")

    # Burst of messages
    {memory_burst, time_burst} = measure_burst_memory(session, 5)
    IO.puts("   5-Message Burst: #{memory_burst}KB (#{Float.round(time_burst/1000, 2)}ms)")

    # Concurrent messages across sessions
    {memory_concurrent, time_concurrent} = measure_concurrent_memory(data, 3)
    IO.puts("   3 Concurrent Messages: #{memory_concurrent}KB (#{Float.round(time_concurrent/1000, 2)}ms)")

    IO.puts("")
  end

  defp measure_message_memory(session_id, sender_id, content) do
    {time_us, memory_bytes} = :timer.tc(fn ->
      measure_memory(fn ->
        Sessions.append_message(session_id, %{
          sender_id: sender_id,
          kind: "text",
          content: %{text: content}
        })
      end)
      |> elem(1)  # Get memory usage
    end)

    memory_kb = Float.round(memory_bytes / 1024, 2)
    {memory_kb, time_us}
  end

  defp measure_burst_memory(session, count) do
    {time_us, memory_bytes} = :timer.tc(fn ->
      measure_memory(fn ->
        Enum.each(1..count, fn i ->
          Sessions.append_message(session.id, %{
            sender_id: session.initiator_id,
            kind: "text",
            content: %{text: "Burst message #{i}"}
          })
        end)
      end)
      |> elem(1)  # Get memory usage
    end)

    memory_kb = Float.round(memory_bytes / 1024, 2)
    {memory_kb, time_us}
  end

  defp measure_concurrent_memory(data, count) do
    sessions = Enum.take_random(data.sessions, count)

    {time_us, memory_bytes} = :timer.tc(fn ->
      measure_memory(fn ->
        sessions
        |> Task.async_stream(fn session ->
          Sessions.append_message(session.id, %{
            sender_id: session.initiator_id,
            kind: "text",
            content: %{text: "Concurrent message"}
          })
        end, timeout: :infinity, max_concurrency: count)
        |> Enum.to_list()
      end)
      |> elem(1)  # Get memory usage
    end)

    memory_kb = Float.round(memory_bytes / 1024, 2)
    {memory_kb, time_us}
  end

  def run_detailed_benchmark do
    IO.puts("🚀 Detailed Message Memory Benchmark")
    IO.puts("====================================")
    IO.puts("")

    global_setup()
    data = create_lightweight_test_data()

    # Run focused benchmark on message sending scenarios
    scenarios = build_memory_scenarios(data)

    Benchee.run(
      scenarios,
      time: 3,
      memory_time: 3,
      warmup: 1,
      formatters: [Benchee.Formatters.Console],
      print: [
        benchmarking: true,
        fast_warning: false
      ]
    )
  end

  defp build_memory_scenarios(data) do
    session = Enum.random(data.sessions)
    agent_session = Enum.find(data.sessions, fn s ->
      s.initiator_id in data.agents or s.peer_id in data.agents
    end) || session

    %{
      "Small Message (Human)" => fn ->
        Sessions.append_message(session.id, %{
          sender_id: session.initiator_id,
          kind: "text",
          content: %{text: "Hi"}
        })
      end,

      "Large Message (Human)" => fn ->
        Sessions.append_message(session.id, %{
          sender_id: session.initiator_id,
          kind: "text",
          content: %{text: String.duplicate("Large message content. ", 30)}
        })
      end,

      "Message to Agent Session" => fn ->
        sender = if agent_session.initiator_id in data.agents, do: agent_session.peer_id, else: agent_session.initiator_id
        Sessions.append_message(agent_session.id, %{
          sender_id: sender,
          kind: "text",
          content: %{text: "Message to agent"}
        })
      end,

      "Agent Response" => fn ->
        agent_id = if agent_session.initiator_id in data.agents, do: agent_session.initiator_id, else: agent_session.peer_id
        Sessions.append_message(agent_session.id, %{
          sender_id: agent_id,
          kind: "text",
          content: %{text: "Agent response"}
        })
      end,

      "Cold Cache Message" => fn ->
        cleanup()  # Clear caches
        Sessions.append_message(session.id, %{
          sender_id: session.initiator_id,
          kind: "text",
          content: %{text: "Cold cache test"}
        })
      end
    }
  end
end

# Parse command line arguments
{opts, _args, _invalid} = OptionParser.parse(System.argv(),
  switches: [benchmark: :boolean],
  aliases: [b: :benchmark]
)

if opts[:benchmark] do
  MessageMemoryAnalysis.run_detailed_benchmark()
else
  MessageMemoryAnalysis.run_analysis()
end
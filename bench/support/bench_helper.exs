defmodule Bench.MockWebhookReceiver do
  @moduledoc """
  Lightweight in-memory webhook receiver used by the benchmark suite.

  Instead of issuing real HTTP requests, webhook deliveries are routed to this
  GenServer which records delivery counts and replies immediately. This keeps
  the dispatcher hot path lightweight and eliminates connection refused errors
  during benchmarks while still exercising the delivery pipeline.
  """

  use GenServer

  @response %Req.Response{
    status: 200,
    headers: %{},
    body: "bench-mock",
    trailers: %{},
    private: %{}
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @spec ensure_started() :: {:ok, pid()} | {:error, term()}
  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end

      pid when is_pid(pid) ->
        {:ok, pid}
    end
  end

  @spec pid() :: pid()
  def pid do
    case ensure_started() do
      {:ok, pid} -> pid
      _ -> raise "mock webhook receiver failed to start"
    end
  end

  @spec reset() :: :ok
  def reset do
    ensure_started()
    GenServer.cast(__MODULE__, :reset)
  end

  @spec deliver(map()) :: {:ok, Req.Response.t()} | {:error, term()}
  def deliver(payload) when is_map(payload) do
    ensure_started()
    GenServer.call(__MODULE__, {:deliver, payload})
  end

  @spec stats() :: %{count: non_neg_integer()}
  def stats do
    ensure_started()
    GenServer.call(__MODULE__, :stats)
  end

  @impl true
  def init(:ok) do
    {:ok, %{count: 0}}
  end

  @impl true
  def handle_call({:deliver, _payload}, _from, state) do
    updated_state = %{state | count: state.count + 1}
    {:reply, {:ok, @response}, updated_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast(:reset, _state) do
    {:noreply, %{count: 0}}
  end
end

defmodule Bench.Helper do
  @moduledoc """
  Helper functions for performance benchmarks.
  Provides realistic user simulation, query counting utilities, and standardized data setup.

  Key features:
  - One-time database setup to avoid repeated overhead
  - Realistic but manageable dataset sizes
  - Cache warming for accurate performance measurement
  - Telemetry-based query counting for optimization insights
  """

  alias Fleetlm.Conversation
  alias Fleetlm.Conversation.Participants
  alias Fleetlm.Agent

  # Automatically disable debug logging when this module is loaded
  require Logger
  Logger.configure(level: :info)

  # Standard dataset sizes for consistent benchmarks
  @default_agent_count 8
  @default_human_count 15
  @default_session_count 20
  @default_messages_per_session 3

  @doc """
  Creates realistic test participants (humans and agents).
  """
  def create_participants(count, type \\ :human) do
    Enum.map(1..count, fn i ->
      case type do
        :human ->
          id = "user:bench_human_#{i}_#{:rand.uniform(999_999)}"

          {:ok, _participant} =
            Participants.upsert_participant(%{id: id, kind: "user", display_name: id})

          id

        :agent ->
          id = "agent:bench_bot_#{i}_#{:rand.uniform(999_999)}"
          # Create agent with endpoint
          {:ok, result} =
            Agent.upsert_agent(%{
              id: id,
              name: id,
              endpoint: %{
                origin_url: "http://localhost:#{4000 + i}/webhook",
                headers: %{"Authorization" => "Bearer test_token"}
              }
            })

          result.participant.id
      end
    end)
  end

  @doc """
  Creates realistic conversation sessions between participants.
  """
  def create_sessions(participants, session_count) do
    Enum.map(1..session_count, fn _i ->
      [initiator, peer] = Enum.take_random(participants, 2)

      {:ok, session} =
        Conversation.start_session(%{
          initiator_id: initiator,
          peer_id: peer
        })

      session
    end)
  end

  @doc """
  Simulates realistic message sending patterns.
  """
  def send_message_burst(session, sender_id, message_count \\ 5) do
    Enum.map(1..message_count, fn i ->
      {:ok, message} =
        Conversation.append_message(session.id, %{
          sender_id: sender_id,
          kind: "text",
          content: %{text: "Benchmark message #{i} at #{DateTime.utc_now()}"}
        })

      message
    end)
  end

  @doc """
  Counts database queries during function execution using telemetry.
  """
  def count_queries(fun) when is_function(fun, 0) do
    query_count = :counters.new(1, [])

    # Attach telemetry handler with named function
    handler_id = "bench_query_counter_#{:rand.uniform(999_999)}"

    :telemetry.attach(
      handler_id,
      [:fleetlm, :repo, :query],
      &__MODULE__.handle_query_telemetry/4,
      query_count
    )

    try do
      result = fun.()
      queries = :counters.get(query_count, 1)
      {result, queries}
    after
      :telemetry.detach(handler_id)
    end
  end

  @doc false
  def handle_query_telemetry(_event, _measurements, _metadata, query_count) do
    :counters.add(query_count, 1, 1)
  end

  @doc """
  Measures memory usage during function execution.
  """
  def measure_memory(fun) when is_function(fun, 0) do
    {:memory, memory_before} = :erlang.process_info(self(), :memory)
    result = fun.()
    {:memory, memory_after} = :erlang.process_info(self(), :memory)
    memory_used = memory_after - memory_before
    {result, memory_used}
  end

  @doc """
  Simulates concurrent user activity with simplified approach.
  """
  def concurrent_workload(participants, sessions, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, 10)
    operations_per_task = Keyword.get(opts, :operations_per_task, 5)

    1..concurrency
    |> Task.async_stream(
      fn _ ->
        simulate_user_activity(participants, sessions, operations_per_task)
      end,
      timeout: :infinity,
      max_concurrency: concurrency
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp simulate_user_activity(participants, sessions, operation_count) do
    Enum.map(1..operation_count, fn _i ->
      participant = Enum.random(participants)
      session = Enum.random(sessions)

      # Simulate different types of activity
      case :rand.uniform(3) do
        1 ->
          # Check inbox
          Conversation.get_inbox_snapshot(participant, limit: 5)

        2 ->
          # Send message if participant is in session
          if participant in [session.initiator_id, session.peer_id] do
            try do
              Conversation.append_message(session.id, %{
                sender_id: participant,
                kind: "text",
                content: %{text: "Activity message"}
              })
            catch
              _, _ -> :error
            end
          else
            :skipped
          end

        3 ->
          # Mark messages as read
          if participant in [session.initiator_id, session.peer_id] do
            try do
              Conversation.mark_read(session.id, participant)
            catch
              _, _ -> :error
            end
          else
            :skipped
          end
      end
    end)
  end

  @doc """
  Setup database once for all benchmarks.
  """
  def global_setup do
    # Start the application
    {:ok, _} = Application.ensure_all_started(:fleetlm)

    # Route agent dispatcher and webhook deliveries through the in-memory mock
    {:ok, receiver_pid} = Bench.MockWebhookReceiver.ensure_started()
    Bench.MockWebhookReceiver.reset()

    Application.put_env(:fleetlm, :agent_dispatcher, %{mode: :test, pid: receiver_pid})

    Application.put_env(:fleetlm, :webhook_delivery, %{
      mode: :mock,
      module: Bench.MockWebhookReceiver
    })

    # Setup database for testing - only once
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])

    cleanup()
  end

  @doc """
  Create standardized test data with configurable sizes.
  """
  def create_standard_test_data(opts \\ []) do
    agent_count = Keyword.get(opts, :agents, @default_agent_count)
    human_count = Keyword.get(opts, :humans, @default_human_count)
    session_count = Keyword.get(opts, :sessions, @default_session_count)
    messages_per_session = Keyword.get(opts, :messages_per_session, @default_messages_per_session)
    warm_caches = Keyword.get(opts, :warm_caches, true)

    # Create participants
    agents = create_participants(agent_count, :agent)
    humans = create_participants(human_count, :human)
    all_participants = agents ++ humans

    # Create sessions between participants
    sessions = create_sessions(all_participants, session_count)

    # Pre-populate with realistic message history
    Enum.each(sessions, fn session ->
      message_count = :rand.uniform(messages_per_session) + 1

      Enum.each(1..message_count, fn _i ->
        sender = if :rand.uniform(2) == 1, do: session.initiator_id, else: session.peer_id
        send_message_burst(session, sender, 1)
      end)
    end)

    # Optionally warm up caches for realistic performance measurement
    if warm_caches do
      Enum.each(agents ++ humans, fn participant ->
        Conversation.get_inbox_snapshot(participant, limit: 20)
      end)
    end

    %{
      agents: agents,
      humans: humans,
      sessions: sessions,
      all_participants: all_participants,
      config: %{
        agent_count: agent_count,
        human_count: human_count,
        session_count: session_count,
        messages_per_session: messages_per_session
      }
    }
  end

  @doc """
  Create lightweight test data for quick benchmarks.
  """
  def create_lightweight_test_data do
    create_standard_test_data(
      agents: 3,
      humans: 5,
      sessions: 8,
      messages_per_session: 2,
      warm_caches: true
    )
  end

  @doc """
  Create heavy test data for stress testing.
  """
  def create_heavy_test_data do
    create_standard_test_data(
      agents: 15,
      humans: 30,
      sessions: 50,
      messages_per_session: 5,
      warm_caches: false
    )
  end

  @doc """
  Clean up test data.
  """
  def cleanup do
    # Clear caches
    Cachex.clear(:fleetlm_session_tails)
    Cachex.clear(:fleetlm_session_inboxes)
  end

  @doc """
  Reset database for clean state between major benchmark runs.
  """
  def reset_database do
    Mix.Task.run("ecto.drop", ["--quiet"])
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
  end

  @doc """
  Run a standardized benchmark with consistent configuration.
  """
  def run_benchmark(name, scenarios, opts \\ []) do
    time = Keyword.get(opts, :time, 3)
    memory_time = Keyword.get(opts, :memory_time, 1)
    warmup = Keyword.get(opts, :warmup, 1)
    formatters = Keyword.get(opts, :formatters, [Benchee.Formatters.Console])

    IO.puts("🚀 Running #{name} benchmarks...")

    Benchee.run(
      scenarios,
      time: time,
      memory_time: memory_time,
      warmup: warmup,
      formatters: formatters,
      print: [
        benchmarking: true,
        fast_warning: false
      ],
      before_each: fn input ->
        # Small cleanup between iterations
        :timer.sleep(5)
        input
      end
    )

    IO.puts("✅ #{name} benchmarks complete!")
  end

  @doc """
  Benchmark function with query counting for optimization insights.
  """
  def benchmark_with_queries(name, fun) when is_function(fun, 0) do
    {time_us, {result, queries}} =
      :timer.tc(fn ->
        count_queries(fun)
      end)

    time_ms = time_us / 1000

    IO.puts("📊 #{name}:")
    IO.puts("   Time: #{Float.round(time_ms, 2)}ms")
    IO.puts("   Queries: #{queries}")
    if is_list(result), do: IO.puts("   Results: #{length(result)} items")

    {time_ms, queries, result}
  end

  @doc """
  Disable debug logging for cleaner benchmark output.
  """
  def disable_debug_logs do
    Logger.configure(level: :info)
  end

  @doc """
  Re-enable debug logging after benchmarks.
  """
  def enable_debug_logs do
    Logger.configure(level: :debug)
  end
end

#!/usr/bin/env elixir

defmodule BenchmarkRunner do
  @moduledoc """
  Master benchmark runner for FleetLM performance tests.

  Usage:
    mix run bench/run_all.exs                      # Run all benchmarks with standard datasets
    mix run bench/run_all.exs --agent             # Run only agent benchmarks
    mix run bench/run_all.exs --participant       # Run only participant benchmarks
    mix run bench/run_all.exs --light             # Run with lightweight datasets
    mix run bench/run_all.exs --heavy             # Run with heavy datasets for stress testing
    mix run bench/run_all.exs --analysis          # Run query analysis instead of performance tests
    mix run bench/run_all.exs --quick             # Quick run with minimal time

  Examples:
    mix run bench/run_all.exs --agent --light --analysis
    mix run bench/run_all.exs --participant --heavy
    mix run bench/run_all.exs --quick
  """

  def main(args \\ []) do
    {opts, _args, _invalid} = OptionParser.parse(args,
      switches: [
        agent: :boolean,
        participant: :boolean,
        light: :boolean,
        heavy: :boolean,
        analysis: :boolean,
        quick: :boolean,
        help: :boolean
      ],
      aliases: [h: :help]
    )

    if opts[:help] do
      print_help()
    else
      run_benchmarks(opts)
    end
  end

  defp run_benchmarks(opts) do
    IO.puts("🚀 FleetLM Performance Benchmark Suite")
    IO.puts("======================================")

    dataset = determine_dataset(opts)
    benchmark_type = determine_benchmark_type(opts)
    analysis_mode = opts[:analysis] || false
    quick_mode = opts[:quick] || false

    IO.puts("Configuration:")
    IO.puts("  Dataset: #{dataset}")
    IO.puts("  Type: #{benchmark_type}")
    IO.puts("  Mode: #{if analysis_mode, do: "Query Analysis", else: "Performance Testing"}")
    IO.puts("  Speed: #{if quick_mode, do: "Quick", else: "Standard"}")
    IO.puts("")

    # Ensure dependencies are available
    {:ok, _} = Application.ensure_all_started(:benchee)

    # Create results directory
    File.mkdir_p!("bench/results")

    # Setup database once for all benchmarks
    IO.puts("🗄️  Setting up database...")
    Code.eval_file("bench/support/bench_helper.exs")
    Bench.Helper.global_setup()
    IO.puts("✅ Database ready")
    IO.puts("")

    case benchmark_type do
      :all -> run_all_benchmarks(dataset, analysis_mode, quick_mode)
      :agent -> run_agent_benchmarks(dataset, analysis_mode, quick_mode)
      :participant -> run_participant_benchmarks(dataset, analysis_mode, quick_mode)
    end

    print_completion_summary()
  end

  defp determine_dataset(opts) do
    cond do
      opts[:light] -> "light"
      opts[:heavy] -> "heavy"
      true -> "standard"
    end
  end

  defp determine_benchmark_type(opts) do
    cond do
      opts[:agent] -> :agent
      opts[:participant] -> :participant
      true -> :all
    end
  end

  defp run_all_benchmarks(dataset, analysis_mode, quick_mode) do
    IO.puts("🎯 Running ALL performance benchmarks...")
    IO.puts("This will take approximately #{estimate_time(analysis_mode, quick_mode)} minutes...\n")

    run_agent_benchmarks(dataset, analysis_mode, quick_mode)
    wait_between_suites()

    run_participant_benchmarks(dataset, analysis_mode, quick_mode)
  end

  defp run_agent_benchmarks(dataset, analysis_mode, quick_mode) do
    IO.puts("🤖 Running Agent Workload Benchmarks...")

    args = build_args(dataset, analysis_mode, quick_mode)
    {result, _exit_code} = System.cmd("mix", ["run", "bench/agent_workload_bench.exs"] ++ args)
    IO.puts(result)
  end

  defp run_participant_benchmarks(dataset, analysis_mode, quick_mode) do
    IO.puts("👥 Running Participant Workload Benchmarks...")

    args = build_args(dataset, analysis_mode, quick_mode)
    extra_args = if analysis_mode do
      ["--analysis"]
    else
      []
    end

    {result, _exit_code} = System.cmd("mix", ["run", "bench/participant_workload_bench.exs"] ++ args ++ extra_args)
    IO.puts(result)
  end

  defp build_args(dataset, analysis_mode, _quick_mode) do
    args = []

    args = if dataset != "standard" do
      ["--dataset", dataset] ++ args
    else
      args
    end

    args = if analysis_mode do
      ["--analysis"] ++ args
    else
      args
    end

    args
  end

  defp wait_between_suites do
    IO.puts("⏸️  Waiting 10 seconds between benchmark suites...\n")
    :timer.sleep(10_000)
  end

  defp estimate_time(analysis_mode, quick_mode) do
    base_time = if analysis_mode, do: 2, else: 8
    multiplier = if quick_mode, do: 0.5, else: 1.0
    Float.round(base_time * multiplier, 1)
  end

  defp print_completion_summary do
    IO.puts("\n🎉 All benchmarks complete!")
    IO.puts("📊 Results have been displayed above")
    IO.puts("💡 Tips:")
    IO.puts("   • Run with --analysis to see query counts and identify optimization opportunities")
    IO.puts("   • Use --light for quick testing or --heavy for stress testing")
    IO.puts("   • Individual benchmarks can be run directly:")
    IO.puts("     mix run bench/agent_workload_bench.exs --dataset light --analysis")
    IO.puts("     mix run bench/participant_workload_bench.exs --scalability")
  end

  defp print_help do
    IO.puts("""
    FleetLM Performance Benchmark Suite

    A comprehensive benchmarking system for testing FleetLM's performance across
    different workloads and scenarios.

    USAGE:
      mix run bench/run_all.exs [OPTIONS]

    OPTIONS:
      --agent         Run agent workload benchmarks only
      --participant   Run participant workload benchmarks only
      --light         Use lightweight datasets (faster, smaller scale)
      --heavy         Use heavy datasets (stress testing, larger scale)
      --analysis      Run query analysis instead of performance benchmarks
      --quick         Quick run with reduced benchmark time
      --help, -h      Show this help message

    DATASETS:
      light     - 3 agents, 5 humans, 8 sessions (quick testing)
      standard  - 8 agents, 15 humans, 20 sessions (realistic load)
      heavy     - 15 agents, 30 humans, 50 sessions (stress testing)

    EXAMPLES:
      mix run bench/run_all.exs
        Run all benchmarks with standard datasets

      mix run bench/run_all.exs --agent --light
        Run only agent benchmarks with lightweight data

      mix run bench/run_all.exs --participant --analysis
        Run participant workload query analysis

      mix run bench/run_all.exs --heavy
        Run all benchmarks with heavy datasets for stress testing

    INDIVIDUAL BENCHMARKS:
      mix run bench/agent_workload_bench.exs --help
      mix run bench/participant_workload_bench.exs --help

    Results are displayed in the console. For detailed analysis, use the --analysis flag
    to see database query counts and identify optimization opportunities.
    """)
  end
end

# Run if called directly
BenchmarkRunner.main(System.argv())
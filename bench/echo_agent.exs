#!/usr/bin/env elixir
#
# FleetLM Echo Agent - High-Performance Benchmark Agent
#
# An HTTP server that responds to FleetLM webhooks with pre-encoded responses.
# Optimized to remove agent-side bottlenecks for measuring FleetLM's raw capacity.
#
# Optimizations:
# - No request logging (major bottleneck at high volume)
# - Pre-encoded JSON responses (zero encoding per request)
# - Minimal parsing and validation
# - Static response (no string interpolation or map building)
# - Multi-threaded Bandit server with tuned connection pool
# - Uses all available CPU cores (2x schedulers as acceptors)
#
# Usage:
#   mix run --no-halt bench/echo_agent.exs
#   PORT=4001 mix run --no-halt bench/echo_agent.exs
#

defmodule BenchEchoAgent do
  @moduledoc """
  High-performance echo agent for load testing.
  Optimized for maximum throughput with minimal overhead.
  """

  use Plug.Router

  # NO LOGGING - major bottleneck at high volume
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  # Pre-encode the health response once
  @health_response Jason.encode!(%{status: "ok", agent: "bench-echo-agent"})

  # Static echo response template
  @echo_response Jason.encode!(%{
    kind: "text",
    content: %{text: "ack"},
    metadata: %{bench: true}
  }) <> "\n"

  get "/health" do
    send_resp(conn, 200, @health_response)
  end

  post "/webhook" do
    # Skip all parsing and validation - just return immediate ack
    # This measures FleetLM's raw capacity without agent overhead
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, @echo_response)
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end
end

# Start the server
port = String.to_integer(System.get_env("PORT", "4001"))

IO.puts("FleetLM Echo Agent (HIGH PERFORMANCE MODE)")
IO.puts("===========================================")
IO.puts("Agent listening on http://localhost:#{port}")
IO.puts("Webhook endpoint: http://localhost:#{port}/webhook")
IO.puts("Health check: http://localhost:#{port}/health")
IO.puts("")
IO.puts("Optimizations enabled:")
IO.puts("  ✓ No request logging")
IO.puts("  ✓ Pre-encoded responses")
IO.puts("  ✓ Minimal parsing")
IO.puts("  ✓ Multi-threaded server")
IO.puts("")

{:ok, _} =
  Bandit.start_link(
    plug: BenchEchoAgent,
    scheme: :http,
    port: port,
    # Performance tuning: use all CPU cores for accepting connections
    thousand_island_options: [
      num_acceptors: System.schedulers_online() * 2
    ]
  )

IO.puts("Performance settings:")
IO.puts("  → #{System.schedulers_online()} CPU cores available")
IO.puts("  → #{System.schedulers_online() * 2} acceptor processes")
IO.puts("")

# Keep the process alive
Process.sleep(:infinity)

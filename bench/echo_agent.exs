#!/usr/bin/env elixir
#
# FleetLM Echo Agent - Simple benchmark agent
#
# A minimal HTTP server that responds to FleetLM webhooks with immediate echo responses.
# Designed for benchmarking with minimal agent-side latency.
#
# Usage:
#   mix run --no-halt bench/echo_agent.exs
#   PORT=4001 mix run --no-halt bench/echo_agent.exs
#

defmodule BenchEchoAgent do
  @moduledoc """
  Simple echo agent for load testing.
  Returns immediate responses with minimal processing overhead.
  """

  use Plug.Router

  plug(Plug.Logger)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok", agent: "bench-echo-agent"}))
  end

  post "/webhook" do
    %{
      "session_id" => session_id,
      "agent_id" => _agent_id,
      "user_id" => user_id,
      "messages" => messages
    } = conn.body_params

    last_message = List.last(messages)

    # Generate echo response
    response = build_echo_response(last_message, user_id, session_id)

    # Return JSONL response
    jsonl = Jason.encode!(response) <> "\n"

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, jsonl)
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp build_echo_response(%{"content" => content} = msg, user_id, session_id) do
    text =
      case content do
        %{"text" => t} when is_binary(t) ->
          "Echo: #{t}"

        other ->
          "Echo: #{inspect(other)}"
      end

    # Preserve client_ref if present for latency tracking
    base_content = %{text: text}

    content_with_ref =
      case content do
        %{"client_ref" => ref} -> Map.put(base_content, :client_ref, ref)
        _ -> base_content
      end

    %{
      kind: "text",
      content: content_with_ref,
      metadata: %{
        echoed_seq: msg["seq"],
        session_id: session_id,
        user_id: user_id
      }
    }
  end
end

# Start the server
port = String.to_integer(System.get_env("PORT", "4001"))

IO.puts("FleetLM Echo Agent")
IO.puts("==================")
IO.puts("Agent listening on http://localhost:#{port}")
IO.puts("Webhook endpoint: http://localhost:#{port}/webhook")
IO.puts("Health check: http://localhost:#{port}/health")
IO.puts("")
IO.puts("Waiting for webhooks from FleetLM...")
IO.puts("")

{:ok, _} =
  Bandit.start_link(
    plug: BenchEchoAgent,
    scheme: :http,
    port: port
  )

# Keep the process alive
Process.sleep(:infinity)
